#!/bin/bash
# Test Ultra-Short Local Voice (~35 chars / 5-6s) -> Immediate Fast Handover to Gemini TTS
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_ultra_short_local.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"次世代AIエージェントの動向について教えてください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"ご説明しますね。……　次世代のAIエージェントは、自律的に思考し行動する段階へと進化しています。\n画面の操作やツールの呼び出しを自ら判断して実行することで、複雑な業務ワークフローをエンドツーエンドで完結させることが可能になりました。\n特に推論能力とリアルタイム性の融合により、人間の意図を深く汲み取った柔軟な意思決定が実現されつつあります。"}
EOF

echo "================================================================="
echo "[Step 1] Trigger PreInvocation (Pre-warming & speculative trigger)..."
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1

echo "[Step 2] Launching Ultra-Short Local (35 chars) -> Fast Gemini Handover..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_ultra_short_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_ultra_short_input.json
