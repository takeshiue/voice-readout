#!/bin/bash
# Test 90-char Local Audio + Gemini TTS Pipeline with VAD Analysis
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/vad_ceo_90char"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

# 1. Filler (filler_13.wav)
FILLER_WAV="$ROOT_DIR/assets/fillers/filler_13.wav"
cp "$FILLER_WAV" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening Audio (90 chars: ~20.5s)
LOCAL_TEXT="全社員の皆さん、聞いてください。AIの急速な進化は、私たちの仕事を奪う脅威ではなく、一人ひとりの可能性を何倍にも解き放つ史上最大のチャンスです。実は私自身、最初はAIに頼ることに戸惑いがありました。"
python3 -c "
import urllib.request
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. Gemini Chunks
CHUNK0_TEXT="しかし自らコードを書き、企画を練る中でAIを対等な壁打ち相手として活用し始めた瞬間、思考の視野が一気に広がり、開発スピードが劇的に向上したのです。"
CHUNK1_TEXT="ルーチン作業をAIに任せることで、私たちは人間にしかできない『情熱を込めた創造』や『本質的な課題解決』にすべてのエネルギーを注ぎ込めるようになります。"
CHUNK2_TEXT="自らの殻を破り、新しい技術を味方につけた皆さんと共に、業界の未来を切り拓いていけると確信しています。失敗を恐れず、AIという最高の相棒と共に、次のステージへ力強く駆け上がりましょう！"

echo "[Step] Generating Gemini TTS Chunks..."
t0=$(date +%s%N)
gen_cloud "gemini" "$CHUNK0_TEXT" "ceo90_0" >/dev/null 2>&1
t1=$(date +%s%N)
gen_cloud "gemini" "$CHUNK1_TEXT" "ceo90_1" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK2_TEXT" "ceo90_2" >/dev/null 2>&1

dur_gen0=$(python3 -c "print(f'{($t1 - $t0)/1e9:.2f}')")
echo "Gemini Chunk 0 generation time: ${dur_gen0}s"

P0="$(_cloud_audio_path "gemini" "ceo90_0")"
P1="$(_cloud_audio_path "gemini" "ceo90_1")"
P2="$(_cloud_audio_path "gemini" "ceo90_2")"

cp "$P0" "$RECORD_DIR/03_gemini_0.wav" 2>/dev/null || true
cp "$P1" "$RECORD_DIR/04_gemini_1.wav" 2>/dev/null || true
cp "$P2" "$RECORD_DIR/05_gemini_2.wav" 2>/dev/null || true

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
_, g2 = read_wav('$RECORD_DIR/05_gemini_2.wav')

pause_filler = np.zeros(int(sr * 0.5), dtype=np.int16)
lead_samples_local = int(sr * 0.26)
lead_samples_cloud = int(sr * 0.21)

timeline = np.concatenate([filler, pause_filler])
timeline = np.concatenate([timeline, local])

cut_point = len(timeline) - lead_samples_local
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g0[:lead_samples_local], g0[lead_samples_local:]])

cut_point = len(timeline) - lead_samples_cloud
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g1[:lead_samples_cloud], g1[lead_samples_cloud:]])

cut_point = len(timeline) - lead_samples_cloud
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g2[:lead_samples_cloud], g2[lead_samples_cloud:]])

out_path = '$RECORD_DIR/ceo_speech_90char_combined.wav'
with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(timeline.astype(np.int16).tobytes())

print('Combined WAV created at:', out_path)
"

echo "======================================================================"
echo "Running VAD Waveform Analysis on 90-char Local Audio Pipeline..."
echo "======================================================================"
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$RECORD_DIR/ceo_speech_90char_combined.wav"
