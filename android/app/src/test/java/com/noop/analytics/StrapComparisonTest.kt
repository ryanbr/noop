package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/** Pins the #1300 two-strap comparison (reuses the existing per-metric tolerances). Swift twin:
 *  `StrapComparisonTests`. */
class StrapComparisonTest {

    private val RHR = MetricArbitrationPolicy.MetricKind.RESTING_HR
    private val HRV = MetricArbitrationPolicy.MetricKind.HRV
    private val STEPS = MetricArbitrationPolicy.MetricKind.STEPS
    private val SPO2 = MetricArbitrationPolicy.MetricKind.SPO2

    @Test
    fun classifiesAgreeMinorConflictSingle() {
        // RHR is an absolute tolerance (±3 agree / ±8 minor bpm).
        assertEquals(AgreementState.AGREE, StrapComparison.agreement(RHR, 55.0, 57.0))       // delta 2
        assertEquals(AgreementState.MINOR_DELTA, StrapComparison.agreement(RHR, 55.0, 60.0)) // delta 5
        assertEquals(AgreementState.CONFLICT, StrapComparison.agreement(RHR, 55.0, 70.0))    // delta 15
        assertEquals(AgreementState.SINGLE, StrapComparison.agreement(RHR, 55.0, null))      // one strap
        assertEquals(AgreementState.SINGLE, StrapComparison.agreement(RHR, null, null))
    }

    @Test
    fun percentToleranceUsesLargerMagnitude() {
        // Steps is a percentage tolerance; an 800-step gap on ~10.8k is within the agree band.
        assertEquals(AgreementState.AGREE, StrapComparison.agreement(STEPS, 10000.0, 10800.0))
    }

    @Test
    fun compareRowPerMetricEitherReportedSkipsOther() {
        val a = mapOf(RHR to 55.0, HRV to 60.0)
        val b = mapOf(RHR to 56.0, SPO2 to 97.0)
        val rows = StrapComparison.compare(a, b)
        assertEquals(3, rows.size) // RHR (both) + HRV (a only) + SpO2 (b only); OTHER never
        assertEquals(AgreementState.AGREE, rows.first { it.metric == RHR }.agreement)
        assertEquals(AgreementState.SINGLE, rows.first { it.metric == HRV }.agreement)
        assertEquals(56.0, rows.first { it.metric == RHR }.b)
        assertEquals(null, rows.first { it.metric == SPO2 }.a)
    }
}
