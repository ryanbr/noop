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
     * The paragraph fires once per CONNECT on a path documented to loop (57 cycles in an hour), so the
     * full text is one-shot and later occurrences must stay countable but terse. If the short form
     * dropped the count it would be unreadable; if it kept the paragraph it would bury the capture.
     */
    @Test
    fun `the repeat form keeps the count but drops the guidance`() {
        val terse = helloDeferredByExplicitBondLine(9, overrideOptedIn = false, overrideAttempts = 0,
                                                    full = false)
        assertTrue("the count is the point of the repeat", terse.contains("9 consecutive connects"))
        assertTrue(terse.contains("see the first occurrence above"))
        assertFalse("advice already given must not repeat", terse.contains("pairing experiment OFF"))
        assertFalse(terse.contains("SMP 0x05"))
        // A FIRST occurrence is unaffected by the flag: there is no guidance to suppress yet.
        val firstShort = helloDeferredByExplicitBondLine(1, false, 0, full = false)
        assertTrue(firstShort.contains("Deferred once so far"))
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
        assertTrue(off.contains("experiment ON, hello override off"))
        assertTrue(on.contains("experiment ON, hello override on (2/6 used)"))
        assertTrue(spent.contains("experiment ON, hello override SPENT (6/6)"))
        assertFalse("a spent override must not read as active", spent.contains("override on ("))
        // The sentence names the EXPERIMENT; the parenthetical must not report only the OTHER switch.
        for (line in listOf(off, on, spent)) {
            assertTrue("both switches must be named: $line", line.contains("experiment ON"))
        }
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

    /**
     * `connectedFamily` defaults to WHOOP4 and otherwise holds the PREVIOUS link's value, so before
     * service discovery it is a guess. Printing a guess would break the same rule the hello line follows
     * — and a guess of WHOOP4 would suppress the explanation on exactly the 5/MG this was built for.
     */
    @Test
    fun `an unestablished family is not guessed and gets no explanation`() {
        val line = backfillDeferredLine(null, false, false, true, 1, 5_000L)
        assertTrue(line.contains("family=unestablished"))
        assertFalse("a guessed family must not appear", line.contains("family=WHOOP4"))
        assertFalse("the explanation must not ride on an unknown family",
                    line.contains("No hello was written"))
    }

    /** An unknown connect time must render as unknown, never as 0s — which would read as "just now". */
    @Test
    fun `an unknown connect time is not reported as zero seconds`() {
        assertTrue(backfillDeferredLine("WHOOP5", false, false, true, 1, -1L).contains("sinceConnect=?"))
        assertTrue(backfillDeferredLine("WHOOP5", false, false, true, 1, 0L).contains("sinceConnect=0s"))
    }

    // ---- liveInsertFailedLine -----------------------------------------------------------------

    /**
     * Two live transports fail independently (#1118). A line that did not say which would leave a reader
     * unable to separate one dead transport from a dead store — the first fork in the diagnosis.
     */
    @Test
    fun `the failing transport is named`() {
        assertTrue(liveInsertFailedLine("live-standard", "E", null, 1, 1, 1).contains("on live-standard"))
        assertTrue(liveInsertFailedLine("live-realtime", "E", null, 1, 1, 1).contains("on live-realtime"))
    }

    @Test
    fun `one failure reads as transient and a run reads as not recovering`() {
        val once = liveInsertFailedLine("live-standard", "SQLiteFullException", "database or disk is full", 12, 13, 1)
        assertTrue(once.contains("Re-buffered for the next cadence"))
        assertFalse(once.contains("consecutive failures"))

        val many = liveInsertFailedLine("live-standard", "SQLiteFullException", "database or disk is full", 12, 13, 9)
        assertTrue(many.contains("9 consecutive failures"))
        assertTrue(many.contains("not recovering them"))
    }

    /**
     * Whole-line equality against the SAME literal the Swift `LivePersistTraceTests` pins, not `contains`.
     * The two platforms emit this line into logs meant to be read beside each other, and every
     * `contains` check above would still pass with a stray space or a moved clause. This is the
     * assertion that actually holds them together.
     */
    @Test
    fun `the whole line matches the Swift rendering byte for byte`() {
        assertEquals(
            "Live persist FAILED on live-standard — SQLiteFullException: database or disk is full" +
                " (hr=12 rr=13). 9 consecutive failures — these rows are not landing and the re-buffer" +
                " is not recovering them.",
            liveInsertFailedLine("live-standard", "SQLiteFullException", "database or disk is full",
                                 hrFrames = 12, rrFrames = 13, consecutiveFailures = 9),
        )
        assertEquals(
            "Live persist FAILED on live-realtime — IllegalStateException (hr=0 rr=4)." +
                " Re-buffered for the next cadence.",
            liveInsertFailedLine("live-realtime", "IllegalStateException", null,
                                 hrFrames = 0, rrFrames = 4, consecutiveFailures = 1),
        )
    }

    /** The message distinguishes the useful cases; the class alone rarely does. */
    @Test
    fun `the throwable message survives and is bounded`() {
        val line = liveInsertFailedLine("live-realtime", "IllegalStateException", "x".repeat(500), 1, 2, 1)
        assertTrue(line.contains("IllegalStateException"))
        assertTrue(line.contains("x".repeat(200)))
        assertFalse("an unbounded message would swamp the capture", line.contains("x".repeat(201)))
    }

    @Test
    fun `a blank or absent message does not leave a dangling separator`() {
        assertFalse(liveInsertFailedLine("live-realtime", "IllegalStateException", null, 1, 2, 1).contains(": ("))
        assertFalse(liveInsertFailedLine("live-realtime", "IllegalStateException", "   ", 1, 2, 1).contains(": ("))
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

    // ---- caller-side contract -----------------------------------------------------------------

    /**
     * The builders above are pure and testable; the two invariants that actually decide whether they
     * print the truth live in `WhoopBleClient`, which no JVM test can construct. Both were WRONG in the
     * first version of this change and neither failure would have been caught by anything above, so they
     * are pinned against the source the way `RawCaptureExportContractTest` pins the collector's.
     */
    private fun clientSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        error("WhoopBleClient.kt not found — this test must not pass by default")
    }

    /**
     * `familyEstablished` must be read BEFORE `connectedFamily`, and the family passed as null when it is
     * false. `connectedFamily` is non-null and defaults to WHOOP4, so the naive read puts a guess in the
     * log — and a guessed WHOOP4 suppresses the explanation on precisely the 5/MG case this exists for.
     * The ordering additionally carries the happens-before that makes the family read safe at all, which
     * is the same rule `batterySource(familyEstablished, connectedFamily)` is documented to follow.
     */
    @Test
    fun `the backfill line never reports a guessed family`() {
        val src = clientSource()
        assertTrue("familyEstablished must be latched before the family is read",
                   src.contains("val established = familyEstablished"))
        assertTrue("an unestablished family must be passed as null, not guessed",
                   src.contains("family = if (established) connectedFamily.name else null"))
    }

    /**
     * A CLIENT_HELLO the stack REJECTED never went out, so nothing may claim one was written: that would
     * suppress the "no hello was written" explanation on a link where it is exactly right, since a
     * rejected write can never be acked and didBond can never become true.
     *
     * Asserted as an ORDERING rather than a presence, because the first version of this passed a
     * presence check while still being wrong — it set the flag before the stack call and cleared it
     * afterwards, which both opened a window for a concurrent reader and cleared the deferral run on an
     * attempt that had failed.
     */
    @Test
    fun `a hello is only counted as written after the stack accepts it`() {
        val fn = clientSource()
            .substringAfter("private fun writeClientHello(")
            .substringBefore("\n    }")
        val call = fn.indexOf("val ok = safeGatt(\"writeClientHello\")")
        val claim = fn.indexOf("helloWrittenThisLink = true")
        val run = fn.indexOf("setHelloDeferredRun(0)")   // -1 once the write no longer clears it
        assertTrue("writeClientHello must call safeGatt", call >= 0)
        assertTrue("the write must be claimed, somewhere", claim >= 0)
        assertTrue("helloWrittenThisLink must be set AFTER the stack accepts", claim > call)
        // The run must NOT be cleared here at all any more. A written-but-unacked hello is not a working
        // handshake, and clearing on the write reset the count on every watchdog bounce - so the strap
        // alternated defer/write/bounce indefinitely instead of letting the #1635 suppression latch bound
        // the attempts. Only a genuine bond ends the run.
        assertEquals("writeClientHello must not clear the deferral run", -1, run)
    }

    /**
     * The deferral run must SURVIVE a process restart, which is the only reason it is in
     * SharedPreferences rather than a field. A field log is usually exported well after the restart that
     * would have reset it, and a run of 1 prints "expected on the connect that asks" - the opposite of
     * the truth for a strap that has never once completed a handshake. Field-backed, that read is exactly
     * what the first version of this got wrong.
     */
    @Test
    fun `the deferral run is persisted rather than held in memory`() {
        val src = clientSource()
        assertTrue("the run must be READ from prefs at the deferral site",
                   src.contains("val deferralRun = helloDeferredRun() + 1"))
        assertTrue("and written straight back", src.contains("setHelloDeferredRun(deferralRun)"))
        assertTrue("the line must report the persisted value", src.contains("consecutive = deferralRun,"))
        // Cleared exactly where the run genuinely ends: a hello that went out, and a genuine bond.
        assertTrue(src.contains("setHelloDeferredRun(0)        // the handshake works on this strap"))
        // ...and NOT in reset(), which runs on every disconnect and would defeat the whole point.
        val resetBody = src.substringAfter("private fun reset() {").substringBefore("\n    }")
        assertFalse("reset() must not clear the cross-connection run",
                    resetBody.contains("setHelloDeferredRun"))
    }

    @Test
    fun `the default gap is one minute`() {
        assertEquals(true, shouldEmitLiveInsertFailure(1L, 60_001L))
        assertEquals(false, shouldEmitLiveInsertFailure(1L, 30_000L))
    }
    // Standard-HR transport lines — byte-identical twins of Swift's LivePersistTrace.

    /**
     * The expected strings are copied from the Swift `LivePersistTraceTests`, not regenerated from the
     * Kotlin. That is the point: a twin asserted against its own implementation proves only that the
     * implementation is self-consistent, and these two lines exist so an Android and an Apple log of the
     * same stall compare directly.
     */
    @Test
    fun `flush success separates offered from actually inserted rows`() {
        assertEquals(
            "standard-hr transport flush-attempt reason=cadence offeredHRRows=4 offeredRRRows=5",
            standardHrFlushAttemptLine(StandardHrFlushReason.CADENCE.raw, 4, 5),
        )
        // Offered 4/5 and inserted 1/2 is the failure that reads like success: the batch was accepted by
        // the call and mostly discarded by the store. Only the store's own count shows it.
        assertEquals(
            "standard-hr transport flush-succeeded reason=cadence offeredHRRows=4 offeredRRRows=5" +
                " insertedHRRows=1 insertedRRRows=2",
            standardHrFlushSucceededLine(StandardHrFlushReason.CADENCE.raw, 4, 5, 1, 2),
        )
    }

    @Test
    fun `retry names the lifecycle reason and the total pending rows`() {
        assertEquals(
            "standard-hr transport rebuffered-for-retry reason=disconnect" +
                " attemptedHRRows=1 attemptedRRRows=2 pendingHRRows=3 pendingRRRows=4" +
                " consecutiveFailures=1",
            standardHrRebufferedForRetryLine(StandardHrFlushReason.DISCONNECT.raw, 1, 2, 3, 4, 1),
        )
    }

    /**
     * The raw values are what the log line carries, so they are the parity surface — not the enum's
     * Kotlin spelling. background and termination have no Android emitter today (the foreground service
     * gives no suspension edge); they exist so the two enums cannot drift apart before one does.
     */
    @Test
    fun `the flush reasons match the Swift raw values exactly`() {
        assertEquals(
            listOf("cadence", "disconnect", "background", "termination", "explicit"),
            StandardHrFlushReason.entries.map { it.raw },
        )
    }

}
