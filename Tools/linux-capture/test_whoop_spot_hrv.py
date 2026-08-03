"""Tests for whoop_spot_hrv.py — the spot-HRV DSP, on synthetic signals with KNOWN beats.

These test the algorithm (peak detection, RR, RMSSD, glitch rejection) against signals whose ground truth
we control — not strap frames. Stdlib only; runs under either `python3 -m unittest` (the runner the
README documents and the only one in requirements.txt) or pytest.
"""
import math

import whoop_spot_hrv as H


def _synth_ppg(fs, n_beats, ibi_ms, width_s=0.12):
    """A clean PPG-like waveform: a Gaussian pulse at each beat time given an IBI sequence."""
    beat_t = [0.5]
    for ms in ibi_ms[: n_beats - 1]:
        beat_t.append(beat_t[-1] + ms / 1000.0)
    dur = beat_t[-1] + 0.5
    nsamp = int(dur * fs)
    t = [i / fs for i in range(nsamp)]
    v = []
    for ti in t:
        s = 0.0
        for bt in beat_t:
            d = (ti - bt) / width_s
            if abs(d) < 4:
                s += math.exp(-d * d)
        v.append(s * 1000.0 + 50000.0)   # scale + DC offset, like the real channel
    return t, v


def test_spot_hrv_recovers_hr_and_rmssd():
    fs = 24.0
    # 60 bpm with a deliberate alternating ±30 ms jitter → successive |diff| = 60 ms → RMSSD ≈ 60 ms
    ibi = [1030 if i % 2 == 0 else 970 for i in range(40)]
    t, v = _synth_ppg(fs, 40, ibi)
    r = H.spot_hrv(t, v, fs)
    assert r is not None
    assert 55 <= r["hr"] <= 65, r["hr"]                 # ~60 bpm
    assert r["n_clean"] >= 25 and r["quality"] == "GOOD"
    assert 35 <= r["rmssd"] <= 90, r["rmssd"]           # ~60 ms, allowing 24 Hz quantisation slack


def test_rmssd_sequential_clean_and_glitch():
    assert H.rmssd_sequential([800, 800, 800, 800]) == 0.0          # no variation
    # a single ectopic (1600) must be rejected, not inflate RMSSD (enough clean beats remain)
    rm = H.rmssd_sequential([800, 800, 800, 800, 1600, 800, 800, 800, 800])
    assert rm is not None and rm < 50, rm
    # too few clean diffs after rejecting the ectopic → conservatively None (no false HRV)
    assert H.rmssd_sequential([800, 800, 1600, 800, 800]) is None


def test_rmssd_sequential_too_short_is_none():
    assert H.rmssd_sequential([]) is None
    assert H.rmssd_sequential([800]) is None


def test_reconstruct_empty_rows():
    t, v, fs = H.reconstruct([])
    assert t == [] and v == [] and fs == 0.0


def test_reconstruct_grid_is_monotonic():
    rows = [(1000, 0, 5), (1000, 1, 6), (1000, 2, 7), (1001, 0, 5), (1001, 1, 6), (1001, 2, 7)]
    t, v, fs = H.reconstruct(rows)
    assert fs == 3.0
    assert t == sorted(t) and t[0] == 0.0
    assert abs(t[3] - 1.0) < 1e-9                       # second 1, sample 0 → t=1.0
    assert len(v) == 6


def test_find_peaks_counts_beats():
    fs = 24.0
    t, v = _synth_ppg(fs, 10, [1000] * 9)               # 10 clean beats at 60 bpm
    vv = H.detrend(v, int(fs))
    import statistics
    pk = H.find_peaks(vv, min_dist=int(0.4 * fs), min_prom=0.3 * statistics.pstdev(vv))
    assert 9 <= len(pk) <= 11, len(pk)


def test_find_peaks_enforces_min_dist_keeping_the_taller():
    """Two maxima closer together than min_dist: only the taller survives.

    Guards the spacing filter specifically. `test_find_peaks_counts_beats` above does not — its beats
    are already well separated, so deleting the min_dist check entirely leaves it passing.
    """
    v = [0.0, 5.0, 0.0, 9.0, 0.0]           # maxima at 1 (5) and 3 (9), two samples apart
    assert H.find_peaks(v, min_dist=3, min_prom=0.0) == [3]
    assert H.find_peaks(v, min_dist=2, min_prom=0.0) == [1, 3]


def test_find_peaks_enforces_min_prom():
    """A local maximum below min_prom is not a peak.

    Guards the prominence gate specifically — deleting it also leaves the beat-count test passing.
    """
    v = [0.0, 2.0, 0.0, 9.0, 0.0]
    assert H.find_peaks(v, min_dist=1, min_prom=5.0) == [3]
    assert H.find_peaks(v, min_dist=1, min_prom=1.0) == [1, 3]
    # Strict `>`: a maximum sitting exactly ON the threshold is rejected. The docstring used to say
    # `>= min_prom`, which is the opposite; the code was right and the doc has been corrected.
    assert H.find_peaks([0.0, 5.0, 0.0], min_dist=1, min_prom=5.0) == []
    assert H.find_peaks([0.0, 5.0, 0.0], min_dist=1, min_prom=4.9) == [1]


def test_find_peaks_plateau_yields_one_index():
    """A flat plateau is one peak, not one per sample.

    The neighbour test is asymmetric on purpose (`> left`, `>= right`). Symmetric `>=` would emit a
    duplicate for every plateau sample and inflate the beat count; symmetric `>` would drop plateaus
    altogether. Nothing pinned that before, and the docstring described it wrongly as `>= neighbours`.
    """
    assert H.find_peaks([0.0, 5.0, 5.0, 0.0], min_dist=1, min_prom=0.0) == [1]
    assert H.find_peaks([0.0, 5.0, 5.0, 5.0, 0.0], min_dist=1, min_prom=0.0) == [1]


def test_spot_hrv_returns_none_on_too_few_samples():
    # too few samples → None (no false HRV)
    assert H.spot_hrv([0, 1, 2], [1.0, 2.0, 1.0], 24.0) is None


def test_spot_hrv_returns_none_on_flat_signal():
    # a flat (no-beat) signal of plenty of samples → no detectable RR → None, never a fabricated value
    fs = 24.0
    t = [i / fs for i in range(120)]
    v = [50000.0] * 120
    assert H.spot_hrv(t, v, fs) is None


# ── unittest collection ───────────────────────────────────────────────────────────────────────────
# Same hook, and the same reason, as test_whoop_activity.py: this module is pytest-style (bare
# `def test_*`, no unittest.TestCase), so `python3 -m unittest` collected NOTHING from it and exited 0
# — which is indistinguishable from passing. All eight take no fixtures, so wrapping them is enough.
def load_tests(loader, tests, pattern):    # noqa: ARG001 — unittest protocol signature
    import unittest
    suite = unittest.TestSuite(tests)
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            suite.addTest(unittest.FunctionTestCase(fn, description=name))
    return suite
