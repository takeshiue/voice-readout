#!/bin/bash
# Antigravity CLI (agy) Stop hook.
# Synchronous hook wrapper: returns {} immediately on stdout and runs the speech
# worker in the background via setsid to prevent blocking agy.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "__worker" ]; then
  source "$SCRIPT_DIR/tts-lib.sh"
  INPUT_FILE="${2:-}"
  trap 'rm -f "$INPUT_FILE"' EXIT

  is_enabled STOP_READOUT || exit 0
  [ -f "$INPUT_FILE" ] || exit 0

  READOUT_MODE="$(get_readout_mode)"

  # Ultra-fast instant filler audio playback (from pre-warmed stage if available)
  STAGED_FILLER="$(cat "$PLUGIN_DATA_DIR/voice-readout-staged-filler" 2>/dev/null)"
  rm -f "$PLUGIN_DATA_DIR/voice-readout-staged-filler" 2>/dev/null
  if [ -n "$STAGED_FILLER" ] && [ -f "$STAGED_FILLER" ]; then
    termux-media-player play "$STAGED_FILLER" >/dev/null 2>&1 &
    log spoke "notice clip (pre-warmed instant filler, nowait)"
  else
    FILLER_CLIP="$(python3 "$SCRIPT_DIR/agy_readout.py" pick-filler 2>/dev/null)"
    if [ -n "$FILLER_CLIP" ] && [ -f "$FILLER_CLIP" ]; then
      play_notice_clip "$FILLER_CLIP" nowait >/dev/null 2>&1 || true
    fi
  fi

  # Extract and clean text using the cross-platform Python core module
  CLEANED="$(python3 "$SCRIPT_DIR/agy_readout.py" parse-hook --mode "$READOUT_MODE" --file "$INPUT_FILE" 2>/dev/null)"
  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 2 ]; then
    # Code-only response
    play_notice_clip "$CODE_ONLY_CLIP" nowait || speak "$READOUT_CODE_ONLY_NOTICE" 60 summary
    exit 0
  fi

  if [ $EXIT_CODE -ne 0 ] || [ -z "$CLEANED" ]; then
    log skip "no speech text extracted from agy transcript"
    exit 0
  fi

  trap readout_speaking_end EXIT
  readout_speaking_begin || exit 0

  if [ "$READOUT_MODE" = "full" ]; then
    speak "$CLEANED" 600 full
  else
    speak "$CLEANED" 120 summary
  fi
  exit 0
fi

# Stop hooks require valid JSON output. Hand a 0600 file to the detached worker.
source "$SCRIPT_DIR/tts-lib.sh"
INPUT_JSON="$(cat)"

# Guard against empty stdin
if [ -z "$INPUT_JSON" ]; then
  printf '{}\n'
  exit 0
fi

umask 077
DATA_DIR="${PLUGIN_DATA_DIR:-/tmp}"
[ -d "$DATA_DIR" ] || DATA_DIR="/tmp"

INPUT_FILE="$(mktemp "${DATA_DIR}/vr-agy-stop.XXXXXX" 2>/dev/null)" || { printf '{}\n'; exit 0; }
printf '%s' "$INPUT_JSON" > "$INPUT_FILE"

SELF="$SCRIPT_DIR/$(basename "$0")"
VOICE_READOUT_GUARD=1 setsid "$SELF" __worker "$INPUT_FILE" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

# Return empty JSON immediately to unblock agy CLI
printf '{}\n'
