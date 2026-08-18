#!/bin/bash
# Test Explanation / Technical Documentation Sample with 0.5s pause
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TEXT="ご説明しますね。……　本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。"

echo "Playing Technical Explanation Sample with 0.5s Pause:"
echo "Text: $TEXT"

VOICE_READOUT_TTS_BACKEND=ondevice speak "$TEXT" 30 summary
