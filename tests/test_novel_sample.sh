#!/bin/bash
# Test 31-year-old romance novel sample playback with 90-char local opening + Gemini TTS
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_novel.jsonl"
cat << 'JSONL' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"31歳女性の恋愛小説を朗読してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お話ししますね。……　三十一歳、恋愛経験ゼロ。仕事に没頭してきた毎日に後悔はないけれど、同僚の結婚報告を聞くたび、胸の奥がチクリと痛む。そんな私が、転職してきた年下の彼と二人きりで残業することになった。\n『先輩、いつも頑張りすぎてますよ』と差し出された温かいカフェラテ。ふと指先が触れ合った瞬間、慣れない鼓動が喉の奥まで跳ね上がった。\n『私、こういうの本当に慣れてなくて……』と視線を落とすと、彼は少し驚いたように目を丸くし、それから柔らかく微笑んだ。\n『知ってますよ。だから、放っておけないんです』\n不器用な私の心の扉が、静かに開いていく音がした。"}
JSONL

echo "================================================================="
echo "[Step 1] Trigger PreInvocation (Pre-warming audio engine)..."
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1

echo "[Step 2] Playing Romance Novel Sample (90-char Local + Gemini Hybrid)..."
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/novel_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/novel_input.json
