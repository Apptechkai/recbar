#!/bin/bash
# Recall Bar smoke test: exercises the real capture engine and asserts on the
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
"$REC" mark "smoke marker" >/dev/null 2>&1   # ★ checked in section 8
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

OUTPUT_MUTED=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
OUTPUT_VOLUME=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
if [ "$OUTPUT_MUTED" = "true" ] || { [ -n "$OUTPUT_VOLUME" ] && [ "$OUTPUT_VOLUME" != "missing value" ] && [ "$OUTPUT_VOLUME" -lt 15 ]; }; then
  skip "echo cancellation (sound output is muted or very low — nothing reaches the mic to cancel)"
elif [ "$HAVE_NUMPY" = 1 ]; then
  # Align both tracks on the movie timeline (aresample first_pts=0): tracks
  # start at slightly different offsets, and post-processing may describe
  # those offsets differently — extracting them unaligned skews the result.
  ffmpeg -v error -y -i "$A" -map 0:a:0 -af "aresample=async=1:first_pts=0" -ac 1 -ar 16000 "$WORK/sys.wav" \
                           -map 0:a:1 -af "aresample=async=1:first_pts=0" -ac 1 -ar 16000 "$WORK/mic.wav" </dev/null
  CORR=$(python3 - "$WORK" <<'EOF'
import sys, wave, numpy as np
W=sys.argv[1]
def load(p):
    w=wave.open(p); return np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(float)/32768
a=load(f"{W}/sys.wav"); b=load(f"{W}/mic.wav"); n=min(len(a),len(b)); a=a[:n]; b=b[:n]
# Only the reference speech (default speakers) should be cancelled; the
# control speech that follows (second device) is meant to reach the mic.
# Split the system track's speech at its longest pause.
fr=800; env=np.array([np.sqrt(np.mean(a[i:i+fr]**2)) for i in range(0,n-fr,fr)])
act=np.where(env>0.01)[0]
if len(act) > 1:
    gaps=np.diff(act); cut=act[np.argmax(gaps)]+1 if gaps.max() > 5 else act[-1]+1
    lo, hi = act[0]*fr, cut*fr
else:
    lo, hi = 0, n
x=a[lo:hi]-a[lo:hi].mean(); y=b[lo:hi]-b[lo:hi].mean(); m=len(x)
best=max(abs(float(np.dot(x[:m-l],y[l:])/(np.linalg.norm(x[:m-l])*np.linalg.norm(y[l:])+1e-9))) for l in range(0,int(16000*0.3),16))
print(f"{best:.3f}")
EOF
)
  # Without echo cancellation, speakers → mic measured ≈0.39 (10 Sep); with
  # it, short clips land well below 0.2 (the canceller adapts in seconds).
  gt 0.2 "$CORR" && pass "echo cancellation: mic/system correlation ${CORR} (< 0.2)" \
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

if command -v whisperkit-cli >/dev/null; then
  # Two clearly different voices taking turns → two speakers, renamable.
  for i in 1 2 3; do
    say -v Samantha -o "$WORK/v$i-a.aiff" "This is the first speaker, talking about the project timeline and the budget for round $i."
    say -v Daniel -o "$WORK/v$i-b.aiff" "And this is the second speaker, answering with questions about scope and staffing in round $i."
  done
  ffmpeg -v error -y $(for i in 1 2 3; do printf -- "-i %s -i %s " "$WORK/v$i-a.aiff" "$WORK/v$i-b.aiff"; done) \
    -filter_complex "concat=n=6:v=0:a=1,aresample=16000" -ac 1 "$WORK/twovoices.wav"
  "$REC" transcribe "$WORK/twovoices.wav" >"$WORK/tx2.log" 2>&1
  SPEAKERS=$(grep -o '\[Speaker [0-9]*\]' "$WORK/twovoices.srt" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [ "${SPEAKERS:-0}" -ge 2 ] && pass "told $SPEAKERS speakers apart" || fail "speakers not separated (found ${SPEAKERS:-0}):$(tail -3 "$WORK/tx2.log")"
  "$REC" speakers "$WORK/twovoices.srt" "Speaker 1=Alice" >/dev/null 2>&1
  grep -q '\[Alice\]' "$WORK/twovoices.srt" && pass "renamed Speaker 1 → Alice in the subtitles" || fail "rename didn't update the .srt"
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
section "7. Recordings folder setting"
PREV_FOLDER=$(defaults read sg.com.apptechsystem.recbar.shared recordingsFolder 2>/dev/null || true)
restore_folder() {
  if [ -n "$PREV_FOLDER" ]; then
    defaults write sg.com.apptechsystem.recbar.shared recordingsFolder "$PREV_FOLDER"
  else
    "$REC" folder --reset >/dev/null 2>&1
  fi
}
CHOSEN="$WORK/chosen-folder"
"$REC" folder "$CHOSEN" >/dev/null 2>&1 && [ -d "$CHOSEN" ] && pass "folder set (and created)" || fail "rec folder didn't set/create the folder"
"$REC" start --audio-only --no-normalize >"$WORK/folder.log" 2>&1 &
sleep 3; "$REC" stop >/dev/null 2>&1; sleep 1
ls "$CHOSEN"/rec-*-audio.mov >/dev/null 2>&1 && pass "recording saved in the chosen folder" \
  || fail "recording not in the chosen folder: $(grep -o '→ .*' "$WORK/folder.log")"
"$REC" folder /System/recbar-smoke >/dev/null 2>&1 && fail "unusable folder was accepted" || pass "unusable folder rejected"
defaults write sg.com.apptechsystem.recbar.shared recordingsFolder "/Volumes/NoSuchDrive-$$/recordings"
"$REC" start --audio-only --no-normalize >"$WORK/fallback.log" 2>&1 &
sleep 3; "$REC" stop >/dev/null 2>&1; sleep 1
FALLBACK=$(grep -o "$HOME/Movies/recordings/rec-[0-9-]*-audio.mov" "$WORK/fallback.log" | head -1)
if grep -q "isn't available" "$WORK/fallback.log" && [ -n "$FALLBACK" ] && [ -f "$FALLBACK" ]; then
  pass "missing folder falls back to ~/Movies/recordings with a warning"
else
  fail "no fallback when the chosen folder is missing"
fi
[ -n "$FALLBACK" ] && rm -f "$FALLBACK"   # don't leave test clips in the user's folder
restore_folder

# ----------------------------------------------------------------------------
section "8. Markers and mic start-up"
if [ -f "${A%.mov}.markers.json" ] && grep -q "smoke marker" "${A%.mov}.markers.json"; then
  pass "rec mark reached the recording"
else
  fail "no marker saved for the audio-only recording"
fi
CHAP=$(ffprobe -v error -show_chapters -of compact "$A" 2>/dev/null | grep -c "smoke marker")
[ "$CHAP" -ge 1 ] && pass "marker embedded as a chapter" || fail "marker not embedded as a chapter"
FIRST=$(ffmpeg -v info -t 0.5 -i "$A" -map 0:a:1 -af volumedetect -f null - 2>&1 | awk '/max_volume/{print $5}')
gt "${FIRST:--999}" -85 && pass "mic live from the first half second (${FIRST} dB)" \
  || fail "mic silent at the start (${FIRST} dB) — echo-canceller warm-up not handled"

# ----------------------------------------------------------------------------
printf "\n\033[1mResult:\033[0m %d passed, %d failed, %d skipped   (artifacts in %s)\n" "$PASS" "$FAIL" "$SKIP" "$WORK"
[ "$FAIL" = 0 ]
