#!/bin/bash
# Single Clean Test: Filler -> Local Voice Body (Single Stream, Zero Overlap)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

TEXT="お待たせしました。安曇野の空は、抜けるように青く澄み渡っていました。"

echo "Playing Single Sample (Clean & Isolated):"
echo "Text: $TEXT"

VOICE_READOUT_TTS_BACKEND=ondevice speak "$TEXT" 30 summary
