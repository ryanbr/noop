import Foundation

/// Per-second heart rate derived from the WHOOP 5.0 type-47 **v26** optical PPG buffer (issue #156).
///
/// On v26-heavy stretches of a night the strap records the 24 Hz optical PPG waveform instead of the
/// v18 per-second summary that carries HR. The v26 records are real cardiac signal, so this pure
/// estimator recovers a per-second HR from them via windowed autocorrelation, keeping the biometric
/// timeline continuous through the gaps. It is HR-only — PPG carries NO body motion, so this fills HR
/// continuity, NOT actigraphy and NOT HRV (the contributor confirmed v26 gives no RMSSD).
///
/// Mirrors `Tools/linux-capture/ppg_hr.py` (PR #162, Python side): 8 s autocorrelation window, a
/// 30–220 bpm search band (lags 6…48 at 24 Hz), linear detrend, normalised peak as confidence, and a
/// fundamental-period preference so the harmonic peaks at 2×/3× the true period don't report half/third
/// the real rate. Pure + Foundation-only so it is unit-testable from synthetic and captured waveforms.

public struct PpgHrSample: Equatable, Codable, Sendable {
    public let ts: Int          // wall-clock unix seconds (one estimate per second)
    public let bpm: Int         // PPG-derived heart rate, whole bpm — the same Int domain as the
                                // measured HRSample.bpm and the Android PpgHr.Estimate.bpm, so the
                                // stored value and type match across platforms (#219).
    public let conf: Double     // normalised autocorrelation peak behind `bpm` (0…1)
    public init(ts: Int, bpm: Int, conf: Double) {
        self.ts = ts; self.bpm = bpm; self.conf = conf
    }
}

public enum PpgHr {
    public static let sampleRateHz = 24          // v26 carries 24 samples per 1-second record
    public static let windowSeconds = 8          // autocorrelation window (stable at low HR)
    public static let hrLoBpm = 30.0
    public static let hrHiBpm = 220.0
    public static let minConfidence = 0.3        // reject a window whose best peak is weaker than this

