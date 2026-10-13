#!/bin/bash
# Builds the app from a clean checkout and zips it as dist/Sermon-Captions.zip
# for a GitHub release. Run on the Mac after bumping VERSION and committing.
set -euo pipefail
cd "$(dirname "$0")"
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first"; exit 1; }
VERSION=$(cat VERSION)
./build.sh
mkdir -p dist
rm -f dist/Sermon-Captions.zip
ditto -c -k --keepParent "$HOME/Applications/Sermon Captions.app" dist/Sermon-Captions.zip
ls -lh dist/Sermon-Captions.zip
echo "Next: tag v$VERSION and upload dist/Sermon-Captions.zip to a GitHub release with that tag."
