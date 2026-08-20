package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1466: a WHOOP 4.0 routinely ends a full, successful night on the idle timeout rather than
 * HISTORY_COMPLETE — a field log shows a session banking 17,205 rows and still exiting `reason=timeout`.
 * Before this, every such sync raised "Sync interrupted - the strap went quiet", reporting a success as a
 * failure. Twin of the Swift `TimeoutSyncErrorTests`.
 */
class TimeoutSyncErrorTest {

    private val wentQuiet = "Sync interrupted - the strap went quiet. It will retry on the next sync."

    /** The regression: rows landed, so there is nothing to warn about. */
    @Test
    fun productiveTimeoutRaisesNoBanner() {
        assertNull(WhoopBleClient.timeoutSyncError(null, bankedThisOffload = true))
    }

    /** The case the banner exists for: the session held the radio and handed over nothing. */
    @Test
    fun stalledTimeoutStillWarns() {
        assertEquals(wentQuiet, WhoopBleClient.timeoutSyncError(null, bankedThisOffload = false))
    }

    /**
     * Pins the predicate: banked iff at least one counter moved.
     *
     * What this does NOT do is stop a caller passing the wrong counter, which is the mistake that nearly
     * shipped — the neighbouring `bankedThisOffload` counts offload FRAMES, and a stall still receives them
     * (three sessions in one field log ran 66–109s and took 42, 51 and 59 frames while banking zero rows).
     * No test over this function can catch that, because a frame count is not one of its inputs. The guard
     * is the signature plus named arguments at both call sites: `chunks`, `rows` and `deepPackets` make a
     * frame count visibly wrong where it is passed, not here. Twin of the Swift `bankedIffSomeCounterMoved`.
     */
    @Test
    fun bankedIffSomeCounterMoved() {
        assertFalse(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 0, deepPackets = 0))
        // ...and the productive night from the same log is banked on rows alone.
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 17_205, deepPackets = 0))
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 3, rows = 0, deepPackets = 0))
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 0, deepPackets = 5))
    }

    /**
     * #324/#928: a future-dated strap times out BECAUSE of its clock, so that banner names the real cause
     * and must outrank the generic one — including on a stalled session.
     */
    @Test
    fun futureClockBannerOutranksTheGenericWarning() {
        assertEquals("clock is ahead",
            WhoopBleClient.timeoutSyncError("clock is ahead", bankedThisOffload = false))
    }

    /**
     * ...and it must survive a PRODUCTIVE timeout too: rows landing does not make a bad clock fine, and
     * those rows are exactly the ones being misfiled.
     */
    @Test
    fun futureClockBannerSurvivesAProductiveTimeout() {
        assertEquals("clock is ahead",
            WhoopBleClient.timeoutSyncError("clock is ahead", bankedThisOffload = true))
    }
}
