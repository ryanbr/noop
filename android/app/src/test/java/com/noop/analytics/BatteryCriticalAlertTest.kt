package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.roundToInt

/**
 * The escalation alerts: the CRITICAL SoC crossing and the BEDTIME night-guard, plus the ~10% cutoff
 * model they both rest on. Behaviour-identical twin of the Swift BatteryCriticalAlertTests — same
 * fixture, same numbers.
 *
 * The fixture below is a REAL measured discharge from a WHOOP 5.0 running R22 deep-data + high-rate
 * IMU capture — the run that lost the user a night of biometrics. Times are PDT; the strap's last HR
 * sample of the session landed at 13:27, i.e. ~27 min after the final 10.9% reading and with no
 * reading below 10.9% ever banked. That 27 min is the ground truth the cutoff model is scored against.
 */
class BatteryCriticalAlertTest {

    // ---- The real discharge fixture ----

    /** Arbitrary epoch anchor; only deltas matter to the fit. */
    private val base = 1_700_000_000L

    /** Seconds after [base] for 13:27, when the strap actually went dark (27 min past the 10.9% read). */
    private val deathOffset = 6420L

    /** The ten real readings, `(seconds after 11:40, SoC%)`. */
    private val realTail: List<Pair<Long, Double>> = listOf(
        0L to 13.1,     // 11:40
        120L to 12.9,   // 11:42
        660L to 12.6,   // 11:51
        1020L to 12.4,  // 11:57
        1620L to 12.1,  // 12:07
        2160L to 11.9,  // 12:16
        2760L to 11.6,  // 12:26
        3060L to 11.4,  // 12:31
        4080L to 11.1,  // 12:48
        4800L to 10.9,  // 13:00
    ).map { (base + it.first) to it.second }

    /**
     * The tail as the estimator really saw it: LiveState seeds the SoC buffer from the persisted
     * battery table on connect (#7) and caps it at 400 readings (~53 h at the strap's ~8 min cadence),
     * so the fit window in production spans the whole discharge from the last near-full charge — NOT
     * just the 80 minutes of tail above. Reconstructed here at the measured 1.65 %/h from 95% down to
     * the 13.1% the tail opens on, ~8 min apart, which is what makes `source == MEASURED` reachable.
     */
    private fun realFullDischarge(): List<Pair<Long, Double>> {
        val rate = 1.65
        val leadSeconds = ((95.0 - 13.1) / rate * 3600).toLong()  // ~49.6 h
        val out = mutableListOf<Pair<Long, Double>>()
        var elapsed = 0L
        while (elapsed < leadSeconds) {
            out.add((base - leadSeconds + elapsed) to (95.0 - rate * elapsed / 3600.0))
            elapsed += 480
        }
        return out + realTail
    }

    // ---- A3 / A4: what the estimator actually says about this run ----

