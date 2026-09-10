package com.noop.analytics

/**
 * Recovery/Charge from DAILY aggregates (Apple Watch / Health Connect / an Oura/Fitbit/Garmin export).
 * Kotlin twin of the Swift `WatchRecovery`.
 *
 * A WHOOP strap gives dense overnight R-R intervals, so RecoveryScorer runs off raw-derived nightly RMSSD.
 * A daily-aggregate source does NOT: it gives a daily HRV (SDNN-ish) reading plus a resting HR. So this is
 * a genuinely lower-density computation.
 *
 * We do NOT invent a new formula. Recovery is HRV-and-RHR-vs-personal-baseline, and because every term is
 * relative to the person's OWN baseline, the metric scale cancels out: SDNN-vs-SDNN-baseline behaves like
 * RMSSD-vs-RMSSD-baseline. So we build HRV and RHR baselines through the existing [Baselines] machinery and
 * feed them straight into the SAME [RecoveryScorer.recovery] the strap uses. Source-only recovery and strap
 * recovery therefore land on the same 0-100 scale and read against the same bands.
 *
 * What we drop vs the strap path: the respiration, sleep-performance and skin-temp terms are not supplied
 * here, so RecoveryScorer renormalises the remaining HRV + RHR weights. The HRV term stays dominant.
 *
 * Honesty rule: return null recovery + CALIBRATING when today's HRV is missing, OR the HRV baseline isn't
 * usable yet, OR the baseline has accepted fewer than [minBaselineNights] nights. We NEVER fabricate a number to
 * fill a sparse week. Confidence comes from the existing [ScoreConfidence.forCharge].
 */
object WatchRecovery {

    /** Result: the score (null while calibrating) and its confidence tier. */
    data class Result(val recovery: Double?, val confidence: ScoreConfidence)

    /**
     * Minimum VALID nights (nights the baseline accepted, `BaselineState.nValid`) before we score recovery
     * from a daily-aggregate source — not raw history entries. Sits ABOVE the
     * baseline's own seed gate (4) deliberately: a strap user crosses the seed faster on dense data, but a
     * sparse daily HRV deserves a longer warm-up before we trust it. Mirrors the Swift constant.
     */
    const val minBaselineNights = 7

    /**
     * Compute recovery/Charge from a daily HRV + resting HR vs the person's own baseline.
     *
     * @param todayHrv today's HRV reading (ms), or null if the source logged none.
     * @param todayRhr today's resting HR (bpm), or null to drop the RHR term. The term is also dropped when
     *   [rhrHistory] has not yet produced a usable RHR baseline.
     * @param hrvHistory ordered nightly HRV values (oldest -> newest), the baseline input.
     * @param rhrHistory ordered nightly resting-HR values (oldest -> newest).
     */
    fun compute(
        todayHrv: Double?,
        todayRhr: Int?,
        hrvHistory: List<Double>,
        rhrHistory: List<Double>,
    ): Result {
        // Build both baselines through the production model (Winsorized EWMA + cold-start gating), exactly
        // as the strap path does. HRV feeds the HRV config; resting HR feeds the RHR config.
        val hrvBase = Baselines.foldHistory(hrvHistory, Baselines.hrvCfg)
        val rhrBase = Baselines.foldHistory(rhrHistory, Baselines.restingHRCfg)

        // Confidence is the SAME helper the strap Charge uses, so the calibrating -> building -> solid arc
        // matches. It reads CALIBRATING whenever recovery would be null (no usable HRV baseline).
        val conf = ScoreConfidence.forCharge(todayHrv, hrvBase)

        // Honesty gate: no number unless we have today's HRV, a usable baseline, AND at least a week of
        // nights. Any miss -> null recovery + calibrating, never a fabricated value.
        // The week is counted in nights the baseline ACCEPTED (nValid), not in raw history entries: a
        // physiologically implausible reading is skip-and-held by [Baselines.update] and contributes
        // nothing to the baseline, so counting it would let rejected values buy a score a week early.
        if (todayHrv == null || !hrvBase.usable || hrvBase.nValid < minBaselineNights) {
            return Result(recovery = null, confidence = ScoreConfidence.CALIBRATING)
        }

        // Reuse the canonical Charge engine. Drop the resp / sleep / skin-temp terms (the daily aggregate
        // doesn't carry them here) -> RecoveryScorer renormalises to HRV + RHR. RHR is optional: the term
        // needs BOTH today's reading AND a usable personal RHR baseline. An empty or all-implausible RHR
        // history folds to foldHistory's synthetic midpoint (the config's min/max mean, e.g. 75 bpm), which
        // is nobody's resting HR — scoring against it would move Charge on a fabricated baseline. Mirrors
        // the `usable ? state : nil` gate the macOS Charge driver breakdown applies (Swift TodayView /
        // CoupledView); without a usable RHR baseline we fall back to the HRV-only path, exactly as when
        // today's reading is missing.
        val recovery = RecoveryScorer.recovery(
            hrv = todayHrv,
            rhr = todayRhr?.toDouble() ?: rhrBase.baseline,
            resp = null,
            hrvBaseline = hrvBase,
            rhrBaseline = if (todayRhr != null && rhrBase.usable) rhrBase else null,
            respBaseline = null,
            sleepPerf = null,
        ) ?: return Result(recovery = null, confidence = ScoreConfidence.CALIBRATING)

        return Result(recovery = recovery, confidence = conf)
    }
}
