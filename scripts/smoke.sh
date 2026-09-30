#!/bin/bash
# RecBar smoke test: exercises the real capture engine and asserts on the
# files it produces. Run with `make smoke`. Plays a few seconds of speech
# through your speakers. Needs Screen Recording + Microphone permission for
# the terminal you run it from (the first run will prompt).
#
# Checks: build present → audio-only recording (system audio captured, echo
# cancellation keeps speaker audio off the mic, mic still hears non-reference
# sound when a second output device exists) → window capture (video sized to
# the window, all 3 tracks, decodes) → normalize → export → transcribe.

set -u
cd "$(dirname "$0")/.."
REC=".build/release/rec"
WORK="${TMPDIR:-/tmp}/recbar-smoke-$$"
mkdir -p "$WORK"
PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
skip() { SKIP=$((SKIP+1)); printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# dB helpers -----------------------------------------------------------------
max_db()  { ffmpeg -v info -i "$1" -map "0:a:$2" -af volumedetect -f null - 2>&1 | awk '/max_volume/{print $5}'; }
mean_db() { ffmpeg -v info -i "$1" -map "0:a:$2" -af volumedetect -f null - 2>&1 | awk '/mean_volume/{print $5}'; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }   # gt A B → A > B
audio_streams() { ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '; }
video_dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1"; }

# ----------------------------------------------------------------------------
section "Preflight"
[ -x "$REC" ] && pass "rec binary built" || { fail "rec binary missing — run make build"; exit 1; }
command -v ffmpeg >/dev/null && pass "ffmpeg present" || { fail "ffmpeg missing (brew install ffmpeg)"; exit 1; }
command -v ffprobe >/dev/null || { fail "ffprobe missing"; exit 1; }
if [ -f /tmp/rec-cli.pid ] && kill -0 "$(cat /tmp/rec-cli.pid)" 2>/dev/null; then
  fail "a recording is already running — stop it first"; exit 1
fi
# This test speaks through the speakers; never do that into a live call.
if [ "${SMOKE_FORCE:-0}" != 1 ] && swift scripts/mic-in-use.swift 2>/dev/null; then
  fail "another app has a microphone open (on a call?) — this test plays speech through your speakers."
  echo "        Rerun when you're free, or override with: SMOKE_FORCE=1 make smoke"
  exit 1
fi
pass "no other app is using a microphone"
HAVE_NUMPY=0; python3 -c "import numpy" 2>/dev/null && HAVE_NUMPY=1
ALT_OUT=$(say -a '?' 2>/dev/null | awk 'NR==2{print $1}')   # a second output device, if any
echo "  (sounds will play through your speakers for ~20 s)"

# ----------------------------------------------------------------------------
section "1. Audio-only recording + echo cancellation"
A="$WORK/audio.mov"
"$REC" start --audio-only --no-normalize "$A" >"$WORK/audio.log" 2>&1 &
sleep 4
if ! [ -f /tmp/rec-cli.pid ]; then
  fail "recording did not start:"; sed 's/^/        /' "$WORK/audio.log"; echo
  echo "  Grant Screen & System Audio Recording + Microphone to this terminal, then rerun."
  exit 1
fi
say -v Samantha "Reference speech through the default speakers for the echo cancellation check."
if [ -n "$ALT_OUT" ]; then
  say -a "$ALT_OUT" -v Samantha "Control speech through the second output device, which the microphone should hear."
fi
sleep 1
"$REC" stop >/dev/null 2>&1; sleep 2
[ -f "$A" ] && pass "file written" || { fail "no output file"; cat "$WORK/audio.log"; }
[ "$(audio_streams "$A")" = "2" ] && pass "2 audio tracks" || fail "expected 2 audio tracks, got $(audio_streams "$A")"
SYS_MAX=$(max_db "$A" 0)
gt "$SYS_MAX" -40 && pass "system audio captured (peak ${SYS_MAX} dB)" || fail "system track silent (peak ${SYS_MAX} dB)"
ffmpeg -v error -i "$A" -f null - 2>/dev/null && pass "file decodes cleanly" || fail "decode errors"

if [ "$HAVE_NUMPY" = 1 ]; then
  ffmpeg -v error -y -i "$A" -map 0:a:0 -ac 1 -ar 16000 "$WORK/sys.wav" -map 0:a:1 -ac 1 -ar 16000 "$WORK/mic.wav"
  CORR=$(python3 - "$WORK" <<'EOF'
import sys, wave, numpy as np
W=sys.argv[1]
def load(p):
    w=wave.open(p); return np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(float)/32768
a=load(f"{W}/sys.wav"); b=load(f"{W}/mic.wav"); n=min(len(a),len(b)); a=a[:n]-a[:n].mean(); b=b[:n]-b[:n].mean()
best=0.0
for lag in range(0,int(16000*0.3),32):
    x=a[:n-lag]; y=b[lag:]
    c=abs(float(np.dot(x,y)/(np.linalg.norm(x)*np.linalg.norm(y)+1e-9)))
    best=max(best,c)
print(f"{best:.3f}")
EOF
)
  gt 0.15 "$CORR" && pass "echo cancellation: mic/system correlation ${CORR} (< 0.15)" \
                  || fail "speaker audio leaking onto mic track (correlation ${CORR})"
else
  skip "echo-cancellation correlation (python3 numpy not installed)"
fi

if [ -n "$ALT_OUT" ]; then
  MIC_MAX=$(max_db "$A" 1)
  gt "$MIC_MAX" -45 && pass "mic hears non-reference sound (peak ${MIC_MAX} dB)" \
                    || fail "mic track silent even for non-reference sound (peak ${MIC_MAX} dB) — mic dead or over-cancelled?"
else
  skip "mic liveness (no second output device to play a control sound through)"
fi

# ----------------------------------------------------------------------------
section "2. Window capture"
FIRST_APP=$("$REC" windows 2>/dev/null | awk -F' — ' 'NR==1{sub(/^ +/,"",$1); print $1}')
if [ -z "$FIRST_APP" ]; then
  skip "no capturable window on screen"
else
  V="$WORK/window.mov"
  "$REC" start --window "$FIRST_APP" --no-normalize "$V" >"$WORK/window.log" 2>&1 &
  sleep 6
  "$REC" stop >/dev/null 2>&1; sleep 2
  DISPLAY_DIMS=$(system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution/{print $2","$4; exit}')
  DIMS=$(video_dims "$V" 2>/dev/null)
  if [ -n "$DIMS" ]; then
    pass "window \"$FIRST_APP\" recorded, video ${DIMS} px"
    [ "$DIMS" != "$DISPLAY_DIMS" ] && pass "video sized to the window, not the display" || fail "video is display-sized (${DIMS})"
  else
    fail "no video track in window recording"; sed 's/^/        /' "$WORK/window.log"
  fi
  [ "$(audio_streams "$V")" = "2" ] && pass "2 audio tracks alongside video" || fail "audio tracks: $(audio_streams "$V")"
  ffmpeg -v error -i "$V" -f null - 2>/dev/null && pass "file decodes cleanly" || fail "decode errors"
fi

# ----------------------------------------------------------------------------
section "3. Normalize"
if "$REC" normalize "$A" >"$WORK/norm.log" 2>&1; then
  M=$(mean_db "$A" 0)
  gt "$M" -30 && gt -8 "$M" && pass "system track normalized (mean ${M} dB)" || fail "unexpected level after normalize (mean ${M} dB)"
  ffmpeg -v error -i "$A" -f null - 2>/dev/null && pass "normalized file decodes" || fail "normalized file broken"
else
  fail "rec normalize failed:"; sed 's/^/        /' "$WORK/norm.log"
fi

# ----------------------------------------------------------------------------
section "4. Export"
SRC="${V:-$A}"; [ -f "$SRC" ] || SRC="$A"
if "$REC" export "$SRC" >"$WORK/export.log" 2>&1; then
  OUT="${SRC%.mov}-share.mp4"
  [ "$(audio_streams "$OUT")" = "1" ] && pass "export has one mixed audio track" || fail "export audio tracks: $(audio_streams "$OUT")"
  CH=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$OUT")
  [ "$CH" = "2" ] && pass "export audio is stereo" || fail "export channels: $CH"
  if [ -n "${V:-}" ] && [ -f "$V" ]; then
    [ "$(video_dims "$OUT")" = "$(video_dims "$V")" ] && pass "export video copied unchanged" || fail "export video dims differ"
  fi
else
  fail "rec export failed:"; sed 's/^/        /' "$WORK/export.log"
fi

# ----------------------------------------------------------------------------
section "5. Transcribe"
if command -v whisperkit-cli >/dev/null; then
  say -v Samantha -o "$WORK/speech.aiff" "The quick brown fox jumps over the lazy dog."
  ffmpeg -v error -y -i "$WORK/speech.aiff" -ar 16000 -ac 1 "$WORK/speech.wav"
  if "$REC" transcribe "$WORK/speech.wav" >"$WORK/tx.log" 2>&1 && grep -qi "brown fox" "$WORK/speech.srt"; then
    pass "transcribed known speech: $(grep -v '^[0-9]' "$WORK/speech.srt" | grep -v -- '-->' | tr -d '\n' | cut -c1-60)"
  else
    fail "transcription missing expected text:"; sed 's/^/        /' "$WORK/tx.log" | tail -5; cat "$WORK/speech.srt" 2>/dev/null
  fi
else
  skip "transcribe (whisperkit-cli not installed)"
fi

# ----------------------------------------------------------------------------
section "6. Back-to-back recordings (clean-up runs in the background)"
B1="$WORK/b2b-1.mov"; B2="$WORK/b2b-2.mov"
"$REC" start --audio-only "$B1" >"$WORK/b2b-1.log" 2>&1 &
sleep 4
say -v Samantha "First of two back to back recordings."
T0=$(python3 -c 'import time;print(time.time())')
"$REC" stop >/dev/null 2>&1
"$REC" start --audio-only "$B2" >"$WORK/b2b-2.log" 2>&1 &
for _ in $(seq 1 50); do
  [ -f /tmp/rec-cli.pid ] && kill -0 "$(cat /tmp/rec-cli.pid)" 2>/dev/null && break
  sleep 0.1
done
GAP=$(python3 -c "import time;print(f'{time.time()-$T0:.1f}')")
if [ -f /tmp/rec-cli.pid ] && gt 3.5 "$GAP"; then
  pass "next recording running ${GAP}s after stop"
else
  fail "next recording not running within 3.5s of stop (${GAP}s)"
fi
grep -q "running in the background" "$WORK/b2b-1.log" && pass "clean-up handed to background job" \
  || fail "first recording didn't hand off its clean-up:"
say -v Daniel "Second of two back to back recordings."
"$REC" stop >/dev/null 2>&1
DEADLINE=$(( $(date +%s) + 120 ))
while pgrep -f "rec normalize $WORK" >/dev/null && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 1; done
if pgrep -f "rec normalize $WORK" >/dev/null; then
  fail "background clean-up still running after 2 minutes"
else
  for f in "$B1" "$B2"; do
    M=$(mean_db "$f" 0)
    if ffmpeg -v error -i "$f" -f null - 2>/dev/null && gt "$M" -30 && gt -8 "$M"; then
      pass "$(basename "$f") processed in background (system mean ${M} dB)"
    else
      fail "$(basename "$f") not processed (system mean ${M} dB)"
    fi
  done
  ls -a "$WORK" | grep -q normalizing && fail "temp file left behind" || pass "no temp files left behind"
fi

# ----------------------------------------------------------------------------
printf "\n\033[1mResult:\033[0m %d passed, %d failed, %d skipped   (artifacts in %s)\n" "$PASS" "$FAIL" "$SKIP" "$WORK"
[ "$FAIL" = 0 ]
