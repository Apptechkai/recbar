# Changelog

## Unreleased

- **User guide** (`docs/user-guide.md`) with screenshots rendered from the
  app's own views (`scripts/doc-screenshots/render.sh`, demo data only).
- Transcripts: line times come from word-level timings (accurate even on
  mostly silent tracks), and lines Whisper invents over silence ("Thank
  you.", "Продолжение следует...") are dropped by comparing each line's
  loudness with the track's background level.
- Settings only warns about notifications after an explicit "Don't Allow".
- **★ Markers**: ⌃⌥M (global), *Add Marker* in the panel, or `rec mark
  [label]`. Saved to `<name>.markers.json` as you go, embedded as video
  chapters after Stop (also when audio clean-up is off), carried into shared
  exports, and highlighted with ★ in transcripts.
- **Speaker separation**: transcripts label the meeting track's voices
  Speaker 1, 2, … (open SpeakerKit models, CC BY 4.0, 11 MB). Names are kept
  in `<name>.transcript.json`; *Name Speakers…* (with ▶ voice samples) and
  `rec speakers` rename them and rewrite the `.srt`. `--no-speakers` to skip.
- **Meeting detection**: notices Zoom, Teams, Slack, Webex, FaceTime, Discord
  and browser meetings taking the microphone, asks to record (notification +
  panel banner), and offers to stop when the call ends. Settings to turn it
  off or record only the meeting app.
- Fix: with echo cancellation, the first ~3 s of the microphone were silent
  (voice processing fades in). Recording now starts once the mic is live
  ("Starting…" for about 2 s).
- Fix: the mic meter and "No mic signal" warning treated echo-cancelled room
  tone (~−60 dB) as silence; only true digital silence now counts.
- `make smoke`: markers, speakers, mic start-up checks; the echo check aligns
  tracks on the movie timeline and is skipped when output is muted.
- Renamed to **Recall Bar** (display name, app bundle, docs). The repository,
  install line, `rec` command and app identity are unchanged, so existing
  permissions and settings carry over.

## 1.0.0 — first public release

- Headless recording of the main display, one window, or one app (all its
  windows) via ScreenCaptureKit; no overlay or on-screen UI.
- One `.mov` with three separate tracks: HEVC video, system audio (AAC
  stereo), microphone (AAC mono). Audio is never mixed.
- Window/app capture limits system audio to that app.
- Microphone selection (`--mic`, RecBar picker).
- Echo-cancelled microphone via macOS voice processing (`--no-echo-cancel`
  to opt out): meeting audio played through speakers stays off the mic track.
- Audio-only mode (`--audio-only`).
- Crash-resilient writing (5-second movie fragments).
- On-stop audio clean-up: high-pass, spectral denoise, presence lift on the
  mic, gentle compression, two-pass linear EBU R128 normalization to −16 LUFS
  (ebur128 measurement + gain + limiter, ~2½ min per hour of recording).
- Clean-up runs in the background after Stop, one job at a time across the
  CLI and RecBar, at low priority — the next recording can start immediately.
  `rec start --wait` to process in the foreground; `rec status` shows the
  current job; quitting RecBar mid-job keeps the original audio intact.
- Local transcription to `.srt` via WhisperKit (large-v3 by default), with
  `[Me]`/`[Them]` speaker labels for RecBar recordings; optional translate
  to English.
- RecBar app: Dock icon with REC badge, ⌃⌥R hotkey, thumbnail source picker,
  live capture preview and audio level meters while recording.
- Shareable export (`rec export`, RecBar "Export for Sharing"): one mixed
  stereo track in an .mp4, video stream-copied, sidecar `.srt` attached or
  burned in.
- Recordings folder setting: RecBar Settings (⌘,) and `rec folder`, shared;
  falls back to ~/Movies/recordings with a warning if the folder is missing.
- Settings → Check for Updates (only when clicked) with Update Now for
  installer-managed copies; builds are stamped with their git commit.
- `rec` CLI: `start` / `stop` / `status` / `windows` / `mics` / `normalize`
  / `transcribe` / `export`.
