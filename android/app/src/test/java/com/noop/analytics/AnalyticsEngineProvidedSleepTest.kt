package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * #804 Fix A (Kotlin twin of AnalyticsEngineProvidedSleepTests): a night the MOTION detector can't stage —
 * an Oura ring sends NO gravity vector, so detectSleep returns nothing and the night scored blank — must
 * still score when the caller hands analyzeDay the ring's OWN persisted hypnogram via `providedSleep`. And
 * the byte-identical default path (empty `providedSleep`) must be unchanged.
 */
class AnalyticsEngineProvidedSleepTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val dayStart = LocalDate.parse("2026-07-27").atStartOfDay(ZoneOffset.UTC).toEpochSecond()
    private val day = "2026-07-27"

    /** hr (30 s) + rr (2 s, varied so RMSSD is computable) over [start, end), NO gravity. */
    private fun nightStreams(start: Long, end: Long): Pair<List<HrSample>, List<RrInterval>> {
        val hr = (start until end step 30).map { HrSample("t", it, 52 + ((it / 300) % 4).toInt()) }
        var i = 0
        val rr = (start until end step 2).map { RrInterval("t", it, 1080 + (i++ % 6) * 8) }
        return hr to rr
    }

    /** A contiguous deep/light/rem/wake hypnogram over [start, end): the shape #773 persists. */
    private fun hypnogram(start: Long): List<StageSegment> {
        var t = start
        fun seg(mins: Int, stage: String): StageSegment {
            val s = StageSegment(t, t + mins * 60L, stage); t += mins * 60L; return s
        }
        return listOf(
            seg(20, "wake"), seg(100, "light"), seg(60, "deep"), seg(60, "light"),
            seg(60, "rem"), seg(120, "light"), seg(60, "deep"), seg(60, "rem"),
            seg(40, "light"), seg(20, "wake"),
        )   // 600 min in bed; deep 120, rem 120, light 320, wake 40
    }

    @Test
    fun providedHypnogramScoresANightWithoutGravity() {
        val sleepStart = dayStart - 4 * 3600            // 20:00 the previous evening
        val sleepEnd = sleepStart + 600 * 60            // +10 h → 06:00, ends on `day`
        val (hr, rr) = nightStreams(sleepStart, sleepEnd)
        val provided = listOf(
            DetectedSleep(sleepStart, sleepEnd, 0.75, hypnogram(sleepStart), restingHR = null, avgHRV = null),
        )

        val res = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = provided)

        assertNotNull("the provided hypnogram must score the night", res.daily.totalSleepMin)
        assertEquals(560.0, res.daily.totalSleepMin!!, 1.0)   // light 320 + deep 120 + rem 120
        assertEquals(120.0, res.daily.deepMin!!, 1.0)
        assertEquals(120.0, res.daily.remMin!!, 1.0)
        assertEquals(0.75, res.daily.efficiency!!, 0.001)
        assertFalse(res.sleepSessions.isEmpty())
        // HRV & resting HR re-derived from THIS day's rr/hr over the provided window (the ring row carried
        // neither) — the crux of #804 (avgHrv was nil despite 36 k rr present).
        assertNotNull("avgHrv must be derived from rr over the provided window", res.daily.avgHrv)
        assertNotNull(res.daily.restingHr)
    }

    @Test
    fun emptyProvidedSleepIsByteIdenticalToOmitting() {
        val (hr, rr) = nightStreams(dayStart - 4 * 3600, dayStart + 6 * 3600)
        val omitted = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile)
        val empty = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = emptyList())
        assertEquals(omitted.daily, empty.daily)
        // No gravity + no provided hypnogram = the pre-fix #804 state: the night does not score.
        assertNull(omitted.daily.totalSleepMin)
        assertNull(omitted.daily.avgHrv)
    }

    @Test
    fun providedSessionKeepsItsOwnStoredHrvWhenPresent() {
        val sleepStart = dayStart - 4 * 3600
        val sleepEnd = sleepStart + 600 * 60
        val (hr, rr) = nightStreams(sleepStart, sleepEnd)
        val provided = listOf(
            DetectedSleep(sleepStart, sleepEnd, 0.8, hypnogram(sleepStart), restingHR = 48, avgHRV = 65.0),
        )
        val res = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = provided)
        assertEquals(48, res.daily.restingHr)
        assertEquals(65.0, res.daily.avgHrv!!, 0.001)
    }
}
