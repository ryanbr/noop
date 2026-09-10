package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of the macOS WatchRecoveryTests: the honesty-critical recovery-from-daily-aggregate engine
 * behind source-only Charge (Apple Watch / Health Connect / Oura-Fitbit-Garmin import, #823). A daily
 * source gives a sparse HRV + resting HR rather than the strap's dense R-R stream, so these fixtures pin the
 * BEHAVIOUR (at-baseline ~ mid, high-HRV / low-RHR -> high, thin history / missing today -> null +
 * calibrating) regardless of the exact logistic constants, which are inherited unchanged from RecoveryScorer
 * so source-only recovery and strap recovery sit on the same scale.
 */
class WatchRecoveryTest {

    @Test
    fun atBaselineGivesMidRecoverySolid() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! in 40.0..60.0)
        assertEquals(ScoreConfidence.SOLID, out.confidence)
    }

    @Test
    fun highHrvLowRhrGivesHighRecovery() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 70.0, todayRhr = 46, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! > 65.0)
    }

    @Test
    fun lowHrvHighRhrGivesLowRecovery() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 22.0, todayRhr = 62, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! < 40.0)
    }

    @Test
    fun insufficientHistoryCalibrates() {
        val out = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = listOf(45.0, 46.0), rhrHistory = listOf(52.0, 51.0))
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    @Test
    fun missingTodayHrvCalibrates() {
        val hist = List(14) { 45.0 }
        val out = WatchRecovery.compute(todayHrv = null, todayRhr = 52, hrvHistory = hist, rhrHistory = hist)
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    // --- Week gate counts ACCEPTED nights, not raw entries (fork issue #62) ---

    /**
     * Seven RAW history entries of which only four are physiologically valid must NOT clear the week gate:
     * [WatchRecovery.minBaselineNights] means nights the baseline ACCEPTED (nValid), so the rejected
     * -1 / 0 / 999 readings cannot buy a score a week early. Swift twin:
     * `testSevenRawNightsWithFourValidCalibrates`.
     */
    @Test
    fun sevenRawNightsWithFourValidCalibrates() {
        val out = WatchRecovery.compute(
            todayHrv = 45.0, todayRhr = null,
            hrvHistory = listOf(45.0, 46.0, 47.0, 48.0, -1.0, 0.0, 999.0), rhrHistory = emptyList(),
        )
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    /** Seven raw entries of which only three are valid: below the baseline's own seed gate too. */
    @Test
    fun sevenRawNightsWithThreeValidCalibrates() {
        val out = WatchRecovery.compute(
            todayHrv = 45.0, todayRhr = null,
            hrvHistory = listOf(45.0, 46.0, 47.0, -1.0, 0.0, 999.0, 1000.0), rhrHistory = emptyList(),
        )
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    /** Six raw entries, all six valid -> still one accepted night short of the gate. */
    @Test
    fun sixRawNightsWithSixValidCalibrates() {
        val out = WatchRecovery.compute(
            todayHrv = 45.0, todayRhr = null,
            hrvHistory = listOf(45.0, 46.0, 47.0, 48.0, 45.0, 46.0), rhrHistory = emptyList(),
        )
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    /** Nine raw entries of which exactly seven are valid -> the gate is met by accepted nights. */
    @Test
    fun nineRawNightsWithSevenValidScores() {
        val out = WatchRecovery.compute(
            todayHrv = 45.0, todayRhr = null,
            hrvHistory = listOf(45.0, 46.0, 47.0, 48.0, 45.0, 46.0, 47.0, -1.0, 999.0),
            rhrHistory = emptyList(),
        )
        assertNotNull(out.recovery)
        assertTrue(out.confidence != ScoreConfidence.CALIBRATING)
    }

    // --- RHR term needs a USABLE RHR baseline (fork issue #61) ---

    /**
     * An empty RHR history yields foldHistory's synthetic midpoint baseline (75 bpm), which must never
     * score today's reading: with no usable RHR baseline the result is the documented HRV-only path,
     * exactly as if today's RHR were missing. Swift twin: `testEmptyRHRHistoryScoresLikeMissingRHR`.
     *
     * The pinned literal is the Swift value, produced by a standalone oracle executable linked against
     * the production `StrandAnalytics` package (so it cannot drift from the Swift source):
     *
     *   import StrandAnalytics
     *   let hist = Array(repeating: 45.0, count: 7)
     *   print(WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
     *                               sdnnHistory: hist, rhrHistory: []).recovery!)
     *   // -> 57.932425214874954
     */
    @Test
    fun emptyRhrHistoryScoresLikeMissingRhr() {
        val hist = List(7) { 45.0 }
        val withRhr = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = hist, rhrHistory = emptyList())
        val hrvOnly = WatchRecovery.compute(todayHrv = 45.0, todayRhr = null, hrvHistory = hist, rhrHistory = emptyList())
        assertNotNull(withRhr.recovery)
        assertNotNull(hrvOnly.recovery)
        assertEquals(hrvOnly.recovery!!, withRhr.recovery!!, 1e-12)
        assertEquals(57.932425214874954, withRhr.recovery!!, 1e-12)
    }

    /**
     * An RHR history that is entirely out of physiological range accepts no night at all, so its baseline
     * is the same synthetic midpoint — likewise dropped.
     */
    @Test
    fun unusableRhrHistoryScoresLikeMissingRhr() {
        val hist = List(7) { 45.0 }
        val junk = List(7) { 300.0 }   // above restingHRCfg.maxVal (120)
        val withRhr = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = hist, rhrHistory = junk)
        val hrvOnly = WatchRecovery.compute(todayHrv = 45.0, todayRhr = null, hrvHistory = hist, rhrHistory = junk)
        assertNotNull(withRhr.recovery)
        assertEquals(hrvOnly.recovery!!, withRhr.recovery!!, 1e-12)
    }

    /**
     * Once the RHR baseline IS usable (>= Baselines.minNightsSeed accepted nights) the term returns: a
     * resting HR above baseline must pull the score below the HRV-only number.
     */
    @Test
    fun usableRhrHistoryStillContributes() {
        val hist = List(7) { 45.0 }
        val rhrHist = List(4) { 52.0 }   // exactly the seed gate -> provisional
        val withRhr = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 62, hrvHistory = hist, rhrHistory = rhrHist)
        val hrvOnly = WatchRecovery.compute(todayHrv = 45.0, todayRhr = null, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(withRhr.recovery)
        assertNotNull(hrvOnly.recovery)
        assertTrue(withRhr.recovery!! < hrvOnly.recovery!! - 1.0)
    }
}
