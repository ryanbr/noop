#!/usr/bin/env python3
"""analyze_v26_waveform.py — characterise the WHOOP 5 type-47 *version-26* record.

The 5.0 historical store interleaves two type-47 record versions: v18 (124-byte per-second biometric
summary, decoded by `decodeWhoop5Historical`) and **v26** (88-byte high-rate buffer, left raw). This
script tests what the v26 buffer *is*, using the heart rate as internal ground truth — no external
reference or app export needed.

Method:
  - v26 records are 1/second (unix u32 LE @15, the same slot v18 uses), each carrying 24 samples.
  - Parse those samples as **little-endian i16** at bytes [27:75] (NOT big-endian — the high byte is
    0xFA..0xFF / 0x00..0x01, i.e. small signed values in LE order).
  - Concatenate consecutive-second runs → a continuous 24 Hz trace; detrend; autocorrelate.
  - If the dominant period equals the heart rate (from the same-timestamp v18 record), the buffer is a
    pulsatile **optical PPG** trace, not an IMU/motion stream (motion does not phase-lock to HR).

Result on capture_hist_ack.json: the autocorrelation peaks at lag 14 (= 102.9 bpm @24 Hz) against a
measured HR of 101.7 bpm — a ~1 bpm match. The v26 buffer is PPG @24 Hz, LE-i16, bytes [27:75].

Usage:  python3 analyze_v26_waveform.py [capture.json]   (default: capture_hist_ack.json)
"""

import json
import statistics
import struct
import sys
from collections import Counter

WAVE_START, WAVE_END = 27, 75          # 24 LE-i16 samples per record
SAMPLE_RATE_HZ = 24                     # 24 samples/record, 1 record/second


def u32le(r, o):
    return r[o] | (r[o + 1] << 8) | (r[o + 2] << 16) | (r[o + 3] << 24)


def le_i16(r, a, b):
    return [struct.unpack("<h", r[i:i + 2])[0] for i in range(a, b - 1, 2)]


def detrend(x, w=12):
    """Subtract a centred moving average (≈1.7 beats wide) to remove DC/baseline wander."""
    out = []
    for i in range(len(x)):
        lo, hi = max(0, i - w), min(len(x), i + w + 1)
        out.append(x[i] - statistics.mean(x[lo:hi]))
    return out


def acf(x, lag):
    n = len(x) - lag
    m = statistics.mean(x)
    den = sum((xi - m) ** 2 for xi in x)
    return (sum((x[i] - m) * (x[i + lag] - m) for i in range(n)) / den) if den else 0.0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "capture_hist_ack.json"
    frames = [bytes.fromhex(c["hex"]) for c in json.load(open(path))]
    v26 = [r for r in frames if len(r) == 88 and r[8] == 47 and r[9] == 26]
    v18 = [r for r in frames if len(r) == 124 and r[8] == 47 and r[9] == 18]
    if not v26:
        print("no v26 records in", path)
        return
    hr_at = {u32le(r, 15): r[22] for r in v18}        # unix → heart_rate (v18 ground truth)
    ts = [u32le(r, 15) for r in v26]

    # Split into consecutive-second runs (phase only continuous within a run).
    runs, cur = [], [0]
    for i in range(1, len(v26)):
        (cur.append(i) if ts[i] - ts[i - 1] == 1 else (runs.append(cur), cur := [i]))
    runs.append(cur)
    runs = [r for r in runs if len(r) >= 4]

    lags = range(8, 30)
    agg = {l: [] for l in lags}
    hrs = []
    for run in runs:
        sig = []
        for i in run:
            sig += le_i16(v26[i], WAVE_START, WAVE_END)
        sig = detrend(sig)
        for l in lags:
            agg[l].append(acf(sig, l))
        hrs += [hr_at[ts[i]] for i in run if ts[i] in hr_at]

    print(f"{path}: {len(v26)} v26 records in {len(runs)} consecutive runs "
          f"({sum(len(r) for r in runs)} samples-of-records)")
    print(f"measured HR (v18, same timestamps): mean {statistics.mean(hrs):.1f} bpm "
          f"({min(hrs)}..{max(hrs)})\n")
    print("lag  bpm@24Hz  mean-autocorr")
    best = None
    for l in lags:
        a = statistics.mean(agg[l])
        bpm = SAMPLE_RATE_HZ * 60 / l
        if 12 <= l <= 16 and (best is None or a > best[1]):
            best = (l, a, bpm)
        print(f"{l:3d}  {bpm:6.1f}   {a:+.3f} {'#' * int(max(0, a) * 40)}")
    print(f"\nfundamental: lag {best[0]} = {best[2]:.1f} bpm  vs measured {statistics.mean(hrs):.1f} bpm")
    verdict = "PPG (HR-locked)" if abs(best[2] - statistics.mean(hrs)) < 6 else "inconclusive"
    print(f"verdict: v26 buffer is {verdict}")


if __name__ == "__main__":
    main()
