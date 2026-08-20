#!/usr/bin/env python3
"""Measure the dead air a listener actually hears between readout chunks.

WHY THIS EXISTS
---------------
The pipeline already logs a `gap` per seam, computed from the timestamp at
which `play` was ISSUED. That is not when sound comes out. On 2026-08-20 the
log reported the on-device -> cloud handover as -0.2s (a slight overlap) while
a microphone measured 2.99s of silence at that exact seam, and a 3.16s gap
INSIDE the on-device half was not represented in the log at all. A recording is
the only instrument that sees what the listener hears, so this reads one.

WHAT IT DOES NOT KEEP
---------------------
A microphone recording contains the room, not just the speaker. This script
reduces the audio to a 5ms-hop loudness envelope and expects its caller to
delete the audio; --envelope writes that envelope out. Speech cannot be
recovered from one RMS value per 5ms.

ATTRIBUTION
-----------
Which seam a silence belongs to is decided by the marker tone that precedes it
(VOICE_READOUT_CHUNK_MARKER=on): 2000Hz ends an on-device unit, 3150Hz ends a
cloud chunk. Detection is by narrowband concentration rather than band energy
-- a tone lands in one bin, a fricative spreads -- which measured ~55dB of
margin against unmarked speech. Without markers every gap is reported as
unattributed rather than guessed at.
"""
import argparse
import sys
import wave

import numpy as np

FRAME_SEC = 0.020
HOP_SEC = 0.005

# Defaults describe voice-readout's own cues, but nothing below is specific to
# it: --marker replaces this table entirely, and with no markers at all the
# tool still reports silence gaps from the waveform. The pairing convention is
# the only thing it assumes -- a label ending in ".end" closes a unit and one
# ending in ".start" opens the next -- and that convention is what turns a gap
# into arithmetic instead of a judgement about where speech resumes.
DEFAULT_MARKERS = {
    1500.0: "ondevice.start",
    2500.0: "ondevice.end",
    3500.0: "cloud.start",
    4500.0: "cloud.end",
}


