package com.noop.analytics

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.sqrt

/*
 * EffectRanker.kt — the unified, LAG-AWARE "what moves your Charge" ranker.
 *
 * Faithful Kotlin mirror of StrandAnalytics/EffectRanker.swift. Keep the lag set, the
 * shift-by-lag alignment, the Welch t / Cohen's d effect math, the best-lag selection, the
 * confidence ladder, and the ranking byte-identical to Swift — cross-platform parity is the
 * contract.
 *
 * Pure, deterministic, DB-free. Generalises ActivityCostEngine's single-sport D+1 to EVERY
 * logged journal behaviour against EVERY daily outcome, searching a small fixed lag set
 * {0,+1,+2} so it can tell "same day" from "shows up the next morning."
 *
 * For each (behaviour b, outcome o, lag L):
 *   1. behaviourDays = the day keys b was logged on (dose ≥ 1; callers pass the set).
 *   2. Pair behaviour day D with outcome day D+L by SHIFTING the outcome map back by L —
 *      re-key outcome[D+L] under D via shiftDay(day, -L). (Same arithmetic ActivityCostEngine
 *      uses for D+1, parameterised over the lag.)
 *   3. Compute the effect (means, delta, Cohen's d via pooled SD, Welch p via a normal-CDF
 *      tail) — the byte-identical port of Swift BehaviorInsights.effect — gated at
 *      min(nWith, nWithout) ≥ 5.
 *   4. Keep, per (b, o), the lag with the LARGEST |cohensD| among lags that cleared the gate.
 *
 * HONESTY (effect-size first): the primary signal is the effect SIZE + n + a ScoreConfidence
 * tier, never a bare "significant" stamp; the lag set is capped so the comparison count stays
 * bounded; copy never claims a behaviour "causes" anything.
 *
 * (Spec: 2026-06-19-v5-insights-correlation-engine-design.md — "Lag-aware effect ranking".)
 */

/**
 * The measured effect of one behaviour on one outcome metric at a single lag. Byte-identical
 * port of Swift's BehaviorEffect (the shared correlation substrate has no standalone Kotlin
 * BehaviorInsights, so the struct + math live here).
 */
data class BehaviorEffect(
    val behavior: String,
    val outcome: String,
    /** Mean outcome on days the behaviour WAS logged. */
    val meanWith: Double,
    /** Mean outcome on days the behaviour was NOT logged. */
    val meanWithout: Double,
    /** meanWith − meanWithout (signed). */
    val delta: Double,
    /** Percent change of meanWith relative to meanWithout, or null when meanWithout is 0. */
    val pctChange: Double?,
    /** Number of behaviour-present days with an outcome value. */
    val nWith: Int,
    /** Number of behaviour-absent days with an outcome value. */
    val nWithout: Int,
    /** Cohen's d using the pooled SD (signed; sign matches delta). */
    val cohensD: Double,
    /** Two-sided p-value (Welch t-test, normal approximation). */
    val pApprox: Double,
    /** pApprox < 0.05 AND min(nWith, nWithout) ≥ 5. */
    val significant: Boolean,
)

/**
 * One ranked, lag-aware behaviour→outcome effect: the best lag's BehaviorEffect plus the
 * lead/lag it was found at and a confidence tier from the paired-day count.
 */
data class RankedEffect(
    val behavior: String,
    val outcome: String,
    /** 0 = same day, +1 = the next morning, +2 = two mornings later. */
    val lag: Int,
    val effect: BehaviorEffect,
    val confidence: ScoreConfidence,
) {
    /** Plain-English lead/lag chip text. */
    val leadLagText: String
        get() = when (lag) {
            0 -> "same day"
            1 -> "next morning"
            else -> "$lag mornings later"
        }

    /** The sign-aware sentence plus the lead/lag clause. */
    fun sentence(): String {
        val base = EffectRanker.sentence(effect)
        val trimmed = if (base.endsWith(".")) base.dropLast(1) else base
        return "$trimmed ($leadLagText)."
    }
}

object EffectRanker {

    /** The fixed, bounded lag set searched per (behaviour, outcome). */
    val lagSet: List<Int> = listOf(0, 1, 2)

    /** Minimum group size (each side) for an effect to be flagged significant. Mirrors Swift
     *  BehaviorInsights.minGroupForSignificance. */
    const val minGroupForSignificance: Int = 5

    /** Significance threshold on the approximate p-value. */
    const val alpha: Double = 0.05

    /** Paired-day count below which a chosen lag's confidence is CALIBRATING. */
    const val calibratingBelow: Int = minGroupForSignificance

