package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #78 hole-4 salvage-probe gate ([WhoopBleClient.shouldSalvageProbe]): the one bounded
 * app-foreground attempt while the #747 bond-loop pause is latched. This is what makes the give-up
 * provably unable to strand a strap the user has since freed (a genuine bond on the probe fully resets
 * the pause) while never re-entering the refusal hammer (probe frequency is capped at one per foreground
 * per [WhoopBleClient.BOND_LOOP_SALVAGE_FLOOR_MS] window, and the give-up stays latched throughout).
 * Twin of the Swift `BondLoopHardeningTests` probe cases.
 */
class BondLoopSalvageProbeTest {

    private val floor = WhoopBleClient.BOND_LOOP_SALVAGE_FLOOR_MS

    @Test
    fun firesPastFloorWhilePaused() {
        assertTrue(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor))
        assertTrue(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor + 3_600_000L))
    }

    @Test
    fun respectsTheFloor() {
        // Below the floor no probe fires - back-to-back foregrounds can't chain attempts.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor - 1))
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = 0L))
    }

    @Test
    fun needsATripTimestamp() {
        // null ms = the pause never tripped this run = never probe.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = null))
    }

    @Test
    fun onlyWhilePaused() {
        // Not paused (the normal healthy path) never probes - the probe exists ONLY for the latched pause.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = false, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor))
    }

    @Test
    fun suppressedWhenConnectedOrUserTornDown() {
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = true,
            intentionalDisconnect = false, msSincePauseTripped = floor))
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = true, msSincePauseTripped = floor))
    }

    // #1539: the background escape.

    /**
     * The regression: a pause tripped while backgrounded had no escape at all. The foreground probe runs
     * from onActivityResumed, so a phone in a pocket never reaches it, and the paused branch suppressed the
     * one passive mechanism that could end the pause. A null elapsed time means "just tripped" — the moment
     * the parked connect must be armed, not skipped, which is where this gate differs from the probe's.
     */
    @Test
    fun justTrippedArmsTheParkedConnectImmediately() {
        assertTrue(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = null))
        // The foreground probe refuses the same input: it has no "first" attempt to arm.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = null))
    }

    /**
     * Refreshes stay floored, so a reachable strap that keeps refusing gets one attempt per window rather
     * than spinning connect -> refuse -> pause -> connect. The anti-hammering property the pause exists for
     * has to survive the escape.
     */
    @Test
    fun refreshesRemainFloored() {
        assertFalse(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = 0L))
        assertFalse(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor - 1))
        assertTrue(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor))
    }

    /** The same three refusals the foreground probe makes: not paused, already linked, user teardown. */
    @Test
    fun theThreeRefusalsMatchTheForegroundProbe() {
        assertFalse(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = false, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = null))
        assertFalse(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = true,
            intentionalDisconnect = false, msSincePauseTripped = null))
        assertFalse(WhoopBleClient.shouldStandingConnectWhilePaused(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = true, msSincePauseTripped = null))
    }
}
