#!/bin/bash
# Measure precise pipeline metrics (chunk gap, slack, audio duration, speed)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="/root/.claude/plugins/data/voice-readout-voice-readout/voice-readout.log"

# Clear queues and stop switch
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_measure_transcript.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"計測用テキストをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"初冬の丸の内、仲通りを渡る風は研ぎ澄まされた刃のように冷たかった。街路樹のイルミネーションが濡れた石畳に橙色の影を落とす中、島崎美由紀は襟元をかき合わせ、時計の針を気にしていた。信州・安曇野の山懐で育ち、丸の内の中堅商社で経理事務を執る彼女の身なりは、手入れの行き届いた紺のウールコートに無地のマフラーと、いかにも堅実そのものであった。待たせてしまったね、美由紀さん。背後からかけられた滑らかなバリトンに振り返ると、そこには完璧な笑みを湛えた石田貴政が立っていた。仕立ての良いチャコールグレーのカシミアコートに、わずかに覗くバーバリーのチェック。整った鼻梁と知性を滲ませる細身の眼鏡の奥で、彼の双眸は獲物の値踏みを済ませた捕食者のように冷たく澄んでいた。いえ、私も今着いたところですから。嘘をつく美由紀の手を、貴政は手袋越しではなく、わざわざ外した素手で優しく包み込んだ。触れた手のひらの熱に、美由紀の白い頬がかすかに上気する。病弱な母が一人遺る信州の寒村から上京して三年。孤独な都会の夜に差し伸べられたその温もりが、彼女の人生を狂わせる甘い罠であることなど、この時の彼女は知る由もなかった。"}
EOF

echo "=== Voice Readout Realtime Metrics Measurement ==="
TEXT_LEN=$(python3 "$ROOT_DIR/bin/agy_readout.py" parse-hook --mode full --file "$TMP_TRANSCRIPT" | wc -m)
echo "Input text length: $TEXT_LEN characters"
echo "TTS Backend: $(grep '^TTS_BACKEND=' /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-config | cut -d= -f2)"
echo "Chunk Marker: $(grep '^CHUNK_MARKER=' /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-config | cut -d= -f2)"
echo ""

START_TIME=$(date +%s)
echo "Starting speech synthesis and playback..."

# Run worker directly so we can wait synchronously and collect exact timing
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_input.json

END_TIME=$(date +%s)
TOTAL_SEC=$(( END_TIME - START_TIME ))

echo ""
echo "=== Measurement Summary ==="
echo "Total Execution & Playback Time: ${TOTAL_SEC}s"
if [ "$TOTAL_SEC" -gt 0 ]; then
  CHARS_PER_SEC=$(awk "BEGIN {printf \"%.2f\", $TEXT_LEN / $TOTAL_SEC}")
  echo "Overall Reading Speed: ${CHARS_PER_SEC} chars/sec"
fi

echo ""
echo "=== Pipeline Timing Log (Latest) ==="
grep -E "pipeline timing|hybrid: handover|spoke" "$LOG_FILE" | tail -n 5

