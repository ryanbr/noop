#!/usr/bin/env python3
"""analyze_v25_waveform.py — pin the WHOOP 4.0 *v25* historical PPG span from a capture corpus (#194).

Reimplemented from @vulnix0x4's PR #307 (RFC for #194); the 1440/N disproof is @ryanbr's.

WHOOP 4.0's offloaded type-47 **v25** record carries an optical PPG waveform (PostHooks labels bytes
~23–73 "PPG waveform (optical)"), but NOOP decodes only its motion + timestamp. #194 proposes reading
that waveform on the odd i16 grid and routing it through the existing `PpgHr` lane to recover HR — the
way the v26/WHOOP-5 sibling already does — which would give 4.0 *offloaded* sleep + recovery.

The catch (and why this is a HARNESS, not a decoder): the exact PPG **span is unpinned** — where it
starts (offset 15 vs 25) and how many samples it holds (21 vs 24). And the obvious validation is a
trap. Concatenating N samples/record before autocorrelating manufactures a self-similarity at lag = N,
so the "recovered" bpm lands on the record PERIOD `1440 / N` (= 60 bpm at N=24) **regardless of the
real heart rate** — exactly the retracted "60 bpm on 3 resting sessions" from the issue. A resting
(~60 bpm) capture therefore CANNOT tell a real 60-bpm pulse from the N=24 artifact.

So pinning the span needs a **corpus**: ≥2 captures whose true HR differs, ideally one clearly ≠ 60
(go for a walk/run while it records). For each candidate (start, N) this sweeps the recovered bpm and
asks the only question that disambiguates physiology from arithmetic:

    does recovered HR TRACK the ground-truth HR across captures, and DIVERGE from 1440/N?

A candidate that tracks ground truth (and isn't just sitting on 1440/N) is the real PPG span. If every
capture is resting, the harness says so and tells you exactly what to send.

This pins the SPAN. The shipped `PpgHr` lane is the authoritative decoder, and
`Whoop4HistoricalV25PpgTests` is the executable guard that a wrong span must not fabricate HR — run
both once a span is pinned here.

Ground truth for v25 is NOT in the record (unlike v26, whose co-timestamped v18 carries HR). It is the
*independent* live-HR you were at while the strap banked that history — read it off your watch, or off
the live `HR notify` (type-40/43) lines in the same strap log.

USAGE
  python3 analyze_v25_waveform.py                 # demo on the 3 bundled resting frames (shows the trap)
  python3 analyze_v25_waveform.py corpus.json     # a real corpus you built (format below / --template)
  python3 analyze_v25_waveform.py --template      # print an empty corpus.json to fill in

CORPUS FORMAT  (JSON list; one entry per contiguous recording at a known HR)
  [
    {"label": "easy spin ~110 bpm", "ground_truth_bpm": 110,
     "frames": ["aa50000c2f19....", "aa50000c2f19....", "..."]},
    {"label": "resting ~58 bpm",    "ground_truth_bpm": 58,  "frames": ["...", "..."]}
  ]
  frames = the raw v25 record hex. Grab them from a strap log's `rejected frame[..]` / undecodable
  type-47 v25 lines (same lines the #194 repro reads), across a window where you know your HR.
"""

import json
import statistics
import struct
import sys

# --- v25 record geometry (WHOOP 4.0 envelope: 0xAA, len u16, crc8, type@4, version@5, ...) -----------
TYPE_HISTORICAL = 0x2F        # 47, at byte 4
VERSION_V25 = 25              # at byte 5
TS_OFFSET = 11               # unix u32 LE
GRAVITY_OFFSET = 73          # the PPG span must end at/before the gravity field
SAMPLE_RATE_HZ = 24          # the v26 sibling's rate (1 record/sec); start + N are the unknowns

# Candidate sweep. start brackets ryanbr's 15 and the proposed 25; N brackets 21..24. Each (start, N)
# is capped so the window ends at/before gravity@73 (start + 2*N <= 73).
START_RANGE = range(13, 28)
N_RANGE = range(18, 31)

HR_BAND_LO, HR_BAND_HI = 30, 220     # plausible human HR (bpm) the autocorrelation searches within
TRACK_TOL_BPM = 8.0                  # |recovered - ground_truth| under this = "tracks"
DISTINCT_MARGIN_BPM = 12.0           # a capture whose GT is this far from 1440/N actually tests the span

# The three REAL resting v25 frames already in the repo (Whoop4HistoricalV25Tests / the #194 fixture),
# App 1.92, consecutive seconds, resting (~60 bpm). Bundled so the demo run needs no external file.
BUNDLED_RESTING = {
    "label": "repo fixture — faklei resting (~60 bpm)",
    "ground_truth_bpm": 60,
    "frames": [
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716",
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf",
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9",
    ],
}

