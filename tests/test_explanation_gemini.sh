#!/bin/bash
# Test Technical Explanation Flow: Local Pre-warmed Filler -> Local Opening -> Gemini TTS Hybrid Flow
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_explanation_gemini.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"技術仕様の説明をお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"ご説明しますね。……　本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声フィードバックを提供することが可能となります。さらに、多様なクラウド音声合成エンジンと連携することで、極めて自然で明瞭なアナウンスを実現しています。"}
EOF

echo "Launching Technical Explanation with Local Filler -> Gemini TTS Hybrid Flow..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_explanation_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_explanation_input.json
