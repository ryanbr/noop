package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.roundToInt

/**
 * #1545: the Effort recipe has to reach the score, and reach the WORKOUTS INSIDE the day by the same
 * route.
 *
 * The denominator work landed the arithmetic; this pins the plumbing. Threading a parameter through a
 * dozen call sites is exactly the kind of change that compiles perfectly while quietly dropping the value
 * somewhere in the middle, and the symptom would be invisible — a score that is merely *wrong*, not
 * missing.
 *
 * Byte-parity twin of Swift `EffortMethodThreadingTests`.
 */
class EffortMethodThreadingTest {

    private val day = "2026-08-23"

    /** A flat hour just UNDER Edwards' 50% HRR floor: it earns nothing there, and real credit under Banister. */
    private fun subThresholdHour(): List<HrSample> {
        val bpm = (60.0 + (190.0 - 60.0) * 0.45).roundToInt()
        return (0 until 3600).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = bpm) }
    }

    private fun profile() = UserProfile(age = 30.0, sex = "male")

    private fun score(method: StrainScorer.Method): Double? = AnalyticsEngine.analyzeDay(
        day = day,
        hr = subThresholdHour(),
        dayHr = subThresholdHour(),
        profile = profile(),
        maxHROverride = 190.0,
        effortMethod = method,
    ).strain

    /**
     * The default must not move. Every caller that says nothing about a method still gets Edwards, and an
     * hour below the floor still scores nothing — because that is what shipped, and this change is
     * supposed to add a choice, not alter one.
     */
    @Test
    fun theDefaultIsStillEdwardsAndStillScoresTheFlooredHourAtZero() {
        val implicit = AnalyticsEngine.analyzeDay(
            day = day, hr = subThresholdHour(), dayHr = subThresholdHour(),
            profile = profile(), maxHROverride = 190.0,
        ).strain
        assertEquals(score(StrainScorer.Method.EDWARDS) ?: -1.0, implicit ?: -2.0, 1e-12)
        assertEquals(0.0, implicit ?: -1.0, 1e-9)
    }

    /**
     * The whole point: asking for Banister actually changes the day's Effort. If the parameter were
     * dropped anywhere between analyzeDay and StrainScorer, this is the assertion that notices.
     */
    @Test
    fun banisterReachesTheDayScore() {
        val banister = score(StrainScorer.Method.BANISTER)
        assertNotNull(banister)
        assertTrue("an hour at 45% HRR should score under Banister, got $banister", banister!! > 40.0)
    }

    /**
     * And it reaches the BOUTS inside the day by the same route. A day scored on Banister whose detected
     * workouts were still on Edwards would show a session scoring less than the day containing it — a
     * contradiction a user would notice long before they noticed either number being individually off.
     */
    @Test
    fun banisterReachesTheWorkoutsDetectedInsideTheDay() {
        // A bout needs motion as well as HR, so drive WorkoutDetector directly with the same window —
        // it is the exact call analyzeDay makes internally.
        val hr = subThresholdHour()
        val grav = (0 until 3600).map {
            com.noop.data.GravitySample(deviceId = "t", ts = it.toLong(), x = 0.9, y = 0.1, z = 0.1)
        }
        val edwards = WorkoutDetector.detect(
            hr = hr, gravity = grav, restingHR = 60.0, maxHR = 190.0, age = 30.0,
            profile = profile(), effortMethod = StrainScorer.Method.EDWARDS)
        val banister = WorkoutDetector.detect(
            hr = hr, gravity = grav, restingHR = 60.0, maxHR = 190.0, age = 30.0,
            profile = profile(), effortMethod = StrainScorer.Method.BANISTER)

        // Whatever the detector finds, it must find the SAME bouts either way — the recipe changes the
        // score, never the segmentation.
        assertEquals("the method must not change which bouts are detected", edwards.size, banister.size)
        for (i in edwards.indices) {
            assertEquals(edwards[i].start, banister[i].start)
            val e = edwards[i].strain
            val b = banister[i].strain
            if (e != null && b != null && e == 0.0) {
                assertTrue("a floored bout should score under Banister (edwards=$e banister=$b)", b > e)
            }
        }
    }

    /** A method change must not disturb anything else the day computes. */
    @Test
    fun onlyEffortMoves() {
        val e = AnalyticsEngine.analyzeDay(
            day = day, hr = subThresholdHour(), dayHr = subThresholdHour(),
            profile = profile(), maxHROverride = 190.0,
            effortMethod = StrainScorer.Method.EDWARDS)
        val b = AnalyticsEngine.analyzeDay(
            day = day, hr = subThresholdHour(), dayHr = subThresholdHour(),
            profile = profile(), maxHROverride = 190.0,
            effortMethod = StrainScorer.Method.BANISTER)
        assertEquals(e.daily.restingHr, b.daily.restingHr)
        assertEquals(e.daily.avgHrv, b.daily.avgHrv)
        assertEquals(e.sleepSessions.size, b.sleepSessions.size)
        assertEquals(e.recovery, b.recovery)
    }
}
