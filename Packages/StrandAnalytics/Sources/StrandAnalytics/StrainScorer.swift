import Foundation
import WhoopProtocol

// StrainScorer.swift — cardiovascular load on a 0–100 logarithmic strain ("Effort") scale.
//
// Ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation of
// published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
// proprietary algorithm; not medical advice).
//
// Scale note: the metric was historically 0–21 (WHOOP's Strain axis); the
// "Charge / Effort / Rest" redesign rescales the OUTPUT to 0–100 by raising
// `maxStrain` 21.0 → 100.0 only. The denominator D = 7201 is unchanged, so the log
// curve and its saturation point (TRIMP 7200 ≈ max) are preserved — a max Effort day
// stays as rare as a 21.0 day used to be. Internal metric key stays `strain`.
//
// Pipeline:
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP accumulated over the window:
//        a. Edwards 5-zone summation (default): sample contributes its zone weight
//           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
//        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
//   4. Logarithmic compression onto [0, 100]:
//        strain = 100 × ln(TRIMP + 1) / ln(D)
//      D belongs to the METHOD, not to the scorer: Edwards uses `strainDenominator` (7201, from its
//      sex-independent 7200 ceiling), Banister its own sex-dependent ceiling + 1. See
//      `logMapDenominator(method:sex:)` — reusing one for the other silently rescales the axis (#1545).
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
// (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).

public enum StrainScorer {

    // MARK: - Constants (strain.py)

    /// Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Sparse-stream acceptance (#482/#480): a low-cadence strap — the WHOOP 5/MG sends live
    /// standard HR only ~every 30 s — would need ~5 h of continuous wear to reach `minReadings`,
    /// so Effort sat un-scored (nil → the gauge showed a stale prior-day value) for most of the day.
    /// Also accept once the HR series SPANS at least `minSpanSeconds` of wall-clock with a small
    /// sample floor. This never fabricates load: TRIMP still integrates honestly over whatever HR is
    /// there, so a genuine low-HR day scores 0 either way — it just lets the live gauge reflect TODAY
    /// instead of yesterday. A dense 1 Hz stream is unaffected (it clears `minReadings` first).
    public static let minSparseReadings: Int = 20
    /// Wall-clock coverage (seconds) that qualifies a sparse stream. 600 s = 10 min, matching the
    /// dense gate's ≈10 min of 600 × 1 Hz samples, so both cadences trust the number at the same age.
    public static let minSpanSeconds: Int = 600
    /// Top of the strain ("Effort") scale. Rescaled 21.0 → 100.0 for the
    /// Charge/Effort/Rest redesign; only the output scale changes, the curve does not.
    public static let maxStrain: Double = 100.0

    /// Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
    /// (top zone weight 5 sustained 24 h = 7200) maps to exactly maxStrain:
    /// D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Banister's daily ceiling: 24 h held at ΔHRR = 1.0. Unlike Edwards' 7200 this is SEX-DEPENDENT,
    /// because the exponent `b` differs — which is the whole reason `strainDenominator` cannot be reused
    /// for it. Feeding Banister TRIMP through the Edwards denominator would score every day against a
    /// ceiling ~14% (men) or ~32% (women) higher than Banister can actually reach, so nobody would ever
    /// see 100 and the two methods would not be on the same axis. (#1545)
    static func banisterDailyCeiling(b: Double) -> Double {
        24.0 * 60.0 * 1.0 * banisterScale * exp(b)
    }

    /// The log-map denominator for a method, so a caller never has to know which constant belongs to
    /// which recipe. Ceiling + 1 in both cases, mirroring how `strainDenominator` was derived, so a
    /// theoretical maximum day maps to exactly `maxStrain` under either method.
    public static func logMapDenominator(method: Method, sex: String) -> Double {
        switch method {
        case .edwards:
            return strainDenominator
        case .banister:
            return banisterDailyCeiling(b: sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen) + 1.0
        }
    }

