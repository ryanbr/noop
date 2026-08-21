package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1505: measure how the two copies of a duplicated second COMPARE, not merely that there are two.
 *
 * A WHOOP 5 emits the beat train live over `0x2A37` — spec-fixed 1/1024-second units, converted on the way
 * in — and again inside its v18 historical record, stored as read. If those are the same beat in two units,
 * a second written by two deliveries holds values 1024/1000 apart. If they are genuinely two beats, the
 * ratios scatter across normal beat-to-beat variability.
 *
 * The field pair that raised the question, from #1451, is `-1s[872#0, 893#0]` — and 893 × 1000/1024 =
 * 872.07. That single pair cannot decide anything: 21 ms is also an ordinary difference between consecutive
 * beats. These tests pin that the measurement reports the distribution honestly in both directions, so a
 * night's worth of pairs can answer what one cannot.
 *
 * Twin of Swift `HRVAnalyzerDuplicatePairTests`.
 */
class DuplicatePairRatioTest {

    private val t0 = 1_780_000_000L

    private fun run(rows: List<Triple<Long, Double, Int?>>) = HrvAnalyzer.duplicatePairRatios(
        rows.map { it.first }, rows.map { it.second }, rows.map { it.third },
    )

    /** The real #1451 pair: two deliveries, one second, values exactly the 1024/1000 ratio apart. */
    @Test fun theFieldPairIsCountedAsATickSignature() {
        val out = run(listOf(Triple(t0, 872.0, 0), Triple(t0, 893.0, 0)))
        assertTrue(out, out.contains("n=1"))
        assertTrue(out, out.contains("tick=1"))
        assertTrue(out, out.contains("other=0"))
        assertEquals("1024", Regex("medPPT=(\\d+)").find(out)!!.groupValues[1])
    }

    /**
     * The honesty requirement: an ordinary pair of DIFFERENT beats must not read as a unit mismatch. 872 vs
     * 940 is a normal difference and lands outside the band — the measurement has to be able to say "no".
     */
    @Test fun anOrdinaryBeatToBeatDifferenceIsNotATickSignature() {
        val out = run(listOf(Triple(t0, 872.0, 0), Triple(t0, 940.0, 0)))
        assertTrue(out, out.contains("tick=0"))
        assertTrue(out, out.contains("other=1"))
    }

    /** Two deliveries that stored the SAME number are exact duplicates, a different finding again. */
    @Test fun anExactDuplicateIsCountedSeparately() {
        val out = run(listOf(Triple(t0, 872.0, 0), Triple(t0, 872.0, 0)))
        assertTrue(out, out.contains("same=1"))
        assertTrue(out, out.contains("tick=0"))
    }

    /**
     * Two CONSECUTIVE beats from one record's array read `ord` 0 then 1, and must be excluded — they are
     * one delivery, so comparing them measures physiology rather than transports. This is the whole reason
     * the pair test keys on `ord` rather than on "two rows share a second".
     */
    @Test fun consecutiveBeatsFromOneDeliveryAreExcluded() {
        assertEquals("rr dupPairs n=0", run(listOf(Triple(t0, 872.0, 0), Triple(t0, 893.0, 1))))
    }

    /** A second carrying more than two rows is ambiguous about which copy pairs with which — skip it. */
    @Test fun secondsWithMoreThanTwoRowsAreSkipped() {
        assertEquals(
            "rr dupPairs n=0",
            run(listOf(Triple(t0, 872.0, 0), Triple(t0, 893.0, 0), Triple(t0, 880.0, 0))),
        )
    }

    /** Rows with no `ord` (written before the column was surfaced) can't be attributed to a delivery. */
    @Test fun rowsWithoutAnOrdAreIgnored() {
        assertEquals("rr dupPairs n=0", run(listOf(Triple(t0, 872.0, null), Triple(t0, 893.0, null))))
    }

    /**
     * Parity: the Swift twin must produce the SAME string for the same input, so a capture read on either
     * platform is comparable. Pinned by value here and in `HRVAnalyzerDuplicatePairTests`.
     */
    @Test fun outputStringIsPinnedForParity() {
        assertEquals(
            "rr dupPairs n=1 same=0 tick=1 other=0 medPPT=1024 spread=1024-1024",
            run(listOf(Triple(t0, 872.0, 0), Triple(t0, 893.0, 0))),
        )
    }

    /**
     * The shape that would actually settle #1505: many pairs, all clustering at the ratio. The spread is
     * reported alongside the median so a tight cluster is distinguishable from a coincidental average.
     */
    @Test fun aPopulationOfTickPairsReportsATightSpread() {
        val rows = ArrayList<Triple<Long, Double, Int?>>()
        for (i in 0 until 10) {
            val live = 850.0 + i * 7
            rows.add(Triple(t0 + i, live, 0))
            rows.add(Triple(t0 + i, live * 1024.0 / 1000.0, 0))   // the same beat, unconverted
        }
        val out = run(rows)
        assertTrue(out, out.contains("n=10"))
        assertTrue(out, out.contains("tick=10"))
        val spread = Regex("spread=(\\d+)-(\\d+)").find(out)!!
        assertTrue(out, spread.groupValues[2].toInt() - spread.groupValues[1].toInt() <= 2)
    }

    /** ...and a population of genuinely different beats must NOT read as a cluster. */
    @Test fun aPopulationOfRealBeatsDoesNotReadAsTicks() {
        val rows = ArrayList<Triple<Long, Double, Int?>>()
        val second = listOf(910.0, 845.0, 990.0, 870.0, 935.0, 820.0, 960.0, 885.0, 1015.0, 830.0)
        for (i in 0 until 10) {
            rows.add(Triple(t0 + i, 900.0, 0))
            rows.add(Triple(t0 + i, second[i], 0))
        }
        val out = run(rows)
        assertTrue(out, out.contains("n=10"))
        assertTrue(out, Regex("tick=(\\d+)").find(out)!!.groupValues[1].toInt() <= 2)
    }
}
