package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1735's second half: "hours after the ride it still is not there". Answering that needs to separate a
 * Health Connect import that never ran from one that ran and brought nothing, and a scoring pass that
 * never happened from one that happened and changed nothing. These lines exist for those four states, so
 * the tests assert that all four stay distinguishable.
 */
class PipelineFreshnessLinesTest {

    // ---- hcImportLine -------------------------------------------------------------------------

    /**
     * The state a static row count cannot express, and the reason the empty path is stamped at all: the
     * import RAN and found nothing. If this rendered like "never", the log would say the same thing about
     * an install that has never connected Health Connect and one whose import is running fine and simply
     * has nothing new - which is the whole distinction being bought here.
     */
    @Test
    fun `ran and found nothing is not the same as never ran`() {
        val ranEmpty = AndroidDiagnostics.hcImportLine(ago = "12m ago", rows = 0, throughDay = null)
        val never = AndroidDiagnostics.hcImportLine(ago = null, rows = 0, throughDay = null)
        assertTrue(ranEmpty.contains("0 row(s) 12m ago"))
        assertTrue(never.contains("never completed"))
        assertFalse("a completed empty import must not read as never", ranEmpty.contains("never"))
    }

    @Test
    fun `a productive import reports rows and how far it reached`() {
        val line = AndroidDiagnostics.hcImportLine(ago = "3m ago", rows = 41, throughDay = "2026-08-30")
        assertTrue(line.contains("41 row(s) 3m ago"))
        assertTrue(line.contains("through 2026-08-30"))
    }

    /** No day recorded must not render a dangling separator or an empty "through". */
    @Test
    fun `a missing through-day leaves no dangling clause`() {
        val line = AndroidDiagnostics.hcImportLine(ago = "3m ago", rows = 41, throughDay = null)
        assertFalse(line.contains("through"))
        assertFalse(line.trimEnd().endsWith("·"))
    }

    /**
     * "never" must not be phrased as a fault. Plenty of installs never connect Health Connect, and a line
     * that reads like a problem sends a reader chasing one that does not exist.
     */
    @Test
    fun `never is stated plainly rather than as a failure`() {
        val never = AndroidDiagnostics.hcImportLine(null, 0, null)
        assertFalse(never.contains("FAIL"))
        assertFalse(never.contains("⚠"))
        assertTrue(never.contains("on this install"))
    }

    // ---- scoringPassLine ----------------------------------------------------------------------

    @Test
    fun `a completed pass and no pass are distinguishable`() {
        assertTrue(AndroidDiagnostics.scoringPassLine("8m ago").contains("last pass 8m ago"))
        assertTrue(AndroidDiagnostics.scoringPassLine(null).contains("no pass has completed"))
        assertFalse(AndroidDiagnostics.scoringPassLine("8m ago").contains("no pass"))
    }

    // ---- shared shape -------------------------------------------------------------------------

    /**
     * Both join the "Data write:" / "Timezone:" / "Last restore:" block, whose labels are padded so the
     * VALUES start at a common column. Asserted exactly (content begins at index 13, matching that block)
     * rather than "somewhere to the right", which a mis-padded line would also satisfy.
     */
    @Test
    fun `the values start at the same column as the block they join`() {
        val lines = listOf(
            AndroidDiagnostics.hcImportLine("1m ago", 1, null),
            AndroidDiagnostics.hcImportLine(null, 0, null),
            AndroidDiagnostics.scoringPassLine("1m ago"),
            AndroidDiagnostics.scoringPassLine(null),
        )
        for (line in lines) {
            val afterColon = line.indexOf(':') + 1
            val valueStart = afterColon + line.drop(afterColon).indexOfFirst { it != ' ' }
            assertEquals("'$line' must start its value at column 13", 13, valueStart)
        }
    }

    /** House style for these lines: no em-dashes. */
    @Test
    fun `the lines carry no em-dash`() {
        assertFalse(AndroidDiagnostics.hcImportLine("1m ago", 1, "2026-08-30").contains("—"))
        assertFalse(AndroidDiagnostics.scoringPassLine(null).contains("—"))
    }
}
