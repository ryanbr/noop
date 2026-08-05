package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #257 — the R-R integrity diagnostics ([HrvAnalyzer.rrCoverage] / [HrvAnalyzer.duplicateBeatCount])
 * that surface a heartbeat OVER-COUNT (the "HRV reads ~2x too high" class of bug) in the always-on
 * `hrv diag` log. Byte-parity twin of `HRVAnalyzerTests` on the Swift side.
 */
class HrvRrCoverageTest {

    @Test fun coverage_cleanStreamIsNearOne() {
        // 5 beats of 1000 ms spanning ts 100..104 (4 s wall clock). sum=5000 ms, span=4000 ms → 1.25.
        val cov = HrvAnalyzer.rrCoverage(
            listOf(100L, 101L, 102L, 103L, 104L),
            listOf(1000.0, 1000.0, 1000.0, 1000.0, 1000.0),
        )
        assertEquals(1.25, cov, 1e-9)
    }

    @Test fun coverage_doubleCountedBeatsExceedsOne() {
        // Each beat stored TWICE at the same second (the #257 over-count): sum=6000 ms over a 2 s span → 3.0.
        val cov = HrvAnalyzer.rrCoverage(
            listOf(100L, 100L, 101L, 101L, 102L, 102L),
            listOf(1000.0, 1000.0, 1000.0, 1000.0, 1000.0, 1000.0),
        )
        assertEquals(3.0, cov, 1e-9)
    }

    @Test fun coverage_zeroForTooFewBeatsOrZeroSpan() {
        assertEquals(0.0, HrvAnalyzer.rrCoverage(emptyList(), emptyList()), 1e-9)
        assertEquals(0.0, HrvAnalyzer.rrCoverage(listOf(100L), listOf(1000.0)), 1e-9)
        assertEquals(0.0, HrvAnalyzer.rrCoverage(listOf(100L, 100L), listOf(1000.0, 1000.0)), 1e-9) // span 0
    }

    @Test fun duplicateBeats_zeroWhenAllDistinct() {
        assertEquals(0, HrvAnalyzer.duplicateBeatCount(listOf(100L, 101L, 102L), listOf(1000.0, 1010.0, 1020.0)))
    }

    @Test fun duplicateBeats_countsExactRepeats() {
        // (100,1000) appears twice → 1 extra copy; (101,1010) distinct.
        assertEquals(1, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L, 101L), listOf(1000.0, 1000.0, 1010.0)))
        // three identical beats → 2 extra copies.
        assertEquals(2, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L, 100L), listOf(1000.0, 1000.0, 1000.0)))
        // same ts but DIFFERENT rrMs are distinct beats, not duplicates.
        assertEquals(0, HrvAnalyzer.duplicateBeatCount(listOf(100L, 100L), listOf(1000.0, 1010.0)))
    }

    // #550 — collapsedCoverage: previews a SAME-SECOND R-R de-dup so the always-on diag reveals whether
    // the #257 over-count is same-second (collapsible) or cross-second (needs an ingest-path fix).

    @Test fun collapsedCoverage_noOpOnCleanStream() {
        // No same-second collisions → collapse changes nothing → equals rrCoverage.
        val ts = listOf(100L, 101L, 102L, 103L, 104L)
        val rr = listOf(1000.0, 1000.0, 1000.0, 1000.0, 1000.0)
        assertEquals(HrvAnalyzer.rrCoverage(ts, rr), HrvAnalyzer.collapsedCoverage(ts, rr), 1e-9)
    }

    @Test fun collapsedCoverage_collapsesSameSecondNearDuplicates() {
        // Each beat double-stamped WITHIN one second, the copies within the 30 ms tol (#257 live+historical).
        val ts = listOf(100L, 100L, 101L, 101L, 102L, 102L)
        val rr = listOf(1000.0, 1010.0, 1000.0, 1015.0, 1000.0, 1005.0)
        // Raw over-counts: sum 6030 ms over a 2 s span → 3.015.
        assertEquals(3.015, HrvAnalyzer.rrCoverage(ts, rr), 1e-9)
        // Collapsed keeps one per second (1000 each) → 3000 ms / 2 s → 1.5, far below raw.
        assertEquals(1.5, HrvAnalyzer.collapsedCoverage(ts, rr), 1e-9)
    }

    @Test fun collapsedCoverage_keepsCrossSecondDuplicates() {
        // The SAME beat stamped one second apart (live now-anchored vs historical RTC) — a same-second
        // collapse CANNOT catch it, so collapsedCov stays == raw. This is the discriminating signal.
        val ts = listOf(100L, 101L, 102L, 103L)
        val rr = listOf(1000.0, 1000.0, 1000.0, 1000.0)
        assertEquals(HrvAnalyzer.rrCoverage(ts, rr), HrvAnalyzer.collapsedCoverage(ts, rr), 1e-9)
    }

    @Test fun collapsedCoverage_respectsRrToleranceForGenuineTwoBeatsInOneSecond() {
        // Two beats in one second whose rr differ by MORE than the tol are genuine distinct beats (a brief
        // >60 bpm moment), not duplicates — both are kept, so collapse is a no-op here too.
        val ts = listOf(100L, 100L, 101L)
        val rr = listOf(900.0, 1200.0, 1000.0)   // |1200-900| = 300 ms > 30 ms tol
        assertEquals(HrvAnalyzer.rrCoverage(ts, rr), HrvAnalyzer.collapsedCoverage(ts, rr), 1e-9)
    }

    // --- Acting on the verdict: beat-spread statistics (SDNN). Twin of Swift RrCoverageVerdictTests. ---

    /** The whole point of the gate: an over-counted capture inflates SDNN directly, because SDNN is a
     *  spread over EVERY interval and some of those intervals are the same beat twice. */
    @Test fun beatSpreadIsTrustworthy_refusesOverCountedWindows() {
        assertFalse(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT))
        assertFalse(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT))
    }

    /** Nothing else gates. UNDER_COVERED is a capture with holes and UNMEASURABLE is what a LIVE spot
     *  reading looks like (real-time beats, no timestamps) — neither duplicates a beat, and refusing
     *  them would suppress honest readings. */
    @Test fun beatSpreadIsTrustworthy_keepsGapsAndUnmeasurable() {
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE))
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED))
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE))
    }

    /** End to end on the shape that motivated this: 60 beats delivered as 10 records of 6, each record
     *  stamping all six at its own second, records 5 s apart — 60 s of beat-time inside a 45 s span. The
     *  same beats stamped one per second stay trusted. Verdict measured, never assumed from the device. */
    @Test fun beatSpreadIsTrustworthy_bankedBurstsRefused_honestlySpacedKept() {
        val rr = List(60) { 1000.0 }
        val honestTs = (0 until 60).map { it.toLong() }
        val honest = HrvAnalyzer.classifyCoverage(
            HrvAnalyzer.rrCoverage(honestTs, rr), HrvAnalyzer.collapsedCoverage(honestTs, rr))
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, honest)
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(honest))

        val bankedTs = (0 until 60).map { ((it / 6) * 5).toLong() }
        val banked = HrvAnalyzer.classifyCoverage(
            HrvAnalyzer.rrCoverage(bankedTs, rr), HrvAnalyzer.collapsedCoverage(bankedTs, rr))
        assertFalse("verdict was $banked", HrvAnalyzer.beatSpreadIsTrustworthy(banked))
    }
}
