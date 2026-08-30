package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * These lines exist to make one specific field state readable — a 5/MG streaming live HR while banking
 * nothing — so the tests assert the DISTINCTIONS a reader depends on, not the prose around them.
 *
 * Android-only, like [ExplicitBond] itself: CoreBluetooth has no explicit pairing API, so there is no
 * Swift twin to hold a byte-identical oracle against and an audit finding this one-sided should leave it.
 */
class StalledLinkDiagnosticsTest {

    // ---- helloDeferredByExplicitBondLine ------------------------------------------------------

    /**
     * One deferral is the experiment behaving as designed; a run of them is the permanent state. If both
     * rendered the same, the line would be decoration — this is the distinction it exists to draw.
     */
    @Test
    fun `a single deferral does not claim the permanent state`() {
        val once = helloDeferredByExplicitBondLine(1, overrideOptedIn = false, overrideAttempts = 0)
        assertTrue(once.contains("Deferred once so far"))
        assertFalse("a single deferral must not assert permanence", once.contains("consecutive connects"))
        assertFalse(once.contains("SMP 0x05"))
    }

    @Test
    fun `a run of deferrals names the permanent state and both escapes`() {
        val many = helloDeferredByExplicitBondLine(47, overrideOptedIn = false, overrideAttempts = 0)
        assertTrue(many.contains("47 consecutive connects"))
        assertTrue("the cause must be named, not implied", many.contains("SMP 0x05"))
        // Both remedies, because either one alone leaves a reader stuck.
        assertTrue(many.contains("pairing experiment OFF"))
        assertTrue(many.contains("hello override ON"))
        // The consequence that actually costs data is the un-clocked strap, not the missing sync.
        assertTrue(many.contains("does not persist its own sensor data to flash"))
    }

    /**
     * The #1635 rule in CLAUDE.md: a diagnostic may only assert what it can attribute. SMP 0x05 is not
     * observable from this process — it needs an HCI capture — so the line must mark it as the cited
     * cause and keep the locally measured facts separate. A future edit that collapses the two into a
     * flat "the strap refuses pairing" fails here, which is the point.
     */
    @Test
    fun `the cited cause is not asserted as observed on this link`() {
        val many = helloDeferredByExplicitBondLine(47, overrideOptedIn = false, overrideAttempts = 0)
        assertTrue("what was measured must be labelled as such", many.contains("Observed on this link:"))
        assertTrue("the cited cause must be hedged", many.contains("only an HCI capture can confirm it HERE"))
        // The consequence, unlike the cause, IS local and may be stated flatly.
        assertTrue(many.contains("local and certain"))
    }

    /**
     * A spent override must not read as an untried option — that is the `didBond`-reader trap pointed at
     * the log: a reader who sees "override on" stops looking for why no hello went out.
     */
    @Test
    fun `override state distinguishes off from on from spent`() {
        val off = helloDeferredByExplicitBondLine(3, overrideOptedIn = false, overrideAttempts = 0)
        val on = helloDeferredByExplicitBondLine(3, overrideOptedIn = true, overrideAttempts = 2)
        val spent = helloDeferredByExplicitBondLine(3, overrideOptedIn = true, overrideAttempts = 6)
        assertTrue(off.contains("override off"))
        assertTrue(on.contains("override on (2/6 used)"))
        assertTrue(spent.contains("override SPENT (6/6)"))
        assertFalse("a spent override must not read as active", spent.contains("override on ("))
    }

    /** The boundary is the cap itself: the attempt that spends the budget is the last permitted one. */
    @Test
    fun `the override reads spent exactly at the cap`() {
        assertTrue(helloDeferredByExplicitBondLine(3, true, HELLO_OVERRIDE_MAX_ATTEMPTS - 1).contains("override on"))
        assertTrue(helloDeferredByExplicitBondLine(3, true, HELLO_OVERRIDE_MAX_ATTEMPTS).contains("override SPENT"))
    }

    // ---- backfillDeferredLine -----------------------------------------------------------------

    /**
     * The unreachable case — WHOOP5, unbonded, no hello ever written — is the one that needs explaining,
     * and it must not be claimed for any other combination or the sentence stops meaning anything.
     */
    @Test
    fun `only the structurally unreachable case gets the explanation`() {
        val unreachable = backfillDeferredLine("WHOOP5", false, false, true, 3, 42_000L)
        assertTrue(unreachable.contains("No hello was written on this link"))
        assertTrue(unreachable.contains("didBond cannot become true"))
        assertTrue(unreachable.contains("SET_CLOCK rides the same handshake tail"))

        // A hello WAS written and went unanswered: a different problem with a different fix.
        assertFalse(backfillDeferredLine("WHOOP5", false, true, true, 3, 42_000L)
            .contains("No hello was written"))
        // WHOOP4 does not gate the handshake on didBond at all.
        assertFalse(backfillDeferredLine("WHOOP4", false, false, false, 1, 5_000L)
            .contains("No hello was written"))
        // Already bonded: the gate is about to open.
        assertFalse(backfillDeferredLine("WHOOP5", true, true, false, 1, 5_000L)
            .contains("No hello was written"))
    }

