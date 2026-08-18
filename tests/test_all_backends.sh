#!/bin/bash
# Test and benchmark all available TTS backends on ~520 chars story text.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/bin/tts-lib.sh"

TEXT="夕暮れの駅のホームに、冷たい冬の風が吹き抜けていく。改札の向こうをじっと見つめながら、私は握りしめたマフラーに少しだけ顔を埋めた。もう来ないかもしれない。スマートフォンの画面を何度確認しても、新しい通知は何一つ届かない。諦めて帰ろうと踵を返しかけたその時、人混みをかき分けるようにして走ってくる足音が聞こえた。『待たせてごめん！』息を切らしながら肩を上下させる彼の頬は、寒さのせいか、それとも全力で走ってきたせいか、ほんのり赤く染まっていた。『ううん、今来たとこだから全然待ってないよ』といつもの嘘をつくと、彼はホッとしたように微笑み、そっと私のかじかんだ右手を自分の両手で包み込んだ。冷え切っていた指先に、じんわりと温かい彼の体温が染み渡っていく。『本当は、すごく怖かったんだ。君がもう待っててくれないんじゃないかって』。彼が静かに呟いたその言葉に、胸の奥がぎゅっと締め付けられた。街のイルミネーションがひとつずつ灯り始め、電車の接近を告げるアナウンスが遠くで鳴り響いていた。私たちは言葉を交わす代わりに、繋いだ手のひらをぎゅっと強く握り直した。白い吐息が重なり合って夜空に溶けていく。二人の距離が、ほんの少し近づいた冬の夜だった。"

echo "=== TTS Benchmark Test ==="
echo "Text length: ${#TEXT} characters"
echo ""

BACKENDS=("ondevice" "elevenlabs" "fishaudio" "inworld" "gemini")

for backend in "${BACKENDS[@]}"; do
  echo "----------------------------------------------------"
  echo "Testing Backend: $backend"
  echo "----------------------------------------------------"

  START_TS=$(date +%s%N)
  
  # Override backend for full readout
  export VOICE_READOUT_TTS_BACKEND="$backend"
  export TTS_BACKEND_FULL="$backend"
  export TTS_BACKEND="$backend"
  export READOUT_MODE="full"

  # Also clear ondevice limit for direct test if testing ondevice full
  if [ "$backend" = "ondevice" ]; then
    export ONDEVICE_MAX_CHARS=1000
    export HYBRID_TTS="off"
  else
    export HYBRID_TTS="off" # test pure backend pipeline
  fi

  trap readout_speaking_end EXIT
  readout_speaking_begin || { echo "Failed to begin readout"; continue; }

  speak "$TEXT" 600 full
  RC=$?
  readout_speaking_end
  trap - EXIT

  END_TS=$(date +%s%N)
  DURATION_MS=$(( (END_TS - START_TS) / 1000000 ))
  DURATION_SEC=$(awk "BEGIN {printf \"%.2f\", $DURATION_MS / 1000}")

  echo "Backend $backend finished with exit code $RC in ${DURATION_SEC}s"
  echo ""
  sleep 2
done

echo "=== Benchmark Finished ==="
