#!/bin/bash
# Test Romance Novel Sequel (After Park Kiss) with Optimized Lead (0.6s/0.75s) via ElevenLabs
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_aftermath.jsonl"
cat << 'JSONL' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"先輩女性にキスされた直後の続きの恋愛小説を朗読してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お話ししますね。……　『こういうの……好き？』と耳元で囁かれ、私の頭の中は真っ白になっていた。男性とお付き合いした経験のない私にとって、先輩の柔らかな唇の感触は、生まれて初めて知る甘い衝撃だった。\n『嫌……じゃ、ないです。むしろ、ずっと先輩のこと……』\nか細い声でそう絞り出すと、水野先輩はふっと愛おしそうに目を細めた。\n『知ってた。君の視線、いつも私を追ってたからね』\nそう言って、先輩は私の右手をそっと握りしめた。\n『これからは、会社でもプライベートでも、ずっと私だけ見ててね』\nベンチの暗がりの中、冷たい夜風を忘れさせるほど強く抱きしめられる。先輩のシャンプーの甘い香りに包まれながら、私は胸いっぱいに幸せを噛みしめていた。"}
JSONL

echo "================================================================="
echo "[Step 1] Triggering Real-time ElevenLabs Playback to Speaker..."
echo "================================================================="
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/aftermath_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/aftermath_input.json

