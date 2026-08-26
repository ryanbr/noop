package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #982 give-up GAP fix. A WHOOP 4.0 that reaches STATE_CONNECTED and subscribes but never lands a
 * genuine bond can self-drop with status 0 at ~7s, BEFORE the escalating #971 bond watchdog fires. In that
 * case onBondWatchdog's recordBounce (which only counts its OWN localTerminate/0x16 bounce) never runs, and
 * the #617 loop detector skips it (never bonded, and status != GATT_CONN_TIMEOUT). Neither give-up counter
 * advanced, while STATE_CONNECTED zeroed the reconnect backoff every cycle — an unbounded connect/subscribe/
 * drop loop that drained the battery. [WhoopBleClient.shouldCountNeverBondedSelfDrop] is the pure gate that
 * feeds exactly (and only) that drop into the shared [BondWatchdogBackoff] give-up counter.
 *
 * The gate is deliberately narrow so a HEALTHY connect (didBond == true) and every other disconnect class is
 * untouched. Pure function -> no BLE seam needed, same shape as [BondWatchdogBackoffTest].
 */
class NeverBondedSelfDropGiveUpTest {

    private val STATUS_SELF_DROP = 0          // strap self-terminated (the #982 signature)
    private val STATUS_LOCAL_TERMINATE = 0x16 // GATT_CONN_TERMINATE_LOCAL_HOST — our own watchdog bounce

    /** The #982 case: connected, subscribed, never bonded, involuntary status-0 self-drop, first time. */
    @Test fun countsTheNeverBondedSelfDrop() {
        assertTrue(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** A healthy strap that bonded on the first connect (didBond == true) is NEVER counted — its behaviour
     *  is unchanged, so we don't manufacture a give-up on a normal transient post-bond drop. */
    @Test fun bondedDropIsNotCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = true, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** A connect that never reached STATE_CONNECTED (failedConnect) is a different path — not counted. */
    @Test fun failedConnectIsNotCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = false, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** A user-/app-initiated disconnect must never accrue toward the give-up. */
    @Test fun intentionalDisconnectIsNotCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = true,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** The stale-direct-bond fallback already has its own scan-recovery path (#78); don't double-handle it. */
    @Test fun staleDirectBondIsNotCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = true, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** Our OWN bond-watchdog bounce arrives as GATT_CONN_TERMINATE_LOCAL_HOST and was ALREADY counted by
     *  onBondWatchdog — excluding it here is what stops a single cycle being double-counted. */
    @Test fun ownLocalTerminateBounceIsNotDoubleCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_LOCAL_TERMINATE, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
    }

    /** Once we've already paused for the bond loop, stop counting — the guide is up and reconnect is off. */
    @Test fun alreadyPausedIsNotCounted() {
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = true, helloSuppressed = false,
            )
        )
    }

    /** Integration: repeated never-bonded self-drops accrue toward the SAME #971 counter and hand off at the
     *  give-up threshold (4) — and NOT before — bounding the loop instead of looping forever. */
    @Test fun repeatedSelfDropsGiveUpAtThreshold() {
        val backoff = BondWatchdogBackoff(giveUpThreshold = 4)
        // Mirror the handleDisconnect call: only recordBounce when the gate passes.
        fun cycle(): Boolean {
            val gate = WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = backoff.shouldGiveUp(),
                helloSuppressed = false,
            )
            return gate && backoff.recordBounce()
        }
        assertFalse("cycle 1 keeps trying", cycle())
        assertFalse("cycle 2 keeps trying", cycle())
        assertFalse("cycle 3 keeps trying", cycle())
        assertTrue("cycle 4 crosses the give-up threshold", cycle())
        assertEquals(4, backoff.consecutiveBounces)
    }

    /** Integration: a mixed streak of our own localTerminate bounces (counted by the watchdog, EXCLUDED
     *  here) interleaved with never-bonded self-drops (counted here) still converges to the shared
     *  threshold without either path double-counting the other. */
    @Test fun mixedWatchdogAndSelfDropStreakConverges() {
        val backoff = BondWatchdogBackoff(giveUpThreshold = 4)
        // cycle 1: our watchdog fired first (localTerminate) -> counted by the watchdog, gate excludes it.
        assertFalse(
            "self-drop gate excludes the watchdog's own localTerminate",
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_LOCAL_TERMINATE, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
        backoff.recordBounce() // the watchdog would have counted this cycle itself
        // cycles 2-4: the strap self-drops (status 0) before the watchdog — the gate counts these.
        repeat(2) {
            assertTrue(
                WhoopBleClient.shouldCountNeverBondedSelfDrop(
                    wasConnected = true, didBond = false, intentionalDisconnect = false,
                    staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
                )
            )
            assertFalse(backoff.recordBounce())
        }
        // the 4th total bounce (2 watchdog-style + this self-drop) crosses the shared threshold.
        assertTrue(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true, didBond = false, intentionalDisconnect = false,
                staleDirectBond = false, status = STATUS_SELF_DROP, alreadyPausedForBondLoop = false, helloSuppressed = false,
            )
        )
        assertTrue("shared streak crosses the give-up threshold at 4", backoff.recordBounce())
        assertEquals(4, backoff.consecutiveBounces)
    }

    @Test
    fun `a deliberately-suppressed strap is never counted as never-bonding`() {
        // #1635: hello suppression makes didBond permanently false ON PURPOSE. Without this exclusion every
        // ordinary drop - out of range, radio off, walking away from the phone - would look like "connects
        // but never pairs", march this counter to a pause, and hand the user a re-pair guide blaming a stale
        // pairing. Not-bonding is only evidence of a fault when we were actually trying to bond.
        assertFalse(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true,
                didBond = false,
                intentionalDisconnect = false,
                staleDirectBond = false,
                status = 0,
                alreadyPausedForBondLoop = false,
                helloSuppressed = true,
            )
        )
        // Same inputs, not suppressed: still counted, so the #982 protection is untouched.
        assertTrue(
            WhoopBleClient.shouldCountNeverBondedSelfDrop(
                wasConnected = true,
                didBond = false,
                intentionalDisconnect = false,
                staleDirectBond = false,
                status = 0,
                alreadyPausedForBondLoop = false,
                helloSuppressed = false,
            )
        )
    }
}
