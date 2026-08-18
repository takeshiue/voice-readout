#!/bin/bash
# Test News Sample 1 with 0.5s pause
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TEXT="それではお答えします。……　気象庁によりますと、関東甲信地方は高気圧に覆われ、各地で穏やかな晴天となる見込みです。"

echo "Playing News Sample 1 with 0.5s Pause:"
echo "Text: $TEXT"

VOICE_READOUT_TTS_BACKEND=ondevice speak "$TEXT" 30 summary
