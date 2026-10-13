# Sermon Captions

A Mac app for HighRidge Church's Spanish sermon videos. It trims the service
video from Subsplash down to the sermon, writes English captions (an SRT file)
to upload to HeyGen, and burns those English captions onto the Spanish video
HeyGen sends back. HeyGen's Spanish runs about 8% longer than the English and
drifts as it goes, so the app retimes every caption to match the Spanish video
before burning it in.

It needs a Mac with Apple silicon and macOS 14 or newer.

## Install or update

Quit the app if it's open, then paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Shakes63/sermon-captions/main/install.sh | bash
```

That downloads the latest version (about 1 GB) and puts it in your home
folder's Applications folder, replacing the old copy. Your sermons and
settings stay where they are. The version number is in the bottom left of the
app's window.

You can also download `Sermon-Captions.zip` from the
[releases page](https://github.com/Shakes63/sermon-captions/releases). macOS
blocks apps downloaded in a browser unless they come from a registered Apple
developer, so you'd need to run this once after unzipping:

```sh
xattr -dr com.apple.quarantine ~/Applications/"Sermon Captions.app"
```

The first time you make captions, the app downloads a 1.6 GB speech model.
"Repair the voice" downloads another 680 MB the first time you turn it on.

## Where things go

- Each sermon gets a folder in `~/Movies/Sermon Captions/`, named after the English video.
- The speech models live in `~/Library/Application Support/Sermon Captions/`.
- Music removal and voice repair save their work in `~/Library/Caches/Sermon Captions/`, so a second save of the same sermon is quick.

## Building it

Builds run on a Mac with the Xcode command line tools.

```sh
./vendor.sh     # once: fetches ffmpeg, whisper-cli, Python, PyTorch, Demucs and the models into vendor/
./build.sh      # builds ~/Applications/Sermon Captions.app
```

`vendor/` is about 950 MB and stays out of git.

The app is SwiftUI (`SermonCaptions.swift`, `TrimEditor.swift`, `Preview.swift`,
`AutoColor.swift`). The real work happens in `sermon_captions.py`, which the
app runs with its own bundled Python. The icon comes from `icon.svg`, and
`./make-icon.sh` turns it into `AppIcon.icns`.

## Releasing a new version

1. Raise the number in `VERSION`. Bump the last digit for fixes, the middle one for new features.
2. Commit and push.
3. On the build Mac, run `./release.sh`. It builds from the clean checkout and writes `dist/Sermon-Captions.zip`.
4. Make a GitHub release tagged `v` plus the version (for example `v1.0.1`), with `Sermon-Captions.zip` attached under exactly that name. The install command always fetches the newest release's file by that name.

The app doesn't check for updates. To update, run the install command again.
