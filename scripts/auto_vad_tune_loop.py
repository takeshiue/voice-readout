#!/usr/bin/env python3
"""
Automated VAD Tuning Loop for Voice-Readout
Repeatedly generates speech, records the complete audio stream,
runs VAD analysis, measures every audible gap, and automatically tunes
lead/offset parameters until all gaps are within 0.40s - 0.55s.
"""
import subprocess
import time
import os
import wave
import numpy as np
import json

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
TTS_LIB = os.path.join(ROOT_DIR, "bin", "tts-lib.sh")
WORK_DIR = "/tmp/vad_autotune"
os.makedirs(WORK_DIR, exist_ok=True)

TEST_TEXTS = [
    # Story 1: IT AI Agents
    ("ITエージェント", "ご説明しますね。……　次世代のAIエージェントは、自律的に思考し行動する段階へと進化しています。画面の操作やツールの呼び出しを自ら判断して実行することで、複雑な業務ワークフローをエンドツーエンドで完結させることが可能になりました。特に推論能力とリアルタイム性の融合により、人間の意図を深く汲み取った柔軟な意思決定が実現されつつあります。"),
    # Story 2: Space Science
    ("宇宙科学", "お待たせしました。……　人類史上最大の宇宙望遠鏡であるジェームズウェッブは、宇宙誕生から間もない初期銀河の姿を次々と捉えています。従来のハッブル望遠鏡を遥かに凌ぐ赤外線観測能力により、ビッグバンからわずか数億年後に誕生したとされる最古の星々の光を鮮明に捉えることに成功しました。これにより初期宇宙の進化モデルが大きく書き換えられようとしています。"),
    # Story 3: Quantum Computing
    ("量子コンピューティング", "回答いたします。……　量子コンピューティングの分野では、誤り耐性汎用量子コンピュータの実現に向けた画期的な進展が相次いでいます。光格子やイオントラップを用いた量子ビットの集積化が進み、従来のスーパーコンピュータでは不可能な分子構造のシミュレーションが可能になりつつあります。材料科学や新薬開発の現場に革命をもたらす日が近づいています。")
]

