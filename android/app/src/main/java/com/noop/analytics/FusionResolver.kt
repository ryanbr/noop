package com.noop.analytics

import kotlin.math.abs

/*
 * FusionResolver (v5 — Local Multi-Device Fusion).
 *
 * Value-for-value Kotlin twin of Packages/StrandAnalytics/.../FusionResolver.swift. Pure,
 * deterministic, on-device fusion per
 * docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §1–§2. Given the per-source
 * values for ONE (metric, day), it:
 *   1. ranks sources by trust tier (MetricArbitrationPolicy), stable tiebreak, and picks the winner's
 *      value VERBATIM (best signal wins — never an average);
 *   2. cross-validates the other sources against the winner and classifies agreement as
 *      single / agree / minorDelta / conflict (the honest part — conflicts are shown, not merged).
 * No I/O — the repository feeds it rows it already loads.
 */
object FusionResolver {

    /**
     * Resolve one metric for one day from each source's value. [metricKey] is the resolver series key
     * (e.g. "rhr", "steps", "sleep_total_min"); it picks the trust tiers and tolerance via
     * [MetricArbitrationPolicy]. Returns null only when [inputs] is empty (no source has the metric).
     *
     * The winner is the lowest-tier source, ties broken by sourcePriority (stable, deterministic). Its
     * value passes through unchanged. The agreement state classifies how far the OTHER sources sit from
     * the winning value, per the metric's tolerance band.
     */
    fun resolve(metricKey: String, inputs: List<FusionInput>): FusedMetricPoint? {
        if (inputs.isEmpty()) return null
        val kind = MetricArbitrationPolicy.kind(metricKey)

        // Build a contributor for every source, tagged with its trust tier + reason. Keep the input
        // index so the sort's final tiebreak is stable across platforms.
        val indexed = inputs.mapIndexed { index, input ->
            index to ContributingSource(
                source = input.source,
                value = input.value,
                tier = MetricArbitrationPolicy.tier(kind, input.source),
                sourcePriority = MetricArbitrationPolicy.sourcePriority(input.source),
                reason = MetricArbitrationPolicy.reason(kind, input.source),
            )
        }

        // Winner = lowest tier, then lowest source-priority, then earliest input index (fully stable).
        val ranked = indexed.sortedWith(
            compareBy({ it.second.tier }, { it.second.sourcePriority }, { it.first }),
        ).map { it.second }

        val winner = ranked[0]
        val agreement = classify(kind, winner.value, ranked)

        return FusedMetricPoint(
            metric = metricKey,
            value = winner.value,
            winningSource = winner.source,
            contributors = ranked,
            agreement = agreement,
        )
    }

    /**
     * Classify how the non-winning sources agree with [winningValue], using the metric's tolerance.
     * Worst case across all other sources wins (one conflicting source makes the point a conflict). One
     * source ⇒ SINGLE (nothing to cross-check).
     */
    fun classify(
        metric: MetricArbitrationPolicy.MetricKind,
        winningValue: Double,
        contributors: List<ContributingSource>,
    ): AgreementState {
        // Only one source reported the metric → nothing to compare against.
        if (contributors.size < 2) return AgreementState.SINGLE

        val tol = MetricArbitrationPolicy.tolerance(metric)
        var worst = AgreementState.AGREE

        for (c in contributors.drop(1)) { // skip the winner (index 0)
            val delta = abs(c.value - winningValue)
            val agreeEdge: Double
            val minorEdge: Double
            if (tol.isPercent) {
                // Percentage band is relative to the winning value's magnitude. With a zero winner, any
                // non-zero second value can't be a fraction of it → fall back to absolute deltas.
                val base = abs(winningValue)
                agreeEdge = tol.agree * base
                minorEdge = tol.minorDelta * base
            } else {
                agreeEdge = tol.agree
                minorEdge = tol.minorDelta
            }

            val state = when {
                delta <= agreeEdge -> AgreementState.AGREE
                delta <= minorEdge -> AgreementState.MINOR_DELTA
                else -> AgreementState.CONFLICT
            }
            worst = worse(worst, state)
        }
        return worst
    }

    /** Order of severity for the worst-case fold: agree < minorDelta < conflict. */
    private fun severity(s: AgreementState): Int = when (s) {
        AgreementState.SINGLE -> 0
        AgreementState.AGREE -> 1
        AgreementState.MINOR_DELTA -> 2
        AgreementState.CONFLICT -> 3
    }

    /** The more-severe of two agreement states. */
    private fun worse(a: AgreementState, b: AgreementState): AgreementState =
        if (severity(a) >= severity(b)) a else b
}
