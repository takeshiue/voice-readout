#!/bin/bash
# Generate 30 filler WAV clips via gen_inworld
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

OUT_DIR="$ROOT_DIR/assets/fillers"
mkdir -p "$OUT_DIR"

declare -A FILLERS=(
  ["filler_01.wav"]="お待たせしました"
  ["filler_02.wav"]="大変お待たせしました"
  ["filler_03.wav"]="お待たせっ"
  ["filler_04.wav"]="お待たせいたしました"
  ["filler_05.wav"]="お待たせ、できたよ"
  ["filler_06.wav"]="準備ができました"
  ["filler_07.wav"]="まとまりました"
  ["filler_08.wav"]="できましたよ"
  ["filler_09.wav"]="えっとですね…"
  ["filler_10.wav"]="ええと…"
  ["filler_11.wav"]="そうですね…"
  ["filler_12.wav"]="うーん、そうですね"
  ["filler_13.wav"]="ええ、そうですね"
  ["filler_14.wav"]="なるほどですね"
  ["filler_15.wav"]="はい、えーっと…"
  ["filler_16.wav"]="えっと、こちらはですね"
  ["filler_17.wav"]="それではお答えします"
  ["filler_18.wav"]="お答えしますね"
  ["filler_19.wav"]="回答いたします"
  ["filler_20.wav"]="ご説明しますね"
  ["filler_21.wav"]="内容をお伝えします"
  ["filler_22.wav"]="お伝えしますね"
  ["filler_23.wav"]="結果をお話しします"
  ["filler_24.wav"]="はい、お答えします"
  ["filler_25.wav"]="では、読み上げます"
  ["filler_26.wav"]="それでは参ります"
  ["filler_27.wav"]="では、いきますね"
  ["filler_28.wav"]="結果はこちらです"
  ["filler_29.wav"]="回答はこちらです"
  ["filler_30.wav"]="内容はこちらです"
)

echo "Generating 30 filler clips into $OUT_DIR..."
count=0

for f in $(printf "%s\n" "${!FILLERS[@]}" | sort); do
  text="${FILLERS[$f]}"
  target="$OUT_DIR/$f"
  printf "Generating [%s]: '%s' ... " "$f" "$text"
  if gen_inworld "$text" "$target"; then
    echo "OK ($(stat -c%s "$target") bytes)"
    ((count++))
  else
    echo "FAILED"
  fi
done

echo "Done! Successfully generated $count/30 filler clips."
