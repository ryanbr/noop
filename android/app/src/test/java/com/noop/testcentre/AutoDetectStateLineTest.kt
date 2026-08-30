package com.noop.testcentre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The line exists to stop a reader drawing #1735's conclusion, so the tests assert the distinctions that
 * do that job rather than the prose. Pure and Context-free, like the rest of the diagnostics helpers.
 */
class AutoDetectStateLineTest {

    /**
     * The misleading combination, and the only one the reassurance belongs on: the toggle is off and rows
     * exist anyway. Claiming it in any other state would be explaining something the line is not looking
     * at, which is how a diagnostic starts asserting more than it observes.
     */
    @Test
    fun `only the misleading combination gets the reassurance`() {
        val misleading = AndroidDiagnostics.autoDetectStateLine(false, storedDetectedRows = 12, dismissedMarkers = 3)
        assertTrue(misleading.contains("suggestion card=off"))
        assertTrue(misleading.contains("are EXPECTED"))

        // Card off and NO rows: nothing to explain.
        assertFalse(AndroidDiagnostics.autoDetectStateLine(false, 0, 0).contains("are EXPECTED"))
        // Card ON: rows are unsurprising to a reader who just enabled it.
        assertFalse(AndroidDiagnostics.autoDetectStateLine(true, 12, 0).contains("are EXPECTED"))
    }

    /** The load-bearing fact: the engine rows are not governed by the toggle. Always stated. */
    @Test
    fun `the ungated engine rows are named in every state`() {
        for (card in listOf(true, false)) {
            for (rows in listOf(0, 7)) {
                val line = AndroidDiagnostics.autoDetectStateLine(card, rows, 0)
                assertTrue("state card=$card rows=$rows must name the ungated derivation",
                           line.contains("not gated by that toggle"))
            }
        }
    }

    @Test
    fun `the counts are reported`() {
        val line = AndroidDiagnostics.autoDetectStateLine(true, storedDetectedRows = 41, dismissedMarkers = 5)
        assertTrue(line.contains("suggestion card=on"))
        assertTrue(line.contains("stored detected=41"))
        assertTrue(line.contains("dismissed markers=5"))
    }

    /**
     * A failed dismissal query must not render as zero. "dismissed markers=0" reads as "your dismissals
     * are not sticking" and would send a reader after the #107 mechanism for a problem that is a failed
     * read, which is the exact class of wrong-attribution CLAUDE.md warns about.
     */
    @Test
    fun `an unavailable dismissal count is not reported as zero`() {
        val unknown = AndroidDiagnostics.autoDetectStateLine(false, 3, dismissedMarkers = null)
        assertTrue(unknown.contains("dismissed markers=n/a"))
        assertFalse(unknown.contains("dismissed markers=0"))
        // A real zero still reads as zero.
        assertTrue(AndroidDiagnostics.autoDetectStateLine(false, 3, 0).contains("dismissed markers=0"))
    }

    /** House style for these lines: no em-dashes. */
    @Test
    fun `the line carries no em-dash`() {
        assertFalse(AndroidDiagnostics.autoDetectStateLine(false, 12, 3).contains("—"))
    }
}
