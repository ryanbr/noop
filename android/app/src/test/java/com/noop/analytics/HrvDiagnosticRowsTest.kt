package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * #2425: the `hrv diag` line must describe the night the #1118 gate judged. It used to pool every session of
 * the day over first-to-last beat, gaps included, and on a refused night printed a verdict that was not an
 * over-count. Asserted as an AGREEMENT with the gate's own helper, not against a fixed label.
 * Byte-parity twin of Swift `HrvDiagnosticRowsTests`: same fixtures, same expected values.
 */
class HrvDiagnosticRowsTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val day = "2026-07-27"
    private val dayStart = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
    private val nightStart = dayStart - 4 * 3600
    private val nightEnd = nightStart + 600 * 60
    private val napStart = dayStart + 13 * 3600
    private val napEnd = napStart + 40 * 60

    private fun verdict(rows: List<RrInterval>): HrvAnalyzer.RrCoverageVerdict {
        val ts = rows.map { it.ts }
        val ms = rows.map { it.rrMs.toDouble() }
        return HrvAnalyzer.classifyCoverage(HrvAnalyzer.rrCoverage(ts, ms), HrvAnalyzer.collapsedCoverage(ts, ms))
    }

    /** Night: two beats every second (refused). Nap: one per second (clean). */
    private fun dayResult(): Pair<DayResult, List<RrInterval>> {
        val night = (nightStart until nightEnd).flatMap { listOf(RrInterval("t", it, 880), RrInterval("t", it, 960)) }
        val nap = (napStart until napEnd).map { RrInterval("t", it, if ((it - napStart) % 2 == 0L) 970 else 1030) }
        val hr = (nightStart until napEnd step 30).map { HrSample("t", it, 55) }
        val sessions = listOf(
            DetectedSleep(nightStart, nightEnd, 0.9, listOf(StageSegment(nightStart, nightEnd, "light")),
                restingHR = null, avgHRV = null),
            DetectedSleep(napStart, napEnd, 0.9, listOf(StageSegment(napStart, napEnd, "light")),
                restingHR = null, avgHRV = null),
        )
        val rr = night + nap
        return AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = sessions) to rr
    }

    @Test fun theDayResultCarriesTheMainNightGroupScoringUsed() {
        val (res, _) = dayResult()
        assertEquals(listOf(nightStart), res.mainNightBlocks.map { it.start })
        assertEquals(listOf(nightEnd), res.mainNightBlocks.map { it.end })
    }

    @Test fun theDiagnosticVerdictAgreesWithTheGateOnARefusedNight() {
        val (res, rr) = dayResult()
        val fallback = res.sleepSessions.map { SleepStageTotals.NightBlock(it.start, it.end) }
        val rows = AnalyticsEngine.hrvDiagnosticRows(rr, res.mainNightBlocks, fallback)
        assertEquals("the night's beats only, the nap is not pooled in", 2 * 600 * 60, rows.size)
        assertTrue("precondition: the gate refuses this night",
            SleepStager.sessionHrvOverCounted(nightStart, nightEnd, rr))
        assertFalse("the line must call it an over-count, as the gate did",
            HrvAnalyzer.successiveDiffIsTrustworthy(verdict(rows)))
        // The old selection, every session pooled over the 7-hour gap: 1.08, PLAUSIBLE.
        val pooled = AnalyticsEngine.hrvDiagnosticRows(rr, emptyList(), fallback)
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, verdict(pooled))
    }

    @Test fun aDayWithNoMainNightKeepsThePooledHalfOpenSet() {
        val rr = listOf(RrInterval("t", 100, 1000), RrInterval("t", 150, 1000), RrInterval("t", 200, 1000))
        val rows = AnalyticsEngine.hrvDiagnosticRows(rr, emptyList(), listOf(SleepStageTotals.NightBlock(100, 200)))
        assertEquals("fallback keeps the old half-open [start, end) window", listOf(100L, 150L), rows.map { it.ts })
        val main = AnalyticsEngine.hrvDiagnosticRows(rr, listOf(SleepStageTotals.NightBlock(100, 200)), emptyList())
        assertEquals("main night uses the gate's inclusive [start, end]", listOf(100L, 150L, 200L), main.map { it.ts })
    }
}
