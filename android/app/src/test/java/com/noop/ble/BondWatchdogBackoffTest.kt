package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #971 WHOOP 4.0 bond-handshake watchdog pacer. A slow-but-healthy bond must get progressively
 * MORE time before the #50 watchdog bounces it, and a handshake that never completes must STOP bouncing
 * after a capped number of tries (surfacing the re-pair guide + pausing auto-reconnect) instead of looping
 * forever. Pure value type -> no BLE seam needed, same shape as [PostBondTimeoutLoopDetectorTest].
 */
class BondWatchdogBackoffTest {

    // The first (0-bounce) window is exactly the historical fixed 7s, so the common first connect is
    // unchanged. Each subsequent bounce widens the window by the step, capped at the ceiling.
    @Test fun windowEscalatesPerBounceAndCaps() {
        val b = BondWatchdogBackoff(baseWindowMs = 7_000L, stepMs = 3_000L, maxWindowMs = 16_000L)
        assertEquals("0 bounces => historical 7s (unchanged first connect)", 7_000L, b.windowMsForAttempt(0))
        assertEquals(10_000L, b.windowMsForAttempt(1))
        assertEquals(13_000L, b.windowMsForAttempt(2))
        assertEquals(16_000L, b.windowMsForAttempt(3))
        // Past the cap the window holds at the ceiling — a dead handshake can't wait minutes.
        assertEquals("capped at the ceiling", 16_000L, b.windowMsForAttempt(4))
        assertEquals(16_000L, b.windowMsForAttempt(99))
    }

    // A negative / uninitialised prior-bounce count coerces to the base window, never a sub-base value.
    @Test fun negativePriorBouncesCoerceToBase() {
        val b = BondWatchdogBackoff(baseWindowMs = 7_000L, stepMs = 3_000L, maxWindowMs = 16_000L)
        assertEquals(7_000L, b.windowMsForAttempt(-5))
    }

    // currentWindowMs() reflects the bounces recorded so far: it widens after each bounce, so the NEXT
    // armed watchdog is the wider window.
    @Test fun currentWindowTracksRecordedBounces() {
        val b = BondWatchdogBackoff(baseWindowMs = 7_000L, stepMs = 3_000L, maxWindowMs = 16_000L, giveUpThreshold = 4)
        assertEquals(7_000L, b.currentWindowMs())     // no bounces yet
        b.recordBounce(attributable = true)
        assertEquals(10_000L, b.currentWindowMs())    // one bounce -> next window is wider
        b.recordBounce(attributable = true)
        assertEquals(13_000L, b.currentWindowMs())
    }

    // We do NOT give up on the first few bounces — a slow bond just needs a wider window. Give-up fires
    // exactly once, on the bounce that crosses the threshold.
    @Test fun givesUpOnceAtThreshold() {
        val b = BondWatchdogBackoff(giveUpThreshold = 4)
        assertFalse("bounce 1 keeps bouncing", b.recordBounce(attributable = true))
        assertFalse(b.shouldGiveUp())
        assertFalse("bounce 2 keeps bouncing", b.recordBounce(attributable = true))
        assertFalse("bounce 3 keeps bouncing", b.recordBounce(attributable = true))
        assertTrue("bounce 4 crosses the cap -> give up (fresh)", b.recordBounce(attributable = true))
        assertTrue(b.shouldGiveUp())
        assertEquals(4, b.consecutiveBounces)
        // Already gave up -> no second "freshly gave up" signal (the caller surfaces the guide once).
        assertFalse("no repeat give-up signal once tripped", b.recordBounce(attributable = true))
        assertTrue(b.shouldGiveUp())
    }

    // A genuine bond (or user reconnect) clears the streak: the next slow handshake starts at the tight
    // base window and can escalate + give up afresh.
    @Test fun resetClearsStreakAndReArmsBaseWindow() {
        val b = BondWatchdogBackoff(baseWindowMs = 7_000L, stepMs = 3_000L, maxWindowMs = 16_000L, giveUpThreshold = 4)
        repeat(4) { b.recordBounce(attributable = true) }
        assertTrue(b.shouldGiveUp())
        assertEquals(16_000L, b.currentWindowMs())

        b.reset()
        assertFalse("give-up cleared after reset", b.shouldGiveUp())
        assertEquals(0, b.consecutiveBounces)
        assertEquals("window back to the tight base after a genuine bond", 7_000L, b.currentWindowMs())

        // And it can escalate + give up again, exactly like the first cycle.
        assertFalse(b.recordBounce(attributable = true))
        assertEquals(10_000L, b.currentWindowMs())
    }

