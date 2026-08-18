#!/bin/bash
# Test 5 Fillers sequentially with Pure On-Device Local Voice (10s each)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Set backend to pure ondevice
export VOICE_READOUT_TTS_BACKEND=ondevice
export VOICE_READOUT_NO_CLOUD_FALLBACK=1

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

SAMPLES=(
  "filler_01.wav:お待たせしました:安曇野の空は、抜けるように青く澄み渡っていました。"
  "filler_09.wav:えっとですね…:美由紀は母と共に、水田に青苗を植え付けていました。"
  "filler_17.wav:それではお答えします:銀座の夜の熱狂から身を引いて、三年が経ちました。"
  "filler_06.wav:準備ができました:冷涼な雪解け水が、静かに大地を潤しています。"
  "filler_25.wav:では、読み上げます:懐かしい故郷の風の匂いが、胸を満たしていました。"
)

echo "Playing 5 filler + pure ondevice local voice samples sequentially..."

for idx in "${!SAMPLES[@]}"; do
  item="${SAMPLES[$idx]}"
  clip_file="$(echo "$item" | cut -d: -f1)"
  clip_label="$(echo "$item" | cut -d: -f2)"
  body_text="$(echo "$item" | cut -d: -f3)"
  clip_path="$ROOT_DIR/assets/fillers/$clip_file"

  echo ""
  echo "=================================================="
  echo "Sample $((idx + 1))/5: [${clip_label}] -> Local Voice"
  echo "=================================================="

  if [ -f "$clip_path" ]; then
    play_notice_clip "$clip_path" nowait >/dev/null 2>&1 || true
    sleep 0.8
  fi

  # Pure On-Device Voice Speak
  VOICE_READOUT_TTS_BACKEND=ondevice speak "$body_text" 30 summary
  sleep 1.5
done

echo ""
echo "Finished all 5 filler + local voice test samples."
