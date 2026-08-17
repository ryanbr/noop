package com.noop.ui

import com.noop.analytics.HrvAnalyzer
import com.noop.ble.LiveState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the spot-HRV capture window contract: monotonic deadline math, lossless [rrPackets] ingest,
 * and the beat-time-vs-wall-clock gate. Mirrors the Swift HRVSnapshotView / HRVAnalyzer twins
 * case-for-case.
 */
class HrvCaptureWindowTest {

    // ── Deadline math: a late tick jumps, never stretches ────────────────────

    @Test
    fun remainingSecondsDerivesFromElapsedTime() {
        assertEquals(60, remainingCaptureSeconds(0))
        assertEquals(59, remainingCaptureSeconds(1_000))
        assertEquals(1, remainingCaptureSeconds(59_999))
        assertEquals(0, remainingCaptureSeconds(60_000))
    }

    @Test
    fun aCallbackDelayedPastTheDeadlineFinishesImmediately() {
        // A delayed callback at 75 s jumps to done — no decrementing a stale counter.
        assertEquals(0, remainingCaptureSeconds(75_000))
    }

    @Test
    fun ingestWindowClosesExactlyAtTheDeadline() {
        assertTrue(captureWindowOpen(0))
        assertTrue(captureWindowOpen(59_999))
        assertFalse(captureWindowOpen(60_000))
        assertFalse(captureWindowOpen(75_000))
    }

    // ── Packet stream: identical consecutive packets both count ─────────────

    /** Equal interval values in two distinct packets: both must survive the StateFlow equality
     *  conflation that used to drop the second one. */
    @Test
    fun identicalConsecutivePacketsBothReachTheBuffer() = runTest {
        val live = MutableStateFlow(LiveState())
        val captureBuffer = mutableListOf<Int>()

        val collector = launch(UnconfinedTestDispatcher(testScheduler)) {
            live.rrPackets().collect { rr -> captureBuffer += rr }
        }

        live.update { it.withRRIntervals(listOf(802)) }
        live.update { it.withRRIntervals(listOf(802)) }   // equal values, distinct packet
        live.update { it.withRRIntervals(listOf(913)) }
        collector.cancel()

        assertEquals(listOf(802, 802, 913), captureBuffer)
    }

    /** Sentinel-only packets (non-positive placeholders) are filtered by the shared stream. */
    @Test
    fun emptyPacketsAreFiltered() = runTest {
        val live = MutableStateFlow(LiveState())
        val seen = mutableListOf<List<Int>>()

        val collector = launch(UnconfinedTestDispatcher(testScheduler)) {
            live.rrPackets().collect { seen += it }
        }

        live.update { it.withRRIntervals(emptyList()) }
        live.update { it.withRRIntervals(listOf(788)) }
        collector.cancel()

        assertEquals(listOf(listOf(788)), seen)
    }

    // ── Beat-time plausibility: more beat time than wall clock is refused ────

    @Test
    fun spotCaptureRejectsMoreBeatTimeThanElapsedTime() {
        // ~700 beats of ~850 ms ≈ 595 s of beat time from a 60 s window — physically impossible.
        val beatTimeMs = List(700) { 830.0 + (it % 5) * 10.0 }.sum()
        assertTrue(HrvAnalyzer.spotCaptureOverCounted(beatTimeMs, captureMs = 60_000))
    }

    @Test
    fun spotCaptureAcceptsAPlausibleWindow() {
        // ~70 beats of 850 ms ≈ 59.5 s of beat time in 60 s — a normal seated reading.
        assertFalse(HrvAnalyzer.spotCaptureOverCounted(70 * 850.0, captureMs = 60_000))
    }

    @Test
    fun spotCaptureToleratesTheRoundingAllowance() {
        // Exactly at the shared COVERAGE_PLAUSIBLE_CEILING (1.10): still trusted — the ceiling is a
        // rounding allowance, and the gate uses strict `>` like classifyCoverage.
        val atCeiling = 60_000 * HrvAnalyzer.COVERAGE_PLAUSIBLE_CEILING
        assertFalse(HrvAnalyzer.spotCaptureOverCounted(atCeiling, captureMs = 60_000))
        assertTrue(HrvAnalyzer.spotCaptureOverCounted(atCeiling + 1.0, captureMs = 60_000))
    }

    @Test
    fun spotCaptureWithZeroElapsedTimeIsNotJudged() {
        // No wall clock to hold the beats against — never reject on a degenerate duration.
        assertFalse(HrvAnalyzer.spotCaptureOverCounted(1_000.0, captureMs = 0))
    }
}
