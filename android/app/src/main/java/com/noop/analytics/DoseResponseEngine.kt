package com.noop.analytics

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/*
 * DoseResponseEngine.kt — a personal dose→outcome slope that SHRINKS toward a documented
 * population prior until the user has logged enough nights.
 *
 * Faithful Kotlin mirror of StrandAnalytics/DoseResponseEngine.swift. Keep the tunables
 * (shrinkageK, the dose gates), the L=1 pairing, the OLS slope, the shrinkage blend, the
 * clamp, the contradiction rule, the confidence ladder, and the curve byte-identical to
 * Swift — cross-platform parity is the contract.
 *
 *   1. Pair (dose_d, outcome_{d+1}) for each logged day with a next-day outcome (L=1 align via
 *      ActivityCostEngine.shiftDay).
 *   2. β_user = OLS slope of outcome on dose (the same slope Swift's CorrelationEngine.pearson
 *      returns; null if < 3 pairs or no spread). n_user = paired days.
 *   3. β = w·β_user + (1−w)·β_prior, w = n_user/(n_user + k); clamp to the prior's range.
 *   4. Report per-unit Δ (= β), the curve, and a ScoreConfidence from n_user.
 *
 * HONESTY: below the dose gate → priorDominated ("typical patterns, not yet yours"); once over
 * the gate a personal slope whose SIGN disagrees with the prior flags contradictsPrior (the
 * person overrides the population). Caffeine "dose" is a TIMING proxy, not mg. No causal claims.
 *
 * (Spec: 2026-06-19-v5-insights-correlation-engine-design.md.)
 */

/**
 * One point on the personal dose-response curve: a dose level and the modelled outcome DELTA
 * from the 0-dose anchor at that dose (so the UI can offset onto any baseline).
 */
data class DoseCurvePoint(val dose: Int, val outcomeDelta: Double)

/** A personal, prior-shrunk dose-response estimate for one dosed behaviour on one outcome. */
data class DoseResponse(
    val behavior: DosedBehavior,
    val outcome: String,
    /** The SHRUNK, clamped effect per ONE extra unit of dose (signed). */
    val perUnit: Double,
    /** The user's own OLS slope (signed), or null when there weren't enough/spread-y pairs. */
    val userSlope: Double?,
    /** The documented population prior's per-unit slope this estimate shrank toward. */
    val priorSlope: Double,
    /** The shrinkage weight w = n_user / (n_user + k) in [0, 1]. */
    val weight: Double,
    /** Number of (dose, next-day-outcome) pairs that backed the personal fit. */
    val nUser: Int,
    /** True while mostly prior (n_user below the dose gate). */
    val priorDominated: Boolean,
    /** True when over the gate AND the user's slope sign disagrees with the prior. */
    val contradictsPrior: Boolean,
    /** Per-result certainty tier from n_user. */
    val confidence: ScoreConfidence,
    /** Curve points (dose, outcomeDelta-from-0-anchor) for dose 0…maxCurveDose. */
    val curve: List<DoseCurvePoint>,
) {
    /** The signed Δ for going from [fromDose] to [toDose] units (each unit contributes perUnit). */
    fun delta(fromDose: Int, toDose: Int): Double = (toDose - fromDose) * perUnit

    /** Plain-English read. Honest about prior-vs-yours. Mirrors Swift exactly. */
    fun sentence(): String {
        val mag = DoseResponseEngine.round1(abs(perUnit))
        val dir = if (perUnit <= 0) "lower" else "higher"
        return when {
            priorDominated ->
                "Each extra unit typically lines up with about $mag $outcome $dir " +
                    "— typical patterns, not yet yours (n=$nUser)."
            contradictsPrior ->
                "In your data so far, this doesn't move your $outcome the way it typically " +
                    "does (n=$nUser)."
            else ->
                "Each extra unit tends to line up with about $mag $outcome $dir for you " +
                    "(n=$nUser)."
        }
    }
}

object DoseResponseEngine {

    // Tunables (documented, deterministic — NOT learned). Mirror Swift exactly.

    /** Pseudo-count of "prior days": the shrinkage constant k in w = n/(n+k). */
    const val shrinkageK: Double = 8.0

    /** Paired (dose, next-day) days below which the estimate is priorDominated. */
    const val minDoseDays: Int = 5

    /** n_user at/above which confidence can reach SOLID. */
    const val solidDoseDays: Int = 12

    /** The highest dose level the curve enumerates (0…maxCurveDose). */
    const val maxCurveDose: Int = 3

    /** Estimate the prior-shrunk dose-response for a behaviour against its DEFAULT outcome. */
    fun estimate(
        behavior: DosedBehavior,
        doseByDay: Map<String, Int>,
        outcomeByDay: Map<String, Double>,
    ): DoseResponse? = estimate(
        behavior, DoseResponsePriors.defaultOutcome(behavior), doseByDay, outcomeByDay,
    )

