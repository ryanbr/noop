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

    /** A thin bin that does NOT win is silent: a thin FINAL bin is structural on most spans, not a finding. */
    @Test fun aThinBinThatCannotWinTheFloorIsSilent() {
        val start = 1_000L
        val end = start + 1800
        val dense = hr(start, 1500, 60)
        val strayHigh = listOf(HrSample("d", start + 1700, 90))   // thin, but far above the floor
        assertNull(
            "a thin bin that cannot win the floor is noise, not a finding",
            SleepStager.rhrBinGateLogLine("2026-01-01", listOf(start to end), dense + strayHigh, 60),
        )
    }

    /**
     * The load-bearing invariant: the line must judge the SAME partition `sessionRestingHR` ships.
     *
     * Every other case here hands the floor in as a literal, so none of them would notice the two
     * binnings drifting apart, and a diagnostic describing a different partition than the one it is
     * measuring would argue for a change on false evidence. Here the shipped floor comes FROM
     * `sessionRestingHR`, and on a night where no bin is thin the gate must agree with it exactly, which
     * the line reports by staying silent. A partition mismatch shows up as a spurious `wouldChange`.
     */
    @Test fun theDiagnosticJudgesTheSamePartitionSessionRestingHrShips() {
        val start = 1_000L
        for (spanS in listOf(1800L, 1801L, 1500L, 300L, 299L)) {   // aligned, +1, exact, one bin, short
            val end = start + spanS
            // Dense, with a genuinely lower stretch so the floor is not degenerate.
            val samples = (0 until spanS.toInt()).map {
                HrSample("d", start + it, if (it in 600..899) 55 else 65)
            }
            val shipped = SleepStager.sessionRestingHR(start, end, samples)
            assertTrue("precondition: a floor exists for span $spanS", shipped != null)
            assertNull(
                "span $spanS: every bin is dense, so the gate must agree with sessionRestingHR " +
                    "and the line must stay silent",
                SleepStager.rhrBinGateLogLine("2026-01-01", listOf(start to end), samples, shipped!!),
            )
        }
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
