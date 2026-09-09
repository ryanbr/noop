package com.noop.analytics

/**
 * Per-day reuse identity for the steps-calibration motion fold in [IntelligenceEngine.analyzeRecent].
 * Kotlin twin of the Swift `StepsMotionCache`.
 *
 * The drain this closes: the calibration fits one coefficient from sixty days of strap motion, and it
 * re-folded all sixty on EVERY pass. Each day meant a `gravitySamplesForDevice` read capped at
 * `STREAM_LIMIT` rows, so a worn library paid millions of materialised rows per pass to re-derive numbers
 * that had not moved. The phase does not scale with the days being re-scored — it always reads the same
 * sixty — so a two-day pass could cost more than a twenty-one-day one, which is what made it hard to see in
 * a cost line keyed on the day loop.
 *
 * [StepsEstimateEngine.dayMotionIntensity] is a pure fold over one day's gravity stream. Nothing else
 * reaches it: no profile field, no baseline, no toggle, no other stream. So unlike [AnalyzeRecentDayCache]
 * there is no pass-config signature to invalidate against — the value changes exactly when that one day's
 * gravity changes, and the key below is the whole story.
 *
 * Like the day-scan cache this is in-memory and per-process. It never persists, never crosses the
 * `.noopbak` boundary, and a relaunch pays the full fold once. That is deliberate: the cost being closed is
 * the repeat within a process, where an offload storm fires passes back to back.
 */
object StepsMotionCache {
    /**
     * The per-day reuse key. Reuse a cached motion volume iff this string is unchanged.
     *
     * - [owner]: the resolved owning device the fold was measured against. A day whose owner flips between
     *   straps must re-fold, and the fingerprint below is device-scoped, so this makes that explicit rather
     *   than relying on two devices never producing an identical count and newest timestamp for one window.
     * - [gravityCount] / [gravityMaxTs]: the day window's gravity witness. Any gravity row added or removed
     *   moves one of the two. Deliberately NOT the wider `dayStreamFingerprint`: that also counts HR, R-R,
     *   respiration, SpO2, steps, skin temp and sleep state, so an ordinary HR offload would invalidate a
     *   motion volume that cannot have changed by it.
     */
    fun cacheKey(owner: String, gravityCount: Int, gravityMaxTs: Long): String =
        "$owner|$gravityCount|$gravityMaxTs"

    /**
     * The pass's one-line reuse readout, beside the phase cost line.
     *
     * [reused] and [folded] sum to the days scanned, so the ratio is readable without a second line. A pass
     * reporting `folded=60` every time means the key is moving when it should not, which is the failure this
     * cache can have and the reason the number is reported at all rather than assumed.
     */
    fun logLine(reused: Int, folded: Int, size: Int): String =
        "analyzeRecent stepsMotion reused=$reused/${reused + folded} size=$size"
}
