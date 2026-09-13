package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Oura history drain + resume-cursor decisions (#91 / #291). Kotlin twin of the Swift
 * OuraHistoryDrainTests — same values, same assertions, so the drain decisions are byte-identical
 * across both ports. Pure decisions — no ring, no BLE.
 */
class OuraHistoryDrainTest {

    // MARK: drain continuation

    @Test
    fun testDrainCompletesWhenBytesLeftZero() {
        val d = OuraHistoryDrain()
        // moreData == false is the healthy end, regardless of the counters.
        assertFalse(d.onSummary(bytesLeft = 0, moreData = false, elapsedSeconds = 0.0))
    }

    @Test
    fun testDrainContinuesWhileBytesLeftShrinks() {
        val d = OuraHistoryDrain()
        assertTrue(d.onSummary(bytesLeft = 400_873, moreData = true, elapsedSeconds = 1.0))
        assertTrue(d.onSummary(bytesLeft = 200_000, moreData = true, elapsedSeconds = 2.0))
        assertTrue(d.onSummary(bytesLeft = 1, moreData = true, elapsedSeconds = 3.0))
    }

    @Test
    fun testStallGuardStopsAfterMaxFlatSummaries() {
        val d = OuraHistoryDrain()
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 1.0)) // sets the floor
        // Same bytes_left repeated — no progress. Stops on the MAX_STALL_SUMMARIES-th flat read.
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 2.0))  // stall 1
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 3.0))  // stall 2
        assertFalse(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 4.0)) // stall 3 -> stop
    }

    @Test
    fun testStallCounterResetsOnFreshProgress() {
        val d = OuraHistoryDrain()
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 1.0))
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 2.0)) // stall 1
        assertTrue(d.onSummary(bytesLeft = 900, moreData = true, elapsedSeconds = 3.0))  // progress -> reset
        assertTrue(d.onSummary(bytesLeft = 900, moreData = true, elapsedSeconds = 4.0))  // stall 1 again
        assertTrue(d.onSummary(bytesLeft = 900, moreData = true, elapsedSeconds = 5.0))  // stall 2 (not stopped)
    }

    @Test
    fun testDeadlineGuardStopsPastMaxDrainSeconds() {
        val d = OuraHistoryDrain()
        assertTrue(d.onSummary(bytesLeft = 500, moreData = true, elapsedSeconds = 299.0))
        assertFalse(
            d.onSummary(
                bytesLeft = 400, moreData = true,
                elapsedSeconds = OuraHistoryDrain.MAX_DRAIN_SECONDS + 0.1,
            ),
        )
    }

    // MARK: stored ring-time → cursor

    @Test
    fun testNoteStoredRingTimeTracksMaxAndIgnoresCorrupt() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(100, resumeCursorAtFetchStart = 0)
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 0)
        d.noteStoredRingTime(50, resumeCursorAtFetchStart = 0) // older, doesn't lower the max
        assertEquals(3_453_828L, d.maxStoredRingTime)
        d.noteStoredRingTime(OuraHistoryDrain.MAX_PLAUSIBLE_RESUME_TICKS + 1, resumeCursorAtFetchStart = 0)
        assertEquals("over-ceiling ring-time must be ignored", 3_453_828L, d.maxStoredRingTime)
        assertFalse(d.sawPreResumeData)
    }

    @Test
    fun testPreResumeDataFlagsReboot() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000)
        assertTrue("a stored sample OLDER than the seek floor means the ring clock reset", d.sawPreResumeData)
    }

    @Test
    fun testFullPullSeekNeverFlagsReboot() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 0)   // cursor 0 = full pull, no floor
        assertFalse(d.sawPreResumeData)
    }

    @Test
    fun testResumeCursorAdvancesWhenForwardAndResolves() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1000)
        assertEquals(3_453_828L, d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = true))
    }

    @Test
    fun testResumeCursorUnchangedWhenNotResolving() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1000)
        assertEquals(1000L, d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = false))
    }

    @Test
    fun testRebootResetsCursorToFullPull() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000)     // reboot flagged
        d.noteStoredRingTime(2000, resumeCursorAtFetchStart = 1000)    // forward sample too
        assertEquals(
            "a reboot forces 0 (full pull) even if a forward sample also arrived",
            0L, d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = true),
        )
    }

    // MARK: #2097 - a SyncTime anchor confirming clock continuity overrides the reboot reset

    @Test
    fun testAnchorConfirmsContinuityKeepsCursorInsteadOfFullReset() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000) // stale sample -> sawPreResumeData
        assertTrue(d.sawPreResumeData)
        assertEquals(
            "continuity confirmed (#2097): not a reboot - discard the stale replay, keep the cursor",
            1000L,
            d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = true, anchorConfirmsContinuity = true),
        )
    }

    @Test
    fun testAnchorConfirmsContinuityStillAdvancesOnRealForwardProgress() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1000) // forward...
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000)       // ...plus a stale replay
        assertTrue(d.sawPreResumeData)
        assertEquals(
            "continuity confirmed: genuine forward progress still commits normally",
            3_453_828L,
            d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = true, anchorConfirmsContinuity = true),
        )
    }

    @Test
    fun testAnchorContinuityDefaultsToOldRebootBehaviorWhenOmitted() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000)
        assertEquals(
            "omitting anchorConfirmsContinuity must not change today's behavior",
            0L, d.resumeCursorAtDrainEnd(currentCursor = 1000, resolvesUnderAnchor = true),
        )
    }

    // MARK: #2097 - anchorsAreContinuous (the SyncTime anchor comparison itself)

    @Test
    fun testAnchorsAreContinuousOnTheReal20260911N2Gap() {
        // The witnessed n=2 occurrence: 12:29:26 -> 14:00:02 local, 5436s wall, 54357 ring ticks
        // (~9.999 ticks/s) spanning the Oura-app handoff. The ring's clock never paused.
        assertTrue(
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 42_236_951L, previousUnixSeconds = 0L,
                currentRingTicks = 42_291_308L, currentUnixSeconds = 5436L,
            ),
        )
    }

    @Test
    fun testAnchorsAreContinuousDetectsARealPause() {
        // A genuine power-cycle: ticks paused for 821s (matches the measured 13m41s dead-battery
        // reboot) somewhere inside a 3600s wall-clock gap.
        val tickedSeconds = 3600 - 821
        assertFalse(
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 1_000_000L, previousUnixSeconds = 0L,
                currentRingTicks = 1_000_000L + tickedSeconds * 10L, currentUnixSeconds = 3600L,
            ),
        )
    }

    @Test
    fun testAnchorsAreContinuousToleratesOrdinaryJitter() {
        // 5s of receipt-latency noise across an otherwise-continuous gap must not false-positive as a
        // pause (well under ANCHOR_CONTINUITY_MAX_PAUSE_SECONDS).
        assertTrue(
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 1_000_000L, previousUnixSeconds = 0L,
                currentRingTicks = 1_003_000L, currentUnixSeconds = 305L, // 305s wall, 300s ticked
            ),
        )
    }

    @Test
    fun testAnchorsAreContinuousDeclinesOnTooShortAGap() {
        assertFalse(
            "too short a gap to judge - declines rather than guessing",
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 1_000_000L, previousUnixSeconds = 0L,
                currentRingTicks = 1_000_050L, currentUnixSeconds = 5L, // below the 10s minimum
            ),
        )
    }

    @Test
    fun testAnchorsAreContinuousOnTheReal20260912FastReconnect() {
        // 2026-09-12 19:38:56 -> 19:39:23: an app relaunch, state restoration resumed the still-connected
        // ring, and the next connect came 27s later with a stale replay. Ring ticks 43358625 -> 43358893
        // = 268 ticks over 27s wall (9.93/s): plainly continuous, but the original 30s floor declined and
        // the old full re-pull fired. Must judge, and must say continuous. Swift twin.
        assertTrue(
            "a 27s gap with a continuous ring clock is judgeable and continuous",
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 43_358_625L, previousUnixSeconds = 0L,
                currentRingTicks = 43_358_893L, currentUnixSeconds = 27L,
            ),
        )
    }

    @Test
    fun testAnchorsAreContinuousDeclinesWhenTicksWentBackward() {
        assertFalse(
            OuraHistoryDrain.anchorsAreContinuous(
                previousRingTicks = 1_000_000L, previousUnixSeconds = 0L,
                currentRingTicks = 999_000L, currentUnixSeconds = 100L, // never observed; decline, not confirm
            ),
        )
    }

    // MARK: in-session continuation cursor (open_oura drain_events `progressed`)

    @Test
    fun testContinuationCursorAdvancesPastMaxSeen() {
        val d = OuraHistoryDrain()
        // The 2026-07-12 shape: sought from 1_681_398, batch served records up to rt 3_595_428.
        d.noteSeenRingTime(1_686_000)
        d.noteSeenRingTime(3_595_428)
        d.noteSeenRingTime(2_000_000)   // out-of-order within the batch, doesn't lower the max
        assertEquals(
            "next request starts one past the newest record served",
            3_595_429L, d.continuationCursor(lastRequestCursor = 1_681_398),
        )
    }

    @Test
    fun testContinuationStopsOnEmptyBatch() {
        val d = OuraHistoryDrain()
        assertNull(
            "no records since the last request → no progress → stop, never re-request",
            d.continuationCursor(lastRequestCursor = 1_681_398),
        )
    }

    @Test
    fun testContinuationStopsWhenCursorWouldNotAdvance() {
        val d = OuraHistoryDrain()
        // A re-served window: records arrived but none newer than where we already asked from.
        d.noteSeenRingTime(1_686_000)
        d.noteSeenRingTime(3_595_428)
        assertNull(
            "a batch that only re-serves old records must stop the drain (the 5x re-serve loop)",
            d.continuationCursor(lastRequestCursor = 3_595_429),
        )
    }

    @Test
    fun testContinuationReArmsProgressTestPerRequest() {
        val d = OuraHistoryDrain()
        d.noteSeenRingTime(2_000_000)
        assertEquals(2_000_001L, d.continuationCursor(lastRequestCursor = 1_000_000))
        // No new records after the advanced request: the next decision is stop, not a re-request at
        // the same cursor.
        assertNull(d.continuationCursor(lastRequestCursor = 2_000_001))
        // Fresh records past the new cursor re-enable progress.
        d.noteSeenRingTime(2_500_000)
        assertEquals(2_500_001L, d.continuationCursor(lastRequestCursor = 2_000_001))
    }

    @Test
    fun testSeenRingTimeIgnoresCorruptAndIsIndependentOfStored() {
        val d = OuraHistoryDrain()
        d.noteSeenRingTime(OuraHistoryDrain.MAX_PLAUSIBLE_RESUME_TICKS + 1)
        assertEquals("over-ceiling ring-time must not steer the continuation", 0L, d.maxSeenRingTime)
        // Unanchored records advance the CONTINUATION cursor without touching the durable one.
        d.noteSeenRingTime(3_000_000)
        assertEquals(3_000_000L, d.maxSeenRingTime)
        assertEquals(0L, d.maxStoredRingTime)
        d.noteStoredRingTime(2_900_000, resumeCursorAtFetchStart = 0)
        assertEquals(2_900_000L, d.maxStoredRingTime)
        assertEquals("stored notes don't inflate the seen max", 3_000_000L, d.maxSeenRingTime)
    }

    // MARK: loaded-cursor sanitize + reset

    @Test
    fun testSanitizeLoadedCursor() {
        assertEquals(3_453_828L, OuraHistoryDrain.sanitizeLoadedCursor(3_453_828))
        assertEquals(0L, OuraHistoryDrain.sanitizeLoadedCursor(0))
        assertEquals(
            "a persisted cursor above the ceiling is pre-fix garbage → full pull",
            0L, OuraHistoryDrain.sanitizeLoadedCursor(OuraHistoryDrain.MAX_PLAUSIBLE_RESUME_TICKS + 1),
        )
    }

    @Test
    fun testResetClearsState() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1000)
        d.noteStoredRingTime(500, resumeCursorAtFetchStart = 1000)
        d.noteSeenRingTime(3_453_900)
        d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 1.0)
        d.reset()
        assertEquals(0L, d.maxStoredRingTime)
        assertEquals(0L, d.maxSeenRingTime)
        assertEquals(0L, d.eventsSinceLastRequest)
        assertFalse(d.sawPreResumeData)
        // Stall floor reset: a fresh flat sequence starts counting from scratch.
        assertTrue(d.onSummary(bytesLeft = 1000, moreData = true, elapsedSeconds = 1.0))
    }

    /**
     * `predatesResume` is the ONE comparison behind `sawPreResumeData`, applied to whole hypnogram bursts
     * by the app layer (a re-served night's tail must not become a phantom session — 2026-09-13). The
     * expected block is the standalone-compiled SWIFT twin's stdout, verbatim
     * (`swiftc -O twin.swift main.swift -o t && ./t`), over the same cases — the Kotlin side is pinned to
     * the Swift oracle, not read side by side with it.
     */
    @Test
    fun predatesResumeMatchesTheSwiftOracleTable() {
        val cases = listOf(
            42_867_280L to 43_895_637L, 43_731_586L to 43_895_637L, 43_895_636L to 43_895_637L, 43_895_637L to 43_895_637L,
            43_895_638L to 43_895_637L, 43_897_237L to 43_895_637L, 0L to 43_895_637L, 1L to 43_895_637L,
            42_867_280L to 0L, 0L to 0L, 4_294_967_295L to 0L, 4_294_967_295L to 4_294_967_295L, 4_294_967_294L to 4_294_967_295L,
            5L to 1L, 1L to 5L, 0L to 1L,
        )
        val got = cases.joinToString("\n") { (rt, cur) -> "$rt,$cur,${OuraHistoryDrain.predatesResume(rt, cur)}" }
        assertEquals(
            """
            42867280,43895637,true
            43731586,43895637,true
            43895636,43895637,true
            43895637,43895637,false
            43895638,43895637,false
            43897237,43895637,false
            0,43895637,true
            1,43895637,true
            42867280,0,false
            0,0,false
            4294967295,0,false
            4294967295,4294967295,false
            4294967294,4294967295,true
            5,1,false
            1,5,true
            0,1,true
            """.trimIndent(),
            got,
        )
    }

    @Test
    fun predatesResumeIsWhatFlagsPreResumeData() {
        val d = OuraHistoryDrain()
        d.noteStoredRingTime(43_731_586L, resumeCursorAtFetchStart = 43_895_637L)
        assertTrue("the drain flag and the burst gate must agree on the same sample", d.sawPreResumeData)
        val e = OuraHistoryDrain()
        e.noteStoredRingTime(43_897_237L, resumeCursorAtFetchStart = 43_895_637L)
        assertFalse(e.sawPreResumeData)
    }
}
