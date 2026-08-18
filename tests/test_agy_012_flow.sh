#!/bin/bash
# Test 0-1-2 chunk flow: 0=Local Voice -> 1,2=Gemini Cloud Chunks
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_012_flow.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"0-1-2チャンクテストをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"初夏の銀座、街路樹の青葉が夕暮れの風に揺れていた。クラブ『エトワール』の控室で、島崎美由紀は鏡の中の自分を静かに見つめていた。仕立ての良い漆黒のドレスに、控えめながら品格のあるパールのネックレス。かつて安曇野の土にまみれていた娘は、今や政財界の重鎮たちが最も信頼を寄せる夜の相談役となっていた。今宵もまた、巨大な利権をめぐる密談がこの部屋で繰り広げられようとしている。重厚な扉が開かれ、大手銀行の頭取が緊張した面持ちで入室してきた。美由紀は微笑み、静かに立ち上がった。"}
EOF

echo "Launching 0-1-2 Hybrid Flow Test (0=Local, 1,2=Gemini)..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_012_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_012_input.json
