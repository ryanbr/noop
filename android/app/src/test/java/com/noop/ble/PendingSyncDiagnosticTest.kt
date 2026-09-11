package com.noop.ble

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2012: the Rest "Pending sync" state is `backfilling || historyPendingSync`, and only the first half
 * left a trace. A reporter's log arrived showing the note in the afternoon, and it could only be read by
 * inferring from what else was happening at that timestamp, which settles nothing.
 *
 * These pin that the line names the DECIDING input, because the four things that can decide it mean four
 * different bugs. Mirrors Swift `PendingSyncDiagnosticTests` case-for-case.
 */
class PendingSyncDiagnosticTest {
    private val threshold = 300L

    @Test
    fun `behind the strap names the gap and the threshold`() {
        val s = PendingSyncDiagnostic.line(
            pending = true, site = PendingSyncDiagnostic.SITE_POST_OFFLOAD,
            newestUnix = 1_788_896_010, frontierUnix = 1_788_861_800,
            futureDated = false, persistedRows = true, thresholdSec = threshold,
        )
        assertTrue(s, s.startsWith("pending-sync ON (post-offload):"))
        assertTrue(s, s.contains("34210s ahead of our frontier"))
        assertTrue(s, s.contains("over the 300s threshold"))
        assertTrue(s, s.contains("gap=34210s"))
    }

    @Test
    fun `caught up says so rather than just OFF`() {
        val s = PendingSyncDiagnostic.line(
            pending = false, site = PendingSyncDiagnostic.SITE_POST_OFFLOAD,
            newestUnix = 1_788_896_010, frontierUnix = 1_788_896_000,
            futureDated = false, persistedRows = true, thresholdSec = threshold,
        )
        assertTrue(s, s.startsWith("pending-sync OFF (post-offload):"))
        assertTrue(s, s.contains("caught up"))
    }

    @Test
    fun `a future-dated strap clock outranks the gap`() {
        // #928/#1012: this latches the flag on forever, so it must be named and not read as "behind".
        val s = PendingSyncDiagnostic.line(
            pending = false, site = PendingSyncDiagnostic.SITE_POST_OFFLOAD,
            newestUnix = 2_000_000_000, frontierUnix = 1_788_896_000,
            futureDated = true, persistedRows = true, thresholdSec = threshold,
        )
        assertTrue(s, s.contains("clock reads ahead of now"))
        assertTrue(s, !s.contains("ahead of our frontier"))
    }

    @Test
    fun `a phantom gap is named as such, not as being behind`() {
        // #1144: the strap advertises newer records and banks none, so the frontier cannot advance.
        // Reading that as "behind" would send the next reader chasing an offload that will never help.
        val s = PendingSyncDiagnostic.line(
            pending = false, site = PendingSyncDiagnostic.SITE_POST_OFFLOAD,
            newestUnix = 1_788_896_010, frontierUnix = 1_788_861_800,
            futureDated = false, persistedRows = false, thresholdSec = threshold,
        )
        assertTrue(s, s.contains("phantom gap"))
        assertTrue(s, s.contains("rowsBanked=no"))
    }

    @Test
    fun `a missing range still produces a line rather than a silent flip`() {
        // The flag flips to false when either input is missing, and an unanswered GET_DATA_RANGE
        // ("requesting history anyway (fail-open)") is a real way to get there. Guarding the log on
        // non-null inputs would have left exactly that transition silent, which is the hole this closes.
        val s = PendingSyncDiagnostic.line(
            pending = false, site = PendingSyncDiagnostic.SITE_POST_OFFLOAD,
            newestUnix = null, frontierUnix = 1_788_861_800,
            futureDated = false, persistedRows = true, thresholdSec = threshold,
        )
        assertTrue(s, s.startsWith("pending-sync OFF (post-offload):"))
        assertTrue(s, s.contains("no range to compare"))
        assertTrue(s, s.contains("newest=unknown"))
    }

    @Test
    fun `the connect site says row evidence is unavailable rather than absent`() {
        // No offload has run there, so "no" would be a lie that reads as a phantom gap.
        val s = PendingSyncDiagnostic.line(
            pending = true, site = PendingSyncDiagnostic.SITE_CONNECT,
            newestUnix = 1_788_896_010, frontierUnix = 1_788_861_800,
            futureDated = false, persistedRows = null, thresholdSec = threshold,
        )
        assertTrue(s, s.contains("(connect)"))
        assertTrue(s, s.contains("rowsBanked=n/a at connect"))
        assertTrue(s, !s.contains("phantom gap"))
    }
}
