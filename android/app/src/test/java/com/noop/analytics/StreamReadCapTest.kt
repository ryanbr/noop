package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Per-stream read caps (#1538) — twin of the Swift `StreamReadCapTests`, same cases and same numbers. */
class StreamReadCapTest {

    /**
     * THE invariant. A cap must exceed what a full window can legitimately hold, or a complete read is
     * indistinguishable from a truncated one — and the truncated one silently loses its newest rows. If
     * the window span or a stream's rate ever changes, this fails instead of a night being clipped.
     */
    @Test fun `cap exceeds a full window for every stream`() {
        val fullHr = StreamReadCap.WINDOW_SECONDS * StreamReadCap.HR_ROWS_PER_SECOND
        val fullRr = StreamReadCap.WINDOW_SECONDS * StreamReadCap.RR_ROWS_PER_SECOND
        assertTrue(StreamReadCap.HR > fullHr)
        assertTrue(StreamReadCap.RR > fullRr)
    }

    /**
     * The test above is derived from the same constants as the caps, so on its own it only asserts that
     * headroom exceeds 1. This one is anchored OUTSIDE the type, to a number the field produced: R-R came
     * back at 200,000 ten times in one capture, so that value is known-insufficient rather than
     * theorised. A cap at or below it would reintroduce the bug no matter how the arithmetic reads.
     */
    @Test fun `caps clear the value that truncated in the field`() {
        val knownInsufficient = 200_000
        assertTrue(StreamReadCap.RR > knownInsufficient)
        assertTrue("HR sat 3% under this and was lucky, not safe", StreamReadCap.HR > knownInsufficient)
    }

    /**
     * The window is not restated here — the engine reads `dayStart - LOOKBACK_SECONDS`, so these are the
     * same number by construction. Pinned so that splitting them again is a visible change.
     */
    @Test fun `window is its two halves`() {
        assertEquals(StreamReadCap.LOOKBACK_SECONDS + StreamReadCap.FORWARD_SECONDS, StreamReadCap.WINDOW_SECONDS)
        assertEquals(30 * 3_600, StreamReadCap.LOOKBACK_SECONDS)
        assertEquals(86_400, StreamReadCap.FORWARD_SECONDS)
    }

    /**
     * The regression itself, in the numbers that caused it. The old shared cap of 200,000 was ABOVE a
     * full HR window and BELOW a full R-R one — which is exactly why HR never truncated, R-R always did,
     * and one number looked adequate from the HR side.
     */
    @Test fun `the old shared cap was below a full R-R window`() {
        val oldSharedCap = 200_000.0
        val fullHr = StreamReadCap.WINDOW_SECONDS * StreamReadCap.HR_ROWS_PER_SECOND
        val fullRr = StreamReadCap.WINDOW_SECONDS * StreamReadCap.RR_ROWS_PER_SECOND
        assertTrue("the old cap fitted HR, which is why it looked fine", oldSharedCap > fullHr)
        assertTrue("and did not fit R-R, which is why nights were clipped", oldSharedCap < fullRr)
        assertTrue("the new cap does fit it", StreamReadCap.RR > fullRr)
    }

    /** R-R must be capped higher than HR: it is one row per BEAT, not one per second. */
    @Test fun `R-R is capped higher than HR`() {
        assertTrue(StreamReadCap.RR > StreamReadCap.HR)
    }

    /**
     * The window is 54 hours — `dayStart - 30h` running through the night. Pinned because both caps are
     * derived from it, so a silent change here would resize them both.
     */
    @Test fun `window is fifty-four hours`() {
        assertEquals(54 * 3_600, StreamReadCap.WINDOW_SECONDS)
        assertEquals(291_600, StreamReadCap.HR)
        assertEquals(583_200, StreamReadCap.RR)
        assertEquals(291_600, StreamReadCap.GRAVITY)
    }

    /**
     * Gravity is the third stream on the 54-hour window, and the field capture put it at 192,698 rows -
     * 96% of the old shared cap. Unlike HR and R-R it is a PLAIN read with no truncation counter, so a
     * clip there reports nothing at all; sleep staging simply gets a night missing its tail.
     */
    @Test fun `gravity clears what the field measured`() {
        val measuredInField = 192_698
        assertTrue(StreamReadCap.GRAVITY > measuredInField)
        assertTrue("the old shared cap it sat 96% of", StreamReadCap.GRAVITY > 200_000)
    }

}
