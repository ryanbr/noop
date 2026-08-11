package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the hypnogram time-axis reconstruction (OuraHypnogramAssembler): burst grouping by
 * envelope ring-time gap, and the 30 s/code backward layout from the anchored burst end. Kotlin twin
 * of the Swift HypnogramAssemblerTests — same values, same assertions.
 */
class HypnogramAssemblerTest {

    private fun phases(stages: List<OuraSleepStage>, rt: Long): List<OuraSleepPhase> =
        stages.mapIndexed { i, stage -> OuraSleepPhase(ringTimestamp = rt, index = i, stage = stage) }

    // MARK: - Backward layout

    @Test
    fun testSingleRecordLaysCodesBackwardFromEnd() {
        val a = OuraHypnogramAssembler()
        val stages = listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM)
        assertNull(a.feed(ringTimestamp = 1000, phases = phases(stages, rt = 1000)))
        val burst = a.flush()!!
        // 4 codes ending at t=10_000: starts at 10_000 - 4*30 = 9_880, spaced 30 s.
        val laid = burst.codesWithTimes(endUnixSeconds = 10_000)
        assertEquals(listOf(9_880L, 9_910L, 9_940L, 9_970L), laid.map { it.ts })
        assertEquals(stages, laid.map { it.phase.stage })
        // The final code's 30 s interval ends exactly at the burst end.
        assertEquals(10_000L, laid.last().ts + 30)
    }

    // MARK: - #1246 unwritten (0xFF) epochs excluded, real codes stay timed. Twin of Swift.

    @Test
    fun unwrittenEpochsDroppedButRealCodesKeepFullSequenceTimes_middleGap() {
        // A burst with an UNWRITTEN run in the MIDDLE. codesWithTimes lays times over the FULL count (so
        // the real codes keep their true positions), then drops the unwritten as a gap — it must NOT pull
        // the pre-gap codes toward the post-gap ones (which a drop-before-lay would).
        val real1 = phases(listOf(OuraSleepStage.DEEP, OuraSleepStage.LIGHT, OuraSleepStage.REM, OuraSleepStage.AWAKE), rt = 1000)
        val gap = (0 until 4).map { OuraSleepPhase(ringTimestamp = 1001, index = it, stage = OuraSleepStage.AWAKE, unwritten = true) }
        val real2 = phases(listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM, OuraSleepStage.LIGHT), rt = 1002)
        val burst = OuraHypnogramBurst(
            listOf(
                OuraHypnogramRecord(1000, real1),
                OuraHypnogramRecord(1001, gap),
                OuraHypnogramRecord(1002, real2),
            ),
        )
        val laid = burst.codesWithTimes(endUnixSeconds = 10_000)   // n=12, 30 s/code
        assertEquals(8, laid.size)                                 // 4 unwritten dropped
        assertTrue(laid.none { it.phase.unwritten })
        assertEquals(listOf(9_640L, 9_670L, 9_700L, 9_730L), laid.take(4).map { it.ts })
        assertEquals(listOf(9_880L, 9_910L, 9_940L, 9_970L), laid.takeLast(4).map { it.ts })
    }

    @Test
    fun allUnwrittenBurstReconstructsEmpty() {
        // Every page erased → no stageable sleep. Returns [] so the caller drops it (no blank/awake night).
        val gap = (0 until 4).map { OuraSleepPhase(ringTimestamp = 1000, index = it, stage = OuraSleepStage.AWAKE, unwritten = true) }
        val burst = OuraHypnogramBurst(listOf(OuraHypnogramRecord(1000, gap)))
        assertTrue(burst.codesWithTimes(endUnixSeconds = 10_000).isEmpty())
        assertTrue(burst.codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = 9_000).isEmpty())
    }

    // MARK: - 0x49 onset start-clamp (clips leading pre-window codes). Twin of Swift's clamp tests.

    private fun fourCodeBurst(): OuraHypnogramBurst {
        val a = OuraHypnogramAssembler()
        val stages = listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM)
        a.feed(ringTimestamp = 1000, phases = phases(stages, rt = 1000))
        return a.flush()!!   // codes at ts [9_880, 9_910, 9_940, 9_970] for end 10_000
    }

    @Test
    fun testStartClampDropsCodesBeforeOnset() {
        val laid = fourCodeBurst().codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = 9_910)
        assertEquals(listOf(9_910L, 9_940L, 9_970L), laid.map { it.ts })
        assertEquals(
            listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM),
            laid.map { it.phase.stage },
        )
    }

    @Test
    fun testStartClampBoundaryInclusiveAndOnsetBeforeStartKeepsAll() {
        assertEquals(4, fourCodeBurst().codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = 9_880).size)
        assertEquals(4, fourCodeBurst().codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = 0).size)
    }

    @Test
    fun testStartClampNeverEmptiesTheNight() {
        val laid = fourCodeBurst().codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = 99_999)
        assertEquals(listOf(9_880L, 9_910L, 9_940L, 9_970L), laid.map { it.ts })
    }

    @Test
    fun testNilOnsetMatchesUnclampedLay() {
        val burst = fourCodeBurst()
        assertEquals(
            burst.codesWithTimes(endUnixSeconds = 10_000).map { it.ts },
            burst.codesWithTimes(endUnixSeconds = 10_000, sleepStartUnixSeconds = null).map { it.ts },
        )
    }

    @Test
    fun testBurstWriteRecordsShareOneSequence() {
        // The on-device shape: multiple records written in one burst (envelope rts a few ticks apart)
        // form ONE contiguous sequence — record 2's codes precede the end, record 1's come before them.
        val a = OuraHypnogramAssembler()
        assertNull(a.feed(5_000, phases(listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT), rt = 5_000)))
        assertNull(a.feed(5_010, phases(listOf(OuraSleepStage.DEEP, OuraSleepStage.AWAKE), rt = 5_010)))
        val burst = a.flush()!!
        assertEquals(4, burst.totalCodes)
        assertEquals(5_010L, burst.lastRingTimestamp)
        val laid = burst.codesWithTimes(endUnixSeconds = 100_000)
        assertEquals(listOf(99_880L, 99_910L, 99_940L, 99_970L), laid.map { it.ts })
        assertEquals(
            listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.AWAKE),
            laid.map { it.phase.stage },
        )
    }

    @Test
    fun testFullNightScaleWindow() {
        // The real 2026-07-12 shape: 23 records x 52 codes = 1,196 codes -> 9 h 58 m window ending at
        // the anchored end. Start must be end - 1,196 * 30 s.
        val a = OuraHypnogramAssembler()
        for (k in 0 until 23) {
            a.feed(3_970_000L + k, phases(List(52) { OuraSleepStage.LIGHT }, rt = 3_970_000))
        }
        val burst = a.flush()!!
        assertEquals(1_196, burst.totalCodes)
        val end = 1_760_000_000L
        val laid = burst.codesWithTimes(endUnixSeconds = end)
        assertEquals(end - 1_196 * 30, laid.first().ts)          // 35,880 s = 9 h 58 m before end
        assertEquals(1_196, laid.size)
        // Strictly increasing, 30 s apart — every code lands on a unique persistence slot.
        assertTrue(laid.zipWithNext().all { (a1, b1) -> b1.ts - a1.ts == 30L })
    }

    // MARK: - Burst splitting

    @Test
    fun testLargeRingTimeGapSplitsBursts() {
        // Two nights in one full dump: finalization writes hours apart must NOT merge.
        val a = OuraHypnogramAssembler()
        assertNull(a.feed(1_000_000, phases(listOf(OuraSleepStage.LIGHT, OuraSleepStage.LIGHT), rt = 1_000_000)))
        // 24 h later in deciseconds = 864_000 ticks — far beyond the 600-tick burst gap.
        val closed = a.feed(1_864_000, phases(listOf(OuraSleepStage.DEEP), rt = 1_864_000))
        assertNotNull("a big rt gap must close the previous burst", closed)
        assertEquals(2, closed!!.totalCodes)
        assertEquals(1_000_000L, closed.lastRingTimestamp)
        // The new record started the next burst.
        val second = a.flush()!!
        assertEquals(1, second.totalCodes)
        assertEquals(1_864_000L, second.lastRingTimestamp)
    }

    @Test
    fun testFlushEmptyReturnsNullAndResetClears() {
        val a = OuraHypnogramAssembler()
        assertNull(a.flush())
        a.feed(10, phases(listOf(OuraSleepStage.REM), rt = 10))
        a.reset()
        assertNull("reset discards partial state", a.flush())
        assertEquals(0, a.pendingRecordCount)
    }

    @Test
    fun testNonMonotonicRingTimesAreSurfacedNotResorted() {
        // A record whose envelope rt steps BACKWARD (within the burst gap) must be flagged — but the
        // layout still trusts arrival order (envelope rts of a burst are near-identical write moments;
        // re-sorting on them could scramble the true code sequence).
        val a = OuraHypnogramAssembler()
        assertNull(a.feed(5_010, phases(listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP), rt = 5_010)))
        assertNull(a.feed(5_000, phases(listOf(OuraSleepStage.REM, OuraSleepStage.AWAKE), rt = 5_000)))   // backward
        val burst = a.flush()!!
        assertTrue(burst.hasNonMonotonicRingTimes)
        // Arrival order preserved in the layout.
        assertEquals(
            listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM, OuraSleepStage.AWAKE),
            burst.codesWithTimes(endUnixSeconds = 1_000).map { it.phase.stage },
        )
        // And a clean forward burst is NOT flagged.
        val b = OuraHypnogramAssembler()
        b.feed(100, phases(listOf(OuraSleepStage.LIGHT), rt = 100))
        b.feed(110, phases(listOf(OuraSleepStage.DEEP), rt = 110))
        assertFalse(b.flush()!!.hasNonMonotonicRingTimes)
    }

    @Test
    fun testEmptyRecordIsIgnored() {
        val a = OuraHypnogramAssembler()
        assertNull(a.feed(10, emptyList()))
        assertNull("a record with no codes never opens a burst", a.flush())
    }
}
