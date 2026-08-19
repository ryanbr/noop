package com.noop.analytics

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1008: `ord` is the per-TIMESTAMP occurrence counter assigned at write time, so it restarts at 0 for
 * every delivery. That is what separates the two remaining explanations for a second carrying many beats.
 * Twin of Swift `HRVAnalyzerSampleOrdTests`.
 */
class HrvAnalyzerSampleOrdTest {

    @Test
    fun aSecondDeliveredOnceReadsAsOneContiguousRun() {
        // Four beats on one second, written by a single delivery: ord counts 0,1,2,3.
        val ts = listOf(100L, 100L, 100L, 100L)
        val rr = listOf(700.0, 750.0, 800.0, 850.0)
        val out = HrvAnalyzer.densestSecondWindowSample(
            ts, rr, srcCodes = listOf(null, null, null, null), ords = listOf(0, 1, 2, 3),
        )
        assertTrue(out, out.contains("700#0"))
        assertTrue(out, out.contains("850#3"))
    }

    @Test
    fun aSecondBuiltAcrossTwoDeliveriesRepeatsTheCounter() {
        // The tell: ord restarts, so the same second shows 0,1 twice. No other stored field says this.
        val ts = listOf(100L, 100L, 100L, 100L)
        val rr = listOf(700.0, 750.0, 800.0, 850.0)
        val out = HrvAnalyzer.densestSecondWindowSample(
            ts, rr, srcCodes = listOf(null, null, null, null), ords = listOf(0, 1, 0, 1),
        )
        assertTrue(out, out.contains("700#0"))
        assertTrue(out, out.contains("800#0"))   // the repeat
        assertTrue(out, out.contains("850#1"))
    }

    @Test
    fun absentOrdsLeaveTheLineUnchanged() {
        // Rows written before reads surfaced ord must not gain a stray marker.
        val ts = listOf(100L, 100L)
        val rr = listOf(700.0, 800.0)
        val out = HrvAnalyzer.densestSecondWindowSample(ts, rr, srcCodes = listOf(null, null))
        assertTrue(out, !out.contains("#"))
    }
}
