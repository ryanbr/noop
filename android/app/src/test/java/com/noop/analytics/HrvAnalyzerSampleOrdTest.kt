package com.noop.analytics

import org.junit.Assert.assertEquals
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

    // #1331/#1008 delivery histogram — twins of the Swift HRVAnalyzerSampleOrdTests cases.

    /**
     * The shape today's 5/MG log shows: one second written by TWO deliveries (two rows at ord 0 with
     * different values), beside seconds written once. Invisible to an exact-duplicate check.
     */
    @Test fun twoDeliveriesOnOneSecondAreCounted() {
        val ts = listOf(100L, 100L, 101L, 102L, 102L, 102L)
        val rr = listOf(872.0, 893.0, 800.0, 500.0, 537.0, 1309.0)
        val ords = listOf<Int?>(0, 0, 0, 0, 1, 2)
        assertEquals(
            "rr deliveries secs[1/2/3/4+]=2/1/0/0 multiSec=33% multiRows=33% multiMs=36% maxDeliv=2 secsNoStart=0 ordUnknown=0",
            HrvAnalyzer.deliveryHistogram(ts, rr, ords),
        )
    }

    /** A clean night: every second written by exactly one delivery. */
    @Test fun singleDeliveryPerSecondReadsClean() {
        val ts = (200L until 210L).toList()
        assertEquals(
            "rr deliveries secs[1/2/3/4+]=10/0/0/0 multiSec=0% multiRows=0% multiMs=0% maxDeliv=1 secsNoStart=0 ordUnknown=0",
            HrvAnalyzer.deliveryHistogram(ts, ts.map { 1000.0 }, ts.map { 0 }),
        )
    }

    /**
     * Rows predating the `ord` column must NOT read as "written once" — that would argue against the
     * mechanism the histogram exists to detect.
     */
    @Test fun nilOrdsAreExcludedNotAssumedFirst() {
        assertEquals(
            "rr deliveries secs[1/2/3/4+]=1/0/0/0 multiSec=0% multiRows=0% multiMs=0% maxDeliv=1 secsNoStart=1 ordUnknown=2",
            HrvAnalyzer.deliveryHistogram(
                listOf(300L, 300L, 301L), listOf(900.0, 910.0, 920.0), listOf(null, null, 0),
            ),
        )
    }

    /**
     * Beat-time rounds half-UP on both platforms. `kotlin.math.round` (half-toward-+infinity) and Swift's
     * `.rounded()` (half-away-from-zero) agree only for positive values; this pins the explicit behaviour
     * so the agreement cannot quietly become a coincidence again (#1473).
     */
    @Test fun msRoundsHalfUpWithoutStdlibRounding() {
        assertEquals(1, HrvAnalyzer.msToInt(0.5))
        assertEquals(2, HrvAnalyzer.msToInt(1.5))
        assertEquals(3, HrvAnalyzer.msToInt(2.5))   // half-to-even would give 2
        assertEquals(2, HrvAnalyzer.msToInt(2.4))
        assertEquals(0, HrvAnalyzer.msToInt(0.0))
    }

    /** Percentages round half-up by integer maths, so a tie cannot render differently per platform. */
    @Test fun percentIsIntegerHalfUp() {
        assertEquals(13, HrvAnalyzer.pct(1, 8))
        assertEquals(38, HrvAnalyzer.pct(3, 8))
        assertEquals(0, HrvAnalyzer.pct(0, 0))
    }

    /**
     * `deliveryHistogram` feeds `pct` a whole night's BEAT-TIME IN MILLISECONDS, not a row count, and
     * `part * 200` needs more than 32 bits past 10,737,418 ms. The numbers below are one real MG night
     * (34,002 beats, meanNN 1044 ms, multiSec 23%): before the widening `part * 200` wrapped and this
     * returned -16, a percentage of a positive subset of a positive total that cannot be negative.
     *
     * The existing cases above cannot reach it - the largest `rrMs` anywhere in this file is 1309.0 - so
     * the overflow sat behind a green suite on Android while the 64-bit Swift twin read correctly.
     */
    @Test fun pctSurvivesAWholeNightOfBeatTime() {
        assertEquals(43, HrvAnalyzer.pct(15_264_177, 35_498_088))
        // The widest multi-delivery share in the same capture: 91% of a 39.9 M ms night (42,981 beats,
        // meanNN 928 ms). Also wrapped to -16, which is what the log reported for that night.
        assertEquals(91, HrvAnalyzer.pct(36_296_594, 39_886_368))
    }

    /**
     * The 32-bit wrap did not always produce a NEGATIVE percentage, so "is it negative" was never a
     * sound test for an affected capture - which matters for anyone re-reading pre-fix Android logs.
     *
     * These pin the exact boundary and the readable-wrong case. The bound is `part * 200 + total`
     * exceeding `Int.MAX_VALUE`, not `part * 200` alone: 10,683,998 was still computed correctly in 32
     * bits, 10,683,999 wrapped to -100, and a 100% multi-share 8 h night wrapped to 25 - positive,
     * plausible, and wrong by 75 points. Twin of Swift `testPctWrapWasNotAlwaysNegative`.
     */
    @Test fun pctWrapWasNotAlwaysNegative() {
        assertEquals(100, HrvAnalyzer.pct(10_683_998, 10_683_998)) // last total 32 bits still got right
        assertEquals(100, HrvAnalyzer.pct(10_683_999, 10_683_999)) // first that wrapped, to -100
        assertEquals(100, HrvAnalyzer.pct(28_800_000, 28_800_000)) // wrapped to 25, not to anything negative
    }
}
