#!/bin/bash
# Installs Sermon Captions, or updates it, from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/Shakes63/sermon-captions/main/install.sh | bash
# curl doesn't mark the download as quarantined, so macOS opens the app
# without the "can't check it for malicious software" block.
set -euo pipefail
URL=https://github.com/Shakes63/sermon-captions/releases/latest/download/Sermon-Captions.zip
APP="$HOME/Applications/Sermon Captions.app"

[ "$(uname -m)" = arm64 ] || { echo "Sermon Captions needs a Mac with Apple silicon."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "Sermon Captions needs macOS 14 or newer."; exit 1; }
if pgrep -xq SermonCaptions; then
  echo "Quit Sermon Captions first, then run this again."
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Sermon Captions (about 1 GB)..."
curl -fL --progress-bar "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
[ -d "$TMP/Sermon Captions.app" ] || { echo "The download didn't contain the app. Nothing was changed."; exit 1; }

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$TMP/Sermon Captions.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed Sermon Captions $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") in $HOME/Applications."