    /// Linear-detrend a waveform: subtract the least-squares best-fit line to remove DC + baseline
    /// wander (slow respiration/perfusion drift) before the autocorrelation, so the pulse dominates.
    static func detrend(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return x.map { _ in 0 } }
        let nD = Double(n)
        // x-axis is the sample index 0…n-1; closed-form slope/intercept of the LS line.
        let sumI = nD * (nD - 1) / 2
        let sumI2 = (nD - 1) * nD * (2 * nD - 1) / 6
        var sumY = 0.0, sumIY = 0.0
        for (i, y) in x.enumerated() { let id = Double(i); sumY += y; sumIY += id * y }
        let denom = nD * sumI2 - sumI * sumI
        guard denom != 0 else {
            let mean = sumY / nD
            return x.map { $0 - mean }
        }
        let slope = (nD * sumIY - sumI * sumY) / denom
        let intercept = (sumY - slope * sumI) / nD
        return x.enumerated().map { (i, y) in y - (slope * Double(i) + intercept) }
    }

    /// Normalised autocorrelation of `x` at `lag` (0 when the signal is flat).
    static func acf(_ x: [Double], _ lag: Int) -> Double {
        let n = x.count - lag
        guard n > 0 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        var den = 0.0
        for v in x { let d = v - mean; den += d * d }
        guard den != 0 else { return 0 }
        var num = 0.0
        for i in 0..<n { num += (x[i] - mean) * (x[i + lag] - mean) }
        return num / den
    }

    /// Subtract the record-synchronous (period = `fs`) component of `x` — the artifact a per-record DC
    /// step / phase reset injects. It autocorrelates strongly at lag = fs (= 60 bpm at 24 Hz), so a
    /// sub-60-bpm sleeper would otherwise SNAP to 60 because fundamental-period preference picks the
    /// smaller lag (#194, ryanbr).
    ///
    /// CRUCIAL: a true ~60-bpm pulse is ALSO period-fs (one cycle per record), so a blind column-mean
    /// subtraction would erase a real 60 bpm. The discriminator is the record BOUNDARY: an artifact
    /// (phase reset / DC step) is DISCONTINUOUS there, while a real pulse flows smoothly across it. So
    /// only de-artifact when the boundary first-difference is much larger than the within-record one;
    /// otherwise leave the signal untouched. Gated on ≥ 4 records so the comb is well estimated.
    static func removeRecordRateComponent(_ x: [Double], fs: Int) -> [Double] {
        let n = x.count
        guard fs > 1, n >= fs * 4 else { return x }
        var withinSum = 0.0, withinCount = 0, boundarySum = 0.0, boundaryCount = 0
        for i in 1..<n {
            let d = abs(x[i] - x[i - 1])
            if i % fs == 0 { boundarySum += d; boundaryCount += 1 } else { withinSum += d; withinCount += 1 }
        }
        guard withinCount > 0, boundaryCount > 0 else { return x }
        let within = withinSum / Double(withinCount)
        let boundary = boundarySum / Double(boundaryCount)
        // Smooth boundaries → a real pulse, not an artifact → leave it alone (preserves a true 60 bpm).
        guard within > 0, boundary > within * 3 else { return x }
        var colSum = [Double](repeating: 0, count: fs)
        var colCount = [Int](repeating: 0, count: fs)
        for i in 0..<n { let p = i % fs; colSum[p] += x[i]; colCount[p] += 1 }
        var colMean = [Double](repeating: 0, count: fs)
        for p in 0..<fs where colCount[p] > 0 { colMean[p] = colSum[p] / Double(colCount[p]) }
        return x.enumerated().map { (i, v) in v - colMean[i % fs] }
    }

    /// Estimate (bpm, confidence) from one PPG window via autocorrelation, or nil when the window is
    /// too short or no pulsatile peak clears `minConfidence` (flat/garbage PPG → no fabricated HR).
    public static func estimate(_ samples: [Int],
                                fs: Int = sampleRateHz,
                                loBpm: Double = hrLoBpm,
                                hiBpm: Double = hrHiBpm,
                                minConf: Double = minConfidence,
                                subLagInterp: Bool = false) -> (bpm: Double, conf: Double)? {
        guard samples.count >= fs * 3 else { return nil }   // need >= 3 s to resolve a low HR
        // De-artifact (#194) THEN linear-detrend, so the autocorrelation sees the pulse, not the
        // record-rate comb that would peg a low HR at 60 bpm.
        let x = detrend(removeRecordRateComponent(samples.map(Double.init), fs: fs))
        let fsD = Double(fs)
        let loLag = max(2, Int((fsD * 60 / hiBpm).rounded()))
        let hiLag = min(x.count - 2, Int((fsD * 60 / loBpm).rounded()))
        guard hiLag > loLag else { return nil }
        var vals = [Int: Double]()
        var peak = -Double.infinity
        for lag in loLag...hiLag {
            let v = acf(x, lag)
            vals[lag] = v
            if v > peak { peak = v }
        }
        guard peak >= minConf else { return nil }
        // Prefer the FUNDAMENTAL period: the smallest-lag local maximum that is nearly as strong as the
        // global peak. Autocorrelation also peaks at 2×/3× the true period (half/third HR); taking the
        // global max there would report half the real rate, so prefer the shortest prominent period.
        var bestLag: Int? = nil
        if loLag + 1 <= hiLag - 1 {
            for lag in (loLag + 1)...(hiLag - 1) {
                let v = vals[lag]!
                if v >= 0.85 * peak && v >= vals[lag - 1]! && v >= vals[lag + 1]! {
                    bestLag = lag
                    break
                }
            }
        }
        let lag = bestLag ?? (vals.max { $0.value < $1.value }!.key)
        // Sub-lag parabolic interpolation (Variant A, opt-in): refine the integer `lag` by fitting a
        // parabola to the ACF peak and its two neighbours, so a true HR sitting BETWEEN two integer lags is
        // not quantized (integer lags step ~16 bpm near 150 bpm, so the estimate can be off up to ~±8 bpm).
        // Guarded to interior lags; a non-concave fit (denom >= 0) or a clamp-defended one falls back to the
        // integer lag. Default OFF is byte-identical to the integer-lag estimate. Mirror of the Kotlin branch.
        var refinedLag = Double(lag)
        if subLagInterp, lag - 1 >= loLag, lag + 1 <= hiLag {
            let y0 = vals[lag - 1]!, y1 = vals[lag]!, y2 = vals[lag + 1]!
            let denom = y0 - 2 * y1 + y2
            if denom < 0 {
                let delta = min(1.0, max(-1.0, 0.5 * (y0 - y2) / denom))
                refinedLag = min(Double(hiLag), max(Double(loLag), Double(lag) + delta))
            }
        }
        // Round to whole bpm (matching Android's Math.round) — whole bpm keeps the value + type in lockstep
        // with Android (#219). conf stays the integer `lag`'s peak (refinement moves frequency, not confidence).
        let bpm = (fsD * 60 / refinedLag).rounded()
        let conf = (vals[lag]! * 1000).rounded() / 1000
        return (bpm, conf)
    }

    /// Per-second PPG-HR over a list of v26 records `(ts, samples)`.
    ///
    /// Records are grouped into consecutive-second runs (PPG phase is only continuous within a run); a
    /// window centred on each second is autocorrelated. Returns one `PpgHrSample` per second that
    /// yielded a confident estimate, ascending by ts. Records may be unsorted / contain gaps.
    public static func derivePpgHr(records: [(ts: Int, samples: [Int])],
                                   fs: Int = sampleRateHz,
                                   windowSeconds: Int = windowSeconds,
                                   subLagInterp: Bool = false) -> [PpgHrSample] {
        guard !records.isEmpty else { return [] }
        // One waveform per second (last write wins on a duplicate ts).
        var secs = [Int: [Int]]()
        for r in records { secs[r.ts] = r.samples }
        let order = secs.keys.sorted()
        // Split into consecutive-second runs.
        var runs = [[Int]]()
        var cur = [order[0]]
        for u in order.dropFirst() {
            if u - cur.last! == 1 { cur.append(u) }
            else { runs.append(cur); cur = [u] }
        }
        runs.append(cur)

        let half = windowSeconds / 2
        var out = [PpgHrSample]()
        for run in runs where run.count >= 3 {
            let runSet = Set(run)
            for t in run {
                // Window of consecutive seconds present in this run, centred on t.
                var win = [Int]()
                for u in (t - half)...(t + half) where runSet.contains(u) { win.append(u) }
                guard win.count >= 3 else { continue }
                var sig = [Int]()
                for u in win { sig.append(contentsOf: secs[u]!) }
                if let est = estimate(sig, fs: fs, subLagInterp: subLagInterp) {
                    out.append(PpgHrSample(ts: t, bpm: Int(est.bpm), conf: est.conf))
                }
            }
        }
        out.sort { $0.ts < $1.ts }
        return out
    }
}