TEMPLATE = [
    {"label": "describe it, e.g. brisk walk ~115 bpm", "ground_truth_bpm": 115, "frames": ["<hex>", "<hex>"]},
    {"label": "a second window at a DIFFERENT HR", "ground_truth_bpm": 60, "frames": ["<hex>", "<hex>"]},
]


def u32le(r, o):
    return r[o] | (r[o + 1] << 8) | (r[o + 2] << 16) | (r[o + 3] << 24)


def le_i16(r, a, b):
    return [struct.unpack("<h", r[i:i + 2])[0] for i in range(a, b - 1, 2)]


def detrend(x, w=12):
    """Subtract a centred moving average (~1.7 beats wide) to remove DC / baseline wander."""
    out = []
    for i in range(len(x)):
        lo, hi = max(0, i - w), min(len(x), i + w + 1)
        out.append(x[i] - statistics.mean(x[lo:hi]))
    return out


def acf(x, lag):
    n = len(x) - lag
    if n <= 0:
        return 0.0
    m = statistics.mean(x)
    den = sum((xi - m) ** 2 for xi in x)
    return (sum((x[i] - m) * (x[i + lag] - m) for i in range(n)) / den) if den else 0.0


def is_v25(r):
    return len(r) > GRAVITY_OFFSET and r[4] == TYPE_HISTORICAL and r[5] == VERSION_V25


def consecutive_runs(records):
    """Group v25 records into consecutive-second runs (phase is only continuous within a run)."""
    recs = sorted(records, key=lambda r: u32le(r, TS_OFFSET))
    runs, cur = [], []
    for r in recs:
        t = u32le(r, TS_OFFSET)
        if cur and t - u32le(cur[-1], TS_OFFSET) != 1:
            runs.append(cur)
            cur = []
        cur.append(r)
    if cur:
        runs.append(cur)
    return [run for run in runs if len(run) >= 2]