    // The default configuration is the shipped one: base 7s, +3s per bounce, 16s ceiling, give up at 4.
    @Test fun defaultsMatchShippedConfig() {
        val b = BondWatchdogBackoff()
        assertEquals(7_000L, b.windowMsForAttempt(0))
        assertEquals(10_000L, b.windowMsForAttempt(1))
        assertEquals(13_000L, b.windowMsForAttempt(2))
        assertEquals(16_000L, b.windowMsForAttempt(3))
        assertEquals(16_000L, b.windowMsForAttempt(4))
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.recordBounce(attributable = true))
        assertTrue("default give-up threshold is 4", b.recordBounce(attributable = true))
    }

    /**
     * The 5h 57m pause, as a unit test.
     *
     * Four bounces on links whose service discovery never returned must NOT reach the give-up: nothing
     * was discovered, no handshake was written, and the strap was never asked anything. The window still
     * escalates on each, because a slow link genuinely should get longer before the next bounce.
     */
    @Test
    fun bouncesBeforeDiscoveryReturnsNeverReachTheGiveUp() {
        val b = BondWatchdogBackoff()
        repeat(10) { assertFalse(b.recordBounce(attributable = false)) }
        assertFalse(b.shouldGiveUp())
        assertEquals(0, b.attributableBounces)
        assertEquals(10, b.consecutiveBounces)
        // The window still escalated, capped, exactly as it would have.
        assertEquals(b.windowMsForAttempt(10), b.currentWindowMs())
    }

    /** A link that DID discover still gives up on the fourth, so the #971 behaviour is unchanged. */
    @Test
    fun attributableBouncesStillGiveUpOnTheFourth() {
        val b = BondWatchdogBackoff()
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.recordBounce(attributable = true))
        assertTrue(b.recordBounce(attributable = true))
        assertTrue(b.shouldGiveUp())
    }

    /** Unattributable bounces in between must not shorten the runway for the real ones. */
    @Test
    fun unattributableBouncesDoNotCountTowardTheThreshold() {
        val b = BondWatchdogBackoff()
        repeat(3) { b.recordBounce(attributable = false) }
        assertFalse(b.recordBounce(attributable = true))
        repeat(3) { b.recordBounce(attributable = false) }
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.recordBounce(attributable = true))
        assertFalse(b.shouldGiveUp())
        assertTrue(b.recordBounce(attributable = true))
    }

    /** reset() clears both counters, or a post-bond link would carry the old attributable streak. */
    @Test
    fun resetClearsTheAttributableStreakToo() {
        val b = BondWatchdogBackoff()
        repeat(2) { b.recordBounce(attributable = true) }
        b.recordBounce(attributable = false)
        b.reset()
        assertEquals(0, b.attributableBounces)
        assertEquals(0, b.consecutiveBounces)
        assertFalse(b.shouldGiveUp())
    }

    /**
     * The give-up line quotes [BondWatchdogBackoff.attributableBounces], so the two counters must be
     * separately readable and must not drift apart silently. A mixed run is the realistic shape on a
     * weak link: several bounces before the command channel exists, then the real handshake attempts.
     */
    @Test
    fun theTwoCountersAreReportedSeparately() {
        val b = BondWatchdogBackoff()
        repeat(8) { b.recordBounce(attributable = false) }
        repeat(2) { b.recordBounce(attributable = true) }
        assertEquals(10, b.consecutiveBounces)
        assertEquals(2, b.attributableBounces)
        assertFalse(b.shouldGiveUp())
    }

    /**
     * The regression the attributability split would otherwise have introduced: excusing these bounces
     * from the pairing give-up must not hand them an unbounded loop instead.
     */
    @Test
    fun unattributableBouncingIsItselfBounded() {
        val b = BondWatchdogBackoff()
        repeat(3) {
            b.recordBounce(attributable = false)
            assertFalse(b.shouldStopBouncingWithoutCommandChannel())
        }
        b.recordBounce(attributable = false)
        assertTrue(b.shouldStopBouncingWithoutCommandChannel())
        // ...and it is still NOT the pairing give-up, which is the point of keeping them apart.
        assertFalse(b.shouldGiveUp())
        assertEquals(0, b.attributableBounces)
    }

    /** The two caps are independent: real handshake attempts are not spent by weak-link bounces. */
    @Test
    fun theTwoCapsDoNotConsumeEachOther() {
        val b = BondWatchdogBackoff()
        repeat(4) { b.recordBounce(attributable = false) }
        assertTrue(b.shouldStopBouncingWithoutCommandChannel())
        assertFalse(b.shouldGiveUp())
        repeat(3) { assertFalse(b.recordBounce(attributable = true)) }
        assertTrue(b.recordBounce(attributable = true))
        assertTrue(b.shouldGiveUp())
    }

    @Test
    fun resetClearsTheUnattributableCapToo() {
        val b = BondWatchdogBackoff()
        repeat(5) { b.recordBounce(attributable = false) }
        assertTrue(b.shouldStopBouncingWithoutCommandChannel())
        b.reset()
        assertEquals(0, b.unattributableBounces)
        assertFalse(b.shouldStopBouncingWithoutCommandChannel())
    }
}
