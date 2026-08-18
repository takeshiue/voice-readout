#!/bin/bash
# Reconstruct timeline and run exact VAD waveform analysis for Park Kiss novel
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/vad_park_kiss"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

# 1. Filler
cp "$ROOT_DIR/assets/fillers/filler_13.wav" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening (98 chars)
LOCAL_TEXT="中高、大学とずっと女子校育ちの二十一歳。男性とお付き合いした経験なんて一度もない私が、心から憧れているのは三歳年上の指導係、水野先輩だった。ある夜、残業を終えた私に、先輩が優しく声をかけてくれた。"
python3 -c "
import urllib.request
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. Gemini Chunks
CHUNK0_TEXT="『一緒に帰ろうか。少し夜風に当たって、公園で休んでいかない？』
街灯が柔らかく照らす夜の公園のベンチ。先輩は『温かいの買ってくるね』と、自販機で缶コーヒーをご馳走してくれた。かじかんだ指先に伝わる温もりに、私の胸は微かに震えていた。"
CHUNK1_TEXT="『はい、お疲れさま』と手渡された直後、ふいに先輩の顔が近づいた。
暗がりの中、冷たい夜風を遮るように重なった先輩の柔らかな唇。
息が止まるような甘い痺れが走る中、先輩は悪戯っぽく瞳を細めて囁いた。
『こういうの……好き？』
突然の出来事に、私はただ真っ赤になって言葉を失っていた。"

gen_cloud "gemini" "$CHUNK0_TEXT" "park_0" >/dev/null 2>&1
gen_cloud "gemini" "$CHUNK1_TEXT" "park_1" >/dev/null 2>&1

P0="$(_cloud_audio_path "gemini" "park_0")"
P1="$(_cloud_audio_path "gemini" "park_1")"

cp "$P0" "$RECORD_DIR/03_gemini_0.wav" 2>/dev/null || true
cp "$P1" "$RECORD_DIR/04_gemini_1.wav" 2>/dev/null || true

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

# Filler (trimmed: only 30ms tail) -> 0.35s natural pause -> Local
pause_after_filler = np.zeros(int(sr * 0.35), dtype=np.int16)
timeline = np.concatenate([filler, pause_after_filler, local])

# Local -> Gemini 0 (0.26s lead)
lead_samples_local = int(sr * 0.26)
cut_point = len(timeline) - lead_samples_local
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g0[:lead_samples_local], g0[lead_samples_local:]])

# Gemini 0 -> Gemini 1 (0.21s lead)
lead_samples_cloud = int(sr * 0.21)
cut_point = len(timeline) - lead_samples_cloud
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + g1[:lead_samples_cloud], g1[lead_samples_cloud:]])

out_path = '$RECORD_DIR/park_kiss_combined.wav'
with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(timeline.astype(np.int16).tobytes())

print('Combined Audio Created:', out_path)
"

echo "======================================================================"
echo "VAD Waveform Analysis Results (Park Kiss Novel):"
echo "======================================================================"
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$RECORD_DIR/park_kiss_combined.wav"
