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
    }
}
