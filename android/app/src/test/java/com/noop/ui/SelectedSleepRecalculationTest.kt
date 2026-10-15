package com.noop.ui

import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.SleepRecalculationWindow
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SelectedSleepRecalculationTest {
    private val window = SleepRecalculationWindow.make("2021-06-15", ZoneId.of("UTC"), 1_800_000_000)!!
    private fun scored(day: String = window.day, sleep: Double? = 420.0) =
        IntelligenceEngine.Computed(day, null, null, sleep, null, null)

    @Test fun oldSelectedDayReachesScanAndOtherDayCannotStandInForIt() = runBlocking {
        val action = SelectedSleepRecalculation()
        assertEquals(SleepRecalculationResult.COMPLETED, action.run(window) {
            assertSame(window, it)
            listOf(scored("2026-10-11"), scored())
        })
        assertEquals(SleepRecalculationResult.INSUFFICIENT_DATA, action.run(window) {
            listOf(scored("2026-10-11"))
        })
    }

    @Test fun noInputsAndScoredWithoutSleepHaveDifferentOutcomes() = runBlocking {
        val action = SelectedSleepRecalculation()
        assertEquals(SleepRecalculationResult.INSUFFICIENT_DATA, action.run(window) { emptyList() })
        assertEquals(SleepRecalculationResult.NO_SLEEP_DETECTED, action.run(window) { listOf(scored(sleep = null)) })
        assertEquals(SleepRecalculationResult.FAILED, action.run(window) { error("store read failed") })
    }

    @Test fun doubleTapCannotStartAnotherScanAndCompletionReleasesGate() = runBlocking {
        val action = SelectedSleepRecalculation()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val first = async {
            action.run(window) { started.complete(Unit); release.await(); listOf(scored()) }
        }
        started.await()
        assertEquals(SleepRecalculationResult.BUSY, action.run(window) { error("second scan must not run") })
        release.complete(Unit)
        assertEquals(SleepRecalculationResult.COMPLETED, first.await())
        assertEquals(SleepRecalculationResult.COMPLETED, action.run(window) { listOf(scored()) })
    }

    @Test fun cancellationIsPropagatedAndReleasesGate() = runBlocking {
        val action = SelectedSleepRecalculation()
        var cancelled = false
        try { action.run(window) { throw CancellationException("view left") } }
        catch (_: CancellationException) { cancelled = true }
        assertTrue(cancelled)
        assertEquals(SleepRecalculationResult.COMPLETED, action.run(window) { listOf(scored()) })
    }

    @Test fun intentionalDeletionStopsScanWithoutClearingIt() = runBlocking {
        assertEquals(SleepRecalculationResult.DELETION_SUPPRESSED,
            SelectedSleepRecalculation().run(window, hasDeletedWindow = { true }) {
                error("a suppressed window must not be scored")
            })
    }

    @Test fun invalidDateNeverStartsScan() = runBlocking {
        assertEquals(SleepRecalculationResult.INVALID_DATE,
            SelectedSleepRecalculation().run(null) { error("scan must not run") })
    }
}
