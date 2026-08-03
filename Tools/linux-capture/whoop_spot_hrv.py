#!/usr/bin/env python3
"""Compute a spot HRV (RMSSD) on Linux from the strap's sparse PPG bursts in the offload.

The historical offload's per-second `rr_packed` field saturates/underestimates HRV, but the strap also
banks a real 24 Hz PPG waveform in its sparse optical bursts (record version 26 -> `feat_ppg` channel 0).
That waveform is genuine cardiac PPG -- its fundamental tracks the heart rate (validated: corr=+0.907 over
14 bursts), so beats can be detected and RMSSD computed directly from it. Where a burst lands inside a deep
sleep window, the PPG-derived RMSSD has matched the cloud's deep-sleep number on the captures we've checked
(and reaches values the offload's clamped `rr` field cannot) -- but that is a handful of windows, not a
controlled study, so treat the accuracy as promising, not proven.

Limits (be honest):
- SPARSE -- PPG bursts are ~40 s every ~18.7 min (~3.3% coverage), so a window only gets HRV if a burst
  lands in it. This is a *spot* HRV, not continuous overnight HRV.
- COARSE -- 24 Hz sampling quantises beat timing (~42 ms/sample); sub-sample interpolation + glitch
  rejection help, but treat RMSSD as approximate and require enough clean beats (see `quality`).
- HRV only, not SpO2 (the PPG is AC-coupled -- no DC red/IR).

Reads the per-second `feat_ppg` channel-0 grid that noop decodes into whoop.db (read-only).

Usage:
  whoop_spot_hrv.py --db captures/whoop.db --device 1                 # auto: every PPG-covered window
  whoop_spot_hrv.py --db captures/whoop.db --device 1 --start S --end E   # one window (e.g. a deep-sleep span)
"""
import argparse
import sqlite3
from collections import Counter
from statistics import median, pstdev


# ---------------------------------------------------------------- validated DSP (pure)

def reconstruct(rows):
    """feat_ppg rows [(unix, sample_idx, value)] -> (times_s, values, fs) on a clean per-second grid.
    fs = samples/second (one record == 1 s); sample i of second k lands at k + i/n."""
    if not rows:
        return [], [], 0.0
    n = max(Counter(u for u, _, _ in rows).values())
    base = rows[0][0]
    t = [(u - base) + (si / n) for u, si, _ in rows]
    v = [float(x) for _, _, x in rows]
    return t, v, float(n)


