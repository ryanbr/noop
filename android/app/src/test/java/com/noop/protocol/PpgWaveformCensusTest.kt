package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2019: the per-session optical census. Twin of the Swift `PpgWaveformCensusTests` against the SAME
 * literals, so the two platforms cannot report the same offload differently.
 */
class PpgWaveformCensusTest {

    /**
     * A session with no v26 windows says nothing at all: a 4.0, or a 5/MG that banked none, must not
     * print a census of zero.
     */
    @Test
    fun noWindowsIsSilent() {
        assertNull(ppgWaveformCensusLine(0, 0, 0, null, null))
    }

    /** The ordinary healthy session: every window carried a base, none saturated. */
    @Test
    fun everyWindowReconstructable() {
        assertEquals(
            "Backfill: v26 optical census: 412 window(s), 412 with a base, 0 saturated, base 361204..379881",
            ppgWaveformCensusLine(412, 412, 0, 361_204L, 379_881L),
        )
    }

    /**
     * `withBase` below the window count is the signal that matters: those windows can never be
     * reconstructed, and before this line existed they were banked with nothing said about it.
     */
    @Test
    fun windowsMissingABaseAreVisible() {
        assertEquals(
            "Backfill: v26 optical census: 10 window(s), 7 with a base, 0 saturated, base 100..200",
            ppgWaveformCensusLine(10, 7, 0, 100L, 200L),
        )
    }

    /**
     * A saturated window earns the caveat inline, because the caveat is the reason to distrust the
     * reconstruction and it is worthless if it only lives in a doc comment.
     */
    @Test
    fun saturationCarriesItsCaveat() {
        assertEquals(
            "Backfill: v26 optical census: 5 window(s), 5 with a base, 2 saturated, base 1..2 " +
                "(a saturated window reconstructs only approximately)",
            ppgWaveformCensusLine(5, 5, 2, 1L, 2L),
        )
    }

    /** An absent range reads as absent rather than as a fabricated zero. */
    @Test
    fun absentBaseRangeSaysSo() {
        assertEquals(
            "Backfill: v26 optical census: 3 window(s), 0 with a base, 0 saturated, base n/a",
            ppgWaveformCensusLine(3, 0, 0, null, null),
        )
    }

    /** Both i16 rails count, and an ordinary delta does not. */
    @Test
    fun saturationIsBothRails() {
        assertTrue(isSaturatedPpgDelta(-32_768))
        assertTrue(isSaturatedPpgDelta(32_767))
        assertFalse(isSaturatedPpgDelta(-1_833))
        assertFalse(isSaturatedPpgDelta(0))
    }
}
