#!/bin/bash
# Antigravity CLI (agy) PreInvocation hook.
# Runs pre-warming in background to prepare Termux:API audio services
# while AI is thinking/generating response.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "__prewarm_worker" ]; then
  source "$SCRIPT_DIR/tts-lib.sh"
  
  # 1. Pre-acquire wake lock in background
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1 || true
  
  # 2. Warm up Termux:API MediaPlayer IPC channel
  command -v termux-media-player >/dev/null 2>&1 && termux-media-player info >/dev/null 2>&1 || true
  
  # 3. Mark last spoke as warm to skip preflight probe
  [ -d "$PLUGIN_DATA_DIR" ] || mkdir -p "$PLUGIN_DATA_DIR" 2>/dev/null || true
  date +%s > "$ONDEVICE_LASTSPOKE_FILE" 2>/dev/null || true
  
  # 4. Pre-copy a random filler clip to scratch dir so it's ready in memory
  local termux_home="${VOICE_READOUT_TERMUX_HOME:-/data/data/com.termux/files/home}"
  local scratch_dir="$termux_home/.voice-readout-tmp"
  mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null || true
  
  # Pick and pre-stage next filler
  FILLER_CLIP="$(python3 "$SCRIPT_DIR/agy_readout.py" pick-filler 2>/dev/null)"
  if [ -n "$FILLER_CLIP" ] && [ -f "$FILLER_CLIP" ]; then
    cp "$FILLER_CLIP" "$scratch_dir/prewarmed_filler.wav" 2>/dev/null || true
    echo "$scratch_dir/prewarmed_filler.wav" > "$PLUGIN_DATA_DIR/voice-readout-staged-filler" 2>/dev/null || true
  fi
  exit 0
fi

# PreInvocation hook must return {} immediately to unblock user input
SELF="$SCRIPT_DIR/$(basename "$0")"
VOICE_READOUT_GUARD=1 setsid "$SELF" __prewarm_worker >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

printf '{}\n'
