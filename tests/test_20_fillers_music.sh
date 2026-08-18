#!/bin/bash
# Test 20 Random Fillers seamlessly connected to Music Title & Lyrics + VAD Analysis
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RECORD_DIR="/tmp/vad_20_fillers_music"
mkdir -p "$RECORD_DIR"
rm -f "$RECORD_DIR"/*

python3 << 'PYEOF'
import os, glob, random, wave, json, urllib.request, subprocess
import numpy as np

# 20 Music Title & Lyrics pairs
SONGS = [
    ("宇多田ヒカルで『First Love』", "最後のキスは タバコのflavorがした。"),
    ("米津玄師で『Lemon』", "夢ならばどれほどよかったでしょう。"),
    ("YOASOBIで『夜に駆ける』", "沈むように溶けてゆくように。"),
    ("King Gnuで『白日』", "時には誰かを知らず知らずのうちに傷つけてしまったり。"),
    ("あいみょんで『マリーゴールド』", "麦わらの帽子の君が揺れたマリーゴールドに似てる。"),
    ("Official髭男dismで『Pretender』", "グッバイ、君の運命のヒトは僕じゃない。"),
    ("スピッツで『チェリー』", "愛してるの響きだけで強くなれる気がしたよ。"),
    ("中島みゆきで『糸』", "縦の糸はあなた、横の糸は私。"),
    ("back numberで『高嶺の花子さん』", "君から見た僕はきっと、ただの友達の友達。"),
    ("優里で『ドライフラワー』", "声も顔も不器用なとこも、全部全部、嫌いじゃないの。"),
    ("Adoで『うっせぇわ』", "正しさとは、愚かさとは、それが何か見せつけてやる。"),
    ("菅田将暉で『虹』", "泣いていいんだよ、そんな一言に僕は救われたんだよ。"),
    ("BUMP OF CHICKENで『天体観測』", "見えないモノを見ようとして、望遠鏡を覗き込んだ。"),
    ("サザンオールスターズで『TSUNAMI』", "風に戸惑う弱気な僕、通りすがるあの日の幻影。"),
    ("星野源で『恋』", "胸の中にあるもの、いつか見えなくなるもの。"),
    ("RADWIMPSで『前前前世』", "やっと目を覚ましたかい、それなのになぜ目を合わせはしないんだい。"),
    ("Mrs. GREEN APPLEで『青と夏』", "涼しい風吹く、青空の匂い、通り過ぎてく夏。"),
    ("Vaundyで『怪獣の花唄』", "思い出すのは君の歌、会話散らかる教室。"),
    ("福山雅治で『家族になろうよ』", "どれほど生きて、どれほど愛せば、家族になれるだろう。"),
    ("いきものがかりで『ありがとう』", "ありがとうって伝えたくて、あなたを見つめるけど。")
]

FILLERS_DIR = '/root/dev/voice-readout/assets/fillers'
filler_files = sorted(glob.glob(f'{FILLERS_DIR}/filler_*.wav'))
random.seed(42)  # reproducible random
chosen_fillers = random.sample(filler_files, 20)

record_dir = '/tmp/vad_20_fillers_music'

def read_wav(p):
    with wave.open(p, 'rb') as w:
        sr = w.getframerate()
        n = w.getnframes()
        data = np.frombuffer(w.readframes(n), dtype=np.int16)
        return sr, data

timeline_blocks = []
target_sr = 24000

print("[Step 1] Synthesizing speech for 20 song titles & lyrics...")

for i, (artist_title, lyric) in enumerate(SONGS):
    text = f"{artist_title}。{lyric}"
    raw_mp3 = f"{record_dir}/speech_{i:02d}.mp3"
    raw_wav = f"{record_dir}/speech_{i:02d}.wav"
    
    url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote(text) + '&tl=ja&client=tw-ob'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req) as resp, open(raw_mp3, 'wb') as f:
        f.write(resp.read())
    
    subprocess.run(['ffmpeg', '-y', '-i', raw_mp3, '-filter:a', 'atempo=1.31', '-ar', str(target_sr), '-ac', '1', raw_wav], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # Read filler and speech
    _, filler_data = read_wav(chosen_fillers[i])
    _, speech_data = read_wav(raw_wav)
    
    # Standard natural pause after trimmed filler: 0.35s
    pause_after_filler = np.zeros(int(target_sr * 0.35), dtype=np.int16)
    
    # Inter-song pause (1.0s before next filler)
    inter_song_pause = np.zeros(int(target_sr * 1.0), dtype=np.int16)
    
    timeline_blocks.extend([filler_data, pause_after_filler, speech_data, inter_song_pause])

full_timeline = np.concatenate(timeline_blocks)

out_wav = f"{record_dir}/20_songs_combined.wav"
with wave.open(out_wav, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(target_sr)
    w.writeframes(full_timeline.astype(np.int16).tobytes())

print(f"Combined WAV created: {out_wav} (Duration: {len(full_timeline)/target_sr:.2f}s)")
PYEOF

COMBINED_WAV="/tmp/vad_20_fillers_music/20_songs_combined.wav"

echo ""
echo "================================================================="
echo "[Step 2] Playing 20-Track Filler + Music Showcase to Speaker..."
echo "================================================================="
termux-media-player play "$COMBINED_WAV" >/dev/null 2>&1 || paplay "$COMBINED_WAV" 2>/dev/null || aplay "$COMBINED_WAV" 2>/dev/null || true

echo ""
echo "======================================================================"
echo "VAD Waveform Analysis on 20-Track Filler + Music Showcase:"
echo "======================================================================"
python3 "$ROOT_DIR/scripts/vad_analyzer.py" "$COMBINED_WAV"
