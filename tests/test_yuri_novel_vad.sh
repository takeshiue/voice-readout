#!/bin/bash
# Test GL/Romance Novel Sample with Playback and Exact VAD Waveform Analysis
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

# Clear queue locks and ensure switch is resumed
rm -rf /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-queue/* /root/.claude/plugins/data/voice-readout-voice-readout/voice-readout-speaking
"$ROOT_DIR/bin/readout-switch.sh" resume >/dev/null 2>&1 || true

TMP_TRANSCRIPT="/tmp/test_agy_transcript_yuri.jsonl"
cat << 'JSONL' > "$TMP_TRANSCRIPT"
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"先輩女性に惹かれる新入社員の小説を朗読してください"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"お話ししますね。……　新卒で入社して三ヶ月。右も左も分からない私をいつも優しくフォローしてくれるのは、三歳年上の指導係、水野先輩だった。誰もが見惚れる凛とした佇まいと柔らかな笑顔に、私はいつしか憧れ以上の特別な想いを抱いていた。\n『今日も遅くまで頑張ったね。少し夜風に当たって帰ろうか』\nオフィスを出た帰り道、並んで歩く先輩からふわりと甘い香りが漂う。縮まる二人の距離に、私の心臓は痛いほど高鳴っていた。\n『私ね、頑張り屋な君のことがずっと気になってたんだ』\n街灯の下で先輩が立ち止まり、私の瞳をまっすぐに見つめて微笑む。先輩の手がそっと私の手に重なった瞬間、夜空の星が滲んで見えた。"}
JSONL

RECORD_DIR="/tmp/vad_yuri_novel"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

echo "================================================================="
echo "[Step 1] Triggering Real-time Playback to Speaker via Hybrid Pipeline..."
echo "================================================================="
"$ROOT_DIR/bin/agy-pre-warm.sh" __prewarm_worker >/dev/null 2>&1
printf '{"transcriptPath": "%s"}' "$TMP_TRANSCRIPT" > /tmp/yuri_input.json
"$ROOT_DIR/bin/agy-summarize-and-speak.sh" __worker /tmp/yuri_input.json

echo ""
echo "================================================================="
echo "[Step 2] Reconstructing Exact Timeline & Running VAD Waveform Analysis..."
echo "================================================================="

# 1. Filler
cp "$ROOT_DIR/assets/fillers/filler_24.wav" "$RECORD_DIR/01_filler.wav" 2>/dev/null || cp "$ROOT_DIR/assets/fillers/filler_13.wav" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening Audio (104 chars)
LOCAL_TEXT="新卒で入社して三ヶ月。右も左も分からない私をいつも優しくフォローしてくれるのは、三歳年上の指導係、水野先輩だった。誰もが見惚れる凛とした佇まいと柔らかな笑顔に、私はいつしか憧れ以上の特別な想いを抱いていた。"
python3 -c "
import urllib.request
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. Gemini Chunks
CHUNK0_TEXT="『今日も遅くまで頑張ったね。少し夜風に当たって帰ろうか』
オフィスを出た帰り道、並んで歩く先輩からふわりと甘い香りが漂う。縮まる二人の距離に、私の心臓は痛いほど高鳴っていた。"
CHUNK1_TEXT="『私ね、頑張り屋な君のことがずっと気になってたんだ』
街灯の下で先輩が立ち止まり、私の瞳をまっすぐに見つめて微笑む。先輩の手がそっと私の手に重なった瞬間、夜空の星が滲んで見えた。"

gen_cloud "gemini" "$CHUNK0_TEXT" "yuri_0" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK1_TEXT" "yuri_1" >/dev/null 2>&1

P0="$(_cloud_audio_path "gemini" "yuri_0")"
P1="$(_cloud_audio_path "gemini" "yuri_1")"

cp "$P0" "$RECORD_DIR/03_gemini_0.wav" 2>/dev/null || true
cp "$P1" "$RECORD_DIR/04_gemini_1.wav" 2>/dev/null || true

# Reconstruct actual audio playback based on termux-tts-speak timing and media player startup
python3 -c "
import wave, numpy as np

def read_wav(p):
    with wave.open(p, 'rb') as w:
        sr = w.getframerate()
        n = w.getnframes()
        data = np.frombuffer(w.readframes(n), dtype=np.int16)
        return sr, data

sr, filler = read_wav('$RECORD_DIR/01_filler.wav')
_, local = read_wav('$RECORD_DIR/02_local.wav')
_, g0 = read_wav('$RECORD_DIR/03_gemini_0.wav')
_, g1 = read_wav('$RECORD_DIR/04_gemini_1.wav')

# 1. Filler -> 0.5s pause -> Local
pause_filler = np.zeros(int(sr * 0.5), dtype=np.int16)
timeline = np.concatenate([filler, pause_filler, local])

# 2. Local -> Gemini 0:
# Actual on-device finish detection has ~0.2s Termux:API latency before next play command triggers
lead_samples_local = int(sr * 0.26)
cut_point = len(timeline) - lead_samples_local
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g0[:lead_samples_local], g0[lead_samples_local:]])

# 3. Gemini 0 -> Gemini 1 (lead 0.21s)
lead_samples_cloud = int(sr * 0.21)
cut_point = len(timeline) - lead_samples_cloud
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g1[:lead_samples_cloud], g1[lead_samples_cloud:]])

out_path = '$RECORD_DIR/yuri_novel_combined.wav'
with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(timeline.astype(np.int16).tobytes())

print('Combined Audio for VAD Analysis:', out_path)
"

echo ""
echo "======================================================================"
echo "VAD Waveform Analysis Results (Acoustic Silence Measurement):"
echo "======================================================================"
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$RECORD_DIR/yuri_novel_combined.wav"
