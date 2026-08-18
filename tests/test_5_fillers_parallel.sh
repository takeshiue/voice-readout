#!/bin/bash
# Test 5 Fillers with True Parallel Kick (Zero Gap to Local Voice)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

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

echo "Playing 5 Samples with True Parallel Kick (Instant Filler + Background Pre-kick Local Voice)..."

for idx in "${!SAMPLES[@]}"; do
  item="${SAMPLES[$idx]}"
  clip_file="$(echo "$item" | cut -d: -f1)"
  clip_label="$(echo "$item" | cut -d: -f2)"
  body_text="$(echo "$item" | cut -d: -f3)"
  clip_path="$ROOT_DIR/assets/fillers/$clip_file"

  echo ""
  echo "=================================================="
  echo "Sample $((idx + 1))/5: [${clip_label}] (Parallel Kick)"
  echo "=================================================="

  # 1. Kick filler audio playback immediately (Non-blocking / Background)
  if [ -f "$clip_path" ]; then
    termux-media-player play "$clip_path" >/dev/null 2>&1 &
  fi

  # 2. At the EXACT SAME INSTANT, launch local voice generation & playback
  # The ~1.0-1.5s initialization/wakelock overhead is completely hidden behind the filler sound!
  VOICE_READOUT_TTS_BACKEND=ondevice speak "$body_text" 30 summary

  sleep 1.0
done

echo ""
echo "Finished all 5 samples with True Parallel Kick."