    @Test
    fun realDischargeFitsMeasuredSlopeAtRoughly1Point65PctPerHour() {
        val est = BatteryEstimator.estimate(realFullDischarge(), BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(
            "the seeded full-discharge buffer must beat the rated fallback",
            BatteryEstimator.Source.MEASURED, est.source,
        )
        assertEquals(10.9, est.currentSoc, 0.001)
        // Recovered slope = currentSoc / remainingHours.
        assertEquals(1.65, est.currentSoc / est.remainingHours, 0.02)
    }

    /**
     * A4, the headline number: `estimate` divides the FULL SoC by the rate, so it reports time-to-0%.
     * At 10.9% and 1.65 %/h that is ~6.6 h of runway — but the strap died 27 min later. ~6 h of the
     * estimate is charge the hardware never actually spends.
     */
    @Test
    fun rawEstimateOverstatesRunwayByTheWholeCutoffBand() {
        val est = BatteryEstimator.estimate(realFullDischarge(), BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals("time-to-0%, not time-to-death", 6.6, est.remainingHours, 0.15)
        val usable = BatteryEstimator.usableRemainingHours(est)
        assertEquals("cutoff / rate = 10 / 1.65", 6.06, est.remainingHours - usable, 0.15)
    }

    /** The cutoff model scored against ground truth: the strap went dark 27 min after the 10.9% read. */
    @Test
    fun cutoffAwareRunwayMatchesTheObservedTimeOfDeath() {
        val est = BatteryEstimator.estimate(realFullDischarge(), BatteryEstimator.ratedLifeHoursWhoop5)!!
        val usableMinutes = BatteryEstimator.usableRemainingHours(est) * 60
        val observedMinutes = (deathOffset - 4800L) / 60.0   // 13:27 − 13:00 = 27 min
        assertEquals(27.0, observedMinutes, 0.001)
        assertEquals(
            "cutoff-aware runway should land within ~10 min of the real time of death",
            observedMinutes, usableMinutes, 10.0,
        )
    }

    @Test
    fun usableRunwayIsZeroAtOrBelowTheCutoff() {
        assertEquals(0.0, BatteryEstimator.usableRemainingHours(6.0, 10.0), 0.0)
        assertEquals(0.0, BatteryEstimator.usableRemainingHours(5.0, 8.0), 0.0)
        assertEquals(0.0, BatteryEstimator.usableRemainingHours(0.0, 50.0), 0.0)
        assertEquals(0.0, BatteryEstimator.usableRemainingHours(10.0, 0.0), 0.0)
    }

    @Test
    fun usableRunwayIsUnaffectedWellAboveTheCutoff() {
        // 90% with 100 h to 0% → 100 × 80/90 = 88.9 h to the cutoff. Real but not dramatic up high.
        assertEquals(88.89, BatteryEstimator.usableRemainingHours(100.0, 90.0), 0.01)
    }

    /**
     * A3's latent second bug, isolated: on a WHOOP 5.0's 288 h rated fallback the predictive alert's
     * 24 h line sits at 8.3% SoC — BELOW the ~10% cutoff, so it is unreachable. A strap on the rated
     * path can therefore never warn before it dies. (The reference device's persisted
     * `batteryRuntimeAlerted = true` proves it was on the MEASURED path in practice.)
     */
    @Test
    fun ratedFallbackOnWhoop5PutsThePredictiveAlertBelowTheHardwareCutoff() {
        val ratedRate = 100.0 / BatteryEstimator.ratedLifeHoursWhoop5
        val socAtAlertLine = BatteryEstimator.runtimeAlertHours * ratedRate
        assertEquals(8.33, socAtAlertLine, 0.01)
        assertTrue(
            "rated-path predictive alert is unreachable before the strap dies",
            socAtAlertLine < BatteryEstimator.cutoffSocPct,
        )
    }

    /**
     * The same trap reached the honest way: a buffer holding ONLY the 80-minute tail spans 1.33 h,
     * short of `minSpanHours` (2.0), so the fit is rejected and the estimate falls back to rated —
     * reporting ~31 h of life on a strap with ~30 min left, and firing nothing.
     */
    @Test
    fun shortBufferFallsBackToRatedAndThePredictiveAlertStaysSilent() {
        val est = BatteryEstimator.estimate(realTail, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.RATED, est.source)
        assertEquals(31.4, est.remainingHours, 0.2)
        assertFalse(
            "31 h estimate is above the 24 h line — no predictive alert, ~30 min before death",
            BatteryEstimator.runtimeAlert(est.remainingHours, charging = false, alerted = false).fire,
        )
    }

    // ---- B1: the critical SoC alert ----

    /**
     * The alert the incident needed: replay the real curve (SoC reaches the policy rounded, as the
     * call site passes `batteryPct.roundToInt()`) and exactly one critical alert must fire — at 12.4% /
     * 11:57, which is 90 minutes of warning before the 13:27 death.
     */
    @Test
    fun realCurveFiresExactlyOneCriticalAlertWithNinetyMinutesOfWarning() {
        var alerted = false
        val firedAt = mutableListOf<Long>()
        for ((ts, soc) in realTail) {
            val out = BatteryEstimator.criticalAlert(soc.roundToInt(), charging = false, alerted = alerted)
            if (out.fire) firedAt.add(ts)
            alerted = out.newAlerted
        }
        assertEquals("exactly once per discharge cycle", 1, firedAt.size)
        assertEquals(90.0, (base + deathOffset - firedAt[0]) / 60.0, 0.001)
    }

    /**
     * The threshold is chosen against the cutoff, and the cutoff is what makes the conventional
     * choices wrong: on this hardware a 5% critical alert can never fire, and even 10% is a coin flip
     * (nothing below 10.9% was ever banked on the real run).
     */
    @Test
    fun conventionalCriticalThresholdsAreUnreachableOnThisHardware() {
        assertEquals(10.9, realTail.minOf { it.second }, 0.001)
        for (deadThreshold in listOf(5, 8, 10)) {
            assertFalse(
                "$deadThreshold% is never reported before the strap dies",
                realTail.any { it.second.roundToInt() <= deadThreshold },
            )
        }
        // 12 is reported, and clears the 15% alert by a genuine 3 pp rather than jitter.
        assertTrue(realTail.any { it.second.roundToInt() <= BatteryEstimator.criticalSocPct })
        assertEquals(12, BatteryEstimator.criticalSocPct)
    }

    /**
     * Latch independence — the actual bug. The critical gate is its OWN parameter (and, at the call
     * site, its own persisted key), so a 15% alert that has already fired and latched cannot silence
     * it. On the incident `batteryLowAlerted` was true for the whole final descent.
     */
    @Test
    fun criticalGateIsIndependentOfAnAlreadyLatchedLowAlert() {
        // Whatever the low alert's gate is doing, a fresh critical gate at 12% fires.
        assertTrue(BatteryEstimator.criticalAlert(12, charging = false, alerted = false).fire)
        assertTrue(BatteryEstimator.criticalAlert(11, charging = null, alerted = false).fire)
    }

    @Test
    fun firesAtThresholdAndArms() {
        val r = BatteryEstimator.criticalAlert(12, charging = false, alerted = false)
        assertTrue(r.fire)
        assertTrue(r.newAlerted)
    }

    @Test
    fun aboveThresholdNoFire() {
        val r = BatteryEstimator.criticalAlert(13, charging = false, alerted = false)
        assertFalse(r.fire)
        assertFalse(r.newAlerted)
    }

    @Test
    fun jitterInsideBandCannotRefire() {
        var alerted = BatteryEstimator.criticalAlert(12, charging = null, alerted = false).newAlerted
        assertTrue(alerted)
        for (pct in listOf(11, 13, 12, 14, 11)) {
            val r = BatteryEstimator.criticalAlert(pct, charging = null, alerted = alerted)
            assertFalse("re-fired at $pct% inside the hysteresis band", r.fire)
            alerted = r.newAlerted
        }
    }

    @Test
    fun rearmsOnGenuineRecoveryThenFiresNextCycle() {
        var alerted = BatteryEstimator.criticalAlert(11, charging = null, alerted = false).newAlerted
        val recovered = BatteryEstimator.criticalAlert(25, charging = null, alerted = alerted)
        assertFalse(recovered.fire)
        assertFalse("25% is the re-arm line (inclusive)", recovered.newAlerted)
        alerted = recovered.newAlerted
        assertTrue(BatteryEstimator.criticalAlert(12, charging = null, alerted = alerted).fire)
    }

    @Test
    fun rearmBoundaryIsInclusive() {
        assertFalse(BatteryEstimator.criticalAlert(25, charging = null, alerted = true).newAlerted)
        assertTrue(BatteryEstimator.criticalAlert(24, charging = null, alerted = true).newAlerted)
    }

    @Test
    fun confirmedChargingSuppressesButUnknownFires() {
        assertFalse(BatteryEstimator.criticalAlert(8, charging = true, alerted = false).fire)
        assertTrue(BatteryEstimator.criticalAlert(8, charging = null, alerted = false).fire)
    }

    @Test
    fun chargingSuppressionDoesNotArmGate() {
        val plugged = BatteryEstimator.criticalAlert(11, charging = true, alerted = false)
        assertFalse(plugged.newAlerted)
        assertTrue(BatteryEstimator.criticalAlert(11, charging = false, alerted = plugged.newAlerted).fire)
    }

    // ---- typicalSleepHours ----

    @Test
    fun typicalSleepHoursIsTheMedianAndIgnoresJunkNights() {
        // A dead-strap 0.3 h night and an all-nighter must not drag the budget.
        val nights = listOf(7.9, 8.1, 0.3, 7.6, 8.4, 7.8, 8.0, 2.0)
        assertEquals(7.85, BatteryEstimator.typicalSleepHours(nights)!!, 0.001)
    }

    @Test
    fun typicalSleepHoursColdStart() {
        assertNull(BatteryEstimator.typicalSleepHours(emptyList()))
        assertNull(BatteryEstimator.typicalSleepHours(listOf(8.0, 8.0, 8.0)))
        assertNull(
            "zero-length nights are not history",
            BatteryEstimator.typicalSleepHours(List(20) { 0.0 }),
        )
        assertNotNull(BatteryEstimator.typicalSleepHours(List(7) { 8.0 }))
    }

    // ---- B2: the bedtime night-guard ----

    /** 03:30 midsleep on an 8 h night → 23:30 bedtime, computed circularly (naively it is negative). */
    private val midsleep0330 = 3 * 3600 + 1800
    private val sleep8h = 8.0
    private fun atClock(h: Int, m: Int = 0): Int = h * 3600 + m * 60

    @Test
    fun firesBeforeBedWhenTheStrapWontClearTheNight() {
        // 22:00, 1.5 h to a 23:30 bedtime → needs 1.5 + 8 + 1 = 10.5 h; has 5 h.
        val r = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 5.0,
            charging = false, alerted = false,
        )
        assertTrue(r.fire)
        assertTrue(r.newAlerted)
        val runway = r.runway!!
        assertEquals("bedtime wrapped midnight correctly", 1.5, runway.hoursUntilBedtime, 0.001)
        assertEquals(10.5, runway.requiredHours, 0.001)
        assertEquals(5.5, runway.shortfallHours, 0.001)
    }

    @Test
    fun staysSilentWhenTheStrapClearsTheNight() {
        val r = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 12.0,
            charging = false, alerted = false,
        )
        assertFalse(r.fire)
        assertEquals(0.0, r.runway!!.shortfallHours, 0.0)
    }