    /** Paired-day count at/above which a chosen lag's confidence is SOLID (else BUILDING). */
    const val solidPairs: Int = 10

    // Rank.

    /**
     * Rank every behaviour against one outcome across the lag set, keeping each behaviour's
     * best lag. Mirrors Swift's ordering on the surviving rows.
     *
     * @param behaviors per behaviour name, the SET of "yyyy-MM-dd" days it was logged (dose ≥ 1).
     * @param outcomeByDay the daily outcome series keyed "yyyy-MM-dd".
     * @param outcome the outcome label carried onto each RankedEffect.
     */
    fun rank(
        behaviors: Map<String, Set<String>>,
        outcomeByDay: Map<String, Double>,
        outcome: String,
    ): List<RankedEffect> {
        val rows = ArrayList<RankedEffect>()
        for (name in behaviors.keys.sorted()) {
            val days = behaviors.getValue(name)
            val r = bestLag(days, outcomeByDay, name, outcome)
            if (r != null) rows.add(r)
        }
        return sorted(rows)
    }

    /** Find the best-lag RankedEffect for ONE behaviour against ONE outcome, or null. */
    fun bestLag(
        behaviorDays: Set<String>,
        outcomeByDay: Map<String, Double>,
        behavior: String,
        outcome: String,
    ): RankedEffect? {
        var bestLagValue = 0
        var bestEffect: BehaviorEffect? = null
        for (lag in lagSet) {
            val shifted = shiftedOutcome(outcomeByDay, lag)
            val e = effect(behaviorDays, shifted, behavior, outcome) ?: continue
            if (minOf(e.nWith, e.nWithout) < minGroupForSignificance) continue

            val cur = bestEffect
            if (cur == null) {
                bestEffect = e
                bestLagValue = lag
            } else {
                val better = abs(e.cohensD) > abs(cur.cohensD) ||
                    (abs(e.cohensD) == abs(cur.cohensD) && lag < bestLagValue)
                if (better) {
                    bestEffect = e
                    bestLagValue = lag
                }
            }
        }
        val chosen = bestEffect ?: return null
        val pairs = minOf(chosen.nWith, chosen.nWithout)
        return RankedEffect(behavior, outcome, bestLagValue, chosen, confidence(pairs))
    }

    // Lag alignment.

    /**
     * Re-key the outcome series so behaviour day D pairs with outcome[D+lag]: move the value ON
     * day `day` back to key `day − lag` via shiftDay(day, −lag). lag == 0 is the identity map.
     */
    internal fun shiftedOutcome(outcomeByDay: Map<String, Double>, lag: Int): Map<String, Double> {
        if (lag == 0) return outcomeByDay
        val out = HashMap<String, Double>(outcomeByDay.size)
        for ((day, value) in outcomeByDay) {
            val behaviourKey = ActivityCostEngine.shiftDay(day, -lag) ?: continue
            out[behaviourKey] = value
        }
        return out
    }

    // Effect (byte-identical port of Swift BehaviorInsights.effect + helpers).

    /**
     * Compute the effect of [behavior] on [outcome]. Days are partitioned into "with"
     * (day ∈ behaviorDays) and "without", restricted to days with an outcome value. Returns
     * null unless both groups are non-empty AND there are ≥ 3 points total.
     */
    internal fun effect(
        behaviorDays: Set<String>,
        outcomeByDay: Map<String, Double>,
        behavior: String,
        outcome: String,
    ): BehaviorEffect? {
        val withVals = ArrayList<Double>()
        val withoutVals = ArrayList<Double>()
        for ((day, value) in outcomeByDay) {
            if (behaviorDays.contains(day)) withVals.add(value) else withoutVals.add(value)
        }

        val n1 = withVals.size
        val n2 = withoutVals.size
        if (n1 < 1 || n2 < 1 || n1 + n2 < 3) return null

        val m1 = withVals.sum() / n1
        val m2 = withoutVals.sum() / n2
        val delta = m1 - m2

        val pct: Double? = if (m2 != 0.0) delta / abs(m2) * 100.0 else null

        val v1 = sampleVariance(withVals, m1)
        val v2 = sampleVariance(withoutVals, m2)

        val d = cohensD(m1, m2, n1, v1, n2, v2)
        val p = welchP(m1, v1, n1, m2, v2, n2)

        val sig = p < alpha && minOf(n1, n2) >= minGroupForSignificance

        return BehaviorEffect(
            behavior = behavior, outcome = outcome,
            meanWith = m1, meanWithout = m2, delta = delta, pctChange = pct,
            nWith = n1, nWithout = n2, cohensD = d, pApprox = p, significant = sig,
        )
    }

