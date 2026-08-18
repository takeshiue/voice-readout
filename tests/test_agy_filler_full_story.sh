#!/bin/bash
# Test Instant Random Filler + Full Story Readout Flow (350+ chars)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_filler_full_story.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"フィラーから本編への連続読み上げをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"初夏の信州、安曇野の空は抜けるように青く澄み渡っていた。島崎美由紀は、素朴な藍染めの着物に手甲を巻き、母と共に水田に青苗を植え付けていた。冷涼な雪解け水に浸した素足の感覚と、掌に伝わる泥の重みが、彼女の魂を静かに大地へと繋ぎ止めていた。銀座の夜の熱狂から身を引いて三年。政財界の権謀術数や、愛憎の果てに自滅していった男たちの虚飾の世界は、今や遠い幻影のようであった。畦道で腰を下ろした母が、手作りの野沢菜漬けと温かいほうじ茶を差し出す。湯気の向こうで穏やかに微笑む母の顔を見つめながら、美由紀は熱い湯呑みを両手で包み込んだ。胸を満たすのは、冷たい銀座の香水の匂いではなく、懐かしい故郷の土と風の匂いだった。"}
EOF

echo "Launching Full Story Test with Instant Random Filler..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_filler_full_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_filler_full_input.json
