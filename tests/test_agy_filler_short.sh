#!/bin/bash
# Test Instant Random Filler + Short 10s Sample Readout (~50 chars)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_filler_short.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"ショートテストをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"初夏の信州、安曇野の空は抜けるように青く澄み渡り、美由紀は母と共に水田に青苗を植え付けていた。"}
EOF

echo "Launching 10s Short Sample Test with Instant Random Filler..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_filler_short_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_filler_short_input.json
