#!/bin/bash
# Test agy hook pipeline with Episode 4 and chunk-marker enabled
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ep4.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"第4話をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"半年後、島崎美由紀は街で知らぬ者のいない『夜の女王』へと変貌していた。\n男たちの見栄や欲望を冷徹に見透かし、微笑み一つで大金を落とさせる。貴政がすり寄ってきても、美由紀は冷淡にグラスを揺らしながら言った。『貴政さん、私の時間を買いたければ、まずはボトルを３本入れてからにしてくださる？』。かつての獲物に逆に支配された貴政は、悔しそうに顔を歪めて去っていった。\nしかし、派手なドレスを脱ぎ捨てた週末、美由紀は鈍行列車に揺られて山あいの故郷へと向かっていた。\n『美由紀、おかえり。身体、壊してないかい？』\n腰の曲がった母が、泥のついた軍手を外して優しく微笑む。\n美由紀はすっぴんの顔をほころばせ、割烹着を着て母の横にしゃがみ込んだ。\n『ううん、元気だよお母さん。はい、これでお薬代と新しいトラクター買ってね』\n封筒を母の手に握らせ、冷たい井戸水で大根の泥を洗い流す美由紀の横顔には、夜の残酷な毒気など微塵もなく、ただただ母を想う純朴な娘の優しい光が宿っていた。"}
EOF

echo "Launching Episode 4 readout via agy Stop hook pipeline (chunk marker enabled)..."
printf '{"transcriptPath": "%s"}\n' "$TMP_TRANSCRIPT" | "$ROOT_DIR/bin/agy-summarize-and-speak.sh"
echo "Hook finished immediately."
