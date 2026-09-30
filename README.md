<p align="center">
  <img src="docs/icon.png" width="128" alt="RecBar icon">
</p>

<h1 align="center">RecBar</h1>

<p align="center">
  <strong>Headless meeting recorder for macOS.</strong><br>
  Records your screen, the meeting audio, and your microphone as <em>separate tracks</em> —
  no bot in the call, no overlay on your screen, nothing uploaded anywhere.
</p>

<p align="center">
  <a href="https://github.com/<you>/recbar/actions"><img src="https://github.com/<you>/recbar/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-15.2%2B-blue" alt="macOS 15.2+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

---

Most meeting recorders either send a bot into your call, upload your audio to
someone's cloud, or draw a toolbar over the screen you're presenting. RecBar
does none of that. It sits in the Dock (or runs from a terminal), captures
what you tell it to via Apple's ScreenCaptureKit, and writes one `.mov`:

| Track   | Contents                                    | Codec                       |
| ------- | ------------------------------------------- | --------------------------- |
| Video   | Display, one window, or all windows of an app | HEVC ~4 Mbps (≈1.8 GB/hour) |
| Audio 1 | System audio — the other participants       | AAC 48 kHz stereo           |
| Audio 2 | Microphone — you                            | AAC 48 kHz mono             |

The two audio tracks are **never mixed**. That's the whole point: each side of
the conversation can be transcribed on its own, so "who said what" is exact
instead of guessed by a diarization model.

## Features

- **Capture what you choose** — the whole display, a single window, or an
  entire app. Window/app capture also **limits the recorded audio to that app**,
  so Slack pings and Spotify stay out of the meeting track.
- **Invisible while you present** — no floating toolbar, no countdown, no
  frame. Only macOS's own purple recording indicator (unavoidable).
- **Dock icon with a REC badge**, live level meters for mic and system audio,
  a live thumbnail of what's being captured, and a **"no mic signal" warning**
  so you never finish a meeting to find your side missing.
- **Thumbnail source picker** (Window / App / Entire screen), plus a global
  hotkey (⌃⌥R) and a terminal-controllable CLI: `rec start`, `rec stop`.
- **Crash-resilient files** — written in 5-second fragments, so a force-quit
  or kernel panic mid-meeting still leaves a playable recording.
- **Audio clean-up in the background** — denoise, gentle compression,
  two-pass EBU R128 loudness normalization, run after Stop at low priority
  while you're free to start the next recording. Video is stream-copied,
  never re-encoded.
- **Local transcription to `.srt`** with WhisperKit (large-v3 on the Neural
  Engine), speaker-labeled `[Me]` / `[Them]`; optional translate-to-English.
- **Echo-cancelled microphone** — the mic is captured through macOS voice
  processing (the same path FaceTime uses), so the meeting audio coming out of
  your speakers doesn't end up on your mic track. Speakers work; headphones
  aren't required.
- **Microphone picker** — use your AirPods or headset without changing the
  system default.
- **Nothing leaves your Mac.** No account, no telemetry, no network calls
  (other than the one-time model download for transcription, if you opt in).

<p align="center">
  <img src="docs/panel.png" width="360" alt="RecBar panel">
</p>

## Install

**Homebrew** (builds from source, no Gatekeeper prompt):

```sh
brew tap <you>/recbar
brew install recbar
cp -R "$(brew --prefix)/opt/recbar/RecBar.app" /Applications/
```