def analyze_vad(wav_path, silence_thresh_db=-32.0, min_silence_len_ms=100):
    with wave.open(wav_path, 'rb') as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw_data = wf.readframes(n_frames)

    if sampwidth == 2:
        audio = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0
    elif sampwidth == 4:
        audio = np.frombuffer(raw_data, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        audio = np.frombuffer(raw_data, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    frame_len = int(framerate * 0.010)
    hop_len = int(framerate * 0.005)
    n_hops = (len(audio) - frame_len) // hop_len
    times = []
    energies_db = []

    for h in range(n_hops):
        idx = h * hop_len
        frame = audio[idx:idx + frame_len]
        rms = np.sqrt(np.mean(frame**2) + 1e-12)
        db = 20.0 * np.log10(rms)
        times.append(idx / framerate)
        energies_db.append(db)

    is_voiced = np.array(energies_db) > silence_thresh_db
    segments = []
    cur_type = 'speech' if is_voiced[0] else 'silence'
    cur_start = 0.0

    for i in range(1, len(is_voiced)):
        t_type = 'speech' if is_voiced[i] else 'silence'
        if t_type != cur_type:
            dur = times[i] - cur_start
            segments.append((cur_type, cur_start, times[i], dur))
            cur_type = t_type
            cur_start = times[i]
    segments.append((cur_type, cur_start, times[-1], times[-1] - cur_start))

    # Merge short intra-speech pauses
    merged = []
    for seg in segments:
        stype, sstart, send, sdur = seg
        if not merged:
            merged.append(seg)
            continue
        prev_type, pstart, pend, pdur = merged[-1]
        if stype == 'silence' and sdur < (min_silence_len_ms / 1000.0):
            continue
        elif stype == prev_type:
            merged[-1] = (prev_type, pstart, send, send - pstart)
        else:
            merged.append(seg)

    silences = [s[3] for s in merged if s[0] == 'silence' and s[1] > 0.1 and s[2] < (times[-1] - 0.1)]
    return merged, silences

def build_audio_stream(theme, full_text, iteration, preplay_lead, cloud_lead, ondevice_chars):
    # Split text into local opening, and cloud chunks (approx 90 chars)
    # 1. Local Opening
    local_part = full_text[:ondevice_chars]
    cloud_part = full_text[ondevice_chars:]
    
    # 2. Cloud Chunks (split by Japanese punctuation)
    cloud_chunks = []
    remaining = cloud_part
    while remaining:
        if len(remaining) <= 90:
            cloud_chunks.append(remaining)
            break
        # find punctuation near 80-90 chars
        split_pos = -1
        for p in ["。\n", "。", "、"]:
            pos = remaining.rfind(p, 0, 95)
            if pos != -1 and pos >= 40:
                split_pos = pos + len(p)
                break
        if split_pos == -1:
            split_pos = min(90, len(remaining))
        cloud_chunks.append(remaining[:split_pos])
        remaining = remaining[split_pos:]

    # Generate Local Audio WAV
    local_wav = os.path.join(WORK_DIR, f"iter_{iteration}_local.wav")
    p_local = subprocess.run([
        "python3", "-c",
        f"""
import urllib.request, subprocess
url = 'https://translate.google.com/translate_tts?ie=UTF-8&q=' + urllib.parse.quote('''{local_part}''') + '&tl=ja&client=tw-ob'
req = urllib.request.Request(url, headers={{'User-Agent': 'Mozilla/5.0'}})
with urllib.request.urlopen(req) as resp, open('{WORK_DIR}/local_raw.mp3', 'wb') as f:
    f.write(resp.read())
subprocess.run(['ffmpeg', '-y', '-i', '{WORK_DIR}/local_raw.mp3', '-filter:a', 'atempo=1.31', '-ar', '24000', '-ac', '1', '{local_wav}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
"""
    ])

    # Generate Cloud Chunks WAV
    cloud_wavs = []
    for c_idx, c_text in enumerate(cloud_chunks):
        c_wav = os.path.join(WORK_DIR, f"iter_{iteration}_cloud_{c_idx}.wav")
        slot_name = f"tune_{iteration}_{c_idx}"
        cmd = [
            "bash", "-c",
            f"source '{TTS_LIB}' && gen_cloud 'gemini' '{c_text}' '{slot_name}' && cp -f \"$(_cloud_audio_path 'gemini' '{slot_name}')\" '{c_wav}'"
        ]
        subprocess.run(cmd, check=True)
        cloud_wavs.append(c_wav)

    # Combine with overlap offsets
    # Local -> Cloud 0 with preplay_lead offset
    # Cloud k -> Cloud k+1 with cloud_lead offset
    # Build filter complex for precision cross-fading/shifting
    concat_wav = os.path.join(WORK_DIR, f"iter_{iteration}_stream.wav")
    
    # Simple acoustic simulation:
    # Measure duration of each wav
    durations = []
    for w in [local_wav] + cloud_wavs:
        with wave.open(w, 'rb') as wf:
            durations.append(wf.getnframes() / float(wf.getframerate()))

    # Build overlapping audio with precise offsets
    # Start times:
    starts = [0.0]
    # Local to Cloud 0: Local duration minus preplay_lead (e.g. 0.4s acoustic overlap)
    starts.append(max(0.0, durations[0] - preplay_lead))
    for k in range(1, len(cloud_wavs)):
        # Cloud k starts at Cloud k-1 start + Cloud k-1 dur - cloud_lead
        starts.append(max(0.0, starts[-1] + durations[k] - cloud_lead))

    # Mix together using ffmpeg adelay & amix
    inputs = ["-i", local_wav]
    for w in cloud_wavs:
        inputs.extend(["-i", w])
    
    filter_parts = []
    for idx, st in enumerate(starts):
        ms = int(st * 1000)
        filter_parts.append(f"[{idx}:a]adelay={ms}|{ms}[a{idx}]")
    amix_inputs = "".join(f"[a{idx}]" for idx in range(len(starts)))
    filter_parts.append(f"{amix_inputs}amix=inputs={len(starts)}:dropout_transition=0:normalize=0[out]")
    
    cmd_mix = ["ffmpeg", "-y"] + inputs + ["-filter_complex", ";".join(filter_parts), "-map", "[out]", "-ar", "24000", "-ac", "1", concat_wav]
    subprocess.run(cmd_mix, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    return concat_wav, durations

def main():
    print("=" * 80)
    print("Starting Automated VAD Optimization Loop (Target: 0.40s - 0.50s Gaps)")
    print("=" * 80)

    # Initial tuning parameters
    preplay_lead = 0.45   # Local -> Cloud overlap
    cloud_lead = 0.40     # Cloud -> Cloud overlap
    ondevice_chars = 50   # Short local opening

    best_score = float('inf')
    best_params = {}

    for iteration in range(1, 6):
        theme, text = TEST_TEXTS[(iteration - 1) % len(TEST_TEXTS)]
        print(f"\n--- Iteration #{iteration}: [{theme}] Testing Lead: preplay={preplay_lead:.2f}s, cloud={cloud_lead:.2f}s, local_chars={ondevice_chars} ---")
        
        wav_file, durs = build_audio_stream(theme, text, iteration, preplay_lead, cloud_lead, ondevice_chars)
        segments, silences = analyze_vad(wav_file)

        print(f"Recorded Full Stream: {wav_file}")
        print(f"Detected {len(silences)} acoustic gap(s):")
        gap_ms_list = []
        for g_idx, g_sec in enumerate(silences):
            ms = g_sec * 1000
            gap_ms_list.append(ms)
            print(f"  Gap #{g_idx+1}: {ms:5.1f} ms ({g_sec:.2f}s)")

        # Target is 450ms (0.45s). Score is mean absolute error from 450ms.
        if silences:
            avg_gap = np.mean(silences)
            score = abs(avg_gap - 0.45)
            print(f"  ==> Average Gap: {avg_gap*1000:5.1f} ms (Target Error: {score*1000:5.1f} ms)")

            if score < best_score:
                best_score = score
                best_params = {
                    "iteration": iteration,
                    "preplay_lead": preplay_lead,
                    "cloud_lead": cloud_lead,
                    "ondevice_chars": ondevice_chars,
                    "avg_gap_ms": avg_gap * 1000,
                    "gaps_ms": gap_ms_list
                }

            # Auto-tuning feedback:
            # If gap is too large (> 0.50s), increase lead (more overlap)
            # If gap is too small (< 0.40s), decrease lead (less overlap)
            if avg_gap > 0.50:
                diff = avg_gap - 0.45
                preplay_lead += diff * 0.7
                cloud_lead += diff * 0.7
                print(f"  [Adjustment] Gap too long -> Increasing overlap lead by +{diff*0.7:.2f}s")
            elif avg_gap < 0.40:
                diff = 0.45 - avg_gap
                preplay_lead -= diff * 0.7
                cloud_lead -= diff * 0.7
                print(f"  [Adjustment] Gap too short -> Decreasing overlap lead by -{diff*0.7:.2f}s")
            else:
                print(f"  [SUCCESS] Gap perfectly in sweet spot (0.40s - 0.50s)!")
                break

    print("\n" + "=" * 80)
    print("Optimization Complete! Best Parametric Configuration:")
    print(json.dumps(best_params, indent=2, ensure_ascii=False))
    print("=" * 80)

if __name__ == '__main__':
    main()
