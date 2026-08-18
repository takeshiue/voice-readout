#!/bin/bash
# Test with 0.5s natural pause between filler and body
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TEXT="お待たせしました。……　安曇野の空は、抜けるように青く澄み渡っていました。"

echo "Playing Sample with 0.5s Natural Pause:"
echo "Text: $TEXT"

VOICE_READOUT_TTS_BACKEND=ondevice speak "$TEXT" 30 summary
