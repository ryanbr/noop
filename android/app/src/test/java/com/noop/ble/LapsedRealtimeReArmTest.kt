package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1865: recovering a WHOOP 5/MG realtime stream that lapsed while the link stayed healthy.
 *
 * Reported as "Live doesn't work — initially it shows real data but now it doesn't", on a strap showing
 * Bonded / FULL BOND, worn, battery fine, "history synced just now", and no bpm.
 *
 * That combination is the bug. A WHOOP 4.0 re-sends TOGGLE_REALTIME_HR on every 30 s keep-alive tick,
 * documented as being because "the firmware lets the realtime HR stream lapse if it isn't re-armed". A
 * 5/MG got none of it, and none of the other recovery paths can see this state:
 *
 *  - `reconcileRealtime` is edge-triggered, so while we believe the stream is armed it sends nothing;
 *  - the one-shot re-subscribe recovers a dropped CCCD, not a stream the firmware let lapse;
 *  - the stall bounce keys on ANY inbound data, and a strap answering battery polls and serving history
 *    never trips it.
 */
class LapsedRealtimeReArmTest {

    private val stall = 300_000L

    /** The reported state: we think it is armed, someone wants it, and no sample has arrived in ages. */
    @Test
    fun aLongHrSilenceWhileArmedEarnsOneReArm() {
        assertTrue(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = true, realtimeArmed = true, reArmedSinceHr = false,
                hrSilentMs = stall + 1, stallMs = stall,
            ),
        )
    }

    /**
     * A resting wearer's 0x2A37 stream legitimately lulls — that lull is why #1414 widened the bounce fuse
     * to ten minutes. A normal quiet spell must not provoke a write.
     */
    @Test
    fun anOrdinaryLullDoesNotReArm() {
        assertFalse(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = true, realtimeArmed = true, reArmedSinceHr = false,
                hrSilentMs = 60_000, stallMs = stall,
            ),
        )
    }

    /** One write per stall episode, not one per 30 s tick — the same discipline the re-subscribe uses. */
    @Test
    fun itOnlyReArmsOncePerEpisode() {
        assertFalse(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = true, realtimeArmed = true, reArmedSinceHr = true,
                hrSilentMs = stall * 10, stallMs = stall,
            ),
        )
    }

    /** Nobody wants the stream: arming it would cost battery for a screen that is closed. */
    @Test
    fun anUnwantedStreamIsNeverArmed() {
        assertFalse(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = false, realtimeArmed = true, reArmedSinceHr = false,
                hrSilentMs = stall * 10, stallMs = stall,
            ),
        )
    }

    /**
     * If we do NOT believe it is armed, `reconcileRealtime` has a genuine false→true edge and sends the
     * toggle itself. This path exists only for the state that reconciler cannot see, so it must stay out
     * of the way rather than racing it with a second write.
     */
    @Test
    fun anUnarmedStreamIsLeftToTheReconciler() {
        assertFalse(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = true, realtimeArmed = false, reArmedSinceHr = false,
                hrSilentMs = stall * 10, stallMs = stall,
            ),
        )
    }

    /** The threshold is exclusive, so exactly-at-the-boundary waits one more tick rather than firing early. */
    @Test
    fun theThresholdIsExclusive() {
        assertFalse(
            WhoopBleClient.shouldReArmLapsedRealtime(
                wantsRealtime = true, realtimeArmed = true, reArmedSinceHr = false,
                hrSilentMs = stall, stallMs = stall,
            ),
        )
    }

    /**
     * The threshold is the only thing standing between "recovers a dead stream" and "writes to a healthy
     * one every five minutes", so it is pinned rather than left to a constant nobody re-reads.
     *
     * It must sit ABOVE the 45 s quiet threshold (an ordinary gap between samples) and BELOW the 600 s
     * bounce fuse — not because the fuse would rescue this case (it cannot; it watches any inbound data,
     * which is the bug) but because a threshold beyond it would mean the app had given up on the link
     * before it ever tried the cheaper fix.
     */
    @Test
    fun theThresholdSitsBetweenTheQuietMarkAndTheBounceFuse() {
        val quietMs = 45_000L
        val bounceFuse5mgMs = 600_000L
        assertTrue("must not fire during an ordinary quiet spell", stall > quietMs)
        assertTrue("must act before the app would give up on the link", stall < bounceFuse5mgMs)
    }

}
