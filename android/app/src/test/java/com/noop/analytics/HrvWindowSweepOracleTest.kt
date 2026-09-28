package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The window sweep buckets exactly as the rescan it replaced (#2556 follow-up).
 *
 * [SleepStager.sessionHrvWindows] used to re-filter the whole R-R segment once per five-minute window. The
 * contract above it already guarantees ts-sorted input, so each window's beats are a contiguous run and one
 * advancing index does the same job; on a 27,879-beat night the Swift measurement was 0.90 ms to 0.03 ms.
 *
 * Cost is not the risk here, output is: this function produces the HRV that lands in the daily row, the
 * sleep-session cache, the Health card and the baseline later nights are scored against. So this is an
 * ORACLE rather than a unit test. [naiveWindows] re-implements the original bucketing directly from the
 * rule, then hands each bucket to the SAME downstream cleaning and RMSSD the production path uses, and the
 * two whole [SleepStager.HrvWindow] lists must match.
 *
 * Comparing whole windows rather than bucket sizes is deliberate: `cleanBeats` is post-cleaning, so a test
 * that only counted raw bucket members would pass while the values on screen moved.
 *
 * The case spread mirrors the Swift oracle that verified the Swift half: dense, sparse, duplicate
 * timestamps (which the contract warns about), everything crammed into the final window, a beat exactly on
 * a boundary, and empty.
 */
class HrvWindowSweepOracleTest {

    /** The bucketing exactly as it was before the sweep, straight from the rule. */
    private fun naiveWindows(
        start: Long, end: Long, rr: List<RrInterval>, stages: List<StageSegment>,
    ): List<SleepStager.HrvWindow> {
        val seg = rr.filter { it.ts in start..end }
        if (seg.isEmpty()) return emptyList()
        val windowS = 5 * 60L
        val out = ArrayList<SleepStager.HrvWindow>()
        var t = start
        do {
            val isFinal = t + windowS >= end
            val bucket = seg.filter { it.ts >= t && (isFinal || it.ts < t + windowS) }.map { it.rrMs.toDouble() }
            val cleaned = HrvAnalyzer.cleanRRGapAware(bucket)
            val rmssd = if (cleaned.nn.size >= HrvAnalyzer.MIN_BEATS) {
                HrvAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous)
            } else {
                null
            }
            val center = t + windowS / 2
            val stage = stages.firstOrNull { center >= it.start && center < it.end }?.stage ?: "?"
            out.add(SleepStager.HrvWindow(t, stage, cleaned.nn.size, rmssd))
            t += windowS
        } while (t < end)
        return out
    }

    private class SplitMix(seed: Long) {
        private var state = seed * -0x61c8_8646_80b5_83ebL
        fun next(): Long {
            state += -0x61c8_8646_80b5_83ebL
            var z = state
            z = (z xor (z ushr 30)) * -0x40a7_b892_e31b_1a47L
            z = (z xor (z ushr 27)) * -0x6b2f_b644_ecce_ee15L
            return (z xor (z ushr 31)) and Long.MAX_VALUE
        }
    }

    @Test
    fun `the sweep produces the same windows as the rescan across every night shape`() {
        val start = 1_790_000_000L
        var cases = 0
        for (seed in listOf(1L, 2L, 3L, 5L, 8L, 13L, 21L, 34L, 55L, 89L)) {
            val g = SplitMix(seed)
            for (durMin in listOf(1, 4, 5, 6, 59, 60, 300, 480)) {
                val end = start + durMin * 60L
                val shapes = mutableListOf<Pair<String, List<RrInterval>>>()

                val dense = ArrayList<RrInterval>()
                var ts = start
                while (ts <= end) { dense.add(RrInterval(deviceId = "d", ts = ts, rrMs = (700 + g.next() % 400).toInt())); ts++ }
                shapes.add("dense" to dense)

                val sparse = ArrayList<RrInterval>()
                ts = start
                while (ts <= end) { sparse.add(RrInterval(deviceId = "d", ts = ts, rrMs = 800)); ts += g.next() % 900 + 1 }
                shapes.add("sparse" to sparse)

                val dup = ArrayList<RrInterval>()
                ts = start
                while (ts <= end) { repeat(3) { dup.add(RrInterval(deviceId = "d", ts = ts, rrMs = 750)) }; ts += 7 }
                shapes.add("duplicate timestamps" to dup)

                shapes.add("all in the final window" to
                    (maxOf(start, end - 120)..end).map { RrInterval(deviceId = "d", ts = it, rrMs = 900) })
                shapes.add("one beat on a boundary" to listOf(RrInterval(deviceId = "d", ts = start + 300, rrMs = 800)))
                shapes.add("empty" to emptyList())

                for ((label, rr) in shapes) {
                    cases++
                    assertEquals(
                        "$label, ${durMin}min, seed $seed",
                        naiveWindows(start, end, rr, emptyList()),
                        SleepStager.sessionHrvWindows(start, end, rr, emptyList()),
                    )
                }
            }
        }
        assertEquals("the spread must actually have run", 480, cases)
    }
}
