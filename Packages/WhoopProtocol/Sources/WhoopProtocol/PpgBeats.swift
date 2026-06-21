import Foundation

/// Beat-to-beat R-R intervals from the WHOOP 5.0 type-47 **v26** optical PPG buffer — the signal-
/// processing front-end an HRV (RMSSD) capability would need, and the harness to decide whether v26 can
/// support HRV at all.
///
/// OPEN QUESTION, not a foregone feature. `PpgHr`'s header records the contributor's finding that v26
/// "gives no RMSSD". This module exists to TEST that, not contradict it. RMSSD needs individual systolic
/// beat *times*; autocorrelation (what `PpgHr` does) only yields an average rate, and at 24 Hz one
/// sample spans ~41.7 ms — coarse against a typical 20–50 ms RMSSD. So beat timing MUST be refined below
/// the sample grid (parabolic interpolation) or the result is pure quantisation noise. Whether that is
/// enough is empirical; the arbiter is the v18 record stream, which carries the strap's OWN R-R — a
/// same-device ground truth (see docs/superpowers/specs/2026-06-21-whoop5-v26-ppg-hrv-feasibility.md).
///
/// Pure + Foundation-only. Reuses `PpgHr.detrend` / `PpgHr.removeRecordRateComponent` (the #194-safe
/// pre-filter) so the detector never re-introduces the record-rate artifact. Produces RAW R-R in ms;
/// the existing `HRVAnalyzer.analyze(rawRR:)` does the range + Malik ectopic clean and the ≥20-beat gate.
public enum PpgBeats {
    /// v26 carries 24 samples per 1-second record (shared with `PpgHr`).
    public static let sampleRateHz = PpgHr.sampleRateHz   // 24

    /// Refractory period (ms): no two systolic peaks closer than this, so a dicrotic notch can't
    /// register as a second beat. Matches `HRVAnalyzer.rrMinMs` (300 ms ≈ 200 bpm) without importing it
    /// (WhoopProtocol has no StrandAnalytics dependency); kept equal by intent + a test.
    public static let refractoryMs = 300.0

    /// Adaptive peak threshold: a candidate local maximum must exceed this multiple of the run's RMS.
    /// After `detrend` the baseline sits at ~0, so RMS scales with pulse amplitude. Conservative + tunable;
    /// the Phase-0 synthetic harness is what should set it, not guesswork on hardware.
    public static let thresholdRmsMult = 0.5

    /// Sub-sample peak position by parabolic interpolation around integer index `i`. Returns `i + delta`
    /// with `delta` in [-0.5, 0.5]; falls back to `Double(i)` on a degenerate (flat) vertex or an out-of-
    /// range index. THIS is what lifts beat timing off the 24 Hz grid — without it R-R is quantised to
    /// ~41.7 ms and RMSSD is meaningless.
    public static func refinePeakIndex(_ x: [Double], _ i: Int) -> Double {
        guard i >= 1, i + 1 < x.count else { return Double(i) }
        let a = x[i - 1], b = x[i], c = x[i + 1]
        let denom = a - 2 * b + c
        guard denom != 0 else { return Double(i) }
        let delta = 0.5 * (a - c) / denom
        guard delta.isFinite, abs(delta) <= 0.5 else { return Double(i) }
        return Double(i) + delta
    }

    /// Detect systolic peaks in one continuous, evenly-sampled waveform; returns refined (fractional)
    /// sample positions, ascending. Pre-filters with the #194-safe `removeRecordRateComponent` →
    /// `detrend`, picks local maxima above an adaptive RMS threshold, enforces refractory spacing (keeping
    /// the taller of any two within it), then parabolically refines each kept peak.
    ///
    /// NOTE (Phase-0 simplicity): the threshold is a single global RMS over the run and the high-pass is
    /// only the linear detrend. A moving threshold + a proper cardiac band-pass are the obvious refinements
    /// once the synthetic harness says the approach is worth pursuing; deliberately omitted here so the
    /// first measurement is of the *simplest* detector, not a tuned one.
    public static func detectPeaks(_ samples: [Int], fs: Int = sampleRateHz) -> [Double] {
        let n = samples.count
        guard n >= fs, fs > 1 else { return [] }
        let x = PpgHr.detrend(PpgHr.removeRecordRateComponent(samples.map(Double.init), fs: fs))
        guard x.count == n else { return [] }

        var sumSq = 0.0
        for v in x { sumSq += v * v }
        let rms = (sumSq / Double(n)).squareRoot()
        guard rms > 0 else { return [] }
        let thr = thresholdRmsMult * rms
        let refractory = max(1, Int((refractoryMs / 1000.0 * Double(fs)).rounded(.down)))

        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i] > thr && x[i] >= x[i - 1] && x[i] > x[i + 1] {
                if let last = peaks.last, i - last < refractory {
                    if x[i] > x[last] { peaks[peaks.count - 1] = i }   // too close → keep the taller
                } else {
                    peaks.append(i)
                }
            }
            i += 1
        }
        return peaks.map { refinePeakIndex(x, $0) }
    }

    /// R-R intervals (ms) over v26 records. Records are grouped into consecutive-second runs (PPG phase is
    /// continuous only within a run — same rule as `PpgHr.derivePpgHr`); within a run the per-second sample
    /// arrays are concatenated in time order and beats detected across the whole run, so an R-R that
    /// straddles a second boundary is measured correctly. Output is every successive-peak interval in ms,
    /// UNCLEANED — feed to `HRVAnalyzer.analyze(rawRR:)`. Records may be unsorted / contain gaps.
    public static func deriveRR(records: [(ts: Int, samples: [Int])], fs: Int = sampleRateHz) -> [Double] {
        guard !records.isEmpty, fs > 1 else { return [] }
        var secs = [Int: [Int]]()
        for r in records { secs[r.ts] = r.samples }
        let order = secs.keys.sorted()

        var runs = [[Int]]()
        var cur = [order[0]]
        for u in order.dropFirst() {
            if u - cur.last! == 1 { cur.append(u) } else { runs.append(cur); cur = [u] }
        }
        runs.append(cur)

        let msPerSample = 1000.0 / Double(fs)
        var rr = [Double]()
        for run in runs {
            var sig = [Int]()
            for u in run { sig.append(contentsOf: secs[u]!) }
            let peaks = detectPeaks(sig, fs: fs)
            guard peaks.count >= 2 else { continue }
            for k in 1..<peaks.count { rr.append((peaks[k] - peaks[k - 1]) * msPerSample) }
        }
        return rr
    }
}
