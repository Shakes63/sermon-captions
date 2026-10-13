#!/bin/bash
# Rebuilds AppIcon.icns from icon.svg (full-bleed artwork). Run on the Mac.
# icon-mask.swift cuts it to Apple's rounded-square shape so macOS 26+ doesn't
# put it inside a gray tile.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
qlmanage -t -s 1024 -o "$T" icon.svg >/dev/null 2>&1
swift icon-mask.swift "$T/icon.svg.png" "$T/icon.png"
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
rm -rf "$T"
echo "made AppIcon.icns"
