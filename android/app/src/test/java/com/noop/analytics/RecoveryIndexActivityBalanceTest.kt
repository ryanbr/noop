package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests the two OPTIONAL Oura-Readiness-style Charge terms (#417) as recovery(...) consumes them:
 * the Recovery-Index overnight HR-decline slope and the Activity-Balance previous-day-Effort term,
 * plus the "strain" MetricCfg that backs the latter. Faithful Kotlin mirror of the #417 cases in
 * RecoveryScorerTests.swift / BaselinesTests.swift — same scenarios, same expected values,
 * byte-identical logic. Both terms are DORMANT (null-default); the central claim pinned here
 * is that every existing caller's score is byte-identical to before they existed.
 */
class RecoveryIndexActivityBalanceTest {

    /** A usable baseline with a given mean and Gaussian sigma (spread is internal abs-dev units). */
    private fun baseline(mean: Double, sigma: Double, nValid: Int = 14): BaselineState =
        BaselineState(
            baseline = mean, spread = sigma / 1.253, nValid = nValid, nightsSinceUpdate = 0,
            status = if (nValid >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL,
        )

    // ── Recovery Index / Activity-Balance folded into recovery(...) ──────────────

    @Test
    fun recoveryIndexAndActivityBalanceDefaultNullByteIdenticalToBefore() {
        // Both new terms default to null; the score must be EXACTLY the same whether the caller
        // omits them (every pre-existing call site in the app) or supplies null explicitly —
        // proving the addition is non-breaking for every caller that does not yet supply the
        // two new signals. Covers BOTH overloads (BaselineState convenience + raw DriverBaseline).
        val omitted = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 52.0, resp = 14.0,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = baseline(14.5, 1.0),
            sleepPerf = 0.9,
            skinTempDev = 0.4,
        )!!
        val explicitNull = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 52.0, resp = 14.0,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = baseline(14.5, 1.0),
            sleepPerf = 0.9,
            skinTempDev = 0.4,
            recoveryIndexSlope = null,
            effortBaseline = null,
            priorDayEffort = null,
        )!!
        assertEquals(omitted, explicitNull, 1e-9)

        val hrvB = RecoveryScorer.DriverBaseline(mean = 50.0, spread = 6.0 / 1.253)
        val rhrB = RecoveryScorer.DriverBaseline(mean = 55.0, spread = 3.0 / 1.253)
        val rawOmitted = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 52.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null,
            sleepPerf = 0.9, skinTempDev = 0.4,
        )!!
        val rawExplicitNull = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 52.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null,
            sleepPerf = 0.9, skinTempDev = 0.4, hrvBaselineUsable = true,
            recoveryIndexSlope = null, effortBaseline = null, priorDayEffort = null,
        )!!
        assertEquals(rawOmitted, rawExplicitNull, 1e-9)
    }

    @Test
    fun recoveryIndexSteeperDeclineRaisesChargeMoreThanFlatOrRising() {
        // Pin HRV/RHR/sleep at neutral so the ONLY thing moving is the slope term.
        fun score(slope: Double?): Double = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = null,
            sleepPerf = RecoveryScorer.sleepPerfCenter,
            recoveryIndexSlope = slope,
        )!!
        val flat = score(0.0)
        val mildDecline = score(-1.0)
        val steepDecline = score(-4.0)
        val rising = score(2.0)

        // Multiple distinct slopes recovered in the expected order (derived-signal rule): a
        // steeper decline raises the Charge contribution more than a flat or rising night.
        assertTrue(steepDecline > mildDecline)
        assertTrue(mildDecline > flat)
        assertTrue(flat > rising)
    }

    @Test
    fun activityBalanceHighEffortYesterdayLowersChargeVsRestDay() {
        // Baseline drivers pinned ABOVE-center (positive composite z), same rigor as the
        // skin-temp precedent test, so the effort term's renormalization dilution has a
        // direction to push against.
        fun score(effort: Double?): Double = RecoveryScorer.recovery(
            hrv = 58.0, rhr = 50.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = null,
            sleepPerf = 0.92,
            effortBaseline = baseline(40.0, 15.0),
            priorDayEffort = effort,
        )!!
        val neutral = score(null)
        val atBaseline = score(40.0)   // exactly typical -> present term, z=0, dilutes toward center
        val restDay = score(10.0)      // well below normal -> supports recovery further
        val hardDay = score(65.0)      // above normal -> pulls recovery down
        val veryHardDay = score(90.0)  // far above normal -> pulls down more

        assertTrue(
            "a present at-baseline effort term still dilutes an above-center composite toward the logistic center",
            atBaseline < neutral,
        )
        assertTrue("a lighter-than-normal day supports recovery vs a typical day", restDay > atBaseline)
        assertTrue("a harder-than-normal day pulls recovery down vs a typical day", atBaseline > hardDay)
        // Multiple distinct levels recovered in strictly the expected monotonic order
        // (derived-signal rule): more effort yesterday -> lower Charge contribution.
        assertTrue(restDay > hardDay)
        assertTrue(hardDay > veryHardDay)
    }

    @Test
    fun activityBalanceDropsTermUnlessBothValueAndBaselineArePresent() {
        fun score(effort: Double?, effortBaseline: BaselineState?): Double = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = null,
            sleepPerf = RecoveryScorer.sleepPerfCenter,
            effortBaseline = effortBaseline,
            priorDayEffort = effort,
        )!!
        val neither = score(effort = null, effortBaseline = null)
        val valueOnly = score(effort = 80.0, effortBaseline = null)
        val baselineOnly = score(effort = null, effortBaseline = baseline(40.0, 15.0))
        val both = score(effort = 80.0, effortBaseline = baseline(40.0, 15.0))

        assertEquals("a value with no baseline must drop the term", neither, valueOnly, 1e-9)
        assertEquals("a baseline with no value must drop the term", neither, baselineOnly, 1e-9)
        assertNotEquals("supplying BOTH must actually change the score", neither, both, 1e-9)
    }

    // ── "strain" MetricCfg (Activity-Balance / previous-day-Effort baseline) ─────

    @Test
    fun strainCfgRegisteredWithEffortScaleBounds() {
        // Bounds match StrainScorer.maxStrain's 0-100 output scale, keyed "strain" to match the
        // existing internal metric-key convention (StrainScorer: "Internal metric key stays strain").
        assertEquals(Baselines.metricCfg.getValue("strain"), Baselines.strainCfg)
        assertEquals(0.0, Baselines.strainCfg.minVal, 1e-9)
        assertEquals(100.0, Baselines.strainCfg.maxVal, 1e-9)
    }

    @Test
    fun strainCfgIsBaselineRelativeOverDailyEffort() {
        // A week of moderate days then a rest day: the baseline tracks the moderate norm, and
        // the rest day reads as a clear BELOW-baseline ("lighter than usual") deviation.
        val moderateWeek = listOf<Double?>(38.0, 42.0, 40.0, 36.0, 44.0, 39.0, 41.0)
        val s = Baselines.foldHistory(moderateWeek, Baselines.strainCfg)
        assertTrue(s.usable)
        assertEquals(40.0, s.baseline, 5.0)

        val restDay = Baselines.deviation(10.0, s)
        assertTrue("a much-lighter-than-normal day must read BELOW the effort baseline", restDay.z < 0)

        val hardDay = Baselines.deviation(85.0, s)
        assertTrue("a much-harder-than-normal day must read ABOVE the effort baseline", hardDay.z > 0)
    }
}
