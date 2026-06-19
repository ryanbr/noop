package com.noop.analytics

/*
 * DoseResponsePriors.kt — documented, conservative POPULATION priors that the per-user
 * dose-response fit shrinks toward until the user has logged enough nights.
 *
 * Faithful Kotlin mirror of StrandAnalytics/DoseResponsePriors.swift. Keep the enum raw
 * strings, the slope magnitudes, the clamp ranges, and the default-outcome mapping
 * byte-identical to Swift — cross-platform parity tests enforce it.
 *
 * These are deliberately CONSERVATIVE, clearly-labelled "typical patterns, not yours"
 * constants — never learned from any user, never updated from the field. The shrinkage in
 * DoseResponseEngine blends the user's own OLS slope with one of these priors weighted by
 * how much data they have; with no data the user sees the prior, with enough data it fades
 * out entirely.
 *
 * Each prior is an EFFECT PER INCREMENTAL UNIT of dose on a named outcome:
 *   - Alcohol  → Charge (recovery, 0–100): roughly −Δ points per extra drink.
 *   - Caffeine → HRV (ms): roughly −Δ ms per step LATER in the day a caffeine dose lands
 *     (the caffeine "dose" axis is a TIMING bucket, not mg — copy says so).
 *
 * (Spec: 2026-06-19-v5-insights-correlation-engine-design.md.)
 */

/**
 * Identifies a dosed behaviour whose dose-response has a documented population prior.
 * The raw string is the stable storage / lookup key (mirrors Swift's enum raw value).
 */
enum class DosedBehavior(val raw: String) {
    /** Alcoholic drinks, dose = number of drinks (0/1/2/3+ ⇒ 0,1,2,3). */
    ALCOHOL("alcohol"),

    /** Caffeine, dose = a TIME-OF-DAY bucket (morning/midday/after-2pm/evening ⇒ 0..3);
     *  "dose" here is timing intensity (later = stronger), NOT milligrams. */
    CAFFEINE("caffeine"),
}

/**
 * A single documented population prior: the typical per-unit effect of a dosed behaviour on
 * one outcome, with a sane clamp range so a runaway extrapolation can never escape it.
 */
data class DoseResponsePrior(
    /** The dosed behaviour this prior describes. */
    val behavior: DosedBehavior,
    /** The outcome label this prior is expressed in (e.g. "Charge", "HRV"). */
    val outcome: String,
    /** Typical signed effect per ONE extra unit of dose. Negative = lower with more dose. */
    val slopePerUnit: Double,
    /** Lower clamp for the (shrunk) per-unit effect — keeps a noisy personal slope sane. */
    val clampLow: Double,
    /** Upper clamp for the (shrunk) per-unit effect. */
    val clampHigh: Double,
)

object DoseResponsePriors {

    /**
     * The default outcome each dosed behaviour's headline prior is expressed in.
     * Alcohol's headline effect is on Charge; caffeine's is on HRV (timing proxy).
     */
    fun defaultOutcome(behavior: DosedBehavior): String = when (behavior) {
        DosedBehavior.ALCOHOL -> "Charge"
        DosedBehavior.CAFFEINE -> "HRV"
    }

    /**
     * The documented, conservative priors. Mirror Swift exactly.
     * - Alcohol → Charge: ≈ −5 Charge points per extra drink (clamped −15…+2).
     * - Caffeine → HRV:   ≈ −4 ms per step later in the day (clamped −20…+4).
     */
    internal val table: List<DoseResponsePrior> = listOf(
        DoseResponsePrior(DosedBehavior.ALCOHOL, "Charge", -5.0, -15.0, 2.0),
        DoseResponsePrior(DosedBehavior.CAFFEINE, "HRV", -4.0, -20.0, 4.0),
    )

    /** Look up the documented prior for a (behaviour, outcome) pair, or null if none. */
    fun prior(behavior: DosedBehavior, outcome: String): DoseResponsePrior? =
        table.firstOrNull { it.behavior == behavior && it.outcome == outcome }

    /** Convenience: the prior for a behaviour's default headline outcome. */
    fun prior(behavior: DosedBehavior): DoseResponsePrior? =
        prior(behavior, defaultOutcome(behavior))
}