    /** Render an effect as a plain-English sentence (byte-identical to Swift BehaviorInsights). */
    internal fun sentence(e: BehaviorEffect): String {
        val directionWord = when {
            e.delta > 0 -> "higher"
            e.delta < 0 -> "lower"
            else -> "unchanged"
        }
        val magnitude = when {
            e.delta == 0.0 -> "no different"
            e.pctChange != null -> "${roundedInt(abs(e.pctChange))}% $directionWord"
            else -> "${round1(abs(e.delta))} $directionWord"
        }
        val avgWith = roundedInt(e.meanWith)
        val avgWithout = roundedInt(e.meanWithout)
        return "On days you logged ‘${e.behavior}’, ${e.outcome} was $magnitude " +
            "(avg $avgWith vs $avgWithout, n=${e.nWith} vs ${e.nWithout})."
    }

    // Confidence.

    /** Below the gate → CALIBRATING; gate…<solidPairs → BUILDING; ≥ solidPairs → SOLID. */
    internal fun confidence(pairs: Int): ScoreConfidence {
        if (pairs < calibratingBelow) return ScoreConfidence.CALIBRATING
        return if (pairs >= solidPairs) ScoreConfidence.SOLID else ScoreConfidence.BUILDING
    }

    // Ranking.

    /** Stable rank: significant first, |cohensD| desc, then behaviour name ascending. */
    internal fun sorted(rows: List<RankedEffect>): List<RankedEffect> =
        rows.sortedWith(
            compareByDescending<RankedEffect> { it.effect.significant }
                .thenByDescending { abs(it.effect.cohensD) }
                .thenBy { it.behavior },
        )

    // Statistics helpers (byte-identical to Swift).

    /** Sample variance (ddof = 1). 0 for fewer than 2 values. */
    internal fun sampleVariance(values: List<Double>, mean: Double): Double {
        val n = values.size
        if (n < 2) return 0.0
        var ss = 0.0
        for (v in values) {
            val d = v - mean
            ss += d * d
        }
        return ss / (n - 1)
    }

    /** Cohen's d with the pooled SD. 0 when df ≤ 0 or the pooled SD is 0. */
    internal fun cohensD(m1: Double, m2: Double, n1: Int, v1: Double, n2: Int, v2: Double): Double {
        val df = n1 + n2 - 2
        if (df <= 0) return 0.0
        val pooledVar = ((n1 - 1) * v1 + (n2 - 1) * v2) / df
        val sp = sqrt(pooledVar)
        if (sp <= 0) return 0.0
        return (m1 - m2) / sp
    }

    /** Two-sided Welch t-test p-value with a normal-approximation tail. */
    internal fun welchP(m1: Double, v1: Double, n1: Int, m2: Double, v2: Double, n2: Int): Double {
        val se2 = v1 / n1 + v2 / n2
        if (se2 <= 0) return if (m1 == m2) 1.0 else 0.0
        val t = (m1 - m2) / sqrt(se2)
        return 2.0 * (1.0 - normalCDF(abs(t)))
    }

    /** Standard-normal CDF Φ(z) using the A&S 7.1.26 erf approximation. */
    internal fun normalCDF(z: Double): Double = 0.5 * (1.0 + erfApprox(z / sqrt(2.0)))

    /** erf(x) — Abramowitz & Stegun 7.1.26, |error| ≤ 1.5e-7. */
    internal fun erfApprox(x: Double): Double {
        val sign = if (x < 0) -1.0 else 1.0
        val ax = abs(x)
        val t = 1.0 / (1.0 + 0.3275911 * ax)
        val y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t -
            0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
        return sign * y
    }

    // Formatting helpers.

    /** Round to nearest integer, HALF AWAY FROM ZERO — matches Swift's Int(x.rounded())
     *  (Kotlin's Math.round / roundToInt round half toward +∞, which would diverge on a
     *  negative .5; we replicate Swift's .toNearestOrAwayFromZero rule exactly). */
    internal fun roundedInt(x: Double): Int {
        val sign = if (x < 0) -1.0 else 1.0
        return (sign * Math.floor(abs(x) + 0.5)).toInt()
    }

    /** Round to one decimal place, half away from zero (mirrors Swift (x*10).rounded()/10). */
    internal fun round1(x: Double): Double {
        val scaled = x * 10.0
        val sign = if (scaled < 0) -1.0 else 1.0
        return sign * Math.floor(abs(scaled) + 0.5) / 10.0
    }
}
