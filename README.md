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

That downloads the latest version (about 330 MB) and puts it in your home
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

## Intro and outro

The trim editor can add a video before the sermon (an intro) or after it (an
outro), like a testimony or a closing slide. They go in as they are, with a
straight cut, sized and paced to match the sermon. With Even out the volume on,
they're brought to the same loudness too. A new sermon starts with whichever
intro and outro you used last, so a weekly one only has to be chosen once.

Anything said in an intro or outro gets English captions too.

## Where things go

- Each sermon gets a folder in `~/Movies/Sermon Captions/`, named after the English video.
- The speech models live in `~/Library/Application Support/Sermon Captions/`.
- Music removal, voice repair and Auto color save their work in `~/Library/Caches/Sermon Captions/`, so a second save of the same sermon is quick. When the app opens, it deletes anything there that hasn't been used in a month.

## Copying to ProPresenter

Step 3 can copy the finished Spanish video straight to the ProPresenter Mac,
into its `Movies/Spanish sermons` folder. It goes over the church network
when you're there, and over Tailscale when you're not. The checkbox and the
Copy to ProPresenter button only show up on a Mac that's been set up for it.

Step 2 has its own checkbox and button for when you trim on one Mac and
finish on the ProPresenter Mac. They copy the trimmed video and its English
captions into the same sermon folder there, under `Movies/Sermon Captions`.
On the ProPresenter Mac, drop that video into step 2 and the captions come
with it, so step 3 is ready to go. This one is off unless you turn it on,
since a trimmed video is a few gigabytes.

Setting up a Mac gives that copy of the app its own SSH key, kept in
`~/Library/Application Support/Sermon Captions/ProPresenter/` with a
`config.json` that says where the ProPresenter Mac is. On the ProPresenter
Mac, that key can only run `propresenter-receive.sh`, which saves one video
or caption file into one of those folders and does nothing else. Jacob has the setup script, since it
names the church's machines.

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
