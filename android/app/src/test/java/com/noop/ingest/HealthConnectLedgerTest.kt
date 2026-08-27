package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1677: a Health Connect record NOOP stops writing is a record NOOP can no longer take back, because
 * Health Connect never removes an id you simply stop producing. These rules decide which previously
 * written ids an export retracts — and, far more importantly, which it must leave alone.
 */
class HealthConnectLedgerTest {

    private val p = HealthConnectLedger.SLEEP_PREFIX
    private val now = 1_800_000_000L
    private val windowStart = now - 60L * 86_400L

    private fun id(ts: Long) = "$p$ts"

    /**
     * The reported bug, end to end. A partial night exported mid-sync under its own start; the heal then
     * replaced that row with a fuller copy starting earlier, so the next export produces a DIFFERENT id
     * and the first record had nothing left pointing at it.
     */
    @Test
    fun `an id the export no longer produces is retracted`() {
        val partial = id(now - 3 * 86_400)          // written during the strap sync
        val full = id(now - 3 * 86_400 - 7_200)     // same night, re-detected two hours earlier
        val stale = HealthConnectLedger.staleClientIds(
            previous = setOf(partial), current = setOf(full),
            prefix = p, windowStartSec = windowStart, nowSec = now,
        )
        assertEquals(listOf(partial), stale)
    }

    /** An id still being produced is an upsert, not a retraction. */
    @Test
    fun `an id still produced is never retracted`() {
        val keep = id(now - 86_400)
        assertTrue(
            HealthConnectLedger.staleClientIds(
                previous = setOf(keep), current = setOf(keep),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ).isEmpty(),
        )
    }

    /**
     * THE one that matters most. The export covers a rolling window, so a night that simply aged out is
     * absent from `current` while its record is perfectly good. Retracting on absence alone would delete
     * the user's history — the failure this rule exists to prevent, not a side note.
     */
    @Test
    fun `a night that merely aged out of the window is left alone`() {
        val old = id(windowStart - 86_400)           // one day older than this export could see
        assertTrue(
            HealthConnectLedger.staleClientIds(
                previous = setOf(old), current = emptySet(),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ).isEmpty(),
        )
    }

    /** The boundaries are inclusive, so the window's own edges are covered rather than skipped. */
    @Test
    fun `the window edges are inclusive`() {
        val edges = setOf(id(windowStart), id(now))
        assertEquals(
            edges.sorted(),
            HealthConnectLedger.staleClientIds(
                previous = edges, current = emptySet(),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ),
        )
    }

    /** A future-dated id is not something this export spoke about either. */
    @Test
    fun `an id past the window's end is left alone`() {
        assertTrue(
            HealthConnectLedger.staleClientIds(
                previous = setOf(id(now + 3_600)), current = emptySet(),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ).isEmpty(),
        )
    }

    /**
     * An id whose timestamp will not parse is not ours to reason about. Abstaining costs one stale row;
     * guessing costs the user's data, so the tie is broken toward doing nothing.
     */
    @Test
    fun `an unparseable id is never retracted`() {
        val junk = setOf("${p}not-a-number", "noop-sleep-", "some-other-app-record")
        assertTrue(
            HealthConnectLedger.staleClientIds(
                previous = junk, current = emptySet(),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ).isEmpty(),
        )
    }

    /** Deterministic order, so a log line and a test read the same sequence. */
    @Test
    fun `retractions come back sorted`() {
        val a = id(now - 5 * 86_400); val b = id(now - 2 * 86_400); val c = id(now - 9 * 86_400)
        assertEquals(
            listOf(a, b, c).sorted(),
            HealthConnectLedger.staleClientIds(
                previous = setOf(b, c, a), current = emptySet(),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ),
        )
    }

    /** The workout ids share the shape, so the rule has to be prefix-agnostic rather than sleep-shaped. */
    @Test
    fun `the rule works for any prefixed id`() {
        val w = HealthConnectLedger.WORKOUT_PREFIX
        assertEquals(
            listOf("$w${now - 86_400}"),
            HealthConnectLedger.staleClientIds(
                previous = setOf("$w${now - 86_400}"), current = emptySet(),
                prefix = w, windowStartSec = windowStart, nowSec = now,
            ),
        )
    }

    // --- what the ledger carries forward ---

    /**
     * The defect this guards is one I shipped in the first version of this change: remembering only the
     * ids just written. A retraction that FAILED still has a live record behind it, and dropping its id
     * forgets it forever — the exact orphan this file exists to prevent, reintroduced through the error
     * path. Anyone "simplifying" this back to `current` should fail here.
     */
    @Test
    fun `a failed retraction stays on the books for the next export`() {
        val written = setOf(id(now - 86_400))
        val couldNotDelete = setOf(id(now - 4 * 86_400))
        val next = HealthConnectLedger.ledgerAfterExport(written, couldNotDelete)
        assertTrue(next.containsAll(written))
        assertTrue(next.containsAll(couldNotDelete))
    }

    /** And it is retried: still in `previous`, still absent from `current`, still inside the window. */
    @Test
    fun `the carried-forward id is retracted again next time`() {
        val stuck = id(now - 4 * 86_400)
        val next = HealthConnectLedger.ledgerAfterExport(setOf(id(now - 86_400)), setOf(stuck))
        assertEquals(
            listOf(stuck),
            HealthConnectLedger.staleClientIds(
                previous = next, current = setOf(id(now - 86_400)),
                prefix = p, windowStartSec = windowStart, nowSec = now,
            ),
        )
    }

    /** Nothing failed: the ledger is exactly what was written, so it cannot grow without cause. */
    @Test
    fun `a clean export carries nothing extra`() {
        val written = setOf(id(now - 86_400), id(now - 2 * 86_400))
        assertEquals(written, HealthConnectLedger.ledgerAfterExport(written, emptySet()))
    }

    // --- one ledger per strap ---

    /**
     * The regression this keying prevents, and it is a data-loss one. The export is device-scoped:
     * `sleepSessionsMerged(deviceId)` reads that strap union the canonical id, so a night banked under a
     * DIFFERENT strap is simply not in its result. Share one ledger and an export running as strap B
     * finds strap A's ids absent-but-in-window and retracts them — deleting valid Health Connect records
     * because the user switched which strap is active.
     */
    @Test
    fun `two straps do not share a ledger`() {
        assertNotEquals(
            HealthConnectLedger.ledgerKey("whoop-aaa", p),
            HealthConnectLedger.ledgerKey("whoop-bbb", p),
        )
    }

    /** The same strap keeps the same key across exports, or nothing would ever be retracted. */
    @Test
    fun `one strap keeps one key`() {
        assertEquals(
            HealthConnectLedger.ledgerKey("whoop-aaa", p),
            HealthConnectLedger.ledgerKey("whoop-aaa", p),
        )
    }

    /** Record types stay separate too: retracting sleep must never reach a workout id. */
    @Test
    fun `record types do not share a ledger either`() {
        assertNotEquals(
            HealthConnectLedger.ledgerKey("whoop-aaa", HealthConnectLedger.SLEEP_PREFIX),
            HealthConnectLedger.ledgerKey("whoop-aaa", HealthConnectLedger.WORKOUT_PREFIX),
        )
    }
}

