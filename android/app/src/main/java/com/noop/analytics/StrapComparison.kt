package com.noop.analytics

import kotlin.math.abs
import kotlin.math.max

/**
 * #1300 tier 2: a READ-ONLY, non-diagnostic comparison of the SAME metric from two straps (e.g. a WHOOP
 * 4.0 and a 5/MG) for one user. Reuses the existing per-metric tolerances ([MetricArbitrationPolicy.tolerance])
 * to say whether the two straps AGREE, differ a little, or conflict — for a "compare my straps" card in the
 * Devices window. NEVER mixes the two into one score (scores stay single-owner-per-day, invariant I2); it
 * only describes how they line up, both values kept visible. Pure + deterministic. Twin of Swift
 * `StrapComparison`.
 */
object StrapComparison {

    /** One metric's two-strap comparison. [a]/[b] are the two straps' values (null = no value); [agreement]
     *  is [AgreementState.SINGLE] when only one strap reported it. */
    data class Row(
        val metric: MetricArbitrationPolicy.MetricKind,
        val a: Double?,
        val b: Double?,
        val agreement: AgreementState,
    )

    /** Compare two straps' per-metric values (each strap's stored daily mapped to MetricKind->value at the
     *  call site). One row per metric EITHER strap reported, in enum declaration order; OTHER is skipped
     *  (the non-comparable passthrough family). Read-only, non-diagnostic. */
    fun compare(
        a: Map<MetricArbitrationPolicy.MetricKind, Double>,
        b: Map<MetricArbitrationPolicy.MetricKind, Double>,
    ): List<Row> =
        MetricArbitrationPolicy.MetricKind.entries.mapNotNull { metric ->
            if (metric == MetricArbitrationPolicy.MetricKind.OTHER) return@mapNotNull null
            val va = a[metric]
            val vb = b[metric]
            if (va == null && vb == null) return@mapNotNull null
            Row(metric, va, vb, agreement(metric, va, vb))
        }

    /** Agreement between two strap values for one metric, using that metric's published tolerance. SINGLE
     *  when only one strap has it. SYMMETRIC: a percentage tolerance is taken against the LARGER magnitude,
     *  so neither strap is privileged as a "winner". */
    fun agreement(metric: MetricArbitrationPolicy.MetricKind, a: Double?, b: Double?): AgreementState {
        if (a == null || b == null) return AgreementState.SINGLE
        val tol = MetricArbitrationPolicy.tolerance(metric)
        val delta = abs(a - b)
        val base = max(abs(a), abs(b))
        val agreeEdge = if (tol.isPercent) tol.agree * base else tol.agree
        val minorEdge = if (tol.isPercent) tol.minorDelta * base else tol.minorDelta
        return when {
            delta <= agreeEdge -> AgreementState.AGREE
            delta <= minorEdge -> AgreementState.MINOR_DELTA
            else -> AgreementState.CONFLICT
        }
    }
}
