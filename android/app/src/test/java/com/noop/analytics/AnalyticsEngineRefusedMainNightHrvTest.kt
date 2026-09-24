package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * A main night whose HRV the #1118 over-count gate REFUSED must not be replaced by the day's naps.
 *
 * Field case: a ring night read 1.31 coverage, the gate made its HRV null, and the day's HRV became the mean
 * of two 26-minute naps, which the baseline then folded as a full night. The cases pin the rule and its
 * boundary: refused ⇒ naps excluded; merely unmeasured (no R-R at all) ⇒ #1884's fill-in from the other
 * sessions is unchanged; clean ⇒ pooled as before.
 * Byte-parity twin of Swift `AnalyticsEngineRefusedMainNightHrvTests`: same fixtures, same expected values.
 */
class AnalyticsEngineRefusedMainNightHrvTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val day = "2026-07-27"
    private val dayStart = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
    private val nightStart = dayStart - 4 * 3600           // 20:00 the evening before
    private val nightEnd = nightStart + 600 * 60            // 06:00 on `day`
    private val napStart = dayStart + 13 * 3600             // 13:00 on `day`
    private val napEnd = napStart + 40 * 60                 // 13:40

    private fun hr(start: Long, end: Long) =
        (start until end step 30).map { HrSample("t", it, 52 + ((it / 300) % 4).toInt()) }

    /** One beat per second, alternating around 1000 ms by [swing]: coverage ~1.0, RMSSD = 2 * swing. */
    private fun cleanRR(start: Long, end: Long, swing: Int) =
        (start until end).map { RrInterval("t", it, if ((it - start) % 2 == 0L) 1000 - swing else 1000 + swing) }

    /** Two beats in every second (880 + 960 ms): ~1.84x the wall clock, refused by the gate. */
    private fun overCountedRR(start: Long, end: Long) =
        (start until end).flatMap { listOf(RrInterval("t", it, 880), RrInterval("t", it, 960)) }

    private fun sessions() = listOf(
        DetectedSleep(nightStart, nightEnd, 0.9, listOf(StageSegment(nightStart, nightEnd, "light")),
            restingHR = null, avgHRV = null),
        DetectedSleep(napStart, napEnd, 0.9, listOf(StageSegment(napStart, napEnd, "light")),
            restingHR = null, avgHRV = null),
    )

    private fun analyze(nightRR: List<RrInterval>) = AnalyticsEngine.analyzeDay(
        day = day, hr = hr(nightStart, nightEnd) + hr(napStart, napEnd),
        rr = nightRR + cleanRR(napStart, napEnd, swing = 30), profile = profile, providedSleep = sessions(),
    )

    @Test fun aRefusedMainNightIsNotReplacedByTheNap() {
        val night = overCountedRR(nightStart, nightEnd)
        assertTrue("precondition: the gate refuses this night",
            SleepStager.sessionHrvOverCounted(nightStart, nightEnd, night))
        assertNotNull("precondition: the nap on its own measures an HRV",
            SleepStager.sessionAvgHRV(napStart, napEnd, cleanRR(napStart, napEnd, swing = 30)))
        assertNull("the day holds rather than reporting the nap as the night", analyze(night).daily.avgHrv)
    }

    @Test fun aMainNightWithNoRrStillFallsBackToTheNap() {
        assertEquals(60.0, analyze(emptyList()).daily.avgHrv!!, 1e-9)
    }

    @Test fun aCleanMainNightIsPooledWithTheNapAsBefore() {
        // In-bed-weighted: (40 * 600 min + 60 * 40 min) / 640 min.
        assertEquals(41.25, analyze(cleanRR(nightStart, nightEnd, swing = 20)).daily.avgHrv!!, 1e-9)
    }

    @Test fun theHelperAgreesWithTheValueGate() {
        for (rr in listOf(overCountedRR(nightStart, nightEnd), cleanRR(nightStart, nightEnd, swing = 20))) {
            assertEquals(SleepStager.sessionHrvOverCounted(nightStart, nightEnd, rr),
                SleepStager.sessionAvgHRV(nightStart, nightEnd, rr) == null)
        }
    }
}
