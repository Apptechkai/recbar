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
rec status                      # is a recording running?
rec stop                        # stop cleanly from another terminal
```

Stop with **Ctrl+C** in the recording terminal, or `rec stop` from anywhere.
Both paths finalize the file properly. The file is also written in 5-second
fragments, so even a hard crash mid-meeting leaves a recoverable recording.

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
