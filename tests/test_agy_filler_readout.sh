#!/bin/bash
# Test Instant Random Filler + Story Readout Flow
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_filler_test.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"フィラーの動作テストをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"フィラー音声のテストです。AIが回答を完了した瞬間に、30パターンの中からランダムに選ばれた導入音声が即座に再生され、その間に裏で準備された本編の読み上げへとスムーズに繋がります。"}
EOF

echo "Launching Test with Instant Random Filler + Readout..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_filler_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_filler_input.json
