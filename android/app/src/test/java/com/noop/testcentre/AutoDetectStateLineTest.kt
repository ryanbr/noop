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
     * The only state that needs a retention explanation: the toggle is off and grandfathered rows remain.
     */
    @Test
    fun `only the misleading combination gets the reassurance`() {
        val misleading = AndroidDiagnostics.autoDetectStateLine(false, storedDetectedRows = 12, dismissedMarkers = 3)
        assertTrue(misleading.contains("suggestion card=off"))
        assertTrue(misleading.contains("retained legacy history"))

        assertFalse(AndroidDiagnostics.autoDetectStateLine(false, 0, 0).contains("retained legacy history"))
        assertFalse(AndroidDiagnostics.autoDetectStateLine(true, 12, 0).contains("retained legacy history"))
    }

    /** The load-bearing fact: analytics never publishes a new generic workout. Always stated. */
    @Test
    fun `confirmation-only publication is named in every state`() {
        for (card in listOf(true, false)) {
            for (rows in listOf(0, 7)) {
                val line = AndroidDiagnostics.autoDetectStateLine(card, rows, 0)
                assertTrue("state card=$card rows=$rows must name confirmation-only publication",
                           line.contains("new workouts=confirmation only"))
                assertTrue(line.contains("analytics does not publish generic rows"))
            }
        }
    }

    @Test
    fun `the counts are reported`() {
        val line = AndroidDiagnostics.autoDetectStateLine(true, storedDetectedRows = 41, dismissedMarkers = 5)
        assertTrue(line.contains("suggestion card=on"))
        assertTrue(line.contains("stored legacy detected=41"))
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
