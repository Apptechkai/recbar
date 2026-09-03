# rec — headless meeting recorder for macOS

Terminal-only screen recorder for meetings. No overlay, no floating toolbar,
no on-screen UI of any kind — just the macOS purple menu-bar dot, which is
system-enforced and unavoidable. Built on ScreenCaptureKit, so system audio is
captured natively (no BlackHole / loopback drivers).

Each recording is **one `.mov` with three separate tracks**:

| Track | Contents | Codec |
|---|---|---|
| Video | Main display, full resolution | HEVC ~4 Mbps (≈1.8 GB/hour) |
| Audio 1 | System audio — the meeting participants (Chrome, etc.) | AAC 48 kHz stereo |
| Audio 2 | Microphone — your voice | AAC 48 kHz mono |

The audio is deliberately **never mixed**, so each side of the conversation can
be transcribed independently (e.g. whisper.cpp per track).

## Requirements

- macOS 15+ (uses ScreenCaptureKit's direct microphone capture)
- Xcode Command Line Tools (`xcode-select --install`) to build

## Build & install

```sh
make install PREFIX=/opt/homebrew/bin   # already on PATH on Apple Silicon
# default PREFIX is ~/bin: make install
```

## First run — permissions

macOS attributes a CLI tool's permissions to the **terminal app that launches
it**. On first run `rec` will trigger the system prompts; grant in
**System Settings → Privacy & Security**:

- **Screen & System Audio Recording** → enable your terminal (Terminal / iTerm / Ghostty …)
- **Microphone** → enable your terminal

Then quit and reopen the terminal and run `rec start` again.

## Usage

```sh
rec start                       # record to ~/Movies/recordings/rec-<timestamp>.mov
rec start ~/Desktop/demo.mov    # record to a specific file
rec start --audio-only          # no video: just system audio + mic (~115 MB/hour)
rec status                      # is a recording running?
rec stop                        # stop cleanly from another terminal
```

### Recording one window instead of the whole display

```sh
rec windows                      # list capturable windows
rec start --window "Meet"        # first window whose title/app contains "Meet"
rec start -w "Google Chrome"     # or match by app name
```

Window capture has a useful side effect: ScreenCaptureKit limits **system
audio to the app that owns the window**, so Slack pings, Spotify, and other
apps stay out of the meeting track. A Chrome *tab* is not its own window —
drag the tab out into a separate window first if you want to capture just it.
RecBar has the same choice in its "Source" picker.

### Choosing the microphone

```sh
rec mics                         # list inputs (system default first)
rec start --mic "AirPods"        # record the mic track from a specific input
```

The recorder follows the system default input unless told otherwise; RecBar
has a "Mic:" picker. This matters more than any processing: a headset or
AirPods close to your mouth gives a full-band, room-free voice track that a
desk-distance mic (e.g. Studio Display) cannot.

### Audio clean-up + loudness normalization

Meeting audio arrives quiet, uneven and noisy. On stop, each audio track gets
a podcast-style chain — high-pass, spectral denoise, a small presence lift on
the mic track, gentle compression — then a two-pass *linear* EBU R128
normalization to −16 LUFS (single-pass `loudnorm` pumps the noise floor up
between words). Video is stream-copied, so the picture is untouched and it
takes roughly a minute per hour of recording. `rec stop` returns as soon as the
file is safe; processing continues afterwards. Opt out with `--no-normalize`
(CLI) or the checkbox in RecBar. Needs `brew install ffmpeg`. A silent track
(e.g. window capture of an app that never played sound) is left as is.

Older or skipped recordings can be processed later, in place:

```sh
rec normalize ~/Movies/recordings/rec-2026-08-31-140227.mov
```

What it can't fix: participants' audio is band-limited by the meeting app
before it ever reaches your Mac, and a distant mic stays a distant mic.

`--audio-only` (or `-a`) drops the video track but keeps the same two separate
audio tracks. System audio means **everything the Mac plays** — Chrome, VLC,
Spotify, any app — so it also works as a plain audio grabber. Note that macOS
gates system-audio capture behind the same "Screen & System Audio Recording"
permission even when no video is recorded.

Stop with **Ctrl+C** in the recording terminal, or `rec stop` from anywhere.
Both paths finalize the file properly. The file is also written in 5-second
fragments, so even a hard crash mid-meeting leaves a recoverable recording.

## RecBar — menu bar app

A minimal menu bar UI over the same engine: `make install-app` builds
`RecBar.app` into /Applications. The ◉ icon gives Start/Stop, an audio-only
toggle, elapsed time, and quick access to the recordings folder. No window, no
dock icon — nothing on screen while presenting. It shares the CLI's pidfile,
so `rec stop` in a terminal also stops a RecBar recording, and the two can
never double-record.

**Can't see the icon?** A crowded menu bar hides it (macOS drops overflow
items silently). Two icon-free ways to the same panel: open RecBar again from
Spotlight / click its Dock icon while it's running, or press **⌃⌥R** anywhere
— either shows the panel as a small window. By default the window hides when
you click into another app; tick **Keep window on top** to pin it.