    @Test
    fun `the state that decided it is all present`() {
        val line = backfillDeferredLine("WHOOP5", false, false, true, 3, 42_000L)
        assertTrue(line.contains("family=WHOOP5"))
        assertTrue(line.contains("didBond=false"))
        assertTrue(line.contains("helloWrittenThisLink=false"))
        assertTrue(line.contains("bondRequestedThisLink=true"))
        assertTrue(line.contains("deferrals=3"))
        assertTrue(line.contains("sinceConnect=42s"))
    }

    /** An unknown connect time must render as unknown, never as 0s — which would read as "just now". */
    @Test
    fun `an unknown connect time is not reported as zero seconds`() {
        assertTrue(backfillDeferredLine("WHOOP5", false, false, true, 1, -1L).contains("sinceConnect=?"))
        assertTrue(backfillDeferredLine("WHOOP5", false, false, true, 1, 0L).contains("sinceConnect=0s"))
    }

    // ---- liveInsertFailedLine -----------------------------------------------------------------

    @Test
    fun `one failure reads as transient and a run reads as not recovering`() {
        val once = liveInsertFailedLine("SQLiteFullException", "database or disk is full", 12, 13, 1)
        assertTrue(once.contains("Re-buffered for the next cadence"))
        assertFalse(once.contains("consecutive failures"))

        val many = liveInsertFailedLine("SQLiteFullException", "database or disk is full", 12, 13, 9)
        assertTrue(many.contains("9 consecutive failures"))
        assertTrue(many.contains("not recovering them"))
    }

    /** The message distinguishes the useful cases; the class alone rarely does. */
    @Test
    fun `the throwable message survives and is bounded`() {
        val line = liveInsertFailedLine("IllegalStateException", "x".repeat(500), 1, 2, 1)
        assertTrue(line.contains("IllegalStateException"))
        assertTrue(line.contains("x".repeat(200)))
        assertFalse("an unbounded message would swamp the capture", line.contains("x".repeat(201)))
    }

    @Test
    fun `a blank or absent message does not leave a dangling separator`() {
        assertFalse(liveInsertFailedLine("IllegalStateException", null, 1, 2, 1).contains(": ("))
        assertFalse(liveInsertFailedLine("IllegalStateException", "   ", 1, 2, 1).contains(": ("))
    }

    // ---- shouldEmitLiveInsertFailure ----------------------------------------------------------

    /**
     * The first failure is the one most worth having. Treating "never emitted" as "just emitted" would
     * silence exactly the case this was built for, so the zero case is asserted rather than assumed.
     */
    @Test
    fun `the first failure always emits`() {
        assertTrue(shouldEmitLiveInsertFailure(lastEmitMs = 0L, nowMs = 1_000L))
        assertTrue(shouldEmitLiveInsertFailure(lastEmitMs = -5L, nowMs = 1_000L))
    }

    @Test
    fun `the gap is honoured at its boundary`() {
        assertFalse(shouldEmitLiveInsertFailure(lastEmitMs = 1_000L, nowMs = 60_999L))
        assertTrue(shouldEmitLiveInsertFailure(lastEmitMs = 1_000L, nowMs = 61_000L))
    }

    /**
     * A clock that steps backwards must not latch the line off. Comparing only forwards would strand
     * `lastEmitMs` in the future and silence the line until real time caught up — for a large step,
     * indefinitely. This is the assertion that forced the guard: the naive version fails it.
     */
    @Test
    fun `a backwards clock emits rather than latching off`() {
        assertTrue(shouldEmitLiveInsertFailure(lastEmitMs = 10_000L, nowMs = 5_000L))
        assertTrue(shouldEmitLiveInsertFailure(lastEmitMs = Long.MAX_VALUE / 2, nowMs = 1_000L))
    }

    @Test
    fun `the default gap is one minute`() {
        assertEquals(true, shouldEmitLiveInsertFailure(1L, 60_001L))
        assertEquals(false, shouldEmitLiveInsertFailure(1L, 30_000L))
    }
}
