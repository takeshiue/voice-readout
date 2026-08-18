#!/bin/bash
# Test Gemini TTS Hybrid pipeline on Ginza VIP Room Scene (Heavy Yamasaki Toyoko style)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_gemini_ginza.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"銀座のクラブでの美由紀の活躍シーンをGemini TTSでお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"銀座の夜が最も深く沈む午前零時、高級クラブ『エトワール』のVIPルームには異様な緊張が漂っていた。\n大手ゼネコンの会長と、メガバンクの副頭取。東京湾岸の大規模再開発を巡り、水面下で鋭く対立する二人の巨頭が、氷の浮いたバカラのグラスを前に険しい沈黙を守っていた。ベテランのホステスたちすら息を潜める修羅場に、漆黒のドレスを纏った島崎美由紀が音もなく現れた。\n美由紀は二人のグラスに絶妙な手つきでヴィンテージのコニャックを注ぐと、楚々とした笑みを湛えて静かに口を開いた。\n『お二人とも、安曇野の春をご覧になったことはございますか。冬の厳しい氷の下で、雪解け水がぶつかり合ってこそ、豊かな実りが生まれます。お二人が築かれる新しい東京の礎も、きっと同じはずでございます』\n安曇野の土の匂いを知る美由紀だからこそ言える、虚飾のない凛とした言葉。その一言が、頑なだった財界の怪物たちの心を解きほぐした。\n『美由紀、お前の勝ちだ。今夜の勘定は全部僕が持とう』\n会長が笑い声を上げ、一千万円の小切手が切られた瞬間、美由紀は冷徹な夜の女王としての微笑みの奥で、静かに次の手を計算していた。"}
EOF

echo "Launching Ginza VIP Room Scene via Gemini TTS Hybrid Pipeline..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_gemini_ginza_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_gemini_ginza_input.json
