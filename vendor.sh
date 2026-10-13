#!/bin/bash
# Fetches everything the app bundles into ./vendor: ffmpeg + ffprobe (static
# arm64), a standalone Python with numpy, torch and demucs (for taking music
# out from under speech) plus the demucs model, Resemble Enhance (repairing
# his voice), and a static whisper-cli built
# without CPU tuning so it runs on any Apple Silicon Mac. Run on a Mac with
# the Xcode command line tools. Only needed once, or to update a version.
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG_ZIPS="https://www.osxexperts.net/ffmpeg9arm.zip https://www.osxexperts.net/ffprobe9arm.zip"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261009/cpython-3.12.15%2B20261009-aarch64-apple-darwin-install_only_stripped.tar.gz"
WHISPER_TAG=v1.9.5
# htdemucs. demucs' own loader would fetch this from the HuggingFace hub.
DEMUCS_URL="https://huggingface.co/adefossez/HTDemucs/resolve/main/955717e8.safetensors"
DEMUCS_SHA256=d9fa14133cfcc034a6758923bb3a8ca9f8dfd0b582134643bbf83f72c17576dd

rm -rf vendor && mkdir -p vendor/bin vendor/models && cd vendor

# Static builds with libass (needed to burn in captions) and VideoToolbox.
for url in $FFMPEG_ZIPS; do
  curl -fsSL -o tool.zip "$url"
  unzip -qo tool.zip -x "__MACOSX/*" -d bin && rm tool.zip
done
xattr -cr bin
# (capture first: with pipefail, grep -q closing the pipe early fails the check)
filters=$(bin/ffmpeg -hide_banner -filters); encoders=$(bin/ffmpeg -hide_banner -encoders)
grep -q " subtitles " <<<"$filters" || { echo "ffmpeg lacks the subtitles filter"; exit 1; }
grep -q h264_videotoolbox <<<"$encoders" || { echo "ffmpeg lacks h264_videotoolbox"; exit 1; }

curl -fsSL -o py.tgz "$PY_URL" && tar xzf py.tgz && rm py.tgz
python/bin/python3 -m pip -q install --no-warn-script-location --disable-pip-version-check numpy
# Only what separating needs: --no-deps skips torchaudio, sympy, the
# HuggingFace client and the rest of demucs' command-line extras.
python/bin/python3 -m pip -q install --no-warn-script-location --disable-pip-version-check --no-deps \
  torch==2.14.1 demucs==4.1.0 julius==0.2.8 einops==0.8.2 pyyaml==6.0.3 tqdm==4.70.1 \
  safetensors==0.8.0 typing_extensions==4.16.0
# Resemble Enhance for "Repair the voice": its model code and what that
# needs at run time (its training-only imports get stand-ins in
# sermon_captions.py). The model itself downloads on first use.
python/bin/python3 -m pip -q install --no-warn-script-location --disable-pip-version-check --no-deps \
  resemble-enhance==0.0.1 torchaudio==2.11.0 omegaconf==2.4.0 rich==15.0.0 markdown-it-py==4.2.0 \
  mdurl==0.1.2 pygments==2.21.0 scipy==1.18.1
rm -rf python/lib/python3.12/site-packages/torch/include
curl -fsSL -o models/htdemucs.safetensors "$DEMUCS_URL"
echo "$DEMUCS_SHA256  models/htdemucs.safetensors" | shasum -a 256 -c --quiet

# Build whisper-cli with a throwaway cmake so nothing gets installed system-wide.
python/bin/python3 -m venv ../.build-venv
../.build-venv/bin/pip -q install --disable-pip-version-check cmake
git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp ../.whisper-src
# Use the SDK's C++ headers by name: a stale, nearly empty c++/v1 folder left
# in some Command Line Tools installs otherwise hides them ('array' not found).
SDK=$(xcrun --sdk macosx --show-sdk-path)
../.build-venv/bin/cmake -S ../.whisper-src -B ../.whisper-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_CXX_FLAGS="-nostdinc++ -isystem $SDK/usr/include/c++/v1" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_SDL2=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
../.build-venv/bin/cmake --build ../.whisper-build -j --config Release --target whisper-cli >/dev/null
cp ../.whisper-build/bin/whisper-cli bin/
rm -rf ../.build-venv ../.whisper-src ../.whisper-build

xattr -cr .
echo "Non-system libraries linked (should be none):"
for f in bin/*; do otool -L "$f" | tail -n +2 | grep -vE "/System/Library|/usr/lib" || true; done
du -sh bin python models
