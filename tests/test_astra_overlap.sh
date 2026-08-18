#!/bin/bash
# Test Project Astra & OpenAI Next-Gen Agents Narrative with 0.5s Acoustic Overlap Tuning
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_astra.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"Project AstraやOpenAIの最新エージェントについて教えてください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"ご説明しますね。……　近年、世界のAI開発競争は、単なるチャットボットから『リアルタイム・マルチモーダルエージェント』へと主戦場を移しています。\nGoogleが発表した『Project Astra』は、スマートフォンのカメラ映像や音声ストリームを遅延なくリアルタイムに処理し、ユーザーの視界にある物を瞬時に認識して会話する未来のAIアシスタント像を鮮烈に提示しました。\nこれに対しOpenAIは、超低遅延な音声対話を実現したアドバンスト・ボイス機能に加え、人間のように深く論理的に思考する推論特化型モデル『o1』や、ウェブブラウザを自律操作するAIエージェント『Operator』の開発を加速させています。\n視覚・音声・自律的アクションを高度に融合させたこれらの次世代AIは、スマートグラスや人型ロボットへの搭載を見据えており、人とテクノロジーの関係性を根底から変革しようとしています。"}
EOF

echo "================================================================="
echo "[Step 1] Trigger PreInvocation (Pre-warming audio engine & lastspoke)..."
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1

echo "[Step 2] Launching Project Astra & OpenAI Narrative with 0.5s Acoustic Overlap..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/meas_astra_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/meas_astra_input.json
