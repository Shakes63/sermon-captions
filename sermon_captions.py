#!/usr/bin/env python3
"""Backend for Sermon Captions.app.

  sermon_captions.py trim [--captions OUT.srt] [--repair VOICE.wav FROM] VIDEO OUT.mp4 START LENGTH FADE LEVEL LOOK.cube [MUSIC.wav AT AMOUNT]...
      Cut VIDEO to LENGTH seconds from START (frame-accurate re-encode).
      With --captions, also writes the trimmed video's English captions,
      made at the same time from the same stretch of VIDEO.
      FADE=1 adds a 1-second fade in and out (picture and sound). LEVEL (or -)
      evens out the volume: the change in dB the app measured to bring the
      kept part to -16 LUFS, with a limiter for the peaks. LOOK.cube
      (or -) is the Auto color table the app made. Each MUSIC.wav
      (from `separate`, starting AT samples into the audio at 48 kHz) is
      mixed in at AMOUNT: 1 takes the music out completely, 0.75 turns it
      down by 12 dB.

  sermon_captions.py repair VIDEO START LENGTH OUT.wav [MUSIC.wav AT AMOUNT]...
      Rebuild his voice with Resemble Enhance (an AI speech restorer) for
      LENGTH seconds from START, after the music choices: undoes the crunch
      of the booth's limiter. Mono 44.1 kHz; OUT.wav.ref as for separate.
      The model (680 MB) downloads on first use.

  sermon_captions.py separate VIDEO FROM TO OUT.wav [FROM TO OUT.wav]...
      Split the speech from the music between samples FROM and TO of VIDEO's
      audio (at 48 kHz) and write OUT.wav: minus the music, faded in and out
      over a second at each end, so adding it to the original audio leaves
      just the voice. OUT.wav.ref holds the loudest second of the original
      (int64 sample position, then 48000 mono float32 samples).

  sermon_captions.py suggest VIDEO OUT.json
      Find the sermon in the untrimmed service from the sound, transcribe
      the parts around where it starts and ends, and suggest
      where to start (the pause before his sign-on, "Welcome to the third
      service…") and end (after his sign-off, or the last pause before the
      band comes back in). Writes candidates, best first, each with its cut
      point (time), the edge of that pause (room), his first/last word
      (word), and the words it's based on (why).

  sermon_captions.py transcribe VIDEO OUT.srt
      English captions for the original video: Whisper, then cleanup
      (filler words, stuttered repeats, house spellings).

  sermon_captions.py spanish ORIGINAL SPANISH EN.srt OUT.srt OUT.mp4
      Retime EN.srt (timed to ORIGINAL) onto SPANISH, the HeyGen
      translation, by matching frames between the two videos, then burn
      the retimed captions into SPANISH.

  sermon_captions.py send VIDEO
  sermon_captions.py send --to FOLDER FILE...
      Copy the finished video to the ProPresenter Mac, as set up in
      ~/Library/Application Support/Sermon Captions/ProPresenter/, or a
      trimmed video and its captions into its sermon folder FOLDER.

Progress goes to stdout, one message per line, for the app to read:
  STAGE <text>   PROGRESS <0..1>   WARN <text>   NOTE <text>   ERROR <text>   DONE
"""
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time

# ffmpeg, ffprobe and whisper-cli ship in the app's Resources/bin, next to
# this script. The speech model is too big to ship; it downloads on first use.
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin")
FFMPEG = os.path.join(BIN, "ffmpeg")
FFPROBE = os.path.join(BIN, "ffprobe")
WHISPER = os.path.join(BIN, "whisper-cli")
MODEL = os.path.expanduser(
    "~/Library/Application Support/Sermon Captions/ggml-large-v3-turbo.bin")
MODEL_URL = ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
             "ggml-large-v3-turbo.bin")
# Demucs (htdemucs) for pulling music out from under speech; ships in
# Resources/models along with torch in the bundled Python.
MUSIC_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "models", "htdemucs.safetensors")
RATE = 48000            # music positions and the music file use this rate
# Resemble Enhance, for "Repair the voice". Downloaded on first use.
REPAIR_DIR = os.path.expanduser("~/Library/Application Support/Sermon Captions/resemble-enhance/enhancer_stage2")
REPAIR_URL = "https://huggingface.co/ResembleAI/resemble-enhance/resolve/main/enhancer_stage2/"
REPAIR_FILES = ["hparams.yaml", "ds/G/latest", "ds/G/default/mp_rank_00_model_states.pt"]
MUSIC_RAMP = 1.0        # seconds to fade the change in and out

WHISPER_PROMPT = "HighRidge Church sermon."
# A sample of the house style: names, and "He" and "His" for God. With it in
# mind throughout (--carry-initial-prompt), Whisper capitalizes the pronouns
# only where they mean God, but its timing gets coarse (often whole seconds).
# So captions come from a pass with the short prompt, and a second pass with
# this one only says which pronouns to capitalize. No Bible references in it:
# with "John 3:16" there, it once wrote a reference nobody said.
CAPTION_PROMPT = ("HighRidge Church sermon by Pastor Zach Gryder. God loves you, and He sent His Son. "
                  "Jesus said He is the way; follow Him. The pool of Bethesda. Not an iota. Bring the tithe. "
                  "Pastor Kyle Fischer, Grace Nguyen, Kaitlin, Miranda, Arrow.")
WORD_FIXES = [
    (r"\bHigh Ridge\b", "HighRidge"),
    (r"\bHighridge\b", "HighRidge"),
    (r"\bEspanol\b", "Español"),
    (r"\bHoward Church\b", "HighRidge Church"),
    (r"\bGr(?:i|ei|ey)der\b", "Gryder"),
    (r"\b(?:Caitlin|Caitlyn|Katelyn|Kaitlyn)\b", "Kaitlin"),
    (r"\b(?:aota|aoda)\b", "iota"),
]
BOOKS = {
    "genesis", "exodus", "leviticus", "numbers", "deuteronomy", "joshua", "judges", "ruth", "samuel",
    "kings", "chronicles", "ezra", "nehemiah", "esther", "job", "psalm", "psalms", "proverbs",
    "ecclesiastes", "isaiah", "jeremiah", "lamentations", "ezekiel", "daniel", "hosea", "joel", "amos",
    "obadiah", "jonah", "micah", "nahum", "habakkuk", "zephaniah", "haggai", "zechariah", "malachi",
    "matthew", "mark", "luke", "john", "acts", "romans", "corinthians", "galatians", "ephesians",
    "philippians", "colossians", "thessalonians", "timothy", "titus", "philemon", "hebrews", "james",
    "peter", "jude", "revelation", "revelations"}
ORDINALS = {"1": "1", "2": "2", "3": "3", "first": "1", "second": "2", "third": "3",
            "1st": "1", "2nd": "2", "3rd": "3"}
STYLE = ("FontName=Helvetica Neue,Bold=1,FontSize=18,BorderStyle=3,"
         "Outline=2,Shadow=0,BackColour=&H80000000,MarginV=28")

FILLERS = re.compile(r"(?i)(?<![\w'])(?:um+|uh+|erm|hmm+)(?![\w'])[,.]?\s*")
# Doubled with a comma ("on, on") is a stumble, unless the word is one
# people repeat for emphasis.
EMPHASIS = {"very", "no", "yes", "yeah", "so", "really", "oh", "much", "more",
            "far", "long", "over", "again", "go", "come", "now", "never",
            "please", "wait", "holy", "hallelujah", "amen", "ha", "okay",
            "right", "well", "bye", "hey", "good", "big", "little"}
# Doubled with no comma is only removed for words that are never correctly
# doubled ("in in", "is is", "that that" can all be real English).
STUTTER = {"the", "a", "an", "and", "i", "of", "but", "we", "they", "he",
           "she", "my", "our", "your", "you're", "i'm", "it's", "this"}

CHILDREN = []


def emit(kind, text=""):
    print(f"{kind} {text}".rstrip(), flush=True)


def on_term(signum, frame):
    for c in CHILDREN:
        if c.poll() is None:
            c.kill()
    sys.exit(130)


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)


class Progress:
    """Maps a stage's own 0..1 onto its slice of the overall bar."""

    def __init__(self):
        self.lo, self.hi, self.last = 0.0, 1.0, -1.0

    def stage(self, text, lo, hi):
        self.lo, self.hi, self.last = lo, hi, -1.0
        emit("STAGE", text)
        self.set(0.0)

    def set(self, frac):
        v = self.lo + (self.hi - self.lo) * min(max(frac, 0.0), 1.0)
        if v - self.last >= 0.002 or frac >= 1.0:
            self.last = v
            emit("PROGRESS", f"{v:.4f}")


P = Progress()


class Fail(Exception):
    pass


def fail(msg):
    raise Fail(msg)


def probe(path, entries, stream=None):
    cmd = [FFPROBE, "-v", "error"]
    if stream:
        cmd += ["-select_streams", stream]
    cmd += ["-show_entries", entries, "-of", "default=nw=1:nk=1", path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"Couldn't read {os.path.basename(path)}: {r.stderr.strip()[-300:]}")
    return r.stdout.strip()


def duration(path):
    try:
        return float(probe(path, "format=duration"))
    except ValueError:
        fail(f"Couldn't find the length of {os.path.basename(path)}.")


def ffmpeg(args, total, on_frac, cwd=None):
    """Run ffmpeg, reporting progress as a fraction of `total` seconds."""
    cmd = [FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error",
           "-progress", "pipe:1", "-nostats", *args]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, cwd=cwd)
    CHILDREN.append(p)
    err = []
    t = threading.Thread(target=lambda: err.extend(p.stderr), daemon=True)
    t.start()
    for line in p.stdout:
        if line.startswith("out_time_us="):
            try:
                on_frac(int(line.split("=", 1)[1]) / 1e6 / total)
            except ValueError:
                pass
    p.wait()
    t.join()
    if p.returncode != 0:
        fail("ffmpeg failed: " + "".join(err).strip()[-400:])
    on_frac(1.0)


# ---------------------------------------------------------------- transcribe

def download_model():
    """One-time download of the Whisper model, resumable via .partial."""
    download(MODEL_URL, MODEL, "speech model", P.set)


def download(url, dest, what, on_frac):
    """Download url to dest, resumable via .partial."""
    import urllib.request
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    partial = dest + ".partial"
    have = os.path.getsize(partial) if os.path.exists(partial) else 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            if have and r.status != 206:
                have = 0          # server ignored the range; start over
            total = have + int(r.headers.get("Content-Length", 0))
            with open(partial, "ab" if have else "wb") as f:
                done = have
                while chunk := r.read(1 << 20):
                    f.write(chunk)
                    done += len(chunk)
                    if total:
                        on_frac(done / total)
    except OSError as e:
        fail(f"Couldn't download the {what} ({e}). Check the internet "
             "connection and try again; it picks up where it left off.")
    if total and os.path.getsize(partial) != total:
        fail(f"The {what} download was cut short. Try again; it picks up where it left off.")
    os.replace(partial, dest)


def ensure_model():
    """Download the speech model if needed; returns where the rest of the
    progress bar starts."""
    if os.path.exists(MODEL):
        return 0.0
    P.stage("Downloading the speech model (one time only, 1.6 GB)…", 0.0, 0.5)
    download_model()
    return 0.5


def whisper(wav, out_base, max_len, extra=(), on_frac=None, captions=False):
    """Whisper to OUT_BASE.srt, reporting progress on the current stage
    (or to on_frac). CAPTIONS: with the house-style prompt."""
    on_frac = on_frac or P.set
    prompt = ["--prompt", CAPTION_PROMPT, "--carry-initial-prompt"] if captions else ["--prompt", WHISPER_PROMPT]
    cmd = [WHISPER, "-m", MODEL, "-f", wav, "-l", "en", "-osrt",
           "-of", out_base, "-ml", str(max_len), "-sow", "-pp", *prompt, *extra]
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, text=True)
    CHILDREN.append(p)
    tail = []
    for line in p.stderr:
        m = re.search(r"progress\s*=\s*(\d+)%", line)
        if m:
            on_frac(int(m.group(1)) / 100)
        tail = (tail + [line])[-20:]
    p.wait()
    if p.returncode != 0 or not os.path.exists(out_base + ".srt"):
        fail("Whisper failed: " + "".join(tail).strip()[-400:])
    return out_base + ".srt"


def transcribe(video, out_srt):
    for tool in (FFMPEG, WHISPER):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    total = duration(video)
    start = ensure_model()
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "audio.wav")
        P.stage("Pulling out the audio…", start, start + 0.04 * (1 - start))
        ffmpeg(["-i", video, "-map", "0:a:0", "-ar", "16000", "-ac", "1", wav],
               total, P.set)

        P.stage("Listening and writing captions…", start + 0.04 * (1 - start), 0.97)
        text = listen(wav, tmp, P.set)

        P.stage("Cleaning up…", 0.97, 1.0)
        text = clean_srt(text)
        write_atomic(out_srt, text)
        P.set(1.0)