**Download:** a signed, notarized `RecBar.app` and the `rec` binary are on the
[Releases](https://github.com/<you>/recbar/releases) page.

**From source:**

```sh
git clone https://github.com/<you>/recbar && cd recbar
make install PREFIX=/opt/homebrew/bin   # the `rec` CLI
make install-app                        # RecBar.app → /Applications
```

Requirements: macOS 15.2 or newer, Apple silicon or Intel. Optional runtime
tools via Homebrew: `ffmpeg` (audio clean-up) and `whisperkit-cli`
(transcription). Recording itself needs nothing extra.

### First run: permissions

macOS will ask for **Screen & System Audio Recording** and **Microphone**.
Grant both to *RecBar* (and to your terminal app if you use `rec`) in
System Settings → Privacy & Security, then relaunch. This happens once.

## Using RecBar

Click the Dock icon or press **⌃⌥R** to open the panel:

1. **Record:** — pick the entire display, a window from the dropdown, or
   *Choose from thumbnails…* for the visual picker. For meetings, the **App**
   tab (e.g. *Google Chrome*) is the easiest: every Chrome window, audio limited
   to Chrome.
2. **Mic:** — leave on system default or pick a headset.
3. **Start Recording.** The panel shows elapsed time, level meters, and a live
   thumbnail; the Dock badge reads REC. Close the panel if you like —
   recording continues.
4. **Stop.** The file is saved in `~/Movies/recordings/` within a second and
   the panel is ready for the next recording straight away. Audio clean-up
   runs in the background (about 2½ minutes per hour of recording, measured on
   an M-series Mac); a strip in the panel shows its progress, and several
   recordings queue up and are processed one at a time.

**Transcribe:** *Transcribe File to Subtitles…* → pick any video/audio file →
a `.srt` appears next to it, with a live progress bar. RecBar recordings get
`[Me]` / `[Them]` labels.

## Using the CLI

```sh
rec start                          # main display + system audio + mic
rec start --window "Meet"          # one window (title or app name substring)
rec start --mic "AirPods"          # choose the microphone
rec start --audio-only             # no video, ~115 MB/hour
rec start --no-echo-cancel         # raw mic (no voice processing)
rec start --meter                  # print mic/audio levels every second
rec stop                           # from another terminal (or Ctrl+C)
rec status
rec windows                        # list capturable windows
rec mics                           # list microphones
rec normalize meeting.mov          # audio clean-up on an existing file, in place
rec transcribe meeting.mov         # → meeting.srt (add --translate for English)
rec export meeting.mov             # → meeting-share.mp4, one mixed audio track
```

Default output: `~/Movies/recordings/rec-YYYY-MM-DD-HHmmss.mov`. Both
`Ctrl+C` and `rec stop` finalize the file cleanly and return immediately; the
audio clean-up then continues as a detached background job, so you can
`rec start` the next recording right away. `rec status` shows what's being
processed, and output goes to `~/Library/Logs/RecBar/processing.log`. Jobs
from the CLI and from RecBar share one queue and never run at the same time.
Use `rec start --wait` if a script needs the processed file when `rec` exits.

## Working with the tracks

```sh
# split the sides for your own transcription / summary pipeline
ffmpeg -i meeting.mov -map 0:a:0 them.wav -map 0:a:1 me.wav
```

`0:a:0` = system audio (participants), `0:a:1` = microphone (you).

Multi-track playback varies by player: **QuickTime** mixes both tracks;
**VLC** plays one at a time (Audio → Audio Track → Track 2 for the mic). Most
upload targets and other people's players use **only the first track** — so
before sharing, export a single-track copy:

```sh
rec export meeting.mov                    # meeting-share.mp4: both sides mixed,
                                          # video copied, .srt attached if present
rec export meeting.mov --burn-subtitles   # subtitles rendered into the picture
```

RecBar has the same as **Export for Sharing (.mp4)…**. The 3-track original
stays untouched. A recording made with nothing playing on the Mac has a silent
track 1 — that's expected, not a bug.

## What it can't do

- Make meeting audio sound better than the meeting app sent it (Meet, Teams,
  and Zoom compress voices heavily). The clean-up step helps; it can't add
  what was never there.
- Make a desk-distance microphone sound close. A headset or AirPods on the
  mic picker helps far more than any processing.
- Record a single browser *tab*. Tabs aren't windows — drag the tab out into
  its own window, or capture the whole browser app.
- Run on Windows or Linux. It's built on ScreenCaptureKit.

## Verifying a build

```sh
make smoke     # ~1 minute; plays a few seconds of speech through your speakers
```

Records for real and checks the results with ffprobe — track layout, levels,
echo cancellation (mic/speaker correlation), window sizing, normalize, export,
and transcription of known speech. 18 checks; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## How it works

One `SCStream` delivers screen frames, system audio, and the microphone
(native mic capture is a macOS 15 ScreenCaptureKit feature) on a shared clock,
into one `AVAssetWriter` with three inputs — which is why the tracks stay in
sync without any timestamp juggling. `RecCore` holds all of that plus the
source catalog, audio processing, and transcription, with no UI; `rec` and
`RecBar` are thin front ends over it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy

RecBar makes no network requests. Recordings and transcripts stay in
`~/Movies/recordings/` (or wherever you point it). The only download is the
WhisperKit model the first time you transcribe, and only if you use that
feature. Please check your local laws and let participants know when you
record a conversation.

## License

[MIT](LICENSE). Built by [Kai](https://github.com/<you>) at
[AppTech System](https://apptechsystem.com.sg).