def detrend(v, win):
    """Subtract a centred moving average (removes PPG baseline wander)."""
    n = len(v); out = [0.0] * n; h = max(1, win // 2)
    for i in range(n):
        lo = max(0, i - h); hi = min(n, i + h + 1)
        out[i] = v[i] - sum(v[lo:hi]) / (hi - lo)
    return out


def find_peaks(v, min_dist, min_prom):
    """Local maxima strictly above min_prom, spaced >= min_dist (keep the taller on conflict).

    The neighbour test is deliberately ASYMMETRIC — `v[i] > v[i-1] and v[i] >= v[i+1]` — so a flat
    plateau yields ONE index (its left edge) instead of one per sample. Making it symmetric `>=`
    would emit a duplicate peak for every plateau sample; making it symmetric `>` would drop
    plateaus entirely. Both are pinned by tests.

    `min_prom` is a strict `>`: a maximum sitting exactly ON the threshold is rejected.
    """
    cand = [i for i in range(1, len(v) - 1) if v[i] > v[i - 1] and v[i] >= v[i + 1] and v[i] > min_prom]
    cand.sort(key=lambda i: -v[i])
    kept = []
    for i in cand:
        if all(abs(i - j) >= min_dist for j in kept):
            kept.append(i)
    return sorted(kept)


def _interp(v, p):
    """Parabolic sub-sample peak offset (fractional samples) around index p."""
    if 0 < p < len(v) - 1:
        a, b, c = v[p - 1], v[p], v[p + 1]
        den = a - 2 * b + c
        return (a - c) / (2 * den) if den else 0.0
    return 0.0


def rmssd_sequential(rr, thr=0.30):
    """RMSSD over consecutive RR, skipping pairs where either RR jumped > thr (ectopic/artifact)."""
    if len(rr) < 2:
        return None
    glitch = [False] * len(rr)
    for i in range(1, len(rr)):
        if abs(rr[i] - rr[i - 1]) > thr * rr[i - 1]:
            glitch[i] = True
    d = [rr[i] - rr[i - 1] for i in range(1, len(rr)) if not glitch[i - 1] and not glitch[i]]
    return (sum(x * x for x in d) / len(d)) ** 0.5 if len(d) >= 2 else None


def spot_hrv(t, v, fs):
    """(times_s, values, fs) -> {hr, rmssd, n_beats, n_rr, span_s, quality}. None if too little signal."""
    if len(v) < 30 or fs <= 0:
        return None
    vv = detrend(v, int(fs))
    sd = pstdev(vv) or 1.0
    peaks = find_peaks(vv, min_dist=int(0.4 * fs), min_prom=0.3 * sd)   # >= 0.4 s apart (<=150 bpm)
    bt = [t[p] + _interp(vv, p) / fs for p in peaks]
    rr = [(bt[i + 1] - bt[i]) * 1000.0 for i in range(len(bt) - 1)]
    rr = [x for x in rr if 300 <= x <= 2000]
    if len(rr) < 2:
        return None
    hr = 60000.0 / median(rr)
    rmssd = rmssd_sequential(rr)
    n_clean = sum(1 for i in range(1, len(rr)) if abs(rr[i] - rr[i - 1]) <= 0.30 * rr[i - 1])
    span = (t[-1] - t[0]) if t else 0.0
    # quality: enough clean beats to trust the RMSSD
    if rmssd is None or n_clean < 10:
        q = "POOR"
    elif n_clean >= 25:
        q = "GOOD"
    else:
        q = "COARSE"
    return {"hr": hr, "rmssd": rmssd, "n_beats": len(bt), "n_rr": len(rr),
            "n_clean": n_clean, "span_s": span, "fs": fs, "quality": q}


# ---------------------------------------------------------------- CLI

def _rows(con, dev, ch, a, b):
    q = "SELECT unix, sample_idx, value FROM feat_ppg WHERE device_id=? AND channel=?"
    args = [dev, ch]
    if a:
        q += " AND unix>=?"; args.append(a)
    if b:
        q += " AND unix<?"; args.append(b)
    q += " ORDER BY unix, sample_idx"
    return con.execute(q, args).fetchall()


def _covered_windows(con, dev, ch):
    """Contiguous runs of seconds that carry channel-`ch` PPG (each ~= one burst)."""
    secs = [r[0] for r in con.execute(
        "SELECT DISTINCT unix FROM feat_ppg WHERE device_id=? AND channel=? ORDER BY unix",
        (dev, ch)).fetchall()]
    runs = []; cur = []
    for s in secs:
        if cur and s == cur[-1] + 1:
            cur.append(s)
        else:
            if len(cur) >= 20:
                runs.append((cur[0], cur[-1] + 1))
            cur = [s]
    if len(cur) >= 20:
        runs.append((cur[0], cur[-1] + 1))
    return runs


def main():
    ap = argparse.ArgumentParser(description="spot HRV (RMSSD) from sparse v26 PPG bursts")
    ap.add_argument("--db", required=True)
    ap.add_argument("--device", type=int, required=True)
    ap.add_argument("--channel", type=int, default=0, help="feat_ppg channel (0 = the 24 Hz waveform)")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--end", type=int, default=0)
    args = ap.parse_args()
    # Read-only: open the DB in immutable/ro mode so this analysis tool can never write to whoop.db.
    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)

    windows = [(args.start, args.end)] if args.start and args.end else _covered_windows(con, args.device, args.channel)
    if not windows:
        print("no PPG-covered windows (need v26 optical bursts in feat_ppg for this device)")
        return 1
    print(f"{'window_start':>12}  {'span':>5}  {'HR':>5}  {'RMSSD':>6}  {'beats':>5}  quality")
    got = 0
    for a, b in windows:
        r = spot_hrv(*reconstruct(_rows(con, args.device, args.channel, a, b)))
        if not r:
            continue
        got += 1
        rm = f"{r['rmssd']:.0f}ms" if r["rmssd"] is not None else "   - "
        print(f"{a:>12}  {r['span_s']:4.0f}s  {r['hr']:4.0f}  {rm:>6}  {r['n_clean']:5d}  {r['quality']}")
    print(f"\n{got} window(s) with usable PPG. RMSSD is a *spot* estimate (sparse + 24 Hz-coarse); trust GOOD,"
          " treat COARSE/POOR with caution. Best signal = a burst inside deep sleep.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