    /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister coefficients.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    /// TRIMP accumulation method.
    public enum Method: Sendable, Hashable { case edwards, banister }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 − age. Last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
    /// the clamped path at both ends).
    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Longest span (minutes) a single reading may be credited with. A wear or connection dropout leaves a
    /// gap with no data in it; without a ceiling the last reading before the gap would be credited with the
    /// whole of it, so one sample in zone 5 could invent hours of effort. 2 min is 4x the sparsest real
    /// cadence we know of (the 5/MG's ~30 s, see `minSparseReadings`), so no genuine cadence is truncated.
    public static let maxSampleGapMin: Double = 2.0

    /// The one Effort figure every read-out on Today must show (#1001).
    ///
    /// Effort has two sources. `stored` is the daily row, rewritten only when the heavy daily pass runs.
    /// `live` is today's in-progress recompute over the raw HR stream (local midnight → now), which
    /// exists precisely because the stored row lags — early in the day it still holds yesterday's Effort
    /// or a stale 0.0 (#402). Past days have no live value and use the row.
    ///
    /// Taking the MAX rather than preferring `live` is not a tie-break: Effort accrues over a day and
    /// must never visibly DROP. The live recompute can UNDER-read when today's HR is sparse, or when a
    /// logged workout's load is not in the raw stream — a 5/MG user who trained in the morning had a real
    /// 38.3 replaced by a live 0 (#489/#506). Flooring at what is already earned is what stops that.
    ///
    /// Shared so the hero ring, the Key Metrics tile and the chart's edge badge cannot drift apart: they
    /// each resolved Effort themselves, and only the ring knew about `live`, so an active morning showed
    /// 2.3 on the ring and 0.5 in the other two until the daily pass caught up (#1001).
    public static func effectiveEffort(live: Double?, stored: Double?) -> Double? {
        guard let live else { return stored }
        guard let stored else { return live }
        return Swift.max(live, stored)
    }

