package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1118: RMSSD is withheld on a night whose own R-R banks more beat-time than the wall clock it spans.
 *
 * Each over-count case asserts TWICE: that the gated call returns null, AND that the very same beats do
 * produce an RMSSD through [SleepStager.sessionHrvWindows]. Without that second assertion the test would
 * pass just as well against a window that had no usable beats at all, proving nothing about the gate.
 */
class HrvOverCountGateTest {

    private fun rr(ts: Long, ms: Int) = RrInterval(deviceId = "d", ts = ts, rrMs = ms)

    private fun windowsYieldRmssd(start: Long, end: Long, rr: List<RrInterval>): Boolean =
        SleepStager.sessionHrvWindows(start, end, rr, emptyList()).mapNotNull { it.rmssd }.isNotEmpty()

    /**
     * Two near-equal beats per second: the shape a same-second collapse WOULD bring back under the
     * ceiling. It must still be withheld, and this is the case that guards the gate's cheap
     * classification — [SleepStager.sessionAvgHRV] passes coverage as its own collapsed figure to avoid
     * a sort, so a night of this shape reports CROSS_SECOND internally. The outcome is what matters and
     * is asserted here; restoring the real collapsed figure would relabel this night and change nothing.
     */
    @Test fun sameSecondOverCountIsWithheld() {
        val start = 1000L
        val end = start + 600
        val rr = (0 until 600).flatMap { i -> listOf(rr(start + i, 900), rr(start + i, 905)) }
        assertTrue("precondition: these beats DO yield an RMSSD", windowsYieldRmssd(start, end, rr))
        assertNull("an over-counted night must report no HRV", SleepStager.sessionAvgHRV(start, end, rr))
    }

    /** Two beats per second far enough apart that a same-second collapse cannot reach them. */
    @Test fun crossSecondOverCountIsWithheld() {
        val start = 1000L
        val end = start + 600
        val rr = (0 until 600).flatMap { i -> listOf(rr(start + i, 880), rr(start + i, 960)) }
        assertTrue("precondition: these beats DO yield an RMSSD", windowsYieldRmssd(start, end, rr))
        assertNull("an over-counted night must report no HRV", SleepStager.sessionAvgHRV(start, end, rr))
    }

    /** The gate must not touch an ordinary night: one beat per second, coverage ~1.0. */
    @Test fun aPlausibleNightStillReportsItsHrv() {
        val start = 1000L
        val end = start + 600
        val rr = (0 until 600).map { i -> rr(start + i, if (i % 2 == 0) 980 else 1020) }
        val hrv = SleepStager.sessionAvgHRV(start, end, rr)
        assertNotNull("a plausible night must keep its HRV", hrv)
        assertTrue("and it must be a real reading, not zero", hrv!! > 0.0)
    }

    /** A sparse night is UNDER_COVERED, which is honest data and stays trusted. */
    @Test fun anUnderCoveredNightIsNotGated() {
        val start = 1000L
        val end = start + 600
        // A beat every other second: ~0.5 coverage, nothing duplicated.
        val rr = (0 until 300).map { i -> rr(start + i * 2, if (i % 2 == 0) 980 else 1020) }
        assertNotNull("sparse is not the same as over-counted",
            SleepStager.sessionAvgHRV(start, end, rr))
    }

    /** The verdict mapping itself, so the seam above and the rule stay pinned separately. */
    @Test fun onlyTheTwoOverCountVerdictsRefuse() {
        assertFalse(HrvAnalyzer.successiveDiffIsTrustworthy(
            HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT))
        assertFalse(HrvAnalyzer.successiveDiffIsTrustworthy(
            HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT))
        assertTrue(HrvAnalyzer.successiveDiffIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE))
        assertTrue(HrvAnalyzer.successiveDiffIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED))
        assertTrue(HrvAnalyzer.successiveDiffIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE))
    }

    /** It refuses exactly what the SDNN gate refuses: same rule, stated twice on purpose, never drifting. */
    @Test fun itRefusesTheSameVerdictsAsTheSdnnGate() {
        for (v in HrvAnalyzer.RrCoverageVerdict.entries) {
            assertEquals("verdict $v must be judged alike by both gates",
                HrvAnalyzer.beatSpreadIsTrustworthy(v), HrvAnalyzer.successiveDiffIsTrustworthy(v))
        }
    }
}
