#!/bin/bash
# Test agy hook pipeline with Episode 2 text
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure stop switch is cleared
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript.jsonl"
cat << 'EOF' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"続きをお願いします"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"連れて行かれたのは、彼が『行きつけ』だと自慢する薄暗いバーだった。カウンターの隅でカクテルグラスを傾ける彼の横顔は、誰が見ても非の打ち所がないほど整っていた。『美咲ってさ、本当に純粋で可愛いよね。俺、そういう素直な子大好きなんだ』。甘い囁きに胸が高鳴る反面、私の心のどこかに小さな棘が刺さる。テーブルの上に置かれた彼のスマートフォンが、さっきから何度も画面を光らせていた。女性の名前とおぼしき通知が次々とポップアップするのを、彼はさりげない手つきで裏返す。『仕事の連絡、多くてさ』と人懐っこい笑顔を浮かべる彼。25年間、真面目だけが取り柄で生きてきた私にとって、彼の住む世界は少し眩しすぎたのかもしれない。お会計の伝票が置かれた瞬間、彼は財布を開くふりをして小さく舌打ちをした。『あ、やべ。今日カードの上限来ちゃっててさ。悪いんだけど、美咲とりあえず立て替えてくれない？ 明日すぐ返すからさ』。差し出された伝票の金額を見て、私は息を呑んだ。"}
EOF

echo "Testing agy Stop hook pipeline with Episode 2 (420 chars)..."
printf '{"transcriptPath": "%s"}\n' "$TMP_TRANSCRIPT" | "$ROOT_DIR/bin/agy-summarize-and-speak.sh"
echo "Hook returned immediately. Speech is playing in background."
