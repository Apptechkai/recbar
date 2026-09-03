# Changelog

## 1.0.0 — first public release

- Headless recording of the main display, one window, or one app (all its
  windows) via ScreenCaptureKit; no overlay or on-screen UI.
- One `.mov` with three separate tracks: HEVC video, system audio (AAC
  stereo), microphone (AAC mono). Audio is never mixed.
- Window/app capture limits system audio to that app.
- Microphone selection (`--mic`, RecBar picker).
- Audio-only mode (`--audio-only`).
- Crash-resilient writing (5-second movie fragments).
- On-stop audio clean-up: high-pass, spectral denoise, presence lift on the
  mic, gentle compression, two-pass linear EBU R128 normalization to −16 LUFS.
- Local transcription to `.srt` via WhisperKit (large-v3 by default), with
  `[Me]`/`[Them]` speaker labels for RecBar recordings; optional translate
  to English.
- RecBar app: Dock icon with REC badge, ⌃⌥R hotkey, thumbnail source picker,
  live capture preview and audio level meters while recording.
- `rec` CLI: `start` / `stop` / `status` / `windows` / `mics` / `normalize`
  / `transcribe`.