While recording, the panel shows what's actually being captured: a live
thumbnail of the video frames, and **live level meters for the mic and the
system audio**, computed from the same samples being written to disk. A
"no mic signal" warning appears if the mic goes digitally silent for 3 s —
usually a muted or wrong microphone. The CLI shows the same levels in its
status line (`--meter` for once a second).

RecBar needs its own one-time permission grant (Screen & System Audio
Recording + Microphone → *RecBar*). macOS ties that grant to the app's code
signature, so an ad-hoc-signed build loses it on every rebuild. The Makefile
therefore signs with a self-signed "RecBar Dev" certificate if one exists in
the login keychain (no trust-store changes needed — `codesign` accepts it and
the resulting designated requirement is stable). To create one:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=RecBar Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -keyout key.pem -out cert.pem
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "RecBar Dev" \
  -out recbar-dev.p12 -passout pass:x
security import recbar-dev.p12 -k ~/Library/Keychains/login.keychain-db -P x \
  -T /usr/bin/codesign && rm key.pem recbar-dev.p12
```

(`-legacy` matters: macOS can't read OpenSSL 3's default PKCS12 format.)

## Transcribe to subtitles (RecBar)

RecBar's panel has **Transcribe File to Subtitles…** — pick any video/audio
file and it writes a `.srt` next to it, with a live progress bar. Runs fully
local via `whisperkit-cli` (brew) using the WhisperKit models MacWhisper has
already downloaded (large-v3 preferred). Files with exactly two audio tracks
(rec-cli recordings) get speaker-labeled cues: `[Them]` = system audio,
`[Me]` = mic.

**Translate to English** uses whisper's built-in translate task: any spoken
language → English subtitles, still offline. (Other target languages need an
external translation step — not built.)

Requires: `brew install whisperkit-cli ffmpeg` and at least one WhisperKit
model downloaded via MacWhisper.

## Hearing what you recorded (multi-track playback)

The tracks are separate **by design**, which trips up players:

- **QuickTime Player** mixes all tracks — you hear both sides at once.
- **VLC** plays only ONE audio track at a time and defaults to track 1 (system
  audio). Your voice is on track 2: Audio → Audio Track → Track 2.
- To listen to one side alone: `ffmpeg -i meeting.mov -map 0:a:1 me.wav`

Also remember track 1 is digital silence unless the Mac was actually playing
sound — in a mic-only test the "movie" can sound silent in VLC even though the
mic track is fine.

## Splitting the tracks afterwards

```sh
ffmpeg -i meeting.mov -map 0:a:0 them.wav -map 0:a:1 me.wav
```

`0:a:0` = system audio (participants), `0:a:1` = microphone (you).

## Design notes

- **One SCStream, one AVAssetWriter.** ScreenCaptureKit delivers screen frames,
  system audio, and mic on a single stream (mic capture is native on macOS 15+),
  and all three share the host clock — so the tracks stay in sync without any
  manual timestamp juggling.
- The writer session is anchored to the first complete video frame, so there is
  no black lead-in and audio/video start together.
- `rec stop` works by sending SIGINT to the recording process (found via
  `/tmp/rec-cli.pid`) — exactly the same clean-shutdown path as Ctrl+C.

## Future direction (not built yet)

Per-track transcription: split tracks → whisper.cpp per speaker side → merge
transcripts → Claude summary → Obsidian. The unmixed-track layout above exists
to make this trivial.
