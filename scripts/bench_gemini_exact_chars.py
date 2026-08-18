#!/usr/bin/env python3
"""
Benchmark Gemini TTS Generation Time & Audio Playback Duration
across exact character counts: 30, 60, 90, 120, 150, 180 chars.
"""
import time
import subprocess
import os
import wave

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
TTS_LIB = os.path.join(ROOT_DIR, "bin", "tts-lib.sh")

# Exact character count Japanese text samples
SAMPLES = [
    (30,  "本システムは、ログファイルを自動的に監視し、更新を検知します。"),  # 30 chars
    (60,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。CLIを止めません。"), # 60 chars
    (90,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。"), # 90 chars
    (120, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携することで明瞭な音質を実現します。"), # 120 chars
    (150, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携することで明瞭な音質を実現します。革新的なスケーリングと安全性の両立を目指します。"), # 150 chars
    (180, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携することで明瞭な音質を実現します。革新的なスケーリングと安全性の両立を目指すこの開発競争は、今後のテクノロジーの方向性を決定づけます。") # 180 chars
]

print("=" * 85)
print("Gemini TTS: Character Count vs Generation Time & Audio Duration Benchmark")
print("=" * 85)

for target_len, text in SAMPLES:
    actual_len = len(text)
    cmd = [
        "bash", "-c",
        f"source '{TTS_LIB}' && gen_cloud 'gemini' '{text}' 'bench_{target_len}' >/dev/null 2>&1"
    ]
    t0 = time.time()
    subprocess.run(cmd, check=True)
    t1 = time.time()
    gen_time = t1 - t0

    # Get audio duration of generated WAV
    cmd_path = [
        "bash", "-c",
        f"source '{TTS_LIB}' && _cloud_audio_path 'gemini' 'bench_{target_len}'"
    ]
    wav_path = subprocess.check_output(cmd_path, text=True).strip()
    
    aud_dur = 0.0
    if os.path.exists(wav_path):
        with wave.open(wav_path, 'rb') as wf:
            aud_dur = wf.getnframes() / float(wf.getframerate())

    # Speed ratio: playback duration / generation time (Must be > 1.0 to sustain pipeline!)
    ratio = aud_dur / gen_time if gen_time > 0 else 0

    print(f"[{actual_len:3d}文字] ──▶ 生成時間: {gen_time:5.2f} 秒 | 音声再生時間: {aud_dur:5.2f} 秒 | 生成/再生比率: {ratio:4.2f}x (余裕度)")

print("=" * 85)
