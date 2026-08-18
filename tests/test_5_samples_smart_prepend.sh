#!/bin/bash
# Test 5 Samples with Smart Filler Text Prepend (Zero Audio-Focus Conflict, Perfect 0.2s Breath Seam)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

FILLERS=(
  "お待たせしました。"
  "えっとですね…"
  "それではお答えします。"
  "準備ができました。"
  "では、読み上げます。"
)

BODIES=(
  "安曇野の空は、抜けるように青く澄み渡っていました。"
  "美由紀は母と共に、水田に青苗を植え付けていました。"
  "銀座の夜の熱狂から身を引いて、三年が経ちました。"
  "冷涼な雪解け水が、静かに大地を潤しています。"
  "懐かしい故郷の風の匂いが、胸を満たしていました。"
)

echo "Playing 5 Samples with Smart Filler Text Prepend (Single Stream, Zero Gap)..."

for idx in "${!FILLERS[@]}"; do
  filler="${FILLERS[$idx]}"
  body="${BODIES[$idx]}"
  combined_text="${filler} ${body}"

  echo ""
  echo "=================================================="
  echo "Sample $((idx + 1))/5: [${filler}] -> Body (Single Stream)"
  echo "Text: ${combined_text}"
  echo "=================================================="

  VOICE_READOUT_TTS_BACKEND=ondevice speak "$combined_text" 30 summary

  sleep 1.0
done

echo ""
echo "Finished all 5 single-stream samples."
