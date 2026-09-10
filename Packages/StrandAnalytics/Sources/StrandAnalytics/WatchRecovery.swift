import Foundation

// WatchRecovery.swift — recovery/Charge from Apple Watch DAILY aggregates.
//
// The honesty-critical piece of "Apple Watch as a device". A WHOOP strap gives us
// dense overnight RR intervals, so RecoveryScorer runs off raw-derived nightly RMSSD.
// The Apple Watch does NOT. It gives a handful of HRV SDNN readings a day plus a
// resting HR, both as daily aggregates. So watch recovery is a genuinely lower-density
// computation.
//
// We do NOT invent a new formula. Recovery is HRV-and-RHR-vs-personal-baseline, and
// because every term is relative to the person's OWN baseline, the metric scale cancels
// out: SDNN-vs-SDNN-baseline behaves like RMSSD-vs-RMSSD-baseline. So we build SDNN and
// RHR baselines through the existing `Baselines` machinery and feed them straight into
// the SAME `RecoveryScorer.recovery(...)` the strap uses. Watch recovery and strap
// recovery therefore land on the same 0-100 scale and read against the same bands.
//
// What we drop vs the strap path: the respiration, sleep-performance and skin-temp terms
// are not supplied here (the watch's daily aggregate doesn't carry them in the same shape),
// so RecoveryScorer renormalises the remaining HRV + RHR weights. The HRV term stays the
// dominant driver either way.
//
// The hard honesty rule: we return nil recovery + `.calibrating` when today's SDNN is
// missing, OR the SDNN baseline isn't usable yet, OR the baseline has accepted fewer than
// `minBaselineNights` nights. We NEVER fabricate a number to fill a sparse week. Confidence comes
// straight from the existing `ScoreConfidence.charge(recovery:hrvBaseline:)`, so the watch
// "calibrating → building → solid" arc is the same one the strap uses.
public enum WatchRecovery {

    /// Result of a watch-recovery computation: the score (nil while calibrating) and its
    /// confidence tier. Same shape the strap path carries onto a DailyMetric.
    public struct Result: Equatable, Sendable {
        /// Recovery in [0, 100], or nil when we can't honestly score yet (calibrating).
        public let recovery: Double?
        /// Per-score confidence, driven by the real SDNN-baseline density (not a hardcoded label).
        public let confidence: ScoreConfidence

        public init(recovery: Double?, confidence: ScoreConfidence) {
            self.recovery = recovery
            self.confidence = confidence
        }
    }

    /// Minimum VALID nights (nights the baseline accepted, `BaselineState.nValid`) before we'll score
    /// recovery from the watch — not raw history entries. The spec's
    /// honesty stance is to keep recovery "calibrating" for about a week of nights rather than
    /// ship a misleading number off a thin baseline. This sits ABOVE the baseline's own seed
    /// gate (`Baselines.minNightsSeed` = 4) deliberately: a strap user crosses the seed faster
    /// on dense data, but the watch's sparse SDNN deserves a longer warm-up before we trust it.
    public static let minBaselineNights = 7

    /// Compute recovery/Charge from the watch's daily SDNN + resting HR vs the person's own baseline.
    ///
    /// - Parameters:
    ///   - todaySDNN: today's HRV SDNN reading (ms), or nil if the watch logged none.
    ///   - todayRHR:  today's resting HR (bpm), or nil to drop the RHR term. The term is also
    ///     dropped when `rhrHistory` has not yet produced a usable RHR baseline.
    ///   - sdnnHistory: ordered nightly SDNN values (oldest → newest), the baseline input.
    ///   - rhrHistory:  ordered nightly resting-HR values (oldest → newest).
    /// - Returns: a `Result` with recovery in [0,100] and a confidence tier, or nil recovery +
    ///   `.calibrating` when today's SDNN is missing, the baseline isn't usable, or history is thin.
    public static func compute(todaySDNN: Double?, todayRHR: Int?,
                               sdnnHistory: [Double], rhrHistory: [Double]) -> Result {
        // Build both baselines through the production model (Winsorized EWMA + cold-start gating),
        // exactly as the strap path does. SDNN feeds the HRV config; resting HR feeds the RHR config.
        let hrvBase = Baselines.foldHistory(sdnnHistory.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHistory.map { Optional($0) }, cfg: Baselines.restingHRCfg)

        // Confidence is the SAME helper the strap Charge uses, so the calibrating → building → solid
        // arc matches. It reads .calibrating whenever recovery would be nil (no usable HRV baseline),
        // and below it we ALSO nil-out recovery, so the two stay consistent.
        let conf = ScoreConfidence.charge(recovery: todaySDNN, hrvBaseline: hrvBase)

        // Honesty gate: no number unless we have today's SDNN, a usable baseline, AND at least a
        // week of nights. Any miss → nil recovery + calibrating, never a fabricated value.
        // The week is counted in nights the baseline ACCEPTED (`nValid`), not in raw history entries:
        // a physiologically implausible reading is skip-and-held by `Baselines.update` and contributes
        // nothing to the baseline, so counting it would let rejected values buy a score a week early.
        guard let sdnn = todaySDNN,
              hrvBase.usable,
              hrvBase.nValid >= minBaselineNights else {
            return Result(recovery: nil, confidence: .calibrating)
        }

        // Reuse the canonical Charge engine. Drop the resp / sleep / skin-temp terms (the watch
        // daily aggregate doesn't carry them here) — RecoveryScorer renormalises to HRV + RHR.
        // RHR is optional: the term needs BOTH today's reading AND a usable personal RHR baseline.
        // An empty or all-implausible RHR history folds to `foldHistory`'s synthetic midpoint (the
        // config's min/max mean, e.g. 75 bpm), which is nobody's resting HR — scoring against it would
        // move Charge on a fabricated baseline. Same `usable ? state : nil` gate the strap Charge
        // surfaces already apply (TodayView / CoupledView); without a usable RHR baseline we fall back
        // to the documented HRV-only path, exactly as when today's reading is missing.
        let recovery = RecoveryScorer.recovery(
            hrv: sdnn,
            rhr: todayRHR.map(Double.init) ?? rhrBase.baseline,   // missing RHR → at-baseline (z≈0, neutral term)
            resp: nil,
            hrvBaseline: hrvBase,
            rhrBaseline: (todayRHR != nil && rhrBase.usable) ? rhrBase : nil,
            respBaseline: nil,
            sleepPerf: nil
        )

        // RecoveryScorer only returns nil on a cold-start HRV baseline, which we already gated above;
        // but stay honest if it ever does — never coerce a nil into a number.
        guard let recovery else {
            return Result(recovery: nil, confidence: .calibrating)
        }
        return Result(recovery: recovery, confidence: conf)
    }
}