    /**
     * Estimate the prior-shrunk dose-response for a behaviour against a NAMED outcome.
     * Returns null when (behaviour, outcome) has no documented prior to shrink toward.
     */
    fun estimate(
        behavior: DosedBehavior,
        outcome: String,
        doseByDay: Map<String, Int>,
        outcomeByDay: Map<String, Double>,
    ): DoseResponse? {
        val prior = DoseResponsePriors.prior(behavior, outcome) ?: return null

        // Pair each logged dose day D with the NEXT-day outcome (D+1) — the L=1 alignment.
        val pairs = ArrayList<Pair<Double, Double>>()
        for (day in doseByDay.keys.sorted()) {
            val dose = doseByDay.getValue(day)
            val d1 = ActivityCostEngine.shiftDay(day, 1) ?: continue
            val outVal = outcomeByDay[d1] ?: continue
            pairs.add(Pair(dose.toDouble(), outVal))
        }
        val nUser = pairs.size

        // Personal OLS slope of outcome on dose (null if < 3 pairs or no spread in either axis).
        val userSlope = olsSlope(pairs)

        // Shrinkage weight: 0 with no data, → 1 as data accumulates past k.
        val w = nUser.toDouble() / (nUser.toDouble() + shrinkageK)

        val blended = if (userSlope != null) {
            w * userSlope + (1.0 - w) * prior.slopePerUnit
        } else {
            prior.slopePerUnit
        }
        val perUnit = clamp(blended, prior.clampLow, prior.clampHigh)

        val priorDominated = nUser < minDoseDays
        val contradicts = if (userSlope != null && nUser >= minDoseDays) {
            !sameSign(userSlope, prior.slopePerUnit)
        } else {
            false
        }

        val confidence = confidenceFor(nUser)

        val curve = ArrayList<DoseCurvePoint>()
        for (dose in 0..maxCurveDose) {
            curve.add(DoseCurvePoint(dose, dose * perUnit + 0.0)) // + 0.0 normalises -0.0 → 0.0 (signed-zero parity)
        }

        return DoseResponse(
            behavior = behavior, outcome = outcome, perUnit = perUnit,
            userSlope = userSlope, priorSlope = prior.slopePerUnit, weight = w, nUser = nUser,
            priorDominated = priorDominated, contradictsPrior = contradicts,
            confidence = confidence, curve = curve,
        )
    }

    // Confidence.

    /** Calibrating while mostly prior; building while blended; solid once personal dominates. */
    internal fun confidenceFor(nUser: Int): ScoreConfidence {
        if (nUser < minDoseDays) return ScoreConfidence.CALIBRATING
        return if (nUser >= solidDoseDays) ScoreConfidence.SOLID else ScoreConfidence.BUILDING
    }

    // OLS slope (byte-identical to the slope Swift's CorrelationEngine.pearson returns).

    /**
     * OLS slope of y on x for the (x, y) pairs: Σ(x−x̄)(y−ȳ) / Σ(x−x̄)². Returns null when
     * < 3 pairs OR either axis has zero variance — exactly the cases Swift's pearson rejects.
     */
    internal fun olsSlope(xy: List<Pair<Double, Double>>): Double? {
        val n = xy.size
        if (n < 3) return null
        val nD = n.toDouble()

        var sumX = 0.0
        var sumY = 0.0
        for (p in xy) {
            sumX += p.first
            sumY += p.second
        }
        val meanX = sumX / nD
        val meanY = sumY / nD

        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for (p in xy) {
            val dx = p.first - meanX
            val dy = p.second - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        // Zero variance in either variable → slope undefined (matches Swift's pearson nil).
        if (sxx <= 0.0 || syy <= 0.0) return null

        return sxy / sxx
    }

    // Helpers (self-contained so the Swift mirror is line-for-line).

    /** True when a and b share a sign; a flat slope (0) contradicts a non-zero prior. */
    internal fun sameSign(a: Double, b: Double): Boolean = when {
        a > 0 && b > 0 -> true
        a < 0 && b < 0 -> true
        a == 0.0 && b == 0.0 -> true
        else -> false
    }

    internal fun clamp(x: Double, lo: Double, hi: Double): Double = min(max(x, lo), hi)

    /** Round to one decimal place, half away from zero (mirrors Swift (x*10).rounded()/10). */
    internal fun round1(x: Double): Double {
        val scaled = x * 10.0
        val sign = if (scaled < 0) -1.0 else 1.0
        return sign * Math.floor(abs(scaled) + 0.5) / 10.0
    }
}
