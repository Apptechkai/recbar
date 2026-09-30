# Contributing to RecBar

Thanks for your interest. RecBar is a small, opinionated tool; contributions
that keep it small and opinionated are the most welcome.

## Ground rules

- **No cloud, no accounts, no telemetry.** Everything runs on-device. PRs that
  add network calls will be declined unless the feature is impossible without
  them and it is strictly opt-in.
- **Audio tracks stay separate.** Never mix the system-audio and microphone
  tracks; per-speaker transcription depends on it.
- **Nothing on screen during a recording** beyond what macOS itself shows.

## Building

```sh
make build            # swift build -c release
make install          # CLI → ~/bin (PREFIX=... to change)
make install-app      # RecBar.app → /Applications
```

Requires macOS 15.2+ and Xcode Command Line Tools. `ffmpeg` and
`whisperkit-cli` (both via Homebrew) are runtime dependencies for audio
clean-up and transcription; recording itself needs nothing extra.

## Layout

| Target    | What                                                                      |
| --------- | ------------------------------------------------------------------------- |
| `RecCore` | Capture engine, source catalog, audio processing, transcription. UI-free. |
| `rec`     | Command-line interface.                                                   |
| `RecBar`  | Menu bar / Dock app (SwiftUI) over `RecCore`.                             |

If a feature is useful from the terminal, put the logic in `RecCore` and
expose it in both `rec` and `RecBar`.

## Testing

```sh
make smoke
```

Runs the real engine end to end in about a minute and asserts on the files
with ffprobe: an audio-only recording (system audio captured, echo
cancellation keeping speaker audio off the mic, mic still hearing a control
sound), a window capture (video sized to the window, all tracks, clean
decode), normalize, export, and transcribe against known speech. It plays a
few seconds of speech through your speakers and needs Screen Recording +
Microphone permission for your terminal. It refuses to start while another
app has a microphone open (you're probably on a call); override with
`SMOKE_FORCE=1 make smoke`. CI runners have no screen or mic, so
this stays a local check; CI only builds.

## Pull requests

- One change per PR, with a sentence on *why*.
- `make smoke` passes on your machine; mention anything it skipped.
- Keep the code readable over clever; comments explain intent, not syntax.

## Reporting bugs

Include macOS version, how you started the recording (RecBar or `rec`), the
capture source (display / window / app), and `ffprobe` output of the file if
the problem is in the recording itself.
