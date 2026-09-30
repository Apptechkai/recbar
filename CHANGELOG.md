# Changelog

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
