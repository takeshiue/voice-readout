#!/usr/bin/env python3
"""
Benchmark Local On-Device TTS (Android Google TTS / termux-tts-speak):
Measures generation/startup overhead, speaking rate (chars/sec), and exact audio duration.
"""
import time
import subprocess
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
TTS_LIB = os.path.join(ROOT_DIR, "bin", "tts-lib.sh")

SAMPLES = [
    (30,  "本システムは、ログファイルを自動的に監視し、更新を検知します。"),
    (60,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。CLIを止めません。"),
    (90,  "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。"),
    (120, "本システムは、ログファイルを自動的に監視し、更新を検知した瞬間にバックグラウンドで処理を実行します。これにより、CLI操作を一切ブロックすることなく、リアルタイムな音声通知が可能となります。さらに、多様なクラウド音声合成エンジンと連携することで明瞭な音質を実現します。")
]

print("=" * 85)
print("Local On-Device TTS (termux-tts-speak -r 1.31) Benchmark")
print("=" * 85)

for target_len, text in SAMPLES:
    actual_len = len(text)
    cmd = [
        "bash", "-c",
        f"source '{TTS_LIB}' && VOICE_READOUT_TTS_BACKEND=ondevice VOICE_READOUT_NO_CLOUD_FALLBACK=1 speak '{text}' 30 summary"
    ]
    t0 = time.time()
    subprocess.run(cmd, check=True)
    t1 = time.time()
    total_time = t1 - t0
    
    # Speed in chars/sec
    cps = actual_len / total_time if total_time > 0 else 0
    print(f"[{actual_len:3d}文字] ──▶ 総合所要時間: {total_time:5.2f} 秒 | 実効発話速度: {cps:4.2f} 文字/秒")

print("=" * 85)