def recovered_bpm(records, start, n):
    """Recovered HR (bpm) + confidence for one (start, N) candidate, autocorrelating the concatenated,
    detrended PPG over the human-HR band. Returns (bpm, conf) or (None, 0) when there isn't enough
    contiguous data."""
    runs = consecutive_runs(records)
    if not runs:
        return None, 0.0
    lo = max(1, SAMPLE_RATE_HZ * 60 // HR_BAND_HI)
    hi = SAMPLE_RATE_HZ * 60 // HR_BAND_LO
    peak_lag, peak_val = None, -2.0
    for run in runs:
        sig = []
        for r in run:
            sig += le_i16(r, start, start + 2 * n)
        sig = detrend(sig)
        for lag in range(lo, min(hi, len(sig) - 1) + 1):
            v = acf(sig, lag)
            if v > peak_val:
                peak_val, peak_lag = v, lag
    if peak_lag is None:
        return None, 0.0
    return round(SAMPLE_RATE_HZ * 60 / peak_lag), round(peak_val, 3)


def load_corpus(argv):
    if "--template" in argv:
        print(json.dumps(TEMPLATE, indent=2))
        sys.exit(0)
    paths = [a for a in argv[1:] if not a.startswith("-")]
    if not paths:
        print("No corpus given — running the DEMO on the bundled resting frames (which cannot pin the\n"
              "span; that is the point). Build a real corpus (--template) with a HR ≠ 60.\n")
        return [BUNDLED_RESTING]
    return json.load(open(paths[0]))


def analyze(corpus):
    captures = []
    for c in corpus:
        frames = [bytes.fromhex(h) for h in c["frames"]]
        v25 = [r for r in frames if is_v25(r)]
        captures.append({"label": c["label"], "gt": float(c["ground_truth_bpm"]), "recs": v25})
        print(f"• {c['label']!r}: {len(v25)}/{len(frames)} v25 records, ground-truth HR {c['ground_truth_bpm']} bpm")
    if not any(cap["recs"] for cap in captures):
        print("\nNo v25 records found (type-47 @byte4, version-25 @byte5). Check the frame hex.")
        return []
    gts = [cap["gt"] for cap in captures]
    spread = (max(gts) - min(gts)) if gts else 0.0
    can_disambiguate = spread >= DISTINCT_MARGIN_BPM
    print(f"\n{len(captures)} capture(s); ground-truth HRs {sorted({round(g) for g in gts})} bpm "
          f"(spread {spread:.0f} bpm — {'enough to disambiguate' if can_disambiguate else 'all too close; cannot pin a span'})\n")

    # Sweep every (start, N) whose window fits before gravity@73; score how it does across the corpus.
    print(f"{'start':>5} {'N':>3} {'1440/N':>7} {'recovered bpm / conf per capture':<44} {'mean|err|':>9}  verdict")
    print("-" * 92)
    pinned = []
    for start in START_RANGE:
        for n in N_RANGE:
            if start + 2 * n > GRAVITY_OFFSET:
                continue
            artifact = round(1440 / n)
            per, errs, tracks_far = [], [], False
            for cap in captures:
                bpm, conf = recovered_bpm(cap["recs"], start, n)
                per.append(f"{cap['gt']:.0f}→{('--' if bpm is None else bpm)}({conf:.2f})")
                if bpm is not None:
                    errs.append(abs(bpm - cap["gt"]))
                    # real evidence: a capture whose true HR is far from THIS span's 1440/N artifact and
                    # whose recovery still follows the true HR (not the artifact).
                    if abs(cap["gt"] - artifact) >= DISTINCT_MARGIN_BPM and abs(bpm - cap["gt"]) <= TRACK_TOL_BPM:
                        tracks_far = True
            mean_err = statistics.mean(errs) if errs else float("nan")
            verdict = ""
            # Pin ONLY when the corpus can disambiguate (≥2 well-separated HRs) AND this span tracks HR
            # across them, including a HR far from its own artifact. A single resting capture never pins.
            if can_disambiguate and errs and mean_err <= TRACK_TOL_BPM and tracks_far:
                verdict = "★ TRACKS HR"
                pinned.append((mean_err, start, n))
            print(f"{start:>5} {n:>3} {artifact:>7} {' '.join(per):<44} {mean_err:>9.1f}  {verdict}")

    print()
    if pinned:
        pinned.sort()
        err, start, n = pinned[0]
        print(f"PINNED → start={start}, N={n}, fs={SAMPLE_RATE_HZ} Hz  (mean |error| {err:.1f} bpm; recovered HR\n"
              f"tracks ground truth and diverges from the 1440/N={round(1440/n)} artifact). Next: wire this span\n"
              f"into the v25 decoder → `PpgHr` lane, then run Whoop4HistoricalV25PpgTests to confirm no fabrication.")
    else:
        distinct = sorted({round(g) for g in gts})
        print("INSUFFICIENT to pin the span. Every candidate either fails to track HR or its 1440/N record-\n"
              f"period artifact is indistinguishable from the ground-truth HR ({distinct} bpm). The autocorrelation\n"
              "cannot tell a real pulse from the concatenation artifact at these HRs.\n\n"
              "WHAT TO SEND (issue #194): one more contiguous v25 capture at a HR clearly ≠ 60 — e.g. record a\n"
              "short walk or easy run — plus the HR you were at (watch, or the live `HR notify` lines in the same\n"
              "strap log). With one non-60 window, the real span will track it while the artifact won't, and this\n"
              "prints PINNED. Use --template for the corpus file shape.")
    return pinned


def _synth_frames(hr_bpm, k, start, n, t0=1_700_000_000, amp=2000.0):
    """Build k consecutive synthetic v25 frames carrying a clean `hr_bpm` pulse at [start:start+2n]."""
    import math
    out = []
    for s in range(k):
        f = bytearray(84)
        f[0] = 0xAA
        f[4] = TYPE_HISTORICAL
        f[5] = VERSION_V25
        f[TS_OFFSET:TS_OFFSET + 4] = struct.pack("<I", t0 + s)
        for i in range(n):
            g = s * n + i
            v = int(amp * math.sin(2 * math.pi * (hr_bpm / 60.0) * g / SAMPLE_RATE_HZ))
            f[start + 2 * i:start + 2 * i + 2] = struct.pack("<h", max(-32768, min(32767, v)))
        out.append(f.hex())
    return out


def selftest():
    """Validate the POSITIVE path: synthetic captures at two well-separated HRs, each carrying a real
    pulse at a known span, must PIN it — and the single-HR resting demo must NOT pin."""
    true_start, true_n = 25, 24
    corpus = [
        {"label": "synthetic ~100 bpm", "ground_truth_bpm": 100, "frames": _synth_frames(100, 8, true_start, true_n)},
        {"label": "synthetic ~58 bpm", "ground_truth_bpm": 58, "frames": _synth_frames(58, 8, true_start, true_n)},
    ]
    pinned = analyze(corpus)
    assert pinned, "selftest FAILED: a real pulse across two distinct HRs must PIN a span"
    err, start, n = sorted(pinned)[0]
    assert err <= TRACK_TOL_BPM, f"selftest FAILED: best pin err {err:.1f} > {TRACK_TOL_BPM}"
    assert not analyze([BUNDLED_RESTING]), "selftest FAILED: a single resting HR must never pin"
    print(f"\nselftest PASSED ✓ — pinned start={start}, N={n} (best err {err:.1f} bpm) on synthetic "
          f"100/58 bpm pulses; the all-resting demo correctly did NOT pin.")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        analyze(load_corpus(sys.argv))