    /**
     * The requirement is anchored to the wait until bedtime, not a flat night: firing 3 h out demands
     * 3 h more runtime than firing at bedtime. Same battery, same night, different answer.
     */
    @Test
    fun requirementScalesWithTheWaitUntilBedtime() {
        val early = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(20, 30), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 10.5,
            charging = false, alerted = false,
        )
        assertEquals(12.0, early.runway!!.requiredHours, 0.001)
        assertTrue("3 h out, 10.5 h of runway does not cover the wait plus the night", early.fire)
        val atBed = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(23, 30), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 10.5,
            charging = false, alerted = false,
        )
        assertEquals(9.0, atBed.runway!!.requiredHours, 0.001)
        assertFalse(atBed.fire)
    }

    @Test
    fun outsideTheWindowIsSilentAndRearms() {
        // 18:00 — 5.5 h before bed, window not open yet. A latched gate re-arms here.
        val early = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(18), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 0.5,
            charging = false, alerted = true,
        )
        assertFalse(early.fire)
        assertFalse(early.newAlerted)
        assertNull(early.runway)
        // 23:45 — bedtime has passed, `hoursUntilBedtime` wraps to ~23.75. Silent, and re-armed for
        // tomorrow: this is what makes the night-guard once-per-NIGHT rather than once-per-discharge.
        val late = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(23, 45), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 0.5,
            charging = false, alerted = true,
        )
        assertFalse(late.fire)
        assertFalse(late.newAlerted)
    }

    @Test
    fun firesOncePerNightThenAgainTheFollowingNight() {
        var alerted = false
        // Tonight's window: fires once, then holds across every later reading in the window.
        for (clock in listOf(atClock(21), atClock(21, 30), atClock(22), atClock(23))) {
            val r = BatteryEstimator.bedtimeAlert(
                nowSecOfDay = clock, habitualMidsleepSec = midsleep0330,
                typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
                charging = false, alerted = alerted,
            )
            assertEquals("exactly one alert per night", clock == atClock(21), r.fire)
            alerted = r.newAlerted
        }
        assertTrue(alerted)
        // Next morning: outside the window → re-armed, WITHOUT needing a charge to do it.
        alerted = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(9), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
            charging = false, alerted = alerted,
        ).newAlerted
        assertFalse(alerted)
        // Tomorrow night: speaks again.
        assertTrue(
            BatteryEstimator.bedtimeAlert(
                nowSecOfDay = atClock(21), habitualMidsleepSec = midsleep0330,
                typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
                charging = false, alerted = alerted,
            ).fire,
        )
    }

    /** Cold start: no learned bedtime → no alert and no fabricated bedtime. */
    @Test
    fun coldStartNeverFiresAndInventsNoBedtime() {
        val noMidsleep = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = null,
            typicalSleepHours = sleep8h, usableRemainingHours = 0.1,
            charging = false, alerted = false,
        )
        assertFalse(noMidsleep.fire)
        assertNull(noMidsleep.runway)
        val noDuration = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = null, usableRemainingHours = 0.1,
            charging = false, alerted = false,
        )
        assertFalse(noDuration.fire)
        assertNull(noDuration.runway)
        // Cold start must not silently consume a latched gate either.
        assertTrue(
            BatteryEstimator.bedtimeAlert(
                nowSecOfDay = atClock(22), habitualMidsleepSec = null,
                typicalSleepHours = null, usableRemainingHours = 0.1,
                charging = false, alerted = true,
            ).newAlerted,
        )
    }

    @Test
    fun noEstimateIsSilent() {
        val r = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = null,
            charging = false, alerted = false,
        )
        assertFalse(r.fire)
        assertNull(r.runway)
    }

    @Test
    fun confirmedChargingSuppressesButUnknownFiresAndGateSurvives() {
        val plugged = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
            charging = true, alerted = false,
        )
        assertFalse(plugged.fire)
        assertFalse("charging suppression must not consume the gate", plugged.newAlerted)
        // Unplugged, still in the window → it fires.
        assertTrue(
            BatteryEstimator.bedtimeAlert(
                nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
                typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
                charging = false, alerted = plugged.newAlerted,
            ).fire,
        )
        // Unknown charge bit (the strap only reports it every ~8 min) still fires.
        assertTrue(
            BatteryEstimator.bedtimeAlert(
                nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
                typicalSleepHours = sleep8h, usableRemainingHours = 2.0,
                charging = null, alerted = false,
            ).fire,
        )
    }

    /**
     * A late sleeper: 05:00 midsleep, 7 h night → 01:30 bedtime, so the window opens at 22:30 and
     * spans midnight. Nothing here may key off a fixed clock band.
     */
    @Test
    fun lateSleeperWindowSpansMidnight() {
        val midsleep0500 = 5 * 3600
        val inWindow = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(0, 30), habitualMidsleepSec = midsleep0500,
            typicalSleepHours = 7.0, usableRemainingHours = 1.0,
            charging = false, alerted = false,
        )
        assertTrue(inWindow.fire)
        assertEquals(1.0, inWindow.runway!!.hoursUntilBedtime, 0.001)
        // 21:00 is still outside a 01:30 bedtime's 3 h window.
        assertFalse(
            BatteryEstimator.bedtimeAlert(
                nowSecOfDay = atClock(21), habitualMidsleepSec = midsleep0500,
                typicalSleepHours = 7.0, usableRemainingHours = 1.0,
                charging = false, alerted = false,
            ).fire,
        )
    }

    /**
     * End to end on the real fixture: at the 13.1% reading the strap has ~32 min of usable runway. If
     * that reading had landed in the pre-bed window, the night-guard would have caught what both
     * latched alerts missed.
     */
    @Test
    fun nightGuardCatchesTheRealIncidentRunway() {
        val est = BatteryEstimator.estimate(realFullDischarge(), BatteryEstimator.ratedLifeHoursWhoop5)!!
        val r = BatteryEstimator.bedtimeAlert(
            nowSecOfDay = atClock(22), habitualMidsleepSec = midsleep0330,
            typicalSleepHours = sleep8h,
            usableRemainingHours = BatteryEstimator.usableRemainingHours(est),
            charging = false, alerted = false,
        )
        assertTrue(r.fire)
        assertEquals(9.95, r.runway!!.shortfallHours, 0.15)
    }
}
