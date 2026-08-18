#!/bin/bash
# Test GL Romance Novel: 21yo Novice & 24yo Senior Park Kiss via Hybrid Pipeline
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_park_kiss.jsonl"
cat << 'JSONL' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"21歳新入社員と先輩女性の公園での夜の恋愛小説を朗読してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お話ししますね。……　中高、大学とずっと女子校育ちの二十一歳。男性とお付き合いした経験なんて一度もない私が、心から憧れているのは三歳年上の指導係、水野先輩だった。ある夜、残業を終えた私に、先輩が優しく声をかけてくれた。\n『一緒に帰ろうか。少し夜風に当たって、公園で休んでいかない？』\n街灯が柔らかく照らす夜の公園のベンチ。先輩は『温かいの買ってくるね』と、自販機で缶コーヒーをご馳走してくれた。かじかんだ指先に伝わる温もりに、私の胸は微かに震えていた。\n『はい、お疲れさま』と手渡された直後、ふいに先輩の顔が近づいた。\n暗がりの中、冷たい夜風を遮るように重なった先輩の柔らかな唇。\n息が止まるような甘い痺れが走る中、先輩は悪戯っぽく瞳を細めて囁いた。\n『こういうの……好き？』\n突然の出来事に、私はただ真っ赤になって言葉を失っていた。"}
JSONL

echo "================================================================="
echo "[Step 1] Trigger PreInvocation & Real-time Hybrid Playback..."
echo "================================================================="
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/park_kiss_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/park_kiss_input.json

