#!/bin/bash
# RecBar installer — installs or updates RecBar from source. No sudo; safe to
# run again (it updates). Read it before running; it's short.
#
#   Install / update:  curl -fsSL https://raw.githubusercontent.com/Apptechkai/recbar/main/install.sh | bash
#   Uninstall:         curl -fsSL https://raw.githubusercontent.com/Apptechkai/recbar/main/install.sh | bash -s -- --uninstall
#
# What it does: checks your macOS version, installs Apple's command line tools
# if missing (one system dialog), installs ffmpeg + whisperkit-cli via Homebrew
# if you have Homebrew, downloads RecBar's source to
# ~/Library/Application Support/RecBar/src, builds it, installs RecBar.app to
# /Applications and the `rec` command next to your Homebrew tools, and opens it.

set -euo pipefail

REPO="https://github.com/Apptechkai/recbar.git"
SRC="$HOME/Library/Application Support/RecBar/src"
LOG="$HOME/Library/Logs/RecBar/install.log"

say()  { printf "\033[1m==>\033[0m %s\n" "$1"; }
note() { printf "    %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$1" >&2; exit 1; }

# Runs a step with its output in the log; on failure shows the end of it.
step() {
  if ! "$@" >>"$LOG" 2>&1 </dev/null; then
    tail -15 "$LOG" >&2
    die "That step failed. Full log: $LOG"
  fi
}

have_brew() { command -v brew >/dev/null 2>&1; }

# Note: `pkill -a` — macOS pkill skips its own ancestors by default, and when
# RecBar's "Update Now" runs this script, RecBar *is* an ancestor.

# Refuse while RecBar is busy: never cut off a recording or an audio clean-up.
check_idle() {
  if [ -f /tmp/rec-cli.pid ] && kill -0 "$(cat /tmp/rec-cli.pid)" 2>/dev/null; then
    die "A recording is in progress. Stop it, then run this again."
  fi
  if pgrep -f 'rec normalize|ebur128=framelog|\.normalizing\.mov' >/dev/null 2>&1; then
    die "RecBar is still cleaning up a recording's audio. Try again in a few minutes."
  fi
}

uninstall() {
  check_idle
  say "Removing RecBar…"
  pkill -a -x RecBar 2>/dev/null || true
  rm -rf /Applications/RecBar.app "$SRC"
  if have_brew; then rm -f "$(brew --prefix)/bin/rec"; fi
  say "RecBar removed. Your recordings in ~/Movies/recordings were not touched."
  note "(ffmpeg and whisperkit-cli stay installed; remove them with"
  note " 'brew uninstall ffmpeg whisperkit-cli' if nothing else uses them.)"
}

install() {
  mkdir -p "$(dirname "$LOG")"
  echo "--- install $(date) ---" >>"$LOG"

  # 1. Right Mac?
  local ver major minor
  ver=$(sw_vers -productVersion)
  IFS=. read -r major minor _ <<<"$ver"
  if [ "$major" -lt 15 ] || { [ "$major" -eq 15 ] && [ "${minor:-0}" -lt 2 ]; }; then
    die "RecBar needs macOS 15.2 or newer (this Mac has $ver)."
  fi

  check_idle

  # 2. Apple's command line tools (compiler + git): one system dialog.
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing Apple's command line tools — click \"Install\" in the dialog that appears."
    note "This download can take several minutes. The installer waits for it."
    xcode-select --install >/dev/null 2>&1 || true
    local waited=0
    until xcode-select -p >/dev/null 2>&1; do
      sleep 10
      waited=$((waited + 10))
      [ "$waited" -lt 3600 ] || die "Command line tools still not installed after an hour. Install them, then run this again."
    done
  fi

  # 3. Optional helpers: audio clean-up, export (ffmpeg) and transcription.
  if have_brew; then
    local missing=()
    for tool in ffmpeg whisperkit-cli; do
      brew list --formula "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      say "Installing helper tools: ${missing[*]} (can take a few minutes)…"
      step brew install "${missing[@]}"
    fi
  else
    warn "Homebrew not found. Recording works, but audio clean-up, export and"
    warn "transcription need it. Install it from https://brew.sh, then run this again."
  fi

  # 4. Get or update the source.
  if [ -d "$SRC/.git" ]; then
    say "Updating RecBar…"
    if ! git -C "$SRC" pull --quiet --ff-only >>"$LOG" 2>&1 </dev/null; then
      rm -rf "$SRC"   # history changed upstream — start clean
    fi
  fi
  if [ ! -d "$SRC/.git" ]; then
    say "Downloading RecBar…"
    mkdir -p "$(dirname "$SRC")"
    step git clone --quiet "$REPO" "$SRC"
  fi

  # 5. Build and install.
  say "Building RecBar (a minute or two)…"
  step make -C "$SRC" build
  pkill -a -x RecBar 2>/dev/null || true
  step make -C "$SRC" install-app
  if have_brew; then
    step make -C "$SRC" install PREFIX="$(brew --prefix)/bin"
  fi

  # 6. Launch and explain the one manual step.
  open -a /Applications/RecBar.app
  say "RecBar $(git -C "$SRC" describe --tags --always 2>/dev/null) is installed and open."
  note "Open it any time from the Dock, Spotlight, or with ⌃⌥R."
  note "First recording: allow Screen & System Audio Recording and Microphone"
  note "in System Settings → Privacy & Security, then quit and reopen RecBar."
  if have_brew; then note "Command-line tool: rec (try 'rec status')."; fi
}

main() {
  case "${1:-}" in
    --uninstall) uninstall ;;
    "")          install ;;
    *)           die "Unknown option: $1 (use --uninstall, or no option to install/update)" ;;
  esac
}

# Everything is inside functions, so bash has read the whole script before
# anything runs — important when it arrives through `curl | bash`.
main "$@"
