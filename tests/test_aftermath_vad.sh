#!/bin/bash
# Reconstruct timeline and run exact VAD analysis for novel sequel with tuned leads
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/bin/tts-lib.sh"

RECORD_DIR="/tmp/vad_aftermath"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

# 1. Filler
cp "$ROOT_DIR/assets/fillers/filler_10.wav" "$RECORD_DIR/01_filler.wav"

# 2. Local Opening (89 chars)
LOCAL_TEXT="『こういうの……好き？』と耳元で囁かれ、私の頭の中は真っ白になっていた。男性とお付き合いした経験のない私にとって、先輩の柔らかな唇の感触は、生まれて初めて知る甘い衝撃だった。"
python3 -c "
import urllib.request, urllib.parse
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''$LOCAL_TEXT''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req) as resp, open('$RECORD_DIR/local.mp3', 'wb') as f:
    f.write(resp.read())
"
ffmpeg -y -i "$RECORD_DIR/local.mp3" -filter:a "atempo=1.31" -ar 24000 -ac 1 "$RECORD_DIR/02_local.wav" >/dev/null 2>&1

# 3. ElevenLabs Chunks
CHUNK0_TEXT="『嫌……じゃ、ないです。むしろ、ずっと先輩のこと……』
か細い声でそう絞り出すと、水野先輩はふっと愛おしそうに目を細めた。
『知ってた。君の視線、いつも私を追ってたからね』
そう言って、先輩は私の右手をそっと握りしめた。"

CHUNK1_TEXT="『これからは、会社でもプライベートでも、ずっと私だけ見ててね』
ベンチの暗がりの中、冷たい夜風を忘れさせるほど強く抱きしめられる。先輩のシャンプーの甘い香りに包まれながら、私は胸いっぱいに幸せを噛みしめていた。"

gen_cloud "elevenlabs" "$CHUNK0_TEXT" "aft_0" >/dev/null 2>&1
gen_cloud "elevenlabs" "$CHUNK1_TEXT" "aft_1" >/dev/null 2>&1

ffmpeg -y -i "$(_cloud_audio_path "elevenlabs" "aft_0")" -ar 24000 -ac 1 "$RECORD_DIR/03_eleven_0.wav" >/dev/null 2>&1
ffmpeg -y -i "$(_cloud_audio_path "elevenlabs" "aft_1")" -ar 24000 -ac 1 "$RECORD_DIR/04_eleven_1.wav" >/dev/null 2>&1

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
_, el0 = read_wav('$RECORD_DIR/03_eleven_0.wav')
_, el1 = read_wav('$RECORD_DIR/04_eleven_1.wav')

# Filler -> 0.35s pause -> Local
pause_filler = np.zeros(int(sr * 0.35), dtype=np.int16)

# Local -> ElevenLabs 0 (HYBRID_PREPLAY_LEAD = 0.60s)
lead_local = int(sr * 0.60)

# ElevenLabs 0 -> ElevenLabs 1 (CLOUD_PLAY_LEAD = 0.75s)
lead_cloud = int(sr * 0.75)

timeline = np.concatenate([filler, pause_filler, local])

cut_point = len(timeline) - lead_local
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + el0[:lead_local], el0[lead_local:]])

cut_point = len(timeline) - lead_cloud
timeline = np.concatenate([timeline[:cut_point], timeline[cut_point:] + el1[:lead_cloud], el1[lead_cloud:]])

out_path = '$RECORD_DIR/aftermath_combined.wav'
with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(timeline.astype(np.int16).tobytes())

print('Exact Combined Audio Created:', out_path)
"

echo ""
echo "======================================================================"
echo "VAD Waveform Analysis Results (Aftermath Sequel with Tuned Leads):"
echo "======================================================================"
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$RECORD_DIR/aftermath_combined.wav"
