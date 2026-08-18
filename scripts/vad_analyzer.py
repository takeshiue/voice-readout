#!/usr/bin/env python3
"""
VAD (Voice Activity Detection) & Silence Gap Analyzer
Analyzes audio waveform and measures exact audible speech boundaries and true silence gaps.
"""
import sys
import wave
import numpy as np

def analyze_audio_gaps(wav_path, silence_thresh_db=-35.0, min_silence_len_ms=150):
    with wave.open(wav_path, 'rb') as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw_data = wf.readframes(n_frames)

    # Convert to mono float numpy array
    if sampwidth == 2:
        audio = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0
    elif sampwidth == 4:
        audio = np.frombuffer(raw_data, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        audio = np.frombuffer(raw_data, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    # Frame-by-frame RMS energy (10ms frames, 5ms hop)
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

    # Voice Activity Detection (VAD)
    is_voiced = np.array(energies_db) > silence_thresh_db

    # Find segments of speech and silence
    segments = [] # list of (type, start_sec, end_sec, dur_sec)
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

    # Filter out tiny micro-silences (< 120ms) inside speech
    merged_segments = []
    for seg in segments:
        stype, sstart, send, sdur = seg
        if not merged_segments:
            merged_segments.append(seg)
            continue
        prev_type, pstart, pend, pdur = merged_segments[-1]
        if stype == 'silence' and sdur < (min_silence_len_ms / 1000.0):
            # Treat short pause as part of speech
            continue
        elif stype == prev_type:
            merged_segments[-1] = (prev_type, pstart, send, send - pstart)
        else:
            merged_segments.append(seg)

    print("=" * 70)
    print(f"VAD Acoustic Waveform Analysis: {wav_path}")
    print(f"Total Duration: {len(audio)/framerate:.2f}s, Sample Rate: {framerate}Hz")
    print("=" * 70)
    
    speech_count = 0
    silence_count = 0
    
    for seg in merged_segments:
        stype, sstart, send, sdur = seg
        if stype == 'speech':
            speech_count += 1
            print(f"[音声区間 #{speech_count:02d}] {sstart:6.2f}s 〜 {send:6.2f}s  (有音長: {sdur:5.2f}s)")
        else:
            silence_count += 1
            print(f"  └── ──▶ 【真の無音ギャップ #{silence_count:02d}】: {sdur*1000:6.1f} ms  ({sdur:4.2f} 秒間)")
    print("=" * 70)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: vad_analyzer.py <audio.wav>")
        sys.exit(1)
    analyze_audio_gaps(sys.argv[1])
