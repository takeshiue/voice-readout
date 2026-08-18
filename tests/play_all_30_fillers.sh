#!/bin/bash
# Play all 30 filler clips via play_notice_clip (Guaranteed Termux:API Media Player access)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

FILLERS_DIR="$ROOT_DIR/assets/fillers"

declare -A LABELS=(
  ["filler_01.wav"]="1. お待たせしました"
  ["filler_02.wav"]="2. 大変お待たせしました"
  ["filler_03.wav"]="3. お待たせっ"
  ["filler_04.wav"]="4. お待たせいたしました"
  ["filler_05.wav"]="5. お待たせ、できたよ"
  ["filler_06.wav"]="6. 準備ができました"
  ["filler_07.wav"]="7. まとまりました"
  ["filler_08.wav"]="8. できましたよ"
  ["filler_09.wav"]="9. えっとですね…"
  ["filler_10.wav"]="10. ええと…"
  ["filler_11.wav"]="11. そうですね…"
  ["filler_12.wav"]="12. うーん、そうですね"
  ["filler_13.wav"]="13. ええ、そうですね"
  ["filler_14.wav"]="14. なるほどですね"
  ["filler_15.wav"]="15. はい、えーっと…"
  ["filler_16.wav"]="16. えっと、こちらはですね"
  ["filler_17.wav"]="17. それではお答えします"
  ["filler_18.wav"]="18. お答えしますね"
  ["filler_19.wav"]="19. 回答いたします"
  ["filler_20.wav"]="20. ご説明しますね"
  ["filler_21.wav"]="21. 内容をお伝えします"
  ["filler_22.wav"]="22. お伝えしますね"
  ["filler_23.wav"]="23. 結果をお話しします"
  ["filler_24.wav"]="24. はい、お答えします"
  ["filler_25.wav"]="25. では、読み上げます"
  ["filler_26.wav"]="26. それでは参ります"
  ["filler_27.wav"]="27. では、いきますね"
  ["filler_28.wav"]="28. 結果はこちらです"
  ["filler_29.wav"]="29. 回答はこちらです"
  ["filler_30.wav"]="30. 内容はこちらです"
)

echo "Playing all 30 filler clips through Termux Media Player..."

for f in $(printf "%s\n" "${!LABELS[@]}" | sort); do
  clip_path="$FILLERS_DIR/$f"
  label="${LABELS[$f]}"
  
  echo ">>> Playing: $label ($f)"
  if [ -f "$clip_path" ]; then
    # Use play_notice_clip with wait mode for audible, clear sequential playback
    play_notice_clip "$clip_path" wait
    sleep 0.4
  fi
done

echo ""
echo "Finished all 30 filler clips."
