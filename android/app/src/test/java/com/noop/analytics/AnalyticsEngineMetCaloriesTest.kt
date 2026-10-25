package com.noop.analytics

import com.noop.analytics.Calories.MetSample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `analyzeDay`'s calorie-path selection (#2242): a day that carries the owner's OWN MET series scores
 * `activeKcalEst` by [Calories.estimateDayEnergyFromMet]; below the coverage floor it withholds the number
 * rather than falling back to HR; no MET (every WHOOP / toggle-OFF caller) keeps the HR path byte-identical.
 * Mirrors the Swift `AnalyticsEngineMetCaloriesTests` vectors value-for-value.
 */
class AnalyticsEngineMetCaloriesTest {

    private val day = "2026-08-15"
    private val off = 7_200L   // Europe/Paris in August
    private val localMid: Long get() = AnalyticsEngine.dayStartUtcSeconds(day) - off
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")

    private fun dayHr(): List<HrSample> =
        (localMid until localMid + 86_400 step 10).map { ts -> HrSample(deviceId = "t", ts = ts, bpm = (60 + (ts / 10) % 40).toInt()) }

    /** Full-day MET at 1.0 with a 40-min 5.0-MET bout, plus spill into both neighbour days that must be ignored. */
    private fun fullMet(): List<MetSample> =
        (localMid - 3_600 until localMid + 86_400 + 3_600 step 60).map { ts ->
            val minute = ((ts - localMid) / 60).toInt()
            val met = if (ts < localMid || ts >= localMid + 86_400) 9.0 else if (minute in 600 until 640) 5.0 else 1.0
            MetSample(ts, met)
        }

    @Test
    fun metPathReplacesHrPathWhenCovered() {
        val lines = ArrayList<String>()
        val res = AnalyticsEngine.analyzeDay(
            day = day, dayHr = dayHr(), dayMet = fullMet(), caloriesDiag = { lines.add(it) },
            profile = profile, tzOffsetSeconds = off,
        )
        val expected = Calories.estimateDayEnergyFromMet(fullMet(), profile, localMid, localMid + 86_400)
        assertEquals(1.0, expected.coverageFraction, 1e-12)
        assertEquals(expected.totalKcal, res.daily.activeKcalEst ?: -1.0, 1e-9)
        // And it is NOT the HR number.
        val hrOnly = AnalyticsEngine.analyzeDay(day = day, dayHr = dayHr(), profile = profile, tzOffsetSeconds = off)
        assertNotEquals(expected.totalKcal, hrOnly.daily.activeKcalEst ?: -1.0, 1e-6)
        assertEquals(1, lines.size)
        assertTrue(lines[0], lines[0].startsWith("calories 2026-08-15: MET path - coverage 100% (1560 samples), active "))
    }

    @Test
    fun belowCoverageFloorWithholdsRatherThanSubstitutes() {
        val lines = ArrayList<String>()
        val thin = fullMet().take(60 + 400)   // 1 h spill + 400 covered minutes = 28 % of the day
        val res = AnalyticsEngine.analyzeDay(
            day = day, dayHr = dayHr(), dayMet = thin, caloriesDiag = { lines.add(it) },
            profile = profile, tzOffsetSeconds = off,
        )
        assertNull(res.daily.activeKcalEst)
        assertEquals(1, lines.size)
        assertTrue(lines[0], lines[0].contains("coverage 28% (460 samples) below 50% floor, estimate withheld"))
    }

    @Test
    fun todayIsJudgedAgainstElapsedHours() {
        // Same 400 covered minutes, but `now` is 07:00 local: 400/420 min = 95 % of the elapsed window.
        val lines = ArrayList<String>()
        val thin = fullMet().take(60 + 400)
        val res = AnalyticsEngine.analyzeDay(
            day = day, dayHr = dayHr(), dayMet = thin, dayMetNow = localMid + 7 * 3600,
            caloriesDiag = { lines.add(it) }, profile = profile, tzOffsetSeconds = off,
        )
        val expected = Calories.estimateDayEnergyFromMet(thin, profile, localMid, localMid + 7 * 3600)
        assertEquals(expected.totalKcal, res.daily.activeKcalEst ?: -1.0, 1e-9)
        assertTrue(lines[0], lines[0].contains("coverage 95% (460 samples)"))
    }

    @Test
    fun noMetKeepsHrPathByteIdentical() {
        val lines = ArrayList<String>()
        val base = AnalyticsEngine.analyzeDay(day = day, dayHr = dayHr(), profile = profile, tzOffsetSeconds = off)
        val nilMet = AnalyticsEngine.analyzeDay(
            day = day, dayHr = dayHr(), dayMet = null, caloriesDiag = { lines.add(it) },
            profile = profile, tzOffsetSeconds = off,
        )
        val emptyMet = AnalyticsEngine.analyzeDay(
            day = day, dayHr = dayHr(), dayMet = emptyList(), caloriesDiag = { lines.add(it) },
            profile = profile, tzOffsetSeconds = off,
        )
        assertEquals(base.daily, nilMet.daily)
        assertEquals(base.daily, emptyMet.daily)
        assertNotNull(base.daily.activeKcalEst)
        assertTrue("the HR path logs nothing new", lines.isEmpty())
    }
}
