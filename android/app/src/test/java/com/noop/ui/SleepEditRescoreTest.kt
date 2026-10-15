package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Audit #2/#3/#4 — Android sleep edits must RE-SCORE the day immediately, not wait up to 15 min.
 *
 * Swift's SleepView calls `intelligence.analyzeRecent()` straight after each of editSleepTimes /
 * deleteSleepSession / addManualNap, so Charge / Rest / recovery (and the persisted sleep_performance)
 * recompute and Today refreshes the same instant the Sleep tab does. Android previously only persisted
 * the row and left the staleness to the 15-min background loop, so Today disagreed with the Sleep tab.
 *
 * The fix wires AppViewModel.updateSleepSessionTimes / deleteSleepSession / addManualNap to call a private
 * `rescoreAfterSleepEdit()` after the repository persist. The VM itself is an [android.app.AndroidViewModel]
 * backed by the process-wide NoopApplication (Room + BLE), so it can't be constructed in the pure-JVM
 * testFullDebugUnitTest suite. These tests instead pin the CONTROL-FLOW contract the wiring relies on, in
 * the same pure-mirror style the rest of this suite uses (e.g. TodayResolverEffortScaleTest mirrors
 * resolveTodayRow): persist-then-rescore, best-effort persist, best-effort rescore, and cancellation
 * propagation (the #125 rule the 15-min loop already follows).
 *
 * Deleted-window cases call the production `reopenDeletedSleepWindow` used by AppViewModel.
 * The remaining edit cases retain the existing mirrors below.
 *
 * The exact edit shapes mirrored from AppViewModel:
 *
 *   suspend fun updateSleepSessionTimes(...) { runCatching { repository.updateSleepSessionTimes(...) }; rescoreAfterSleepEdit() }
 *   suspend fun deleteSleepSession(...)      { runCatching { repository.deleteSleepSession(...) };      rescoreAfterSleepEdit() }
 *   suspend fun addManualNap(...)            { runCatching { repository.addManualNap(...) };            rescoreAfterSleepEdit() }
 *
 *   private suspend fun rescoreAfterSleepEdit() {
 *       runCatching { IntelligenceEngine.analyzeRecent(...) }
 *           .onFailure { if (it is CancellationException) throw it }
 *   }
 */
class SleepEditRescoreTest {

    /** Records the order calls happened in, so a test can assert persist ran before re-score. */
    private class Recorder { val events = mutableListOf<String>() }

    /** Pure mirror of `rescoreAfterSleepEdit`: swallow analyzeRecent failures, but rethrow a
     *  CancellationException so a VM teardown mid-edit isn't masked (matches the launch loop's #125 rule). */
    private suspend fun rescoreAfterSleepEdit(analyzeRecent: suspend () -> Unit) {
        runCatching { analyzeRecent() }
            .onFailure { if (it is CancellationException) throw it }
    }

    /** Pure mirror of an edit method: best-effort persist, then unconditional re-score. */
    private suspend fun editMethod(
        persist: suspend () -> Unit,
        analyzeRecent: suspend () -> Unit,
    ) {
        runCatching { persist() }
        rescoreAfterSleepEdit(analyzeRecent)
    }

    @Test
    fun rescoreRunsAfterAPersist() = runTest {
        val rec = Recorder()
        editMethod(
            persist = { rec.events += "persist" },
            analyzeRecent = { rec.events += "rescore" },
        )
        assertEquals("persist must precede the re-score", listOf("persist", "rescore"), rec.events)
    }

    @Test
    fun rescoreStillRunsWhenPersistThrows() = runTest {
        // The Sleep screen already applied the edit optimistically, so a persist failure must NOT skip the
        // re-score (the day still needs to recompute off whatever the persist managed / the prior state).
        val rec = Recorder()
        editMethod(
            persist = { throw IllegalStateException("DB write failed") },
            analyzeRecent = { rec.events += "rescore" },
        )
        assertEquals("a failed persist must not suppress the re-score", listOf("rescore"), rec.events)
    }

    @Test
    fun rescoreSwallowsAnalyzeFailure() = runTest {
        // An analyzeRecent hiccup must never throw into the edit caller (the screen's scope.launch) — the
        // 15-min loop will catch up. Best-effort, exactly like the loop's runCatching.
        editMethod(
            persist = { },
            analyzeRecent = { throw RuntimeException("scoring blew up") },
        )
        // Reaching here without throwing IS the assertion.
        assertTrue(true)
    }

    @Test
    fun rescorePropagatesCancellation() = runTest {
        // A scope cancellation surfaces as CancellationException; it must propagate so a ViewModel teardown
        // mid-edit actually stops, not get swallowed by the best-effort runCatching (the #125 rule).
        try {
            rescoreAfterSleepEdit(analyzeRecent = { throw CancellationException("VM cleared") })
            fail("CancellationException from the re-score must propagate, not be swallowed")
        } catch (e: CancellationException) {
            assertEquals("VM cleared", e.message)
        }
    }

    @Test
    fun deletedSleepMarkerIsClearedBeforeRedetection() = runTest {
        val rec = Recorder()
        val accepted = reopenDeletedSleepWindow(
            clearMarker = { rec.events += "clear" },
            scanRecent = { rec.events += "redetect" },
        )
        assertTrue(accepted)
        assertEquals(listOf("clear", "redetect"), rec.events)
    }

    @Test
    fun failedMarkerClearDoesNotRunRedetection() = runTest {
        val rec = Recorder()
        val accepted = reopenDeletedSleepWindow(
            clearMarker = { throw IllegalStateException("DB write failed") },
            scanRecent = { rec.events += "redetect" },
        )
        assertTrue(!accepted)
        assertTrue(rec.events.isEmpty())
    }

    @Test
    fun markerClearStillSucceedsWhenRecentScanFails() = runTest {
        assertTrue(reopenDeletedSleepWindow(
            clearMarker = {},
            scanRecent = { throw IllegalStateException("no scan completed") },
        ))
    }

    @Test
    fun cancellingMarkerClearDoesNotRequestScan() = runTest {
        val rec = Recorder()
        try {
            reopenDeletedSleepWindow(
                clearMarker = { throw CancellationException("clear cancelled") },
                scanRecent = { rec.events += "scan" },
            )
            fail("marker cancellation must propagate")
        } catch (e: CancellationException) {
            assertEquals("clear cancelled", e.message)
        }
        assertTrue(rec.events.isEmpty())
    }

    @Test
    fun cancellingRecentScanPropagatesAfterMarkerClear() = runTest {
        val rec = Recorder()
        try {
            reopenDeletedSleepWindow(
                clearMarker = { rec.events += "clear" },
                scanRecent = { throw CancellationException("scan cancelled") },
            )
            fail("scan cancellation must propagate")
        } catch (e: CancellationException) {
            assertEquals("scan cancelled", e.message)
        }
        assertEquals(listOf("clear"), rec.events)
    }
}