def load_mono(path):
    with wave.open(path, "rb") as wf:
        rate = wf.getframerate()
        width = wf.getsampwidth()
        chans = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    if width == 2:
        audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif width == 4:
        audio = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        audio = np.frombuffer(raw, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0
    if chans > 1:
        audio = audio.reshape(-1, chans).mean(axis=1)
    return audio, rate


def envelope(audio, rate):
    """One RMS value per hop, in dBFS. This is all that survives the audio."""
    flen = int(rate * FRAME_SEC)
    hop = int(rate * HOP_SEC)
    n = (len(audio) - flen) // hop
    if n < 2:
        raise SystemExit("recording too short to analyse")
    frames = np.lib.stride_tricks.sliding_window_view(audio, flen)[::hop][:n]
    rms = np.sqrt((frames ** 2).mean(axis=1) + 1e-12)
    return np.arange(n) * HOP_SEC, 20.0 * np.log10(rms)


def otsu_threshold(db):
    """Split the loudness histogram into noise floor and speech.

    A fixed dB threshold does not survive a change of room or microphone: the
    recording this was built against had its floor at -60dB and its speech at
    -18dB, while the previous analyser in this repo assumed -35dB. Otsu finds
    the valley between the two modes with no constant to tune.
    """
    finite = db[np.isfinite(db)]
    lo, hi = np.percentile(finite, 0.5), np.percentile(finite, 99.5)
    hist, edges = np.histogram(np.clip(finite, lo, hi), bins=256)
    centers = (edges[:-1] + edges[1:]) / 2
    w = hist.cumsum()
    total = w[-1]
    if total == 0:
        return -40.0
    mean = (hist * centers).cumsum()
    grand = mean[-1]
    with np.errstate(invalid="ignore", divide="ignore"):
        between = (grand * w / total - mean) ** 2 / (w * (total - w) / total ** 2 + 1e-12)
    between[~np.isfinite(between)] = -np.inf
    return float(centers[int(np.argmax(between))])


def tonality(audio, rate, freq):
    """dB by which a narrow bin at `freq` stands above its neighbourhood.

    Band energy alone cannot tell a marker tone from an /s/: both put energy up
    there. Concentration can -- measured 52dB for the tone versus 5dB for the
    band-energy test on the same material.
    """
    flen = int(rate * FRAME_SEC)
    hop = int(rate * HOP_SEC)
    n = (len(audio) - flen) // hop
    frames = np.lib.stride_tricks.sliding_window_view(audio, flen)[::hop][:n]
    spec = np.abs(np.fft.rfft(frames * np.hanning(flen), axis=1)) ** 2
    f = np.fft.rfftfreq(flen, 1.0 / rate)
    core = (f > freq - 80) & (f < freq + 80)
    ring = ((f > freq - 800) & (f < freq - 150)) | ((f > freq + 150) & (f < freq + 800))
    if not core.any() or not ring.any():
        return np.full(n, -np.inf)
    return 10 * np.log10((spec[:, core].mean(axis=1) + 1e-15) /
                         (spec[:, ring].mean(axis=1) + 1e-15))


def find_markers(audio, rate, table, thresh_db, min_sep_sec=0.30):
    """Marker onsets as (time, kind). Threshold is loose on purpose: the gap
    between a marker (65dB) and unmarked speech (10dB) leaves anywhere in
    15..60 correct, so this does not need tuning per recording."""
    hits = []
    for freq, kind in table.items():
        ton = tonality(audio, rate, freq)
        above = ton > thresh_db
        i = 0
        while i < len(above):
            if above[i]:
                j = i
                while j + 1 < len(above) and above[j + 1]:
                    j += 1
                # Onset AND offset, not a centre: a gap runs from where one
                # tone stops to where the next starts, so folding a 40ms cue
                # into a midpoint would charge half of each marker's length to
                # the silence between them.
                hits.append((i * HOP_SEC, (j + 1) * HOP_SEC, kind))
                i = j + 1
            else:
                i += 1
    hits.sort()
    kept = []
    for a, b, kind in hits:
        if kept and a - kept[-1][0] < min_sep_sec and kind == kept[-1][2]:
            continue
        kept.append((a, b, kind))
    return kept


def segment(times, db, thresh, min_sil):
    """Speech/silence runs. Silences under min_sil are absorbed into speech:
    below that they are the stops inside words, not seams."""
    voiced = db > thresh
    runs = []
    cur, start = bool(voiced[0]), 0.0
    for i in range(1, len(voiced)):
        if bool(voiced[i]) != cur:
            runs.append(("speech" if cur else "silence", start, times[i]))
            cur, start = bool(voiced[i]), times[i]
    runs.append(("speech" if cur else "silence", start, times[-1]))

    merged = []
    for kind, a, b in runs:
        if kind == "silence" and (b - a) < min_sil and merged:
            merged[-1] = ("speech", merged[-1][1], b)
        elif merged and merged[-1][0] == kind:
            merged[-1] = (kind, merged[-1][1], b)
        else:
            merged.append((kind, a, b))
    return merged


def paired_gaps(markers):
    """Gaps as (start, duration, unit_that_ended, unit_that_began).

    This is the measurement the marker scheme exists for: an ".end" cue and the
    next ".start" cue are both unambiguous events, so the silence between them
    is a subtraction. Nothing here consults the loudness envelope, which means
    a soft onset or a breath cannot move the number.
    """
    out = []
    for i, (_, off, kind) in enumerate(markers):
        if not kind.endswith(".end"):
            continue
        for on2, _, kind2 in markers[i + 1:]:
            if kind2.endswith(".start"):
                out.append((off, on2 - off, kind.rsplit(".", 1)[0], kind2.rsplit(".", 1)[0]))
                break
            if kind2.endswith(".end"):
                break
    return out


def label_gap(start, markers, window=0.60):
    """A gap belongs to the marker that just ended the unit before it."""
    best = None
    for _, off, kind in markers:
        if start - window <= off <= start + 0.10:
            if best is None or off > best[0]:
                best = (off, kind)
    return best[1] if best else None


def parse_marker(spec):
    freq, _, label = spec.partition(":")
    if not label:
        raise argparse.ArgumentTypeError(f"expected FREQ:LABEL, got {spec!r}")
    return float(freq), label


def main():
    ap = argparse.ArgumentParser(
        description="Measure silence gaps in a recording, optionally bracketed "
                    "by marker tones. Works on any mono/stereo WAV.")
    ap.add_argument("wav")
    ap.add_argument("--marker", type=parse_marker, action="append", metavar="FREQ:LABEL",
                    help="marker tone, repeatable. Labels ending .start/.end are "
                         "paired into exact gaps. Replaces the built-in table.")
    ap.add_argument("--no-markers", action="store_true",
                    help="waveform only; report every silence, attribute none")
    ap.add_argument("--min-silence", type=float, default=0.15,
                    help="shorter silences are within-speech, not gaps (s)")
    ap.add_argument("--report-above", type=float, default=0.30,
                    help="only list silences at least this long (s)")
    ap.add_argument("--marker-threshold", type=float, default=45.0,
                    help="dB of narrowband concentration to call a tone present")
    ap.add_argument("--fail-over", type=float, default=None,
                    help="exit 1 if any paired gap exceeds this (s)")
    ap.add_argument("--trim", type=float, default=0.0,
                    help="ignore this many seconds at each end (s)")
    ap.add_argument("--envelope", help="write the loudness envelope here (CSV)")
    ap.add_argument("--json", help="write the full result here as JSON")
    ap.add_argument("--quiet", action="store_true", help="suppress the text report")
    args = ap.parse_args()

    table = {} if args.no_markers else (dict(args.marker) if args.marker else dict(DEFAULT_MARKERS))

    audio, rate = load_mono(args.wav)
    times, db = envelope(audio, rate)
    if args.envelope:
        np.savetxt(args.envelope, np.c_[times, db], fmt="%.4f,%.2f",
                   header="t_sec,db", comments="")

    thresh = otsu_threshold(db)
    markers = find_markers(audio, rate, table, args.marker_threshold) if table else []
    pairs = paired_gaps(markers)
    runs = segment(times, db, thresh, args.min_silence)

    lo, hi = args.trim, times[-1] - args.trim
    silences = []
    for kind, a, b in runs:
        if kind != "silence" or (b - a) < args.report_above:
            continue
        if b < lo or a > hi:
            continue
        silences.append({"at": round(a, 3), "seconds": round(b - a, 3),
                         "after": label_gap(a, markers)})

    result = {
        "file": args.wav,
        "duration_sec": round(float(times[-1]), 3),
        "speech_threshold_db": round(thresh, 1),
        "markers_found": [{"at": round(a, 3), "until": round(b, 3), "label": k}
                          for a, b, k in markers],
        "paired_gaps": [{"at": round(t, 3), "seconds": round(d, 3),
                         "from": a, "to": b} for t, d, a, b in pairs],
        "silences": silences,
    }
    if pairs:
        arr = np.array([d for _, d, _, _ in pairs])
        result["summary"] = {
            "count": int(arr.size), "median_sec": round(float(np.median(arr)), 3),
            "max_sec": round(float(arr.max()), 3), "total_sec": round(float(arr.sum()), 3),
        }

    verdict = None
    if args.fail_over is not None:
        # No markers means NO MEASUREMENT, which is not the same as a good one.
        # Reporting "worst gap 0.00s, pass" off an empty list is how a broken
        # recording becomes a green light -- it happened on 2026-08-20, when a
        # run whose cues never reached the microphone reported a clean pass.
        problems = []
        if table and not markers:
            problems.append("マーカーが1つも検出されなかった")
        elif table and not pairs:
            problems.append("開始・終了の対が1つも成立しなかった")
        else:
            opened = sum(1 for _, _, k in markers if k.endswith(".start"))
            closed = sum(1 for _, _, k in markers if k.endswith(".end"))
            if opened != closed:
                problems.append(f"開始 {opened} と終了 {closed} が不一致（検出漏れ）")
        worst = max((d for _, d, _, _ in pairs), default=0.0)
        verdict = (not problems) and worst <= args.fail_over
        result["verdict"] = {"pass": bool(verdict), "worst_sec": round(float(worst), 3),
                             "limit_sec": args.fail_over, "problems": problems}

    if args.json:
        import json
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(result, fh, ensure_ascii=False, indent=2)

    if not args.quiet:
        print("=" * 70)
        print(f"無音計測: {args.wav}")
        print(f"全長 {times[-1]:.1f}s / 有音しきい値 {thresh:.1f} dB (自動決定)")
        if table:
            counts = {}
            for _, _, k in markers:
                counts[k] = counts.get(k, 0) + 1
            print("マーカー検出: " + (", ".join(f"{k} {v}" for k, v in sorted(counts.items()))
                                 if counts else "なし"))
        print("=" * 70)
        if pairs:
            print("【マーカー間の実測（引き算のみ、VAD判定を経ない）】")
            for t, d, a, b in pairs:
                print(f"  {t:7.2f}s  {d * 1000:7.0f} ms   {a} 終了 → {b} 開始")
        if silences:
            print("【波形から見た無音（参考）】")
            for s_ in silences:
                who = s_["after"] or "マーカー無し"
                print(f"  {s_['at']:7.2f}s  {s_['seconds'] * 1000:7.0f} ms   {who}")
        print("-" * 70)
        if "summary" in result:
            g = result["summary"]
            print(f"継ぎ目 {g['count']} 箇所 / 中央値 {g['median_sec'] * 1000:.0f} ms / "
                  f"最大 {g['max_sec'] * 1000:.0f} ms / 合計 {g['total_sec']:.2f}s")
        if verdict is not None:
            v = result["verdict"]
            if v["problems"]:
                print("判定: 測定不成立 — " + " / ".join(v["problems"]))
            else:
                print(("判定: 合格 — " if v["pass"] else "判定: 不合格 — ") +
                      f"最大 {v['worst_sec']:.2f}s / 基準 {v['limit_sec']:.2f}s")

    return 0 if verdict is not False else 1


if __name__ == "__main__":
    sys.exit(main())
