#!/bin/bash
# Long GL Romance Novel Sequel (Hotel Invitation Arc) via ElevenLabs Hybrid Pipeline
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_long_sequel.jsonl"
cat << 'JSONL' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"先輩女性との公園でのキスの続き、ホテルへ誘われるまでの長編恋愛小説を朗読してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お話ししますね。……　夜の公園のベンチで、冷たい風を忘れさせるほど強く抱きしめられた私。水野先輩の甘い香りに包まれ、生まれて初めて知る胸の高鳴りに身を委ねていたその時、先輩の指先が私のタイトスカートの裾へと静かに伸びてきた。\n『あっ……先輩、だめです……っ』\n思わず肩を跳ねさせ、私は先輩の細い手首をぎゅっと掴んで制止した。\n『こんな場所で……誰かに見られたら……それに私、本当に心の準備が……』\nパニックになりながら視線を彷徨わせる私を見て、先輩はふっと息を漏らし、ゆっくりと手を引いた。\n『ごめんね。可愛い顔見てたら、つい我慢できなくなっちゃった』\n少し困ったように微笑む先輩の瞳には、オフィスでは決して見せない熱っぽい光が宿っていた。\n冷えた指先で私の乱れた髪を優しく整えながら、先輩が耳元に唇を寄せて囁く。\n『ここじゃ寒すぎるし……もっと二人だけで、落ち着ける場所に行こ？』\n『落ち着ける場所、ですか……？』\n問い返した私の手を、先輩は迷いなくしっかりと握りしめた。\n『うん。朝まで誰にも邪魔されない場所。……ホテル、行こう』\nそのストレートな言葉に、私の心臓は跳ね上がり、顔全体が一瞬で熱くなった。\n女子校育ちで男性経験も恋愛経験もゼロの私にとって、それは未知の世界への扉だった。\n先輩の手のひらから伝わる熱と、まっすぐに見つめてくる真剣な眼差し。\n恐怖よりも、先輩のことをもっと知りたいという想いが、私の迷いをそっと溶かしていく。\n『……はい。先輩と一緒なら……行きたいです』\n小さく頷いた私を、先輩は嬉しそうに見つめ、夜の街へと歩き出した。\n二人の歩幅が重なるたび、夜の静寂の中に新しい物語が始まっていく音がしていた。"}
JSONL

echo "================================================================="
echo "[Step 1] Trigger PreInvocation & Real-time ElevenLabs Playback..."
echo "================================================================="
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/long_sequel_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/long_sequel_input.json

