#!/bin/bash
# Test ElevenLabs Hybrid pipeline on Episode 4 (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep4_eleven.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第4話をElevenLabsでお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"夜の帳が降りる頃、銀座の並木通りに佇む最高級クラブ『エトワール』の重厚な扉が開かれた。\nフロアの中央でバカラのグラスを傾ける島崎美由紀の姿は、もはやかつての純朴な田舎娘の面影を完全に脱ぎ捨てていた。漆黒のイブニングドレスに身を包み、大輪の薔薇のように妖艶な微笑みを浮かべる彼女は、政財界の大物たちの虚栄心を冷徹に手玉に取っていた。かつて彼女を騙した石田貴政が、売掛金の回収と更なる無心に訪れた際も、美由紀は冷ややかに煙草の煙をくゆらせながら告げた。\n『貴政さん、ここは三流の男が足を踏み入れて良い場所ではなくてよ。私の前で頭を下げたいのなら、まずは一千万円のヴィンテージ・ロマネコンティを空けてからにしてくださる？』\n獲物に首輪を嵌め返された貴政は、青ざめて逃げ去った。\nだが、その翌朝、華やかな香水の香りを落とした美由紀は、一人特急あずさに揺られていた。\n信州・安曇野の畦道で、泥だらけの長靴を履いた母が腰をさすりながら手を振っている。\n美由紀は駆け寄り、すっぴんの顔をほころばせて母の手を握りしめた。\n『お母さん、ただいま。畑仕事、無理しちゃ駄目だよ』\n冷たい井戸水で大根を洗う美由紀の瞳には、夜の残酷な毒気など微塵もなく、ただただ母を愛する純朴な娘の優しい涙が滲んでいた。"}
EOF

echo "Launching Episode 4 via ElevenLabs Hybrid Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ep4_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ep4_input.json
