package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The per-day probe readout. Twin of the Swift `StoreProbeTallyTests`, pinned against the SAME literals:
 * the line is read off one shared strap log, so a one-sided change to the format would make two platforms'
 * logs incomparable exactly when they are being compared.
 */
class StoreProbeTallyTest {

    /**
     * A warm two-strap pass: the scoring loop's 21 owner probes plus the steps loop's 60, and one gravity
     * witness per steps day. This is the shape the line exists to make readable.
     */
    @Test
    fun rendersCallsAndMillisInOrder() {
        val line = StoreProbeTally.logLine(
            listOf(Triple("ownerHr", 81L, 1.24), Triple("gravityFp", 60L, 1.89)),
        )
        assertEquals("analyzeRecent storeProbes total=3130ms ownerHr=81/1240ms gravityFp=60/1890ms", line)
    }

    /**
     * A default SINGLE-strap install skips the owner probe entirely (#970), so zero calls must render as
     * zero rather than being omitted: "not measured" and "measured, and it was free" are different
     * findings, and only one of them means the batching idea is pointless for that user.
     */
    @Test
    fun zeroCallsStillRender() {
        val line = StoreProbeTally.logLine(
            listOf(Triple("ownerHr", 0L, 0.0), Triple("gravityFp", 60L, 1.89)),
        )
        assertEquals("analyzeRecent storeProbes total=1890ms ownerHr=0/0ms gravityFp=60/1890ms", line)
    }

    @Test
    fun noProbesSaysSoRatherThanRenderingAnEmptyTail() {
        assertEquals("analyzeRecent storeProbes total=0ms (no probes)", StoreProbeTally.logLine(emptyList()))
    }

    /**
     * The renderer clamps, and that is a contract about the RENDERER rather than a claim about the probes:
     * both sides now count monotonic nanoseconds, so neither can hand it a negative. It is pinned anyway
     * because a negative or non-finite seconds value is the one input where Swift's round-half-away-from-
     * zero and Kotlin's round-half-up disagree, at exactly -0.5 ms, and the two platforms render into one
     * shared strap log. A probe cannot take less than no time, so nothing true is lost by flooring it.
     */
    @Test
    fun negativeAndNonFiniteSecondsClampToZeroOnBothSides() {
        val line = StoreProbeTally.logLine(
            listOf(Triple("ownerHr", 3L, -0.0005), Triple("gravityFp", 1L, Double.NaN)),
        )
        assertEquals("analyzeRecent storeProbes total=0ms ownerHr=3/0ms gravityFp=1/0ms", line)
    }

    /**
     * Sixty calls of exactly 20 ms. The counters accumulate INTEGER nanos and divide once, so this is
     * exactly 1.2 s and renders 1200ms. Converting each call to seconds and summing those would spend
     * sixty roundings and land a hair either side. The Swift twin
     * `StoreProbeCountsTests.testAccumulatesIntegerNanosRatherThanSummingDoubles` pins the same literal,
     * because both platforms render into ONE shared strap log and a divergence there reads as two devices
     * behaving differently rather than as an arithmetic difference.
     */
    @Test
    fun recordAccumulatesIntegerNanosLikeTheSwiftTwin() {
        StoreProbeTally.reset()
        repeat(60) { StoreProbeTally.recordGravityFp(20_000_000L) }
        assertEquals(
            "analyzeRecent storeProbes total=1200ms dayOwner=0/0ms ownerHr=0/0ms gravityFp=60/1200ms",
            StoreProbeTally.line(),
        )
    }

    /**
     * [StoreProbeTally.reset] DRAINS. A line has to describe one pass, and the passes this runs under are
     * the back-to-back ones an offload storm is made of, so counters left standing would make every pass
     * after the first report its predecessors' work as its own.
     */
    @Test
    fun resetDrainsSoAPassCannotInheritTheLastOne() {
        StoreProbeTally.reset()
        StoreProbeTally.recordOwnerHr(5_000_000L)
        StoreProbeTally.reset()
        assertEquals(
            "analyzeRecent storeProbes total=0ms dayOwner=0/0ms ownerHr=0/0ms gravityFp=0/0ms",
            StoreProbeTally.line(),
        )
    }

    /**
     * The LOCKED-override lookup is counted separately from the presence probe. They are different queries
     * with different costs, and collapsing them is exactly what hid the lookup: the first cut counted the
     * probe alone, reported it as nearly free, and left a warm pass with seconds unaccounted for. The Swift
     * twin `StoreProbeCountsTests.testDayOwnerAndOwnerHrAreCountedSeparately` pins the same separation.
     */
    @Test
    fun dayOwnerAndOwnerHrAreCountedSeparately() {
        StoreProbeTally.reset()
        repeat(81) { StoreProbeTally.recordDayOwner(20_000_000L) }
        repeat(132) { StoreProbeTally.recordOwnerHr(1_000_000L) }
        assertEquals(
            "analyzeRecent storeProbes total=1752ms dayOwner=81/1620ms ownerHr=132/132ms gravityFp=0/0ms",
            StoreProbeTally.line(),
        )
    }
}
