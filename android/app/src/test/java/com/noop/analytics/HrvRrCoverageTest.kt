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

    // --- The second, independent fault: beat-VALUE accuracy (P7'). Twin of the Swift tests. ---

    /** A beat-accurate stream steps one interval per beat, so each wall-clock gap equals its own R-R
     *  value and the fraction is 1.0. This is what WHOOP R-R and the synthetic fixtures look like. */
    @Test fun beatAccurateFraction_isFullOnABeatAccurateStream() {
        val rr = List(60) { 1000.0 }
        val ts = (0 until 60).map { it.toLong() }
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(ts, rr), 1e-9)
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(HrvAnalyzer.beatAccurateFraction(ts, rr)))
    }

    /** A BANKED stream stamps a whole record of intervals on one timestamp, so nearly every gap is 0 s
     *  against a ~1 s value. Six beats per record: five of every six gaps are 0, so the fraction lands
     *  far below the boundary — the shape every measured Oura night has (2.6-6.6%). */
    @Test fun beatAccurateFraction_collapsesOnABankedStream() {
        val rr = List(60) { 1000.0 }
        val ts = (0 until 60).map { ((it / 6) * 7).toLong() }
        val frac = HrvAnalyzer.beatAccurateFraction(ts, rr)
        assertTrue("fraction was $frac", frac < HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION)
        assertFalse(HrvAnalyzer.beatValuesAreTrustworthy(frac))
    }

    /** **The case that motivated P7'.** The two faults are INDEPENDENT: this stream is perfectly
     *  covered — 60 intervals of 1050 ms are exactly the 63 s first-to-last span, so classifyCoverage
     *  says PLAUSIBLE and the over-count gate passes it — yet the beats are banked six to a record, so
     *  their individual values are a decomposition of a record period, not beat-to-beat measurements.
     *  The 2026-08-06 Oura night is exactly this shape (coverage 1.03, PLAUSIBLE, SDNN 174 ms). */
    @Test fun aPerfectlyCoveredBankedNightStillRefusesBeatValues() {
        val rr = List(60) { 63_000.0 / 60.0 }
        val ts = (0 until 60).map { ((it / 6) * 7).toLong() }
        val verdict = HrvAnalyzer.classifyCoverage(
            HrvAnalyzer.rrCoverage(ts, rr), HrvAnalyzer.collapsedCoverage(ts, rr))
        assertTrue("the over-count gate must PASS this — that is the point (verdict $verdict)",
            HrvAnalyzer.beatSpreadIsTrustworthy(verdict))
        val frac = HrvAnalyzer.beatAccurateFraction(ts, rr)
        assertFalse("the beat-value gate must REFUSE it (fraction $frac)",
            HrvAnalyzer.beatValuesAreTrustworthy(frac))
    }

    /** A live spot reading carries no timestamps, so there is nothing to measure and nothing to refuse:
     *  too-short or mismatched input returns 1.0 and stays trusted. */
    @Test fun beatAccurateFraction_tooShortOrMismatchedStaysTrusted() {
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(emptyList(), emptyList()), 1e-9)
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(listOf(5L), listOf(1000.0)), 1e-9)
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(listOf(0L, 1L, 2L), listOf(1000.0)), 1e-9)
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(1.0))
    }

    /** NaN means "not measured", and an unmeasured window must not be silently refused — the same
     *  negated-comparison convention classifyCoverage uses so both platforms fold NaN identically. */
    @Test fun beatValuesAreTrustworthy_nanStaysTrusted() {
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(Double.NaN))
    }

    /** The boundary itself: exactly at the minimum is trusted, just below is not. */
    @Test fun beatValuesAreTrustworthy_boundaryIsInclusive() {
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION))
        assertFalse(HrvAnalyzer.beatValuesAreTrustworthy(HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION - 0.01))
    }

    // #1008 — densestSecondWindowSample: the raw-row sample that makes an over-count's MECHANISM readable
    // from the always-on log. Exact-string assertions pin byte-parity with the Swift twin. ---

    /** Near-equal copies clustered in one second (the "same beat stored twice" shape): the sample shows
     *  `[1199,1200,1201]` — values a de-dup would collapse. This is the signature of a duplication bug. */
    @Test fun densestSample_showsNearEqualCopies() {
        val ts = listOf(100L, 100L, 100L, 101L, 102L)
        val rr = listOf(1200.0, 1199.0, 1201.0, 1200.0, 1198.0)
        val src = listOf<Int?>(null, null, null, null, null)
        assertEquals(
            "beatsPerSec=1.67 maxInSec=3 occSec=3 totBeats=5 src=none | " +
                "t0=100 0s[1199,1200,1201] +1s[1200] +2s[1198]",
            HrvAnalyzer.densestSecondWindowSample(ts, rr, src),
        )
    }

    /** Distinct interval trains (a full ~1200 ms beat beside a ~600 ms one, every second): the sample
     *  shows `[600,1200]` — NOT copies of one beat, so this is a genuine second stream, not a de-dupable
     *  duplicate. The two shapes are what the maintainer needs to tell apart to pick the fix. */
    @Test fun densestSample_showsDistinctTrains() {
        val ts = listOf(100L, 100L, 101L, 101L, 102L, 102L)
        val rr = listOf(1200.0, 600.0, 1200.0, 600.0, 1200.0, 600.0)
        val src = listOf<Int?>(null, null, null, null, null, null)
        assertEquals(
            "beatsPerSec=2.00 maxInSec=2 occSec=3 totBeats=6 src=none | " +
                "t0=100 0s[600,1200] +1s[600,1200] +2s[600,1200]",
            HrvAnalyzer.densestSecondWindowSample(ts, rr, src),
        )
    }

    /** A non-null srcChannel is surfaced as `@code`, and the `src=` field lists the distinct codes — so a
     *  tagged (Oura #1071) stream is obvious, and `src=none` on a WHOOP night confirms that machinery
     *  does NOT apply and the over-count has a different origin. */
    @Test fun densestSample_surfacesSrcChannelTags() {
        val ts = listOf(100L, 100L)
        val rr = listOf(1000.0, 1000.0)
        val src = listOf<Int?>(1, 2)
        assertEquals(
            "beatsPerSec=2.00 maxInSec=2 occSec=1 totBeats=2 src=1/2 | t0=100 0s[1000@1,1000@2]",
            HrvAnalyzer.densestSecondWindowSample(ts, rr, src),
        )
    }

    /** Nothing to sample (< 2 beats) → empty string, so the engine emits no `hrv rrsample` line. */
    @Test fun densestSample_emptyForTooFewBeats() {
        assertEquals("", HrvAnalyzer.densestSecondWindowSample(emptyList(), emptyList(), emptyList()))
        assertEquals("", HrvAnalyzer.densestSecondWindowSample(listOf(100L), listOf(1000.0), listOf<Int?>(null)))
    }

    // Parity edge cases — the SAME literal strings are asserted in the Swift twin (produced by an
    // independent Swift run), so ties, truncation, short srcCodes, and half-value rounding are pinned
    // byte-for-byte across platforms, not just the three headline shapes above.

    /** Densest-second TIE (100 & 101 both hold 2) resolves to the EARLIEST ts; equal rrMs order by index. */
    @Test fun densestSample_tieResolvesToEarliestSecond() {
        assertEquals(
            "beatsPerSec=1.67 maxInSec=2 occSec=3 totBeats=5 src=none | t0=100 0s[1000,1000] +1s[1000,1000] +2s[999]",
            HrvAnalyzer.densestSecondWindowSample(
                listOf(100L, 100L, 101L, 101L, 102L),
                listOf(1000.0, 1000.0, 1000.0, 1000.0, 999.0),
                listOf<Int?>(null, null, null, null, null),
            ),
        )
    }

    /** A runaway second is truncated to maxRowsPerSecond with a `+K` remainder marker. */
    @Test fun densestSample_truncatesRunawaySecond() {
        assertEquals(
            "beatsPerSec=3.00 maxInSec=5 occSec=2 totBeats=6 src=none | t0=50 0s[700,710,720,+2] +1s[1000]",
            HrvAnalyzer.densestSecondWindowSample(
                listOf(50L, 50L, 50L, 50L, 50L, 51L),
                listOf(700.0, 710.0, 720.0, 730.0, 740.0, 1000.0),
                listOf<Int?>(null, null, null, null, null, null),
                maxRowsPerSecond = 3,
            ),
        )
    }

    /** srcCodes SHORTER than the beat list is index-guarded (no crash), and only the tagged beat shows `@`. */
    @Test fun densestSample_shortSrcCodesAreIndexGuarded() {
        assertEquals(
            "beatsPerSec=1.50 maxInSec=2 occSec=2 totBeats=3 src=3 | t0=10 0s[1000@3,1000] +1s[1000]",
            HrvAnalyzer.densestSecondWindowSample(
                listOf(10L, 10L, 11L), listOf(1000.0, 1000.0, 1000.0), listOf<Int?>(3),
            ),
        )
    }

    /** beatsPerSec at an exact half (3 beats / 2 seconds = 1.50) folds identically on both platforms. */
    @Test fun densestSample_halfValueBeatsPerSecRounding() {
        assertEquals(
            "beatsPerSec=1.50 maxInSec=2 occSec=2 totBeats=3 src=none | t0=200 0s[900,900] +1s[900]",
            HrvAnalyzer.densestSecondWindowSample(
                listOf(200L, 200L, 201L), listOf(900.0, 900.0, 900.0), listOf<Int?>(null, null, null),
            ),
        )
    }
}
