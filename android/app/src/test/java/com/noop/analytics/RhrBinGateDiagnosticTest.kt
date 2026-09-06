package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1943 measure-only: the line must describe the partition `sessionRestingHR` actually uses, and must
 * stay silent on a night where an artefact gate would change nothing. A diagnostic that fired every
 * night would be ignored; one that fired on the wrong bins would argue for a change on false evidence.
 */
class RhrBinGateDiagnosticTest {

    private fun hr(start: Long, count: Int, bpm: Int, step: Long = 1L) =
        (0 until count).map { HrSample("d", start + it * step, bpm) }

    /** A dense, ordinary night: every bin well-populated, so the gate would change nothing. Silent. */
    @Test fun aWellPopulatedNightSaysNothing() {
        val start = 1_000L
        val end = start + 1800                       // 6 bins at 1 Hz
        val samples = hr(start, 1800, 60)
        assertNull(SleepStager.rhrBinGateLogLine("2026-01-01", listOf(start to end), samples, 60))
    }

    /** A one-sample bin that WINS the floor is the whole point: it must be reported, and named. */
    @Test fun aThinWinningBinIsReportedWithWhatTheGateWouldDo() {
        val start = 1_000L
        val end = start + 1800
        // Five dense bins at 60 bpm, then a single stray low sample alone in the last bin.
        val dense = hr(start, 1500, 60)
        val stray = listOf(HrSample("d", start + 1700, 38))
        val line = SleepStager.rhrBinGateLogLine("2026-01-01", listOf(start to end), dense + stray, 38)
        assertTrue("a thin winning bin must be reported, got: $line", line != null)
        assertTrue("must count the thin bin, got: $line", line!!.contains("thin=1"))
        assertTrue("must name the winning bin's size, got: $line", line.contains("winnerN=1"))
        assertTrue("must say the gate would move the floor, got: $line", line.contains("wouldChange=true"))
        assertTrue("must report the gated floor it would use instead, got: $line", line.contains("gated=60"))
    }

    /** A thin bin that does NOT win still reports, because the population is what is being measured. */
    @Test fun aThinBinThatDoesNotWinStillReportsButChangesNothing() {
        val start = 1_000L
        val end = start + 1800
        val dense = hr(start, 1500, 60)
        val strayHigh = listOf(HrSample("d", start + 1700, 90))   // thin, but far above the floor
        val line = SleepStager.rhrBinGateLogLine("2026-01-01", listOf(start to end), dense + strayHigh, 60)
        assertTrue("still worth reporting, got: $line", line != null)
        assertTrue(line!!.contains("thin=1"))
        assertTrue("the floor is unchanged, got: $line", line.contains("wouldChange=false"))
    }

    /** No sleep sessions, or no samples inside them, is not a finding. */
    @Test fun nothingToMeasureIsSilent() {
        assertNull(SleepStager.rhrBinGateLogLine("2026-01-01", emptyList(), hr(1_000L, 100, 60), 60))
        assertNull(SleepStager.rhrBinGateLogLine("2026-01-01", listOf(9_000L to 9_900L), hr(1_000L, 100, 60), 60))
    }

    /** It carries counts and bpm only: no timestamps, so a shared strap log gains no new identifiers. */
    @Test fun theLineCarriesNoTimestamps() {
        val start = 1_700_000_000L
        val end = start + 1800
        val line = SleepStager.rhrBinGateLogLine(
            "2026-01-01", listOf(start to end),
            hr(start, 1500, 60) + listOf(HrSample("d", start + 1700, 38)), 38,
        )
        assertTrue(line != null)
        assertTrue("must not leak an epoch timestamp, got: $line", !line!!.contains("17000000"))
    }
}
