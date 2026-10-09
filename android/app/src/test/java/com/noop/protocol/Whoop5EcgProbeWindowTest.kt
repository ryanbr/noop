package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891 — the two rules that decide whether a run can OBSERVE a completed reading at all.
 *
 * Both defects they pin were invisible to every existing test, because the probe's own report looked
 * correct: the packet count was honest, the verdict wording was honest, and the run simply never reached
 * the frame that carries the answer. @meta1971's field timing (terminal frame at 38 to 39 s across five
 * MG sessions, variability unset for 2 to 9 s after it) is the evidence behind the numbers.
 *
 * Twin of Swift `Whoop5EcgProbeWindowTests`, pinning the same cases.
 */
class Whoop5EcgProbeWindowTest {

    @Test
    fun `capture window outlasts the measured terminal frame`() {
        // The whole defect in one assertion: 30 s cannot reach a frame that lands at 38 to 39 s.
        assertTrue(Whoop5EcgProbe.Window.CAPTURE > 39)
        assertEquals(60, Whoop5EcgProbe.Window.CAPTURE)
        // A run waiting on a COMMAND_RESPONSE is not waiting on a reading, so it keeps the short window.
        assertEquals(30, Whoop5EcgProbe.Window.SELECT_OR_STOP)
        // Long enough to outlast the measured 2-to-9 s unset variability window after the terminal frame.
        assertTrue(Whoop5EcgProbe.Window.TERMINAL_GRACE > 9)
        assertEquals(10, Whoop5EcgProbe.Window.TERMINAL_GRACE)
    }

    @Test
    fun `ordinary frames fill the cap and then stop`() {
        assertTrue(Whoop5EcgProbe.retainsCandidate(0, 0, isTerminal = false))
        assertTrue(Whoop5EcgProbe.retainsCandidate(11, 0, isTerminal = false))
        assertFalse(Whoop5EcgProbe.retainsCandidate(12, 0, isTerminal = false))
        assertFalse(Whoop5EcgProbe.retainsCandidate(99, 0, isTerminal = false))
    }

    @Test
    fun `terminal frames are kept past the cap but stay bounded`() {
        // THE #891 CASE. R17 arrives about once a second, so at the terminal frame the ordinary cap has
        // long since filled with seconds 1 to 12 — the twelve frames that carry no result.
        assertTrue(Whoop5EcgProbe.retainsCandidate(12, 0, isTerminal = true))
        assertTrue(Whoop5EcgProbe.retainsCandidate(40, 3, isTerminal = true))
        // Bounded: the reserve is four slots, not an exemption.
        assertFalse(Whoop5EcgProbe.retainsCandidate(40, 4, isTerminal = true))
        assertEquals(
            16,
            Whoop5EcgProbe.MAX_CANDIDATE_LINES + Whoop5EcgProbe.MAX_TERMINAL_CANDIDATE_LINES,
        )
    }

    @Test
    fun `the grace extension happens once per run`() {
        assertEquals(10, Whoop5EcgProbe.terminalGraceSeconds(isTerminal = true, alreadyExtended = false))
        // A terminal STREAM must not be able to postpone the verdict indefinitely.
        assertNull(Whoop5EcgProbe.terminalGraceSeconds(isTerminal = true, alreadyExtended = true))
        // An ordinary frame leaves the run's deadline alone.
        assertNull(Whoop5EcgProbe.terminalGraceSeconds(isTerminal = false, alreadyExtended = false))
        assertNull(Whoop5EcgProbe.terminalGraceSeconds(isTerminal = false, alreadyExtended = true))
    }
}
