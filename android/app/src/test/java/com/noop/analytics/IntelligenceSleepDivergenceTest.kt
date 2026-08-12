package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Pins the #674/#1244 divergence diagnostic. A COMPUTED day can carry a sleep total with zero matched
 * sessions — an edited/hand-logged block folded onto a day the detector staged nothing (often a day
 * absorbed into a neighbour's coupled window, so it never got its own pass). That total leaks to
 * Today/Coupled while the Sleep tab (session-backed) shows nothing. The line names the fold (`editFold=`)
 * so the next capture proves whether it's an orphaned edit. Pure formatter the loop calls; tested directly,
 * byte-identical to the Swift `IntelligenceSleepDivergenceTests`.
 */
class IntelligenceSleepDivergenceTest {

    @Test
    fun divergenceNamesTheEditFold() {
        // The #1244 shape: 558 min on the rollup, no matched session, folded from one edited row.
        val line = IntelligenceEngine.sleepDivergenceLogLine(day = "2026-08-11", totalSleepMin = 558, editFold = 1)
        assertEquals("sleep divergence day=2026-08-11 totalSleepMin=558 matched=0 editFold=1", line)
    }

    @Test
    fun divergenceWithNoEditIsAZeroFold() {
        val line = IntelligenceEngine.sleepDivergenceLogLine(day = "2026-08-07", totalSleepMin = 0, editFold = 0)
        assertEquals("sleep divergence day=2026-08-07 totalSleepMin=0 matched=0 editFold=0", line)
    }

    @Test
    fun divergenceCarriesNoEmDash() {
        val line = IntelligenceEngine.sleepDivergenceLogLine(day = "2026-08-11", totalSleepMin = 1, editFold = 0)
        assertFalse(line.contains("—"))
    }
}
