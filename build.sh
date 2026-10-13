#!/bin/bash
# Builds "Sermon Captions.app" into ~/Applications. Run on the Mac.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Sermon Captions.app"
VERSION=$(cat VERSION)
# Build number: how many commits the source has, so every release goes up.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
BUILD=$(mktemp -d)
mkdir -p "$BUILD/App.app/Contents/MacOS" "$BUILD/App.app/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
  SermonCaptions.swift TrimEditor.swift AutoColor.swift Preview.swift -o "$BUILD/App.app/Contents/MacOS/SermonCaptions"
[ -x vendor/bin/whisper-cli ] && [ -f vendor/models/htdemucs.safetensors ] || { echo "run ./vendor.sh first"; exit 1; }
cp sermon_captions.py AppIcon.icns "$BUILD/App.app/Contents/Resources/"
cp -R vendor/bin vendor/python vendor/models "$BUILD/App.app/Contents/Resources/"
# Precompile so Python never writes into the signed bundle at run time.
"$BUILD/App.app/Contents/Resources/python/bin/python3" -m compileall -q -j 0 \
  "$BUILD/App.app/Contents/Resources/python/lib" >/dev/null 2>&1 || true
# Every Mach-O inside must be signed (ad hoc is enough) for Apple Silicon.
find "$BUILD/App.app/Contents/Resources" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 |
  while IFS= read -r -d "" f; do
    if file -b "$f" | grep -q Mach-O; then codesign --force --sign - "$f" 2>/dev/null; fi
  done
cat > "$BUILD/App.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sermon Captions</string>
  <key>CFBundleDisplayName</key><string>Sermon Captions</string>
  <key>CFBundleIdentifier</key><string>com.hrc.sermoncaptions</string>
  <key>CFBundleExecutable</key><string>SermonCaptions</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$BUILD/App.app"
rm -rf "$APP"
mkdir -p "$HOME/Applications"
mv "$BUILD/App.app" "$APP"
# Make Finder and the Dock pick up a changed icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
rm -rf "$BUILD"
echo "built $APP (version $VERSION, build $BUILD_NUMBER)"
