#!/bin/bash
# Test Gemini TTS Hybrid pipeline on Epilogue (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_gemini_epilogue.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"エピローグをGemini TTSでお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"北アルプスの残雪が春霞に煙る五月、安曇野の空は抜けるように青かった。\n島崎美由紀は、素朴な藍染めの絣の着物に手甲を巻き、母と共に水田に青苗を植え付けていた。冷涼な雪解け水に浸した素足の感覚と、掌に伝わる泥の重みが、彼女の魂を静かに大地へと繋ぎ止めていた。\n銀座の夜の熱狂から身を引いて三年。政財界の権謀術数や、愛憎の果てに自滅していった男たちの虚飾の世界は、今や遠い幻影のようであった。\n『美由紀、一休みしてお茶にしようか』\n畦道で腰を下ろした母が、手作りの野沢菜漬けと温かいほうじ茶を差し出す。\n湯気の向こうで穏やかに微笑む母の顔を見つめながら、美由紀は熱い湯呑みを両手で包み込んだ。\n過酷な夜の伏魔殿を生き抜く中で手に入れた莫大な富は、今や地域の農業振興と福祉基金へと姿を変え、静かにこの大地を潤していた。\n吹き抜ける風が、青々と茂る水田を揺らし、美由紀の黒髪を撫でていく。\nその凛とした横顔には、幾重もの修羅場を乗り越えた者だけが宿す、揺るぎない静寂と深い慈愛の光が満ち満ちていた。"}
EOF

echo "Launching Epilogue via Gemini TTS Hybrid Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_gemini_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_gemini_input.json
