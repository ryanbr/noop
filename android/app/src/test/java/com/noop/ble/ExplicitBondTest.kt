package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The #1635 explicit-bond experiment: when NOOP asks Android to pair, and what it says about it. */
class ExplicitBondTest {
    private fun ask(
        optedIn: Boolean = true,
        isWhoop5: Boolean = true,
        osBonded: Boolean = false,
        appBonded: Boolean = false,
        already: Boolean = false,
    ) = shouldRequestExplicitBond(optedIn, isWhoop5, osBonded, appBonded, already)

    @Test
    fun `off by default - nothing happens without opt-in`() {
        assertFalse(ask(optedIn = false))
    }

    @Test
    fun `never on a WHOOP 4 - it bonds fine and this is a 5-MG-only probe`() {
        assertFalse(ask(isWhoop5 = false))
    }

    @Test
    fun `an opted-in unbonded 5-MG is asked to pair`() {
        assertTrue(ask())
    }

    /**
     * The recurrence, stated so nothing downstream may treat this request as one-shot.
     *
     * On a strap that answers SMP "Pairing Not Supported" neither bond flag ever becomes true, and the
     * only remaining bound is per LINK — so with the switch on, this fires on every connect, forever. Code
     * that hangs a once-only side effect off "we asked to pair" is therefore doing it on every connect: on
     * 31 Aug that was clearing the hello-suppression latch, 36 times, which made the latch unable to end
     * the loop it exists to end.
     */
    @Test
    fun `asking recurs on every link, so it is not a once-only event`() {
        repeat(5) { assertTrue(ask(already = false)) }
    }

    @Test
    fun `an OS-level pairing already exists, so we do not ask again`() {
        assertFalse(ask(osBonded = true))
    }

    @Test
    fun `the app-level flag also suppresses it, though the two are unrelated`() {
        // encryptedBond has only ever meant "a handshake write was acked" — a strap can read Bonded in the
        // UI with no OS pairing at all. Both are checked because either being true means there is nothing
        // to gain from a pairing dialog.
        assertFalse(ask(appBonded = true))
    }

    @Test
    fun `one attempt per link - a retry cadence of seconds must not mean a dialog per retry`() {
        assertFalse(ask(already = true))
    }

    @Test
    fun `asking defers the hello, because doing both at once reproduces the bug`() {
        // Writing to the encrypted characteristic while a pairing is in flight is exactly what has been
        // dropping the link. The hello waits for the next connect, when the link may already be encrypted.
        assertTrue(explicitBondDefersHello(requestedThisLink = true))
        assertFalse(explicitBondDefersHello(requestedThisLink = false))
    }

    @Test
    fun `a refusal to START pairing does not read like a pairing that failed`() {
        val started = explicitBondRequestLine(initiated = true, bondStateName = "BOND_NONE")
        val refused = explicitBondRequestLine(initiated = false, bondStateName = "BOND_NONE")
        assertTrue(started.contains("asked Android to pair"))
        assertTrue(refused.contains("refused to START pairing"))
        assertFalse(refused.contains("watch the bond state lines"))
        assertEquals(false, started == refused)
    }

    @Test
    fun `a throw is reported as local, never as the strap refusing`() {
        // createBond needs BLUETOOTH_CONNECT. Swallowing a SecurityException into `false` would print a
        // confident claim about hardware for a problem that is entirely local - the failure mode this
        // whole investigation kept producing.
        val threw = explicitBondThrewLine("SecurityException", "BOND_NONE")
        val refused = explicitBondRequestLine(initiated = false, bondStateName = "BOND_NONE")
        assertTrue(threw.contains("local problem"))
        assertTrue(threw.contains("SecurityException"))
        assertFalse(threw.contains("refused to START pairing"))
        assertFalse(refused.contains("local problem"))
    }

    // #1635: the deferral is permanent unless the override breaks it

    /**
     * The capture that forced this. "Leave the hello for the next connect" assumed the pairing might
     * succeed; a 5/MG answers every Pairing Request with `Pairing Not Supported`, and the next connect
     * requests a bond and defers again. Two full btsnoop captures contain zero hello writes as a result.
     */
    @Test
    fun `without the override a requested bond defers the hello forever`() {
        assertTrue(explicitBondDefersHello(requestedThisLink = true))
        assertTrue(explicitBondDefersHello(requestedThisLink = true, helloOverride = false))
    }

    /** The override breaks the cycle — otherwise the switch is a no-op for everyone running the
     *  pairing experiment, which is exactly who would turn it on. */
    @Test
    fun `the override lets the hello through despite a requested bond`() {
        assertFalse(explicitBondDefersHello(requestedThisLink = true, helloOverride = true))
    }

    /** No bond requested means nothing to defer, override or not. */
    @Test
    fun `no bond request never defers`() {
        assertFalse(explicitBondDefersHello(requestedThisLink = false))
        assertFalse(explicitBondDefersHello(requestedThisLink = false, helloOverride = true))
    }

    /**
     * The regression this exists to end. Before [priorDeferrals], a strap that refuses SMP deferred the
     * hello on EVERY connect: no hello, no bond, no SET_CLOCK, and an un-clocked 5/MG banks nothing to
     * flash, so history sync stopped entirely and silently. Field-confirmed - four days without a sync and
     * not one hello written after the experiment was enabled.
     */
    @Test fun stopsDeferringOnceThePairingHasHadItsConnect() {
        // First connect after the bond request: defer, exactly as before.
        assertTrue(explicitBondDefersHello(requestedThisLink = true, priorDeferrals = 0))
        // Every connect after that: the answer is already in, so write the hello.
        assertFalse(explicitBondDefersHello(requestedThisLink = true, priorDeferrals = 1))
        assertFalse(explicitBondDefersHello(requestedThisLink = true, priorDeferrals = 13))
    }

    /** No bond requested on this link means there was never anything to defer around. */
    @Test fun neverDefersWhenNoBondWasRequested() {
        assertFalse(explicitBondDefersHello(requestedThisLink = false, priorDeferrals = 0))
        assertFalse(explicitBondDefersHello(requestedThisLink = false, priorDeferrals = 5))
    }

    /** The override still short-circuits the very first deferral, which is the whole point of that switch. */
    @Test fun theOverrideStillWinsOnTheFirstConnect() {
        assertFalse(explicitBondDefersHello(requestedThisLink = true, helloOverride = true, priorDeferrals = 0))
    }

    /**
     * The default keeps every existing caller honest: omitting priorDeferrals must behave like a FIRST
     * connect (defer), not like a strap that has already exhausted its chance. A default of 1 would have
     * silently disabled the deferral everywhere.
     */
    @Test fun theDefaultBehavesLikeAFirstConnect() {
        assertTrue(explicitBondDefersHello(requestedThisLink = true))
    }
}