def listen(wav, tmp, on_frac):
    """Captions for a 16 kHz WAV, before clean_srt: the words and timing from
    one pass, anything it skipped heard again, and "He"/"His" for God from a
    second pass with the house-style prompt."""
    raw = whisper(wav, os.path.join(tmp, "words"), 42, on_frac=lambda f: on_frac(0.5 * f))
    styled = whisper(wav, os.path.join(tmp, "style"), 42, on_frac=lambda f: on_frac(0.5 + 0.5 * f), captions=True)
    text = relisten(wav, open(raw, encoding="utf-8").read())
    return restyle(text, open(styled, encoding="utf-8").read())


def restyle(text, styled):
    """TEXT with he/him/his/himself capitalized wherever STYLED, the same
    speech written with the house style, capitalizes them. The pronouns in
    the two are lined up in order, one to one, by how many of the three words
    either side agree (said within 5 seconds of each other, and the closer
    the better), so a phrase said twice can't take the other's. Sentence
    starts don't count."""
    cues = parse_srt(text)
    mine = [(ci, li, wi, w) for ci, (_, lines) in enumerate(cues) for li, line in enumerate(lines)
            for wi, w in enumerate(line.split())]
    when = [t for t, _, _ in spread_words(text)]
    theirs = spread_words(styled)
    m = [core(w[3]) for w in mine]
    t = [core(w) for _, _, w in theirs]
    pron = {"he", "him", "his", "himself"}
    a = [i for i, c in enumerate(m) if c in pron]
    b = [j for j, c in enumerate(t) if c in pron]

    def score(i, j):
        if m[i] != t[j] or abs(when[i] - theirs[j][0]) >= 5:
            return None
        same = sum(0 <= i + d < len(m) and 0 <= j + d < len(t) and m[i + d] == t[j + d]
                   for d in (-3, -2, -1, 1, 2, 3))
        return same + (5 - abs(when[i] - theirs[j][0])) / 5 if same else None

    # Best in-order pairing (like lining up two sequences).
    best = [[0.0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for x in range(len(a) - 1, -1, -1):
        for y in range(len(b) - 1, -1, -1):
            sc = score(a[x], b[y])
            best[x][y] = max(best[x + 1][y], best[x][y + 1],
                             sc + best[x + 1][y + 1] if sc is not None else 0.0)
    x = y = 0
    while x < len(a) and y < len(b):
        sc = score(a[x], b[y])
        if sc is not None and best[x][y] == sc + best[x + 1][y + 1]:
            i, j = a[x], b[y]
            w, sw = mine[i][3], theirs[j][2]
            before = theirs[j - 1][2] if j else "."
            starts = re.search(r"[.?!:][\"'\u201d\u2019)\]]*$", before) or before in ("\"", "\u201c")
            if w[:1].islower() and sw[:1].isupper() and not starts:
                ci, li, wi, _ = mine[i]
                words = cues[ci][1][li].split()
                words[wi] = w[0].upper() + w[1:]
                cues[ci][1][li] = " ".join(words)
            x, y = x + 1, y + 1
        elif best[x][y] == best[x + 1][y]:
            x += 1
        else:
            y += 1
    return format_srt(cues)


def relisten(wav, text):
    """Whisper sometimes skips ahead inside its 30-second window and drops
    what was said. One caption then stays up for 20 seconds with only a few
    words in it; a whole scripture reading went missing that way. Listen to
    each stretch like that again on its own, and use what it hears if it's
    clearly more."""
    cues = parse_srt(text)
    times = [tuple(srt_seconds(x.strip()) for x in t.split("-->")) for t, _ in cues]
    said = [" ".join(lines).split() for _, lines in cues]
    sparse = [b - a >= 6 and len(w) < 1.2 * (b - a) for (a, b), w in zip(times, said)]
    out = []
    k = 0
    with tempfile.TemporaryDirectory() as tmp:
        while k < len(cues):
            if not sparse[k]:
                out.append(cues[k])
                k += 1
                continue
            first = k
            while k + 1 < len(cues) and sparse[k + 1]:
                k += 1
            # From where the caption before ends (the dropped words can start
            # in the gap) to a few seconds past the end, so the phrase it cuts
            # into isn't lost. It listens from 5 seconds earlier still: started
            # mid-sentence, Whisper can leave out all the punctuation.
            a, b = times[first][0], times[k][1]
            if first:
                a = max(min(times[first - 1][1], a), a - 3)
            early = max(a - 5, 0)
            piece = os.path.join(tmp, f"again{k}.wav")
            slice_wav(wav, early, b + 3, piece)
            raw = whisper(piece, os.path.join(tmp, f"again{k}"), 42, ["-mc", "0"], on_frac=lambda f: None)
            heard = [(early + x, early + y, w) for x, y, w in spread_words(open(raw, encoding="utf-8").read())]
            heard = trim_overlap(heard, said[first - 1] if first else [], said[k + 1] if k + 1 < len(cues) else [], a, b)
            if len(heard) < sum(len(w) for w in said[first:k + 1]) + 4:
                out += cues[first:k + 1]
            else:
                # Between the captions either side, whatever Whisper's timing says.
                lo = times[first - 1][1] if first else 0.0
                hi = times[k + 1][0] if k + 1 < len(cues) else b + 3
                out += regroup(heard, max(lo, 0.0), max(hi, b))
            k += 1
    return format_srt(out)


def spread_words(text):
    """[(start, end, word)] for every word in an SRT, each caption's time
    shared out by the length of its words. (Asking Whisper for one word per
    caption gets real word times, but sometimes no punctuation at all.)"""
    out = []
    for timing, lines in parse_srt(text):
        a, b = (srt_seconds(x.strip()) for x in timing.split("-->"))
        ws = " ".join(lines).split()
        total = sum(len(w) + 1 for w in ws)
        t = a
        for w in ws:
            d = (b - a) * (len(w) + 1) / total
            out.append((t, t + d, w))
            t += d
    return out


def trim_overlap(heard, before, after, a, b):
    """Of words heard again from A to a little past B, the ones that belong
    between the caption BEFORE and the caption AFTER. Their timing is only
    roughly right, so the edges are found by the words the neighbours share
    with it, and by time when they don't match up."""
    said = [core(w) for _, _, w in heard]
    # Where the next caption's first two words (or only word) come in, closest to B.
    nxt = [core(w) for w in after[:2]]
    cut = [j for j in range(len(heard) - len(nxt) + 1) if nxt and said[j:j + len(nxt)] == nxt
           and abs(heard[j][0] - b) < 2.5]
    end = min(cut, key=lambda j: abs(heard[j][0] - b)) if cut \
        else next((j for j, h in enumerate(heard) if h[0] >= b - 0.05), len(heard))
    # And where the last caption's final two words end (it heard them too),
    # or by time.
    prev = [core(w) for w in before[-2:]]
    lead = [j + len(prev) for j in range(min(end, len(heard)) - len(prev) + 1) if prev
            and said[j:j + len(prev)] == prev and abs(heard[j][0] - a) < 3]
    start = min(lead, key=lambda j: abs(heard[j - 1][1] - a)) if lead \
        else next((j for j, h in enumerate(heard) if h[0] >= a - 0.05), end)
    return heard[start:end]


def regroup(heard, lo, hi):
    """Words back into captions of up to 42 characters, as in the first pass,
    timed in order between LO and HI (the captions either side)."""
    groups = [[heard[0]]]
    for h in heard[1:]:
        if len(" ".join(w for _, _, w in groups[-1] + [h])) > 42:
            groups.append([])
        groups[-1].append(h)
    # Each starts no earlier than LO or the one before, and leaves the rest
    # at least 0.3 s each before HI.
    starts, t = [], lo
    for n, g in enumerate(groups):
        t = min(max(g[0][0], t), hi - 0.3 * (len(groups) - n))
        starts.append(max(t, lo))
        t = starts[-1] + 0.3
    out = []
    for n, g in enumerate(groups):
        end = starts[n + 1] if n + 1 < len(groups) else min(max(g[-1][1], starts[n] + 0.3), hi)
        out.append([f"{srt_time(starts[n])} --> {srt_time(max(end, starts[n]))}", [" ".join(w for _, _, w in g)]])
    return out


def captions_text(video, start, length, on_frac):
    """Cleaned English captions for LENGTH seconds of VIDEO from START,
    timed from START (so they fit the trimmed video), without saving it."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "audio.wav")
        ffmpeg(["-ss", f"{start:.4f}", "-i", video, "-t", f"{length:.4f}", "-map", "0:a:0",
                "-ar", "16000", "-ac", "1", wav], length, lambda f: on_frac(0.05 * f))
        return clean_srt(listen(wav, tmp, lambda f: on_frac(0.05 + 0.95 * f)))


def parse_srt(text):
    cues = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip()):
        lines = block.split("\n")
        i = next((k for k, l in enumerate(lines) if "-->" in l), None)
        if i is None:
            continue
        cues.append([lines[i].strip(), [l.strip() for l in lines[i + 1:] if l.strip()]])
    return cues


def format_srt(cues):
    out = []
    for n, (timing, lines) in enumerate(cues, 1):
        out.append(f"{n}\n{timing}\n" + "\n".join(lines))
    return "\n\n".join(out) + "\n"


def core(word):
    return re.sub(r"[^\w']", "", word).lower()


def strip_fillers(line):
    """Drop um/uh. A capitalised filler started a sentence, so the word
    after it takes the capital."""
    out, pos, cap = "", 0, False
    for m in FILLERS.finditer(line):
        out += line[pos:m.start()]
        pos = m.end()
        cap = cap or m.group(0)[:1].isupper()
        if cap and pos < len(line):
            rest = line[pos:]
            line = line[:pos] + rest[0].upper() + rest[1:]
            cap = False
    out += line[pos:]
    return re.sub(r"\s{2,}", " ", out).strip()


def verse_ref(ws, i):
    """If a Bible reference starts at word I ("Galatians chapter 2, verse 20.",
    "2 Peter 1, 20-21", "Proverbs 4.23", "2 Timothy 3, 14 through 17"),
    return it written as "Galatians 2:20." and how many words it took."""
    j, book = i, []
    if core(ws[j]) in ORDINALS and j + 1 < len(ws) and core(ws[j + 1]) in BOOKS and ws[j][-1].isalnum():
        book.append(ORDINALS[core(ws[j])])
        j += 1
    if j >= len(ws) or core(ws[j]) not in BOOKS or not ws[j][:1].isupper() or not ws[j][-1].isalpha():
        return None
    book.append(ws[j])
    j += 1
    if j < len(ws) and ws[j].lower() == "chapter":
        j += 1
    if j >= len(ws):
        return None
    joined = re.fullmatch(r"(\d+)[.:](\d+)(?:[-–](\d+))?(\W*)", ws[j])
    if joined:
        ch, v, to, tail = joined.groups()
        j += 1
    else:
        m = re.fullmatch(r"(\d+)(,?)", ws[j])
        if not m or j + 1 >= len(ws):
            return None
        ch = m.group(1)
        j += 1
        verse_word = ws[j].lower() in ("verse", "verses")
        if not m.group(2) and not verse_word:
            return None   # "John 3 16" could be anything
        j += verse_word
        m = j < len(ws) and re.fullmatch(r"(\d+)(?:[-–](\d+))?(\W*)", ws[j])
        if not m:
            return None
        v, to, tail = m.groups()
        j += 1
        # "Mark 1, 2, and 3 on your outline" is a list, not a verse. (After a
        # name that's also a plain word, "Mark 1, 2 and 3" is too.)
        more = j + 1 < len(ws) and ws[j].lower() in ("and", "or") and re.fullmatch(r"\d+\W*", ws[j + 1])
        if j < len(ws) and ((tail == "," and (re.fullmatch(r"\d+\W*", ws[j]) or more))
                            or (more and core(book[-1]) in ("mark", "job", "acts", "numbers"))):
            return None
        if not to and not tail and j + 1 < len(ws) and ws[j].lower() in ("through", "to"):
            m = re.fullmatch(r"(\d+)(\W*)", ws[j + 1])
            if m:
                to, tail = m.groups()
                j += 2
    return " ".join(book) + f" {ch}:{v}" + (f"-{to}" if to else "") + tail, j - i


def clean_srt(text):
    cues = parse_srt(text)
    # Fillers and house spellings, per line.
    for cue in cues:
        lines = []
        for line in cue[1]:
            for pat, rep in WORD_FIXES:
                line = re.sub(pat, rep, line)
            new = strip_fillers(line)
            if new:
                lines.append(new)
        cue[1] = lines

    # Joins and stuttered repeats, across cue boundaries too.
    words = [[ci, li, wi, w] for ci, cue in enumerate(cues)
             for li, line in enumerate(cue[1])
             for wi, w in enumerate(line.split())]
    # Bible references as "John 3:16", and "High" / "Ridge" split across lines.
    ws, joined, k = [w[3] for w in words], [], 0
    absorbed = set()   # captions whose words moved into a later one
    while k < len(words):
        ref = verse_ref(ws, k)
        n = ref[1] if ref else 2 if ws[k] == "High" and k + 1 < len(words) \
            and re.fullmatch(r"Ridge\W*", ws[k + 1]) else 1
        if n > 1:
            # It goes where its last part was said, so it's on screen then;
            # captions it empties hand their time to the next one.
            host = words[k + n - 1]
            host[3] = ref[0] if ref else "HighRidge" + ws[k + 1][5:]
            absorbed |= {w[0] for w in words[k:k + n - 1]} - {host[0]}
            joined.append(host)
        else:
            joined.append(words[k])
        k += n
    words = joined
    drop = set()
    for k in range(1, len(words)):
        a, b = words[k - 1][3], words[k][3]
        ca = core(a)
        if not ca or ca != core(b) or a[-1] in ".?!":
            continue
        if (a.endswith(",") and ca not in EMPHASIS) or (a[-1].isalnum() and ca in STUTTER):
            drop.add(k - 1)
            if a[:1].isupper() and not b[:1].isupper():
                words[k][3] = b[0].upper() + b[1:]
    # Always capitalized: Scripture(s), Word of God, God's Word.
    alive = [w for k, w in enumerate(words) if k not in drop]
    plain = [core(w[3].replace("\u2019", "'")).strip("'") for w in alive]
    ends = [bool(re.search(r"[.?!,;:]\W*$", w[3])) for w in alive]   # the phrase can't run past these
    up = lambda w: re.sub(r"^(\W*)([a-z])", lambda m: m.group(1) + m.group(2).upper(), w)
    for k, w in enumerate(alive):
        if plain[k] in ("scripture", "scriptures", "scripture's"):
            w[3] = up(w[3])
        elif plain[k] == "word" and plain[k + 1:k + 3] == ["of", "god"] and not any(ends[k:k + 2]):
            w[3], alive[k + 2][3] = up(w[3]), up(alive[k + 2][3])
        elif plain[k] == "word" and k and plain[k - 1] == "god's" and not ends[k - 1]:
            w[3], alive[k - 1][3] = up(w[3]), up(alive[k - 1][3])
    rebuilt = [[[] for _ in cue[1]] for cue in cues]
    for k, (ci, li, wi, w) in enumerate(words):
        if k not in drop:
            rebuilt[ci][li].append(w)
    kept, early = [], None
    for ci, (cue, lines) in enumerate(zip(cues, rebuilt)):
        cue[1] = [" ".join(ws) for ws in lines if ws]
        if cue[1]:
            if early:
                cue[0] = early + " --> " + cue[0].split("-->")[1].strip()
                early = None
            kept.append(cue)
        elif ci in absorbed and early is None:
            # Its words went into a later caption (a reference said across
            # captions), which starts this one's time instead.
            early = cue[0].split("-->")[0].strip()
    return format_srt(screen_time(kept))


def screen_time(cues):
    """Every caption on screen for a real stretch, in order. Whisper now and
    then writes one that starts and ends at the same moment (HeyGen rejects
    the whole file: "end time is before start time") or that starts before
    the one before it ends. Such a caption gets time from the gap before or
    after it (about 60 ms a character, at least 0.3 s); with no room either
    side, its words join the caption before."""
    times = [[srt_seconds(x.strip()) for x in t.split("-->")] for t, _ in cues]
    out = []   # [start, end, lines]
    for k, ((a, b), (_, lines)) in enumerate(zip(times, cues)):
        prev = out[-1][1] if out else 0.0
        a = max(a, prev)
        if b - a >= 0.05:
            out.append([a, b, lines])
            continue
        need = max(0.3, 0.06 * len(" ".join(lines)))
        nxt = times[k + 1][0] if k + 1 < len(cues) else b + need
        if b - max(prev, b - need) >= 0.3 - 1e-6:   # (tolerance for float rounding)
            out.append([max(prev, b - need), b, lines])
        elif min(nxt, a + need) - a >= 0.3 - 1e-6:
            out.append([a, min(nxt, a + need), lines])
        elif out:
            out[-1][1] = max(out[-1][1], b)
            out[-1][2] = out[-1][2] + lines
        else:
            out.append([a, a + need, lines])
    return [[f"{srt_time(a)} --> {srt_time(b)}", lines] for a, b, lines in out]


def write_atomic(path, text):
    tmp = path + ".partial"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


# ------------------------------------------------------------------- spanish

FPS = 10.0
W, H = 96, 54
COARSE = 5      # coarse pass compares every 5th frame
MAXSTEP = 8     # the copy may advance 0..MAXSTEP frames per original frame
BAND = 40       # fine-pass search radius (frames) around the coarse path


def extract_frames(videos, outs):
    """Tiny grayscale frames from both videos at once, top 78% only so
    captions already burned into a video don't affect matching."""
    totals = [duration(v) for v in videos]
    fracs = [0.0, 0.0]
    errors = []
    threads = []
    for i, (v, o) in enumerate(zip(videos, outs)):
        def run(i=i, v=v, o=o):
            def setter(f):
                fracs[i] = f
            args = ["-i", v, "-map", "0:V:0", "-vf",
                    f"fps={FPS:g},crop=iw:ih*0.78:0:0,scale={W}:{H},format=gray",
                    "-f", "rawvideo", "-y", o]
            try:
                ffmpeg(args, totals[i], setter)
            except Fail as e:
                errors.append(str(e))
        threads.append(threading.Thread(target=run, daemon=True))
    for t in threads:
        t.start()
    while any(t.is_alive() for t in threads):
        P.set(sum(fracs) / 2)
        time.sleep(0.25)
    if errors:
        fail(errors[0])
    P.set(1.0)


def time_map(orig_gray, copy_gray):
    import numpy as np

    def feats(path):
        a = np.fromfile(path, dtype=np.uint8).reshape(-1, H * W).astype(np.float32)
        a -= a.mean(axis=0, keepdims=True)          # drop the static background
        return a / np.maximum(np.linalg.norm(a, axis=1, keepdims=True), 1e-3)

    def dtw(cost, n, m, lo, hi):
        """Monotonic path through rows 0..n-1, j(i)-j(i-1) in [0, MAXSTEP],
        row i limited to columns [lo[i], hi[i]). Backpointers kept banded."""
        INF = np.float32(1e9)
        width = int((hi - lo).max())
        back = np.zeros((n, width), dtype=np.int8)
        prev = np.full(m, INF, dtype=np.float32)
        prev[0] = cost(0, 0, 1)[0]
        for i in range(1, n):
            a, b = lo[i], hi[i]
            best = np.full(b - a, INF, dtype=np.float32)
            arg = np.zeros(b - a, dtype=np.int8)
            for k in range(0, MAXSTEP + 1):
                s, e = a - k, b - k
                cand = np.full(b - a, INF, dtype=np.float32)
                cs = max(s, 0)
                if e > cs:
                    cand[cs - s:] = prev[cs:e]
                better = cand < best
                best = np.where(better, cand, best)
                arg = np.where(better, k, arg)
            row = np.full(m, INF, dtype=np.float32)
            row[a:b] = best + cost(i, a, b)
            back[i, :b - a] = arg
            prev = row
        j = m - 1
        path = [j]
        for i in range(n - 1, 0, -1):
            j -= int(back[i, j - lo[i]])
            path.append(j)
        path.reverse()
        return np.array(path)

    O, E = feats(orig_gray), feats(copy_gray)
    n, m = len(O), len(E)
    if n < 20 or m < 20:
        fail("One of the videos is too short to line up.")

    Oc, Ec = O[::COARSE], E[::COARSE]
    nc, mc = len(Oc), len(Ec)
    Cc = 1.0 - Oc @ Ec.T
    pc = dtw(lambda i, a, b: Cc[i, a:b], nc, mc,
             np.zeros(nc, dtype=int), np.full(nc, mc))

    centre = np.interp(np.arange(n) / COARSE, np.arange(nc), pc * COARSE)
    lo = np.clip(np.floor(centre - BAND).astype(int), 0, m - 1)
    hi = np.clip(np.ceil(centre + BAND).astype(int) + 1, 1, m)
    lo[0], hi[-1] = 0, m
    pf = dtw(lambda i, a, b: 1.0 - E[a:b] @ O[i], n, m, lo, hi)

    match = 1.0 - np.einsum("ij,ij->i", O, E[pf])
    if np.mean(match > 0.6) > 0.15 or np.median(match) > 0.3:
        fail("These two videos don't look like the same message. Check that "
             "the Spanish video was made from this English video.")

    # Smooth the staircase: ~1s running median, then running mean.
    k = int(FPS)
    pad = np.pad(pf.astype(np.float32), k, mode="edge")
    win = np.lib.stride_tricks.sliding_window_view(pad, 2 * k + 1)
    med = np.median(win, axis=1)
    pad = np.pad(med, k, mode="edge")
    smooth = np.convolve(pad, np.ones(2 * k + 1) / (2 * k + 1), mode="valid")
    smooth = np.maximum.accumulate(smooth)
    return np.arange(n) / FPS, smooth / FPS


def srt_seconds(s):
    h, mi, rest = s.split(":")
    sec, ms = rest.replace(".", ",").split(",")
    return int(h) * 3600 + int(mi) * 60 + int(sec) + int(ms.ljust(3, "0")[:3]) / 1000


def srt_time(t):
    ms = max(int(round(t * 1000)), 0)
    h, ms = divmod(ms, 3600000)
    mi, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{mi:02d}:{s:02d},{ms:03d}"


def retime(text, t_orig, t_copy):
    import numpy as np
    end_o, end_c = float(t_orig[-1]), float(t_copy[-1])

    def remap(t):
        if t > end_o:
            return end_c + (t - end_o)
        return float(np.interp(t, t_orig, t_copy))

    rx = re.compile(r"\s*(\d+:\d+:\d+[,.]\d+)\s*-->\s*(\d+:\d+:\d+[,.]\d+)(.*)")
    cues = parse_srt(text)
    if not cues:
        fail("The English captions file is empty or isn't an SRT.")
    for cue in cues:
        m = rx.fullmatch(cue[0])
        if not m:
            fail(f"Couldn't read this caption timing: {cue[0]}")
        a, b = remap(srt_seconds(m.group(1))), remap(srt_seconds(m.group(2)))
        cue[0] = f"{srt_time(a)} --> {srt_time(max(b, a + 0.2))}"
    return format_srt(cues)


def spanish(orig, copy, en_srt, out_srt, out_mp4):
    for tool in (FFMPEG, FFPROBE):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    src_srt = open(en_srt, encoding="utf-8-sig").read()
    with tempfile.TemporaryDirectory() as tmp:
        og, cg = os.path.join(tmp, "orig.gray"), os.path.join(tmp, "copy.gray")
        P.stage("Reading both videos…", 0.0, 0.18)
        extract_frames([orig, copy], [og, cg])

        P.stage("Lining up the Spanish video with the original…", 0.18, 0.24)
        t_orig, t_copy = time_map(og, cg)
        write_atomic(out_srt, format_srt(screen_time(parse_srt(retime(src_srt, t_orig, t_copy)))))
        P.set(1.0)

        P.stage("Adding captions to the Spanish video…", 0.24, 1.0)
        shutil.copy(out_srt, os.path.join(tmp, "captions.srt"))
        bps = video_bitrate(copy)
        partial = out_mp4 + ".partial.mp4"
        try:
            ffmpeg(["-i", copy, "-map", "0:V:0", "-map", "0:a:0?",
                    "-vf", f"subtitles=captions.srt:force_style='{STYLE}'",
                    "-c:v", "h264_videotoolbox", "-a53cc", "0", "-b:v", str(bps), "-profile:v", "high",
                    "-c:a", "copy", "-movflags", "+faststart", "-y", partial],
                   duration(copy), P.set, cwd=tmp)
            os.replace(partial, out_mp4)
        finally:
            if os.path.exists(partial):
                os.remove(partial)


# Copying the finished video to the ProPresenter Mac. config.json there says
# where it is: {"host", "user", "jump"} for another Mac, reached directly when
# on the church network and through "jump" (over Tailscale) when not, or
# {"folder"} when this is the ProPresenter Mac. "key" and "known_hosts" sit
# next to it. On the ProPresenter Mac the key may only run the receive
# script, and on the jump host it may only connect through to it.
SEND_DIR = os.path.expanduser("~/Library/Application Support/Sermon Captions/ProPresenter")


def send_config():
    import json
    try:
        return json.load(open(os.path.join(SEND_DIR, "config.json")))
    except (OSError, ValueError):
        fail("Copying to ProPresenter isn't set up on this Mac.")


def ssh_args(cfg, via_jump):
    # Quoted because the folder has spaces, and ssh would read them as a list of files.
    # -F /dev/null: none of this Mac's own ssh settings apply.
    opts = ["-F", "/dev/null", "-i", os.path.join(SEND_DIR, "key"), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", 'UserKnownHostsFile="%s"' % os.path.join(SEND_DIR, "known_hosts"),
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
    # The host key is checked under a fixed name, so the same address on
    # another network (another campus uses the same numbers) is refused.
    target = opts + ["-o", "HostKeyAlias=" + cfg.get("alias", "propresenter")]
    if via_jump:
        import shlex
        jump = " ".join(shlex.quote(a) for a in ["/usr/bin/ssh", *opts, "-W", "%h:%p", cfg["jump"]])
        target += ["-o", "ProxyCommand=" + jump]
    return ["/usr/bin/ssh", *target, f"{cfg['user']}@{cfg['host']}"]


def send(*args):
    """send VIDEO: the finished Spanish video into Movies/Spanish sermons.
    send --to FOLDER FILE...: a trimmed video and its captions into
    Movies/Sermon Captions/FOLDER, to finish there. Files go in the order
    given (the video before its captions, so the captions are the newer)."""
    to = None
    if args[:1] == ("--to",) and len(args) > 2:
        to, args = args[1], args[2:]
    files = list(args)
    for f in files:
        if not os.path.exists(f):
            fail(f"Can't find {f}")
    sizes = [os.path.getsize(f) for f in files]
    total = max(sum(sizes), 1)
    cfg = send_config()
    if "folder" in cfg:   # this is the ProPresenter Mac
        P.stage("Copying to ProPresenter…", 0.0, 1.0)
        if to:
            shown = f"Movies/Sermon Captions/{to}"
            folder = os.path.expanduser(f"~/{shown}")
        else:
            shown = cfg["folder"].replace("~/", "", 1)
            folder = os.path.expanduser(cfg["folder"])
        os.makedirs(folder, exist_ok=True)
        done = 0
        for f in files:
            dest = os.path.join(folder, os.path.basename(f))
            if os.path.exists(dest) and os.path.samefile(f, dest):
                done += os.path.getsize(f)
                continue
            fd, part = tempfile.mkstemp(prefix=".upload.", dir=folder)
            try:
                with open(f, "rb") as src, os.fdopen(fd, "wb") as dst:
                    while chunk := src.read(4 << 20):
                        dst.write(chunk)
                        done += len(chunk)
                        P.set(done / total)
                os.chmod(part, 0o644)
                os.replace(part, dest)
            finally:
                if os.path.exists(part):
                    os.remove(part)
        emit("NOTE", shown)
        return

    P.stage("Finding the ProPresenter Mac…", 0.0, 0.0)
    routes = [False, True] if cfg.get("jump") else [False]
    found = None
    for via_jump in routes:
        try:
            r = subprocess.run(ssh_args(cfg, via_jump) + ["check"], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            continue
        if r.returncode == 0 and r.stdout.startswith("ok"):
            found, reply = via_jump, r.stdout.split()
            break
    if found is None:
        fail("Couldn't reach the ProPresenter Mac. It may be asleep or turned off. Away from church, "
             "this Mac also needs Tailscale turned on. Everything is still in this sermon's folder, "
             "so you can try again with Copy to ProPresenter.")
    if len(reply) > 1 and reply[1].isdigit() and int(reply[1]) * 1024 < total + (2 << 30):
        fail("The ProPresenter Mac is almost out of space.")

    P.stage("Copying to ProPresenter…", 0.0, 1.0)
    done, saved = 0, ""
    for f, size in zip(files, sizes):
        name = os.path.basename(f)
        command = f"upload-to {size} {to}/{name}" if to else f"upload {size} {name}"
        proc = subprocess.Popen(ssh_args(cfg, found) + [command], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=False)
        CHILDREN.append(proc)
        # Read its replies while sending, so a chatty ssh can't fill a pipe and stall both sides.
        replies = {}
        readers = [threading.Thread(target=lambda k, h: replies.__setitem__(k, h.read()[-4000:]), args=(k, h),
                                    daemon=True)
                   for k, h in (("out", proc.stdout), ("err", proc.stderr))]
        for t in readers:
            t.start()
        try:
            with open(f, "rb") as src:
                while chunk := src.read(1 << 20):
                    proc.stdin.write(chunk)
                    done += len(chunk)
                    P.set(done / total)
        except BrokenPipeError:
            pass   # the other end gave up; its message comes next
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
        proc.wait()
        for t in readers:
            t.join()
        out = replies.get("out", b"").decode(errors="replace").strip()
        if proc.returncode != 0 or not out.startswith("saved "):
            why = replies.get("err", b"").decode(errors="replace").strip().splitlines()
            if why and why[-1] == "not allowed":
                why = ["the ProPresenter Mac needs its copy of Sermon Captions set up again"]
            elif why and why[-1] == "bad name":
                why = [f"it won't take a file named {name}"]
            fail("Copying to the ProPresenter Mac stopped partway" + (f" ({why[-1]})" if why else "")
                 + ". Try again with Copy to ProPresenter.")
        saved = out[len("saved "):]
    emit("NOTE", os.path.dirname(saved) if to else saved)


FADE_SECONDS = 1.0


def video_bitrate(path, default=12_000_000):
    """Bitrate to re-encode at: comfortably above the source so a second
    generation (HeyGen re-encodes again) doesn't look soft."""
    try:
        src = int(probe(path, "stream=bit_rate", "V:0"))
    except ValueError:
        return default
    return min(max(int(src * 1.5), 8_000_000), 25_000_000)


def mixed_sound(video, music, first):
    """ffmpeg inputs (numbered from `first`) and filters for VIDEO's sound
    with the music choices mixed in, on the whole file's timeline, ending
    in [mix]. The music files line up by sample count from the start of the
    audio, so this mixes into an unseeked copy; cut it afterwards."""
    fmt = f"aresample={RATE},aformat=sample_fmts=flt:channel_layouts=stereo"
    inputs = ["-i", video]
    graph = f"[{first}:a:0]{stereo(video)}[orig];"
    for k, (path, at, _) in enumerate(music):
        inputs += ["-i", path]
        graph += f"[{first + 1 + k}:a]{fmt},adelay=delays={at}S:all=1,apad[m{k}];"
    if music:
        weights = " ".join(["1"] + [f"{amount:.4f}" for _, _, amount in music])
        graph += ("[orig]" + "".join(f"[m{k}]" for k in range(len(music)))
                  + f"amix=inputs={len(music) + 1}:weights='{weights}':normalize=0:duration=first[mix];")
    else:
        graph += "[orig]anull[mix];"
    return inputs, graph


def parse_music(music):
    music = [(music[i], int(music[i + 1]), float(music[i + 2])) for i in range(0, len(music), 3)]
    music = [m for m in music if m[2] > 0]
    if any(not os.path.exists(path) for path, _, _ in music):
        fail("The separated music is missing. Separate it again in the trim editor.")
    return music


LOUDNESS_TARGET = -16.0  # what "Even out the volume" aims for (the trim window's targetLoudness)
LIMITER = "alimiter=limit=0.8414:attack=5:release=50:level=disabled:latency=1"


BT709 = "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"


def rate_of(text):
    """A frame rate as ffmpeg writes it ("30000/1001") in frames a second."""
    a, _, b = text.partition("/")
    try:
        return float(a) / float(b or 1)
    except (ValueError, ZeroDivisionError):
        return 0.0


def frames_in(length, rate):
    """How many frames at RATE trimming to LENGTH seconds keeps (with room
    for ffprobe's rounding to the microsecond)."""
    return max(int(-(-(length * rate - 0.01) // 1)), 1)


def clip_frames(length, rate):
    """How many frames at RATE the fps filter makes of a clip whose picture
    ends at LENGTH: to the nearest frame, a half up as ffmpeg does it (with
    room for ffprobe's rounding; the app counts the same way)."""
    return max(int(length * rate + 0.5 + 1e-4), 1)


def picture(video):
    """Width and height as shown (after any rotation) and the frame rate
    ffmpeg will give VIDEO's picture."""
    def run(cmd):
        return subprocess.run(cmd, capture_output=True, text=True).stdout

    out = run([FFPROBE, "-v", "error", "-select_streams", "V:0", "-show_entries",
               "stream=width,height,r_frame_rate,avg_frame_rate:stream_side_data=rotation",
               "-of", "default=nw=1", video])
    info = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    try:
        w, h = int(info["width"]), int(info["height"])
    except (KeyError, ValueError):
        fail(f"Couldn't read the picture size of {os.path.basename(video)}.")
    if abs(rate_of(info.get("rotation", "0") + "/1")) % 180 == 90:
        w, h = h, w
    # As ffmpeg picks it: the stream's own rate, unless that's implausible.
    rate = info.get("r_frame_rate", "")
    if not 0 < rate_of(rate) <= 210:
        rate = info.get("avg_frame_rate", "")
    if not 0 < rate_of(rate) <= 210:
        rate = "30"
    return w, h, rate


def picture_length(video):
    """When VIDEO's picture ends, counted from the start of the file (the
    sound can start earlier or run a little longer)."""
    try:
        start, length = (probe(video, "stream=start_time,duration", "V:0").split("\n") + [""])[:2]
        first = probe(video, "format=start_time")
        return float(length) + max(float(start) - float(first), 0)
    except ValueError:
        return duration(video)


def has_sound(video):
    return probe(video, "stream=index", "a:0") != ""


def loudness(video):
    """Integrated loudness of VIDEO's sound in LUFS, as it goes into the
    saved video (stereo), or None if it's silent."""
    r = subprocess.run([FFMPEG, "-nostdin", "-hide_banner", "-i", video, "-map", "0:a:0",
                        "-af", stereo(video) + ",ebur128=framelog=quiet", "-f", "null", "-"],
                       capture_output=True, text=True)
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", r.stderr)
    return float(found[-1]) if found and float(found[-1]) > -60 else None


def add_clip(path, k, label, size, level, target=LOUDNESS_TARGET):
    """Filters for an intro or outro (ffmpeg input K) made to match the
    sermon: same picture size and frame rate, letterboxed if the shape
    differs, 48 kHz stereo sound (silence if it has none), and brought to
    the same loudness when the sermon's volume is evened out. Ends in
    [LABELv] and [LABELa], the same length to the frame; returns the
    filters and how many frames that is."""
    w, h, rate = size
    length = picture_length(path)
    frames = clip_frames(length, rate_of(rate))
    sound = frames / rate_of(rate)
    # Untagged clips are taken the way players take them (HD as bt709);
    # tagged ones go by their tags.
    matrix = "auto"
    if probe(path, "stream=color_space", "V:0") in ("", "unknown", "reserved"):
        tall = probe(path, "stream=height", "V:0")
        matrix = "bt709" if tall.isdigit() and int(tall) >= 720 else "bt601"
    # Square pixels first, so a clip with non-square ones keeps its shape.
    # Picture and sound keep their places relative to each other: whichever
    # starts late is padded at the front (first frame held, or silence).
    graph = (f"[{k}:V:0]scale=trunc(iw*sar/2)*2:ih,setsar=1,"
             f"scale={w}:{h}:force_original_aspect_ratio=decrease:force_divisible_by=2"
             f":in_color_matrix={matrix}:out_color_matrix=bt709:out_range=tv,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1,"
             f"fps={rate}:start_time=0,format=yuv420p,{BT709},trim=end_frame={frames},settb=AVTB[{label}v];")
    if has_sound(path):
        gain = ""
        lufs = loudness(path) if level else None
        if lufs is not None:
            gain = f",volume={min(max(target - lufs, -12), 18):.2f}dB,{LIMITER}"
        graph += (f"[{k}:a:0]aresample=async=1:first_pts=0,{stereo(path)}{gain},apad,"
                  f"atrim=duration={sound:.6f}[{label}a];")
    else:
        graph += f"anullsrc=r={RATE}:cl=stereo,aformat=sample_fmts=flt,atrim=duration={sound:.6f}[{label}a];"
    return graph, frames


# What Whisper writes for music or silence instead of words.
NOT_SPEECH = re.compile(r"\s*(\[[^\]]*\]|\([^)]*\)|[♪♫\s*]+)\s*")


def trim(video, out_mp4, start, length, fade, level, look, *music, captions=None, repair=None,
         intro=None, outro=None, intro_fade=0.0, outro_fade=0.0):
    for tool in (FFMPEG, FFPROBE) + ((WHISPER,) if captions else ()):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    start, length = float(start), float(length)
    music = parse_music(music)
    if repair and not os.path.exists(repair[0]):
        fail("The repaired voice is missing. Turn Repair the voice off and on again.")
    if length <= 0:
        fail("The end point has to be after the start point.")
    if look != "-" and not os.path.exists(look):
        fail("The Auto color table is missing. Turn Auto color off and on again.")
    for which, path in (("intro", intro), ("outro", outro)):
        if path and not os.path.exists(path):
            fail(f"The {which} video ({os.path.basename(path)}) is missing. Choose it again in the trim editor.")
    vf, af = [], []
    if look != "-":
        # The table holds the video's own R'G'B' values (bt709), in 16 bits
        # so the round trip through RGB doesn't band.
        vf.append("scale=in_color_matrix=bt709,format=gbrp16le,lut3d=file=look.cube:interp=tetrahedral,"
                  "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p")
    # Level first, then fade, so the limiter never works on the fade ramps.
    if level != "-":
        # One fixed change (what the trim window previews), then a limiter
        # 1.5 dB under full scale for peaks the boost pushes too far.
        af += [f"volume={float(level):.2f}dB", LIMITER]
    # An intro or outro cuts or crossfades to the sermon, so that end doesn't fade.
    if fade == "1" and length > 2 * FADE_SECONDS:
        end = length - FADE_SECONDS
        if not intro:
            vf.append(f"fade=t=in:st=0:d={FADE_SECONDS}")
            af.append(f"afade=t=in:st=0:d={FADE_SECONDS}")
        if not outro:
            vf.append(f"fade=t=out:st={end:.3f}:d={FADE_SECONDS}")
            af.append(f"afade=t=out:st={end:.3f}:d={FADE_SECONDS}")
    base = ensure_model() if captions else 0.0
    P.stage("Saving the trimmed video and writing its captions…" if captions else "Saving the trimmed video…",
            base, 1.0)
    partial = out_mp4 + ".partial.mp4"
    # -ss before -i plus a re-encode cuts on the exact frame, not the
    # nearest keyframe. -a53cc 0 everywhere: Subsplash downloads carry TV
    # closed captions, and the hardware encoder fails trying to keep them.
    args = ["-ss", f"{start:.4f}", "-t", f"{length:.4f}", "-i", video]
    after = "".join("," + f for f in af)
    sermon_sound = has_sound(video)
    # The sermon's sound ends in [sa] and its picture in [sv].
    if repair:
        # The repaired voice (music choices already in it) replaces the sound.
        path, from_ = repair
        args += ["-i", path]
        graph = (f"[1:a]atrim=start={start - float(from_):.6f}:duration={length:.6f},asetpts=PTS-STARTPTS,"
                 f"aresample={RATE},aformat=sample_fmts=flt:channel_layouts=mono,pan=stereo|c0=c0|c1=c0"
                 + after + "[sa];")
    elif music:
        inputs, graph = mixed_sound(video, music, 1)
        args += inputs
        graph += f"[mix]atrim=start={start:.6f}:duration={length:.6f},asetpts=PTS-STARTPTS" + after + "[sa];"
    elif sermon_sound:
        graph = "[0:a:0]" + (",".join(af) or "anull") + (f",{stereo(video)}" if intro or outro else "") + "[sa];"
    elif intro or outro:
        graph = f"anullsrc=r={RATE}:cl=stereo,aformat=sample_fmts=flt,atrim=duration={length:.6f}[sa];"
    else:
        graph = ""   # no sound in, none out
    graph += "[0:V:0]" + (",".join(vf) or "null") + "[sv]"
    # What the captions are made from: (video, from, length, where it lands, name).
    pieces = [(video, start, length, 0.0, "sermon", 0.0, length)]
    total = length
    if not (intro or outro):
        maps = ["-map", "[sv]"] + (["-map", "[sa]"] if "[sa]" in graph else [])
    else:
        # The clips are made to match the sermon's picture and sound, each
        # piece exactly a whole number of frames long, then joined with a
        # straight cut or a crossfade.
        size = picture(video)
        rate = rate_of(size[2])
        # The app evens out a mono sermon measured as mono; doubled onto both
        # sides here it plays 3 dB louder, so the clips go 3 dB louder too.
        target = LOUDNESS_TARGET
        if not repair and sermon_sound and probe(video, "stream=channels", "a:0").split("\n")[0] == "1":
            target += 3
        frames = frames_in(length, rate)
        graph += (f";[sv]setsar=1,fps={size[2]}:start_time=0,format=yuv420p,{BT709},"
                  f"trim=end_frame={frames},settb=AVTB[mv];"
                  f"[sa]aresample={RATE}:async=1:first_pts=0,aformat=sample_fmts=flt:channel_layouts=stereo,"
                  f"apad,atrim=duration={frames / rate:.6f}[ma];")
        parts = []   # (label, frames, video, from, name)
        for label, path in (("intro", intro), ("m", None), ("outro", outro)):
            if label == "m":
                parts.append(("m", frames, video, start, "sermon"))
            elif path:
                filters, n = add_clip(path, args.count("-i"), label, size, level != "-", target)
                args += ["-i", path]
                graph += filters
                parts.append((label, n, path, 0.0, label))
        # A crossfade is whole frames, no longer than the clip or half the sermon.
        def overlap(seconds, clip):
            return min(int(float(seconds) * rate + 0.5), clip, frames // 2) if float(seconds) > 0 else 0
        fades = [overlap(intro_fade, parts[0][1]) if intro else 0] * (len(parts) - 1)
        if outro:
            fades[-1] = overlap(outro_fade, parts[-1][1])
        # Each piece lands where the one before it ends, less the crossfade.
        lands, at = [], 0
        for k, part in enumerate(parts):
            at -= fades[k - 1] if k else 0
            lands.append(at)
            at += part[1]
        total = at / rate
        cur = parts[0][0]
        for k, part in enumerate(parts[1:]):
            d, nxt, j = fades[k], part[0], f"j{k}"
            if d:
                # Only the overlap goes through xfade (it works in 4:4:4, so
                # the rest of the picture is left alone); the sound crossfades
                # equal-power.
                at = lands[k + 1]   # where the overlap starts in what's joined so far
                graph += (f"[{cur}v]split[{j}p][{j}q];[{j}p]trim=end_frame={at}[{j}b];"
                          f"[{j}q]trim=start_frame={at},setpts=PTS-STARTPTS[{j}t];"
                          f"[{nxt}v]split[{j}r][{j}s];[{j}r]trim=end_frame={d}[{j}h];"
                          f"[{j}s]trim=start_frame={d},setpts=PTS-STARTPTS[{j}n];"
                          f"[{j}t][{j}h]xfade=transition=fade:duration={d / rate:.6f}:offset=0,"
                          f"format=yuv420p,settb=AVTB[{j}x];"
                          f"[{j}b][{j}x][{j}n]concat=n=3:v=1:a=0[{j}v];"
                          f"[{cur}a][{nxt}a]acrossfade=d={d / rate:.6f}:c1=qsin:c2=qsin[{j}a];")
            else:
                graph += f"[{cur}v][{cur}a][{nxt}v][{nxt}a]concat=n=2:v=1:a=1[{j}v][{j}a];"
            cur = j
        # Every piece is the same frame rate, so the picture is stamped by
        # frame count (concat gives a one-frame piece no length otherwise).
        num, _, den = size[2].partition("/")
        graph = graph.rstrip(";").replace(f"[{cur}a]", "[a]") + f";[{cur}v]settb={den or 1}/{num},setpts=N[v]"
        # What's said in each piece is captioned from where its crossfades
        # are half done, so no caption runs into the next piece's.
        pieces = []
        for k, (label, n, path, from_, name) in enumerate(parts):
            if label == "m" and not sermon_sound:
                continue   # a silent sermon has nothing to caption
            if label != "m" and not (captions and has_sound(path) and loudness(path) is not None):
                continue   # nor does a silent clip
            span = length if label == "m" else n / rate
            first = fades[k - 1] / 2 / rate if k else 0.0
            last = span - (fades[k] / 2 / rate if k < len(fades) else 0.0)
            pieces.append((path, from_, span, lands[k] / rate, name, first, last))
        maps = ["-map", "[v]", "-map", "[a]"]
    args += ["-filter_complex", graph] + maps
    args += ["-c:v", "h264_videotoolbox", "-a53cc", "0", "-b:v", str(video_bitrate(video)), "-profile:v", "high",
             "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
             "-movflags", "+faststart", "-y", partial]
    # The captions are made at the same time, from the original's sound for
    # the same stretch: Whisper runs on the GPU and the save on the video
    # encoder, so together they take about as long as the save alone.
    frac = {"video": 0.0, "captions": 0.0}
    text, problem = [], []
    missed = []   # (intro or outro, why) for a clip whose captions failed

    def show():
        P.set(0.65 * frac["video"] + 0.35 * frac["captions"] if captions else frac["video"])

    def make_captions():
        try:
            # The sermon, plus anything said in the intro or outro, each
            # moved to where it lands in the saved video.
            cues, done = [], 0.0
            whole = sum(piece[2] for piece in pieces)
            for path, at, span, lands, name, first, last in pieces:
                try:
                    part = captions_text(path, at, span,
                                         lambda f: frac.__setitem__("captions", (done + f * span) / whole))
                    # None runs past its own piece into the next.
                    for cue in parse_srt(part):
                        t0, t1 = (srt_seconds(x.strip()) for x in cue[0].split("-->"))
                        if t0 >= last - 0.05 or (first and t1 <= first + 0.05) \
                                or all(NOT_SPEECH.fullmatch(line) for line in cue[1]):
                            continue
                        cues.append([f"{srt_time(max(t0, first) + lands)} --> {srt_time(min(t1, last) + lands)}",
                                     cue[1]])
                except Exception as e:
                    if name == "sermon":
                        raise
                    # A failed intro or outro doesn't stop the sermon's captions, but it's reported.
                    why = str(e) if isinstance(e, Fail) else f"{type(e).__name__}: {e}"
                    missed.append((name, " ".join(why.split())))   # one line: the app reads messages by line
                done += span
            if cues:
                text.append(format_srt(screen_time(cues)))
            else:
                problem.append(missed[0][1] if missed else "there's no speech in it")
        except Fail as e:
            problem.append(str(e))
        except Exception as e:
            problem.append(f"{type(e).__name__}: {e}")

    worker = threading.Thread(target=make_captions, daemon=True) if captions else None
    if worker:
        worker.start()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            if look != "-":
                shutil.copy(look, os.path.join(tmp, "look.cube"))
            ffmpeg(args, total, lambda f: (frac.__setitem__("video", f), show()), cwd=tmp)
        if worker and worker.is_alive():
            emit("STAGE", "Finishing the captions…")
            while worker.is_alive():
                show()
                time.sleep(0.25)
        os.replace(partial, out_mp4)
    finally:
        if os.path.exists(partial):
            os.remove(partial)
    # Written after the video so they don't look older than it (step 2 would
    # call them out of date).
    if captions:
        if text:
            write_atomic(captions, text[0])
            if missed:
                emit("WARN", "The trimmed video and captions are saved, but the captions for the "
                     + " and ".join(name for name, _ in missed) + " couldn't be made (" + missed[0][1][:200]
                     + "). Click Make English captions in step 2 to try again.")
        else:
            emit("WARN", "The trimmed video is saved, but its captions couldn't be made ("
                 + (problem[0] if problem else "unknown error")[:200]
                 + "). Click Make English captions in step 2.")


# ------------------------------------------------------------------ suggest

# How he usually opens and closes. Lower-case, matched against the words of
# one sentence.
SIGN_ON = [
    r"\b(first|second|third|1st|2nd|3rd)\b.{0,20}\bservice",
    r"\bwelcome\b", r"\bgood (morning|evening|afternoon)\b",
    r"\bhow'?s everybody doing\b", r"\bhow (are|is) (you|everybody|we)\b",
    r"\bglad (you|you guys|y'?all|everybody|everyone) (are|is|'re) here\b",
    r"\b(joining|watching) (us )?(online|from home|on the livestream)\b",
    r"\bhappy (sunday|easter|mother'?s day|father'?s day|new year)\b",
    r"\bif you'?re new\b", r"\bmy name is\b",
]
# A personal greeting from the speaker ("how are we this morning?"). The
# video starts at one of these if it comes shortly before his welcome to the
# third service; a bare "welcome to church" (on 9/20, the end of the baptism
# celebration) doesn't count.
GREETING = [
    r"\bgood (morning|evening|afternoon)\b", r"\bhow'?s everybody\b", r"\bhow (are|is) (you|everybody|we)\b",
    r"\bglad (you|you guys|y'?all|everybody|everyone) (are|is|'re) here\b",
    r"\bhappy (sunday|easter|mother'?s day|father'?s day|new year)\b",
]
# Handing the third service to its own host. Just mentioning the third
# service isn't enough (on 9/20 he told them about Bibles in Spanish).
HANDOFF = [r"\bmessage host\b", r"\bhost (is|will|'?ll)\b", r"\btake over the message\b"]
# A whole sentence that only gets attention ("All right, church."): part of
# the sign-on that follows it.
OPENER = r"^(hey|hi|hello|all ?right|alright|well|okay|ok|so|good morning)\b[ ,!.]*" \
         r"(church|everybody|everyone|guys|you guys|y'?all|high ?ridge)?[ ,!.]*$"
# Introducing a video near the end: the video can end just before it plays.
VIDEO_INTRO = r"\b(watch|see|play|roll|show)\b.{0,20}\b(video|clip|testimony)\b"
# Starting to wrap up: the video can end before this.
CLOSING = [
    r"\bas we (close|wrap up|finish)\b",
    r"\b(go ahead and|would you|will you|can you|please|let'?s( all)?|ask (all of )?you to( please)?( also)?( just)?) (stand|pray)\b",
    r"\blet me pray\b", r"\bi want to pray (over|for) you\b",
]
SIGN_OFF = [
    r"\bgod bless\b", r"\bhave a (great|good|blessed|wonderful) (week|day|sunday|rest)\b",
    r"\bsee you (next|this|soon|then|on)\b", r"\bthanks? (you )?for (joining|watching|being)\b",
]
FRAME = 0.01        # energy frames for finding pauses (seconds)


def cut_room(gap, most):
    """How far into a pause of `gap` seconds to cut, from his voice: up to
    `most` seconds, but never right against the sound on the other side.
    Jacob's cuts (fade on): starts about a second before he speaks (in a
    long pause that's usually the stage changing over), or just after the
    sound before in a short pause; ends up to 1.5 s after."""
    return min(max(gap - 0.12, 0), most)


START_ROOM = 1.0
END_ROOM = 1.5


def words_from_srt(text):
    """[(start, end, word)] from a one-word-per-cue SRT, minus empty cues."""
    rx = re.compile(r"\s*(\d+:\d+:\d+[,.]\d+)\s*-->\s*(\d+:\d+:\d+[,.]\d+)")
    out = []
    for timing, lines in parse_srt(text):
        m = rx.match(timing)
        w = " ".join(lines).strip()
        if m and w:
            out.append((srt_seconds(m.group(1)), srt_seconds(m.group(2)), w))
    return out


ABBREVIATIONS = {"a.m.", "p.m.", "mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "etc.", "jr.", "sr."}


def sentences(words):
    """Group words into sentences: break after . ? ! (not "p.m." and the
    like) or a gap over 0.7 s."""
    out, cur = [], []
    for w in words:
        if cur and (w[0] - cur[-1][1] > 0.7):
            out.append(cur)
            cur = []
        cur.append(w)
        if w[2][-1:] in ".?!" and w[2].lower().strip(",") not in ABBREVIATIONS:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    # Whisper sometimes leaves out punctuation for half a minute ("…there we
    # go well I'm so glad you guys are here today hey do me a favor church
    # help me welcome third service…", 10/11). Split those run-ons where
    # spoken English starts a new thought.
    split = []
    for sent in out:
        cur = []
        for w in sent:
            if len(sent) > 20 and cur and re.sub(r"[^a-z]", "", w[2].lower()) in RESTARTS:
                split.append(cur)
                cur = []
            cur.append(w)
        split.append(cur)
    return split


RESTARTS = {"well", "hey", "alright", "okay", "ok"}


def energy(wav16):
    """Level in dB of each 10 ms of 16 kHz mono audio."""
    import numpy as np
    a = np.fromfile(wav16, dtype=np.int16, offset=44).astype(np.float32) / 32768
    n = int(16000 * FRAME)
    a = a[:len(a) // n * n].reshape(-1, n)
    return 10 * np.log10(np.mean(a * a, axis=1) + 1e-10)


def speech_windows(db, win=5.0):
    """Per 5-second window: True where it sounds like speech. Speech keeps
    dropping well below its own peaks between syllables and words; music
    (the band, or singing over it) mostly doesn't."""
    import numpy as np
    per = int(win / FRAME)
    out = []
    for i in range(0, len(db), per):
        w = db[i:i + per]
        top = np.percentile(w, 90)
        out.append(top > -50 and np.mean(w < top - 18) > 0.15)
    return np.array(out), win


def sermon_span(words, db):
    """The longest run of speech, allowing short breaks (a video clip, a
    long pause). Lyrics sung over the band don't count."""
    if len(db) == 0:
        return None
    speechy, win = speech_windows(db)
    spoken = [w for w in words if speechy[min(int(w[0] / win), len(speechy) - 1)]]
    if not spoken:
        return None
    blocks, cur = [], [spoken[0]]
    for w in spoken[1:]:
        if w[0] - cur[-1][1] > 25:
            blocks.append(cur)
            cur = []
        cur.append(w)
    blocks.append(cur)
    best = max(blocks, key=lambda b: b[-1][1] - b[0][0])
    return best[0][0], best[-1][1]


def speech_span(db):
    """Where the long stretch of talking is, from the sound alone (5-second
    windows; breaks of up to 25 s allowed). Good enough to know which parts
    of the service to transcribe."""
    if len(db) == 0:
        return None
    speechy, win = speech_windows(db)
    best = start = last = None
    for i, talk in enumerate(speechy):
        if not talk:
            continue
        if start is None or i - last > 5:
            start = i
        last = i
        if best is None or last - start > best[1] - best[0]:
            best = (start, last)
    return None if best is None else (best[0] * win, (best[1] + 1) * win)


def refine_span(words, db, coarse):
    """The talking's first and last words, near the edges `speech_span` found."""
    speechy, win = speech_windows(db)
    spoken = [w for w in words if speechy[min(int(w[0] / win), len(speechy) - 1)]]
    first = [w for w in spoken if w[0] >= coarse[0] - 10]
    last = [w for w in spoken if w[1] <= coarse[1] + 10]
    return (first[0][0], last[-1][1]) if first and last else coarse


# The parts of the service to transcribe, around where the talking starts
# and ends (seconds before, after). They cover every window find_cuts looks
# in, with room to spare.
START_LISTEN = (180, 480)
END_LISTEN = (720, 60)


def listen_parts(span, total):
    s0, s1 = span
    parts = sorted([(max(s0 - START_LISTEN[0], 0), min(s0 + START_LISTEN[1], total)),
                    (max(s1 - END_LISTEN[0], 0), min(s1 + END_LISTEN[1], total))])
    if parts[1][0] <= parts[0][1]:
        parts = [(parts[0][0], max(parts[0][1], parts[1][1]))]
    return parts


def slice_wav(src, a, b, dst):
    """Seconds a..b of a 16 kHz mono WAV, as its own WAV."""
    import wave
    with wave.open(src, "rb") as r, wave.open(dst, "wb") as w:
        rate = r.getframerate()
        w.setnchannels(r.getnchannels())
        w.setsampwidth(r.getsampwidth())
        w.setframerate(rate)
        r.setpos(min(int(a * rate), r.getnframes()))
        w.writeframes(r.readframes(max(int((b - a) * rate), 0)))


def loud_threshold(db, a, b):
    """A level between the quiet and the talking around a..b (seconds)."""
    import numpy as np
    seg = db[max(int(a / FRAME), 0):max(int(b / FRAME), 1)]
    if len(seg) < 10:
        return -40.0
    return max(np.percentile(seg, 10) + 10, np.percentile(seg, 95) - 20)


def talking(db, thr):
    """Per 10 ms frame: inside sustained sound (12 of 20 frames loud), so a
    clap or a mic bump doesn't count as his voice."""
    import numpy as np
    if len(db) < 20:
        return db > thr
    loud = (db > thr).astype(np.int32)
    c = np.convolve(loud, np.ones(20, dtype=np.int32), mode="same")
    return c >= 12


def voice_start(db, t, upto):
    """Where his voice really starts for a sentence Whisper stamps from t
    (ending at upto), and how long it was quiet before that.

    Whisper's stamp for a first word is unreliable: after a long pause it's
    often seconds early, and after a short one it can land on the tail of
    the phrase before. So: if the stamp is in a sound that began just before
    it (within 0.3 s), that's him; otherwise take the first sound after it
    that's followed by real talking (a clap or mic bump isn't). If it's in
    a sound that's been going over 1.5 s (applause or music running straight
    into him), Whisper's time is as good as it gets."""
    import numpy as np
    # His level, from his own talking (what came before may be the band).
    thr = loud_threshold(db, t - 0.3, upto + 3)
    lo, hi = max(int((t - 8.0) / FRAME), 0), min(int((upto + 1.5) / FRAME), len(db))
    if hi - lo < 2:
        return t, 0.0
    on = talking(db[lo:hi], thr)
    k0 = min(max(int(t / FRAME) - lo, 0), len(on) - 1)
    k = None
    if on[k0]:
        back = k0
        while back > 0 and on[back - 1] and k0 - back < 150:
            back -= 1
        if k0 - back <= 30:
            k = back
        elif k0 - back >= 150:
            return t, 0.0
    if k is None:
        dense = np.convolve(on.astype(np.int32), np.ones(150, dtype=np.int32))[149:] >= 40
        rises = [r for r in range(max(k0, 1), min(int(upto / FRAME) - lo, len(on)))
                 if on[r] and not on[r - 1] and dense[r]]
        if not rises:
            return t, 0.0
        k = rises[0]
    gap = 0
    while k - gap - 1 >= 0 and not on[k - gap - 1]:
        gap += 1
    return (lo + k) * FRAME, gap * FRAME


def voice_stop(db, t, since):
    """Where his voice really stops for a last word Whisper stamps since..t,
    and how long it stays quiet after. Whisper's stamp can be off either way
    (on 10/11 the last word was 0.7 s late, with his mic being faded down for
    a video); he has to stop between 1.5 s before it starts and 0.6 s after
    it ends, so music coming straight in isn't taken for him."""
    import numpy as np
    # His level, from his own talking: what comes next may be much louder
    # (a video, the band).
    thr = loud_threshold(db, since - 3, t + 0.3)
    lo, hi = max(int((since - 1.5) / FRAME), 0), min(int((t + 6.5) / FRAME), len(db))
    if hi - lo < 2:
        return t, 0.0
    on = talking(db[lo:hi], thr)
    behind = np.convolve(on.astype(np.int32), np.ones(150, dtype=np.int32))[:len(on)] >= 15
    k1 = int(t / FRAME) - lo
    falls = [k for k in range(max(int((since - 1.5) / FRAME) - lo, 1), min(k1 + 60, len(on) - 1))
             if on[k] and not on[k + 1] and behind[k]]
    if not falls:
        return t, 0.0
    k = falls[-1]
    gap = 0
    while k + gap + 1 < len(on) and not on[k + gap + 1]:
        gap += 1
    return (lo + k + 1) * FRAME, gap * FRAME


def quote(sentence, limit=14):
    ws = [w[2] for w in sentence]
    return " ".join(ws[:limit]) + (" …" if len(ws) > limit else "")


def find_cuts(words, db, total=None, span=None):
    """Candidate starts and ends, best first. Each has the cut point (time),
    the far edge of the pause it's in (room), his first or last word there
    (word), and why. `span` (first and last word of the talking) is worked
    out from the words if not given."""
    span = span or sermon_span(words, db)
    if not span:
        return None
    s0, s1 = span
    sents = sentences(words)

    def hits(patterns, lo, hi):
        """(pattern rank, sentence index) for sentences starting in lo..hi."""
        out = []
        for k, sent in enumerate(sents):
            if lo <= sent[0][0] <= hi:
                text = " ".join(w[2] for w in sent).lower()
                rank = next((r for r, p in enumerate(patterns) if re.search(p, text)), None)
                if rank is not None:
                    out.append((rank, k))
        return out

    def start_at(k, why):
        """Cut in the pause before sentence k."""
        first = sents[k]
        t, gap = voice_start(db, first[0][0], first[-1][1])
        return {"time": t - cut_room(gap, START_ROOM), "room": t - gap, "word": t,
                "why": why + quote(first)}

    def end_at(k, why, upto=None):
        """Cut in the pause after sentence k (only its words up to `upto`)."""
        last = [w for w in sents[k] if upto is None or w[0] <= upto] or sents[k][:1]
        t, gap = voice_stop(db, last[-1][1], last[-1][0])
        return {"time": t + cut_room(gap, END_ROOM), "room": t + gap, "word": t,
                "why": why + quote(last)}

    def opener_start(k):
        """Back up over attention-getters said just before sentence k."""
        while k > 0 and re.match(OPENER, " ".join(w[2] for w in sents[k - 1]).lower()) \
                and start_at(k, "")["word"] - sents[k - 1][-1][1] < 4.0:
            k -= 1
        return k

    starts, ends = [], []
    signs = hits(SIGN_ON, s0 - 120, s0 + 300)
    if signs:
        # The strongest sign ("third service" before a plain "welcome", which
        # a worship leader might say too), then the first greeting leading up
        # to it ("Well, I'm so glad you guys are here today. … Help me welcome
        # third service").
        rank, best = min(signs, key=lambda h: (h[0], h[1]))
        # His run of talking: back to the last pause over 4 s, measured in
        # the sound (Whisper's timing of a gap isn't reliable), like the stage
        # changing over. If that's within 45 s, he starts there; otherwise
        # (talking straight on from announcements) at a personal greeting
        # within 30 s, or at the welcome itself.
        first = best
        while first > 0 and voice_start(db, sents[first][0][0], sents[first][-1][1])[1] < 4 \
                and sents[best][0][0] - sents[first - 1][0][0] <= 60:
            first -= 1
        quiet_before = voice_start(db, sents[first][0][0], sents[first][-1][1])[1] >= 4
        if quiet_before and sents[best][0][0] - sents[first][0][0] <= 45:
            lead = first
        else:
            greetings = [k for _, k in hits(GREETING, sents[best][0][0] - 30, sents[best][0][0])]
            lead = min(greetings + [best])
        starts.append(start_at(opener_start(lead), "He starts with: "))
        for _, k in sorted(signs, key=lambda h: h[1]):
            starts.append(start_at(opener_start(k), "He starts with: "))
    first_spoken = next(k for k, x in enumerate(sents) if x[-1][1] >= s0)
    starts.append(start_at(first_spoken, "Where the long stretch of talking starts: "))

    # In order of how Jacob ended them: right before a video he introduces
    # (10/11), right after the handoff to the third service's host (9/13),
    # at his sign-off (9/20); then the other places it could end.
    intro = hits([VIDEO_INTRO], s1 - 600, s1 + 30)
    for _, k in intro:
        if sents[k][0][0] > s0 + 300 and (0, k + 1) not in intro:
            ends.append(end_at(k, "Right before the video he introduces: "))
    handoff = hits(HANDOFF, s1 - 420, s1 + 30)
    after_handoff = [k for _, k in handoff if sents[k][0][0] > s0 + 300 and not any(h[1] == k + 1 for h in handoff)]
    for k in after_handoff:
        ends.append(end_at(k, "Right after he hands the third service to their host: "))
    for _, k in sorted(hits(SIGN_OFF, s1 - 300, s1 + 30), key=lambda h: -h[1]):
        ends.append(end_at(k, "His sign-off: "))
    for _, k in sorted(hits(CLOSING, s1 - 600, s1 + 30), key=lambda h: h[1]):
        if sents[k][0][0] > s0 + 300 and k > 0:
            ends.append(end_at(k - 1, "Before he starts to wrap up (\"" + quote(sents[k], 8) + "\"): "))
    for _, k in handoff:
        if sents[k][0][0] > s0 + 300 and k > 0 and not any(h[1] == k - 1 for h in handoff):
            ends.append(end_at(k - 1, "Just before the hand-off to the third service host: "))
    last_spoken = max(k for k, x in enumerate(sents) if x[0][0] <= s1)
    # Clipped at the end of the talking: a sentence can run on into lyrics.
    if total is not None and total - s1 < 3:
        ends.append(end_at(last_spoken, "The recording stops right after: ", upto=s1))
    else:
        ends.append(end_at(last_spoken, "His last words before the music: ", upto=s1))

    def dedupe(cands):
        out = []
        for c in cands:
            if all(abs(c["time"] - o["time"]) > 1.5 for o in out):
                out.append(c)
        return out[:5]

    return {"sermon": [s0, s1], "starts": dedupe(starts), "ends": dedupe(ends)}


def suggest(video, out_json):
    import json
    for tool in (FFMPEG, WHISPER):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    total = duration(video)
    start = ensure_model()
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "audio.wav")
        P.stage("Pulling out the audio…", start, start + 0.04 * (1 - start))
        ffmpeg(["-i", video, "-map", "0:a:0", "-ar", "16000", "-ac", "1", wav], total, P.set)

        db = energy(wav)
        coarse = speech_span(db)
        if not coarse:
            fail("Couldn't find any speaking in this video.")

        # Only the parts around where the talking starts and ends: about 20
        # minutes instead of the whole service.
        P.stage("Listening to the start and end of the message…", start + 0.04 * (1 - start), 0.98)
        parts = listen_parts(coarse, total)
        length = sum(b - a for a, b in parts)
        words, done = [], 0.0
        for k, (a, b) in enumerate(parts):
            piece = os.path.join(tmp, f"part{k}.wav")
            slice_wav(wav, a, b, piece)
            # No carried-over context: over music Whisper invents "Thank you."
            # and would otherwise keep repeating it.
            srt = whisper(piece, os.path.join(tmp, f"part{k}"), 1, ["-mc", "0", "-sns"],
                          on_frac=lambda f, done=done, n=b - a: P.set((done + f * n) / length))
            words += [(x + a, y + a, w) for x, y, w in words_from_srt(open(srt, encoding="utf-8").read())]
            done += b - a
        P.stage("Finding the start and end…", 0.98, 1.0)

    result = find_cuts(words, db, total, refine_span(words, db, coarse))
    if not result:
        fail("Couldn't find any speaking in this video.")
    result["duration"] = total
    write_atomic(out_json, json.dumps(result, indent=1))
    P.set(1.0)


# -------------------------------------------------------------------- repair

# Only Resemble Enhance's training code uses these; stand-ins let its model
# load without them (DeepSpeed doesn't exist for Macs at all).
# A stand-in that accepts anything: any attribute, any call, prints as "".
_ANYTHING = ("class _Anything:\n"
             "    def __init__(self, *a, **k): pass\n"
             "    def __call__(self, *a, **k): return _Anything()\n"
             "    def __getattr__(self, name): return _Anything()\n"
             "    def __iter__(self): return iter(())\n"
             "    def __str__(self): return ''\n"
             "def __getattr__(name):\n"
             "    return _Anything()\n")
REPAIR_STUBS = {
    "deepspeed/__init__.py": "class DeepSpeedConfig:\n    def __init__(self, *a, **k): pass\n"
                             "def init_distributed(*a, **k): pass\n",
    "deepspeed/accelerator/__init__.py": "class _A:\n    def communication_backend_name(self): return 'gloo'\n"
                                         "def get_accelerator(): return _A()\n",
    "deepspeed/runtime/__init__.py": "",
    "deepspeed/runtime/engine.py": "class DeepSpeedEngine: pass\n",
    "deepspeed/runtime/utils.py": "def clip_grad_norm_(*a, **k): return 0.0\n",
    "matplotlib/__init__.py": "",
    "matplotlib/pyplot.py": _ANYTHING,
    "pandas/__init__.py": _ANYTHING,
    "celluloid/__init__.py": _ANYTHING,
    "soundfile/__init__.py": _ANYTHING,
    "librosa/__init__.py": _ANYTHING,
}


def ensure_repair_model(lo, hi):
    """Download Resemble Enhance (680 MB) if needed, on the bar from lo to hi."""
    missing = [f for f in REPAIR_FILES if not os.path.exists(os.path.join(REPAIR_DIR, f))]
    if not missing:
        return lo
    P.stage("Downloading the voice repair model (one time only, 680 MB)…", lo, hi)
    for k, f in enumerate(missing):
        download(REPAIR_URL + f, os.path.join(REPAIR_DIR, f), "voice repair model",
                 lambda x, k=k: P.set((k + x) / len(missing)))
    return hi


def resemble(wav, sr, on_frac, stubs):
    """Resemble Enhance on mono float audio; returns (audio, rate)."""
    import types
    import numpy as np
    import scipy.optimize
    import torch
    import torch.nn.functional as F
    from pathlib import Path
    for rel, body in REPAIR_STUBS.items():
        path = os.path.join(stubs, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(body)
    sys.path.insert(0, stubs)
    import resemble_enhance.inference as ri
    import resemble_enhance.enhancer.lcfm.cfm as cfm
    from resemble_enhance.enhancer.enhancer import Enhancer
    from resemble_enhance.enhancer.hparams import HParams

    # Written for older NumPy: float() of fsolve's one-element array.
    solve = scipy.optimize.fsolve
    cfm.scipy = types.SimpleNamespace(optimize=types.SimpleNamespace(
        fsolve=lambda *a, **k: float(np.ravel(solve(*a, **k))[0])))

    class SplitConv(torch.nn.Module):
        """Apple's GPU backend gets a Conv1d with very many output channels
        (221,184 in the vocoder) wrong; in slices it's exact."""
        def __init__(self, conv, step=4096):
            super().__init__()
            self.conv, self.step = conv, step

        def forward(self, x):
            w, b = self.conv.weight, self.conv.bias
            out = None
            for i in range(0, w.shape[0], self.step):
                part = F.conv1d(x, w[i:i + self.step], None if b is None else b[i:i + self.step],
                                self.conv.stride, self.conv.padding, self.conv.dilation)
                if out is None:
                    out = part.new_empty(part.shape[0], w.shape[0], part.shape[2])
                out[:, i:i + part.shape[1]] = part
            return out

    def load(device):
        model = Enhancer(HParams.load(Path(REPAIR_DIR)))
        state = torch.load(os.path.join(REPAIR_DIR, "ds/G/default/mp_rank_00_model_states.pt"),
                           map_location="cpu")["module"]
        model.load_state_dict(state)
        model.eval()
        for block in model.vocoder.blocks:
            for name in ("kernel_conv", "bias_conv"):
                conv = getattr(block.kernel_predictor, name)
                if conv.out_channels > 8192:
                    setattr(block.kernel_predictor, name, SplitConv(conv))
        ri.remove_weight_norm_recursively(model)
        model.to(device)
        # Resemble's own settings, with only a light touch of its denoiser.
        model.configurate_(nfe=64, solver="midpoint", lambd=0.1, tau=0.5)
        if device == "mps":
            # On the graphics chip, the two heavy parts run at half
            # precision: about twice as fast, and the result differs from
            # full precision far less than two runs of the model differ from
            # each other.
            model.lcfm.cfm.net = Half(model.lcfm.cfm.net)
            model.vocoder = Half(model.vocoder)
        # The vocoder needs about 15 GB per piece, so it never gets a batch.
        model.vocoder = OneAtATime(model.vocoder)
        return model

    class Half(torch.nn.Module):
        def __init__(self, net):
            super().__init__()
            self.net = net.half()

        def forward(self, *args, **kwargs):
            half = lambda a: a.half() if torch.is_tensor(a) else a
            return self.net(*map(half, args), **{k: half(v) for k, v in kwargs.items()}).float()

    class OneAtATime(torch.nn.Module):
        def __init__(self, net):
            super().__init__()
            self.net = net

        def forward(self, x, y=None):
            return torch.cat([self.net(x[i:i + 1], y) for i in range(len(x))])

    def enhance(model, x, device):
        """Resemble's own inference (30 s pieces, 29 s apart, merged), but
        with up to `batch` same-length pieces through the model at once."""
        size, hop = 30 * 44100, 29 * 44100
        pieces = [x[s:s + size] for s in range(0, len(x), hop)]
        chunks = []
        # Keep the bar moving within a batch: the flow model's steps are
        # about 60% of the time and the vocoder (one piece at a time) the rest.
        steps, group = [0, 0], []
        def tick(k):
            steps[k] += 1
            within = 0.6 * min(steps[0] / model.lcfm.cfm.solver.nfe, 1) + 0.4 * steps[1] / len(group)
            on_frac((len(chunks) + within * len(group)) / len(pieces))
        model.lcfm.cfm.net.register_forward_hook(lambda *_: tick(0))
        model.vocoder.net.register_forward_hook(lambda *_: tick(1))
        while len(chunks) < len(pieces):
            group = pieces[len(chunks):len(chunks) + batch]
            # The last piece is usually shorter: it goes on its own.
            group = [c for c in group if len(c) == len(group[0])]
            steps[:] = [0, 0]
            peak = torch.stack([c.abs().max().clamp(min=1e-7) for c in group])[:, None]
            wavs = F.pad(torch.stack(group) / peak, (0, 441)).to(device)
            chunks += list(model(wavs).cpu()[:, :len(group[0])] * peak)
            on_frac(len(chunks) / len(pieces))
        return ri.merge_chunks(chunks, size, hop, sr=44100, length=len(x))

    # A last piece of a few hundred samples is too short for Resemble's
    # spectrum step, so pad that case (and cut the padding off the result).
    assert sr == 44100
    n, hop = len(wav), 29 * 44100
    short = n % hop
    if 0 < short < 2 * 44100:
        wav = np.concatenate([wav, np.zeros(2 * 44100 - short, dtype=np.float32)])
    x = torch.from_numpy(np.ascontiguousarray(wav, dtype=np.float32))
    # Four pieces at a time is about 10% faster but needs about 13 GB of
    # memory; on a smaller Mac, one at a time.
    batch = 4 if os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") >= 32e9 else 1
    lo, hi = P.lo, P.hi
    for device in (["mps"] if torch.backends.mps.is_available() else []) + ["cpu"]:
        try:
            with torch.inference_mode():
                out = enhance(load(device), x, device)
            return out.numpy()[:n], 44100
        except Fail:
            raise
        except Exception as e:
            if device == "cpu":
                raise
            if hasattr(torch, "mps"):
                torch.mps.empty_cache()
            P.stage(f"Repairing his voice without the graphics chip ({type(e).__name__}); this is much slower…",
                    lo, hi)


def repair(video, start, length, out_wav, *music):
    import numpy as np
    for tool in (FFMPEG, FFPROBE):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    start, length = float(start), float(length)
    music = parse_music(music)
    base = ensure_repair_model(0.0, 0.4)
    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, "sound.f32")
        P.stage("Getting the sound ready…", base, base + 0.03 * (1 - base))
        inputs, graph = mixed_sound(video, music, 0)
        graph += (f"[mix]atrim=start={start:.6f}:duration={length:.6f},asetpts=PTS-STARTPTS,"
                  f"aresample=44100,pan=mono|c0=0.5*c0+0.5*c1[a]")
        ffmpeg(inputs + ["-filter_complex", graph, "-map", "[a]", "-f", "f32le", "-y", raw], length, P.set)
        sound = np.fromfile(raw, dtype=np.float32)
        if len(sound) < 44100:
            fail("There's no sound to repair there.")

        P.stage("Repairing his voice (this takes a while)…", base + 0.03 * (1 - base), 0.98)
        voice, rate = resemble(sound, 44100, P.set, os.path.join(tmp, "stubs"))

        P.stage("Finishing up…", 0.98, 1.0)
        # The loudest second of the original, so the trim window's player can
        # line the repaired voice up with its own decoding (see separate).
        per = 44100
        loud = max(range(len(sound) // per), key=lambda k: float(np.square(sound[k * per:(k + 1) * per]).sum()))
        at = start + loud
        r = subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-i", video, "-map", "0:a:0",
                            "-af", f"aresample={RATE},atrim=start={at:.6f}:duration=1",
                            "-ac", "1", "-f", "f32le", "-"], capture_output=True)
        ref = np.frombuffer(r.stdout, dtype=np.float32)[:RATE]
        partial = out_wav + ".partial"
        try:
            with open(partial, "wb") as f:
                f.write(struct.pack("<q", int(round(at * RATE))))
                f.write(ref.astype(np.float32).tobytes())
            os.replace(partial, out_wav + ".ref")
            with open(partial, "wb") as f:
                write_wav_header(f, len(voice), channels=1, rate=rate)
                f.write(np.asarray(voice, dtype=np.float32).tobytes())
            os.replace(partial, out_wav)
        finally:
            if os.path.exists(partial):
                os.remove(partial)
        P.set(1.0)


# --------------------------------------------------------------------- music

BLOCK = 30.0            # seconds of audio given to the model at a time
OVERLAP = 2.0           # crossfade between blocks


def stereo(video):
    """Filter to 48 kHz float stereo, used the same way by `separate` and
    `trim` so the music file lines up. Mono goes to both sides at full
    level, as the app's player does it (ffmpeg's own upmix is 3 dB down)."""
    fmt = f"aresample={RATE},aformat=sample_fmts=flt"
    if probe(video, "stream=channels", "a:0").split("\n")[0] == "1":
        return fmt + ",pan=stereo|c0=c0|c1=c0"
    return fmt + ":channel_layouts=stereo"


def write_wav_header(f, frames, channels=2, rate=RATE):
    data = frames * channels * 4
    f.write(b"RIFF" + struct.pack("<I", 36 + data) + b"WAVE")
    f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, channels, rate, rate * channels * 4,
                                  channels * 4, 32))
    f.write(b"data" + struct.pack("<I", data))


def load_demucs():
    from demucs.apply import BagOfModels
    from demucs.hf import load_safetensors_model
    model = BagOfModels([load_safetensors_model(MUSIC_MODEL)])
    model.eval()
    return model


def demucs_vocals(model, src, dst, on_frac):
    """Voice only, from 44.1 kHz stereo float32 raw audio, in blocks so a
    long section never has to fit in memory at once."""
    import numpy as np
    import torch
    from demucs.apply import apply_model

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    sr = model.samplerate
    voice = model.sources.index("vocals")
    mix = np.memmap(src, dtype=np.float32, mode="r").reshape(-1, 2)
    n = len(mix)

    # Normalise the way demucs' own command line does, over the whole section.
    total = sq = 0.0
    for i in range(0, n, sr * 60):
        mono = mix[i:i + sr * 60].astype(np.float64).mean(axis=1)
        total += mono.sum()
        sq += (mono * mono).sum()
    mean = total / n
    std = max((sq / n - mean * mean) ** 0.5, 1e-6)

    block, overlap = int(BLOCK * sr), int(OVERLAP * sr)
    tail = None
    pos = 0
    with open(dst, "wb") as out:
        while pos < n:
            last = n - pos <= block + overlap + 10 * sr    # don't leave a scrap
            end = n if last else pos + block + overlap
            x = torch.from_numpy(np.ascontiguousarray(mix[pos:end].T))
            x = (x - mean) / std
            with torch.no_grad():
                y = apply_model(model, x[None], device=device, shifts=1, split=True,
                                overlap=0.25, progress=False)[0, voice]
            v = (y * std + mean).cpu().numpy().T.astype(np.float32)
            if tail is not None:
                w = np.linspace(0, 1, len(tail), endpoint=False, dtype=np.float32)[:, None]
                v[:len(tail)] = tail * (1 - w) + v[:len(tail)] * w
            if last:
                out.write(v.tobytes())
                break
            out.write(v[:block].tobytes())
            tail = v[block:].copy()
            pos += block
            on_frac(pos / n)
    on_frac(1.0)


def separate(video, *sections):
    """Each section is FROM TO OUT.wav; the model loads once for all of them."""
    for tool in (FFMPEG, FFPROBE):
        if not os.path.exists(tool):
            fail(f"Missing {tool}")
    if not os.path.exists(MUSIC_MODEL):
        fail(f"Missing {MUSIC_MODEL}")
    jobs = [(int(sections[i]), int(sections[i + 1]), sections[i + 2])
            for i in range(0, len(sections), 3)]
    if any(end - start < RATE for start, end, _ in jobs):
        fail("Each music section has to be at least a second long.")
    P.stage("Loading the music separator…", 0.0, 0.02)
    model = load_demucs()
    fmt = stereo(video)
    total = sum(end - start for start, end, _ in jobs)
    done = 0
    for k, (start, end, out_wav) in enumerate(jobs):
        lo = 0.02 + 0.98 * done / total
        done += end - start
        hi = 0.02 + 0.98 * done / total
        at = int(start / RATE)
        which = f" (the section at {at // 3600}:{at // 60 % 60:02d}:{at % 60:02d})" if len(jobs) > 1 else ""
        separate_one(video, fmt, model, start, end, out_wav, lo, hi, which)


def separate_one(video, fmt, model, start, end, out_wav, lo, hi, which):
    import numpy as np
    n = end - start
    part = lambda a, b: (lo + (hi - lo) * a, lo + (hi - lo) * b)
    raw = ["-f", "f32le", "-ac", "2"]
    with tempfile.TemporaryDirectory() as tmp:
        orig, mix, voice44, voice = (os.path.join(tmp, f) for f in
                                     ("orig.f32", "mix.f32", "voice44.f32", "voice.f32"))
        P.stage(f"Pulling out the audio{which}…", *part(0.0, 0.05))
        # Same decode as the trim step's, counted in samples from the start.
        ffmpeg(["-i", video, "-map", "0:a:0", "-af",
                f"{fmt},atrim=start_sample={start}:end_sample={end}", *raw, "-y", orig],
               n / RATE, P.set)
        if os.path.getsize(orig) < RATE * 8:
            fail(f"There's no sound in the music section{which}.")
        ffmpeg(["-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", orig,
                "-af", "aresample=44100", *raw, "-y", mix], n / RATE, lambda f: None)

        P.stage(f"Separating his voice from the music{which}…", *part(0.05, 0.95))
        demucs_vocals(model, mix, voice44, P.set)

        P.stage(f"Finishing up{which}…", *part(0.95, 1.0))
        ffmpeg(["-f", "f32le", "-ar", "44100", "-ac", "2", "-i", voice44,
                "-af", f"aresample={RATE}", *raw, "-y", voice], n / RATE, lambda f: None)
        o = np.memmap(orig, dtype=np.float32, mode="r").reshape(-1, 2)
        v = np.memmap(voice, dtype=np.float32, mode="r").reshape(-1, 2)
        n = len(o)
        ramp = max(min(int(MUSIC_RAMP * RATE), n // 4), 1)
        # The app's player can decode the original a few ms off from ffmpeg
        # (they treat the encoder's start padding differently), so leave it
        # the loudest second of the original to line its copy up against.
        loud = max(range(n // RATE), key=lambda k: float(np.square(o[k * RATE:(k + 1) * RATE]).sum()))
        ref = out_wav + ".ref"
        partial = out_wav + ".partial"
        try:
            with open(partial, "wb") as f:
                f.write(struct.pack("<q", start + loud * RATE))
                f.write(o[loud * RATE:(loud + 1) * RATE].mean(axis=1).astype(np.float32).tobytes())
            os.replace(partial, ref)
            with open(partial, "wb") as f:
                write_wav_header(f, n)
                for i in range(0, n, RATE * 10):
                    j = min(i + RATE * 10, n)
                    d = np.zeros((j - i, 2), dtype=np.float32)
                    k = min(j, len(v)) - i
                    if k > 0:
                        d[:k] = v[i:i + k]
                    d -= o[i:j]
                    # Fade the change in over the first second and out over the last.
                    idx = np.arange(i, j)
                    env = np.minimum(np.minimum(idx, n - 1 - idx) / ramp, 1.0)
                    env = (0.5 - 0.5 * np.cos(np.pi * env)).astype(np.float32)
                    f.write((d * env[:, None]).tobytes())
                    P.set(j / n)
            os.replace(partial, out_wav)
        finally:
            if os.path.exists(partial):
                os.remove(partial)


def main():
    args = sys.argv[2:]
    captions = repaired = intro = outro = None
    intro_fade = outro_fade = 0.0
    while sys.argv[1:2] == ["trim"] and args[:1] in (["--captions"], ["--repair"], ["--intro"], ["--outro"],
                                                     ["--intro-crossfade"], ["--outro-crossfade"]):
        if args[0] == "--captions" and len(args) > 1:
            captions, args = args[1], args[2:]
        elif args[0] == "--intro" and len(args) > 1:
            intro, args = args[1], args[2:]
        elif args[0] == "--outro" and len(args) > 1:
            outro, args = args[1], args[2:]
        elif args[0] in ("--intro-crossfade", "--outro-crossfade") and len(args) > 1:
            try:
                seconds = float(args[1])
                assert 0 <= seconds <= 10
            except (ValueError, AssertionError):
                fail(f"{args[0]} takes a number of seconds (0 to 10), not {args[1]}.")
            if args[0] == "--intro-crossfade":
                intro_fade = seconds
            else:
                outro_fade = seconds
            args = args[2:]
        elif args[0] == "--repair" and len(args) > 2:
            repaired, args = (args[1], args[2]), args[3:]
        else:
            break
    if sys.argv[1:2] == ["trim"] and len(args) >= 7 and (len(args) - 7) % 3 == 0:
        trim(*args, captions=captions, repair=repaired, intro=intro, outro=outro,
             intro_fade=intro_fade, outro_fade=outro_fade)
    elif len(sys.argv) >= 6 and (len(sys.argv) - 6) % 3 == 0 and sys.argv[1] == "repair":
        repair(*sys.argv[2:])
    elif len(sys.argv) >= 6 and (len(sys.argv) - 3) % 3 == 0 and sys.argv[1] == "separate":
        separate(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "suggest":
        suggest(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "transcribe":
        transcribe(*sys.argv[2:])
    elif len(sys.argv) == 7 and sys.argv[1] == "spanish":
        spanish(*sys.argv[2:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "send":
        send(*sys.argv[2:])
    else:
        fail("usage: trim [--captions OUT.srt] [--repair VOICE.wav FROM] [--intro CLIP [--intro-crossfade SECONDS]] "
             "[--outro CLIP [--outro-crossfade SECONDS]] VIDEO OUT.mp4 START LENGTH FADE LEVEL LOOK.cube "
             "[MUSIC.wav AT AMOUNT]... | "
             "repair VIDEO START LENGTH OUT.wav [MUSIC.wav AT AMOUNT]... | "
             "separate VIDEO FROM TO OUT.wav [FROM TO OUT.wav]... | suggest VIDEO OUT.json | "
             "transcribe VIDEO OUT.srt | "
             "spanish ORIG SPANISH EN.srt OUT.srt OUT.mp4 | send VIDEO | send --to FOLDER FILE...")
    emit("DONE")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        emit("ERROR", str(e))
        sys.exit(1)
    except Exception as e:
        emit("ERROR", f"Something went wrong: {type(e).__name__}: {e}")
        sys.exit(1)