    /// Infer per-sample duration (minutes) from the first two timestamps. Falls
    /// back to 1 s when fewer than two samples or coincident timestamps.
    ///
    /// No production caller remains — TRIMP uses `sampleDurationsMinutes` (#950). Kept ONLY so the
    /// uniform-identity regression test can compare the new accumulation against the SHIPPED old formula
    /// rather than a reimplementation of it. Delete it if that test ever goes.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    /// Per-sample durations (minutes): each reading covers the gap to the NEXT one, clamped to
    /// `maxSampleGapMin`; the last reuses the gap before it.
    ///
    /// #950: TRIMP used to take ONE duration inferred from the first two timestamps and multiply the whole
    /// zone-weight sum by it. NOOP's HR stream is not uniformly spaced — live Bluetooth arrives ~1 s apart,
    /// banked 5/MG history ~30 s, and dropouts leave larger holes — so whichever gap happened to be first
    /// set the scale for the entire window. Worse, a workout window and the day that contains it start at
    /// different samples, so they picked different factors and the two Effort numbers stopped being
    /// comparable, which is what the report was about.
    ///
    /// For a UNIFORMLY spaced series every gap is the same, so this returns the old value for every sample
    /// and the resulting TRIMP is unchanged — which is why no existing test moves. Byte-parity twin of
    /// Kotlin `sampleDurationsMinutes`.
    static func sampleDurationsMinutes(_ hr: [HRSample]) -> [Double] {
        if hr.isEmpty { return [] }
        if hr.count == 1 { return [fallbackSampleMin] }
        var out: [Double] = []
        out.reserveCapacity(hr.count)
        for i in 0..<(hr.count - 1) {
            let deltaS = abs(Double(hr[i + 1].ts - hr[i].ts))
            let minutes = deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
            out.append(min(minutes, maxSampleGapMin))
        }
        out.append(out[out.count - 1])   // the final reading has no successor; reuse the gap before it
        return out
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             durations: [Double]) -> Double {
        var acc = 0.0
        for i in hr.indices {
            acc += Double(zoneWeight(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve))
                * durations[i]
        }
        return acc
    }

    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              durations: [Double], b: Double) -> Double {
        var acc = 0.0
        for i in hr.indices {
            let x = pctHRR(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 { acc += durations[i] * x * banisterScale * exp(b * x) }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
    /// TRIMP ≤ 0 → 0.
    ///
    /// The default D is **Edwards'**. A Banister TRIMP passed here without an explicit denominator is
    /// scored against the wrong ceiling and reads low — prefer `strain(…)`, which resolves the
    /// method's own denominator, or pass `logMapDenominator(method:sex:)` yourself. (#1545)
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
    /// least-squares line: ln(D) = maxStrain × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
    /// (reference_strain pairs must be on the same 0–maxStrain axis as the output.)
    /// Throws when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain / "Effort" (0–100) from an HR series. APPROXIMATE.
    ///
    /// Returns nil when there isn't yet enough data to trust the number — fewer than
    /// `minReadings` samples AND less than `minSpanSeconds` of HR coverage (the sparse-strap
    /// path, #482) — or when maxHR ≤ restingHR (invalid HRR).
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm). Defaults to 220 − defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator (default 60).
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: "male"/"female" — selects the Banister coefficient (ignored by Edwards).
    ///   - denominator: log-map D. `nil` (the default) resolves to the denominator that BELONGS to
    ///     `method` — Edwards' 7201, or Banister's sex-dependent ceiling. Pass a value only to override.
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .edwards,
                              sex: String = "male",
                              denominator: Double? = nil) -> Double? {
        // Resolve BEFORE the memo key is built, or a Banister request would be cached under Edwards'
        // denominator and a later Edwards request could collide with it.
        let resolvedDenominator = denominator ?? logMapDenominator(method: method, sex: sex)
        // v7.0.2 perf (#707): TRIMP integrates over the day's HR stream; called once per day in the post-sync
        // scoring loop AND from the Today view (which re-reads on each live-HR tick). Memoize on the HR
        // fingerprint + every scalar that steers the score, so an identical re-request is a lookup. The
        // result is a single `Double?`; the HR array is not retained.
        let key = StrainKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            maxHR: maxHR, restingHR: restingHR, method: method,
            sexF: sex.lowercased().hasPrefix("f"), denom: resolvedDenominator)
        return strainCache.value(key) {
            strainUncached(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex,
                           denominator: resolvedDenominator)
        }
    }

    /// Key folds `sex` to the single bit the recipe reads (`hasPrefix("f")`) so "female"/"f"/"F" all hit.
    private struct StrainKey: Hashable {
        let hr: StreamFingerprint
        let maxHR: Double?; let restingHR: Double; let method: Method
        let sexF: Bool; let denom: Double
    }
    private static let strainCache = AnalyticsMemoCache<StrainKey, Double?>(capacity: 48)

    private static func strainUncached(_ hr: [HRSample], maxHR: Double?, restingHR: Double,
                                       method: Method, sex: String, denominator: Double) -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Enough data to trust the score: a dense stream (≥ minReadings) OR a sparse-but-sustained
        // one spanning ≥ minSpanSeconds with a sample floor (#482 — the 5/MG's ~30 s HR cadence).
        let enoughData: Bool
        if hr.count >= minReadings {
            enoughData = true
        } else if hr.count >= minSparseReadings {
            let tss = hr.map { $0.ts }
            enoughData = ((tss.max() ?? 0) - (tss.min() ?? 0)) >= minSpanSeconds
        } else {
            enoughData = false
        }
        if !enoughData || effMax <= restingHR { return nil }

        let durations = sampleDurationsMinutes(hr)
        let hrReserve = effMax - restingHR

        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                  durations: durations, b: b)
        case .edwards:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 durations: durations)
        }
        return trimpToStrain(trimp, denominator: denominator)
    }
}
