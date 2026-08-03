package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #550: the coverage pair encodes WHICH over-count a night has, and until now that reading rule lived only
 * in a comment — so triaging an "HRV reads ~2x high" report required knowing it. These pin the rule.
 *
 * Kotlin twin of `RrCoverageVerdictTests`, same vectors and same expected verdicts. The real-capture pairs
 * come from #803 (WHOOP 4.0, two consecutive nights).
 */
class RrCoverageVerdictTest {

    /**
     * #803's 2026-07-15, which this file used to call "a night whose beat-time fits the wall clock".
     * It does not: at 0.89 an eighth of the beat-time is missing. That label was written when the
     * classifier only looked upward, so PLAUSIBLE was the ONLY verdict this night could receive — it
     * recorded the absence of an over-count, not the presence of a clean capture. (#977)
     *
     * It lands 0.01 outside the symmetric allowance, so it is also the first case worth re-examining if
     * real coverage distributions ever say a WHOOP 4.0 night simply runs near 0.89.
     */
    @Test
    fun nineTenthsOfANightIsNotAFitAnyMore() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(0.89, 0.88),
        )
    }

    /** The reported case (#977): 0.859 on one wearer's WHOOP 5 corpus, previously "nothing to explain". */
    @Test
    fun theReportedUnderCoveredNightIsNamed() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(0.859, 0.85),
        )
    }

    /** The floor mirrors the ceiling exactly: 1.10 above, 0.90 below. Not fitted to any corpus. */
    @Test
    fun floorMirrorsCeiling() {
        assertEquals(0.90, HrvAnalyzer.COVERAGE_PLAUSIBLE_FLOOR, 1e-12)
        assertEquals(
            HrvAnalyzer.COVERAGE_PLAUSIBLE_CEILING - 1.0,
            1.0 - HrvAnalyzer.COVERAGE_PLAUSIBLE_FLOOR,
            1e-12,
        )
    }

    /** Symmetric with the ceiling test: exactly at the floor fits, a hair under does not. */
    @Test
    fun floorIsInclusive() {
        val floor = HrvAnalyzer.COVERAGE_PLAUSIBLE_FLOOR
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, HrvAnalyzer.classifyCoverage(floor, floor))
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(floor - 0.01, 0.5),
        )
    }

    /** An almost entirely absent night must not read as fitting either. */
    @Test
    fun anAlmostEmptyNightIsUnderCovered() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(0.01, 0.01),
        )
    }

    /** A genuinely clean night still reads as one — the guard that this did not invert the bug. */
    @Test
    fun aCleanNightIsStillPlausible() {
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, HrvAnalyzer.classifyCoverage(0.99, 0.98))
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, HrvAnalyzer.classifyCoverage(1.00, 1.00))
    }

    /**
     * The night that prompted the report. #803's 2026-07-16: collapsing same-second duplicates drops it
     * 2.54 -> 1.99, still impossible — so the duplicates straddle second boundaries and a same-second
     * de-dup would NOT fix it. This is the case #550 needs to know about.
     */
    @Test
    fun realCrossSecondCaptureIsNotFixableBySameSecondDedup() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT,
            HrvAnalyzer.classifyCoverage(2.54, 1.99),
        )
    }

    /** Over-covered, but the collapse brings it back in range — the extra beats share a timestamp. */
    @Test
    fun collapseRecoveringRangeMeansSameSecond() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT,
            HrvAnalyzer.classifyCoverage(1.60, 1.02),
        )
    }

    /** The ceiling is a rounding allowance: exactly at it still fits, a hair over does not. */
    @Test
    fun ceilingIsInclusive() {
        val ceil = HrvAnalyzer.COVERAGE_PLAUSIBLE_CEILING
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE,
            HrvAnalyzer.classifyCoverage(ceil, ceil),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT,
            HrvAnalyzer.classifyCoverage(ceil + 0.01, 0.5),
        )
    }

    @Test
    fun unmeasurableWindowIsNotReportedAsClean() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(0.0, 0.0),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(-1.0, 0.0),
        )
    }

    /**
     * Parity guard. Every IEEE-754 comparison with NaN is false, so `<=` and `>` are not each other's
     * inverse there — writing one platform with `<=` and the other with `>` made the twins disagree on a
     * NaN coverage (Swift said plausible, Kotlin said SAME_SECOND_OVER_COUNT). Both now negate `>`.
     */
    @Test
    fun nonFiniteCoverageIsUnmeasurableOnBothPlatforms() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(Double.NaN, 0.5),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(Double.NaN, Double.NaN),
        )
    }

    /**
     * The verdict keys on coverage first; it must not depend on collapsed <= coverage holding.
     *
     * #977: this expected PLAUSIBLE before the floor existed, which was the bug rather than the intent —
     * half the beat-time is missing at 0.5. The property under test is unchanged and is now shown more
     * sharply: `collapsed` at 9.9 screams over-count and the verdict still follows `coverage`.
     */
    @Test
    fun collapsedAboveCoverageStillClassifiesOnCoverageFirst() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(0.5, 9.9),
        )
    }
}
