package com.noop.analytics

import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SleepStagerV2.respRegularity] reads its twiddle factors from a per-night table ([SleepStagerV2.RespDft])
 * instead of evaluating `cos`/`sin` for every epoch. The stage labels hang on this value, so the table must be a
 * pure speed change: the reference below is the function as it was, and the two must return the SAME Double,
 * bit for bit, for every window, including the null cases, with one table reused across windows the way a
 * night reuses it. Mirrors the Swift `SleepStagerRespDFTTableTests`.
 */
class SleepStagerRespDftTableTest {

    /** The function before the table, verbatim. */
    private fun respRegularityBeforeTable(beats: List<Pair<Double, Double>>): Double? {
        if (beats.size < 12) return null
        val t0 = beats.first().first; val tN = beats.last().first
        if (tN <= t0) return null
        val n = ceil((tN - t0) / 0.25 - 1e-9).toInt()
        if (n < 16) return null
        val y = DoubleArray(n)
        var seg = 0
        for (i in 0 until n) {
            val t = t0 + 0.25 * i
            while (seg < beats.size - 2 && beats[seg + 1].first < t) seg++
            val ta = beats[seg].first; val tb = beats[seg + 1].first
            val va = beats[seg].second; val vb = beats[seg + 1].second
            y[i] = if (tb <= ta) va else va + ((t - ta) / (tb - ta)).coerceIn(0.0, 1.0) * (vb - va)
        }
        val mean = y.sum() / n
        for (i in 0 until n) y[i] -= mean
        val kLo = ceil(0.15 * 0.25 * n).toInt()
        val kHi = floor(0.40 * 0.25 * n).toInt()
        if (kHi < kLo || kLo < 0) return null
        var maxP = 0.0; var sumP = 0.0
        for (k in kLo..kHi) {
            var re = 0.0; var im = 0.0
            val w = -2.0 * PI * k / n
            for (j in 0 until n) { val a = w * j; re += y[j] * cos(a); im += y[j] * sin(a) }
            val p = re * re + im * im
            sumP += p
            if (p > maxP) maxP = p
        }
        if (sumP == 0.0) return null
        return maxP / sumP
    }

    /** A beat window as `features()` builds one: whole-second times, several beats a second or none, 300…2000 ms. */
    private fun windowForTest(rng: java.util.Random, span: Int, density: Int): List<Pair<Double, Double>> {
        val beats = ArrayList<Pair<Double, Double>>()
        for (s in 0 until span) {
            if (rng.nextInt(100) >= density) continue
            repeat(1 + rng.nextInt(2)) {
                val breathing = 60.0 * sin(s * 2 * PI / (3 + rng.nextInt(4)))
                val v = 650.0 + breathing + rng.nextInt(400) - 200
                beats.add((1_790_000_000L + s).toDouble() to v.coerceIn(300.0, 2000.0))
            }
        }
        beats.sortWith(compareBy<Pair<Double, Double>>({ it.first }, { it.second }))
        return beats
    }

    @Test
    fun tableReturnsTheSameValueAsRecomputingEveryFactor() {
        val rng = java.util.Random(0x57A6E)
        val dft = HashMap<Int, SleepStagerV2.RespDft>()
        var nonNull = 0
        repeat(3_000) {
            val span = if (rng.nextInt(5) == 0) 2 + rng.nextInt(208) else 205 + rng.nextInt(5)
            val beats = windowForTest(rng, span, 30 + rng.nextInt(71))
            val before = respRegularityBeforeTable(beats)
            val now = SleepStagerV2.respRegularity(beats, dft)
            assertEquals("window of ${beats.size} beats over $span s", before?.toRawBits(), now?.toRawBits())
            if (before != null) nonNull++
        }
        assertTrue("most windows must reach the transform: $nonNull", nonNull > 2_000)
        assertTrue("several grid lengths must share the table: ${dft.size}", dft.size > 3)
    }

    @Test
    fun answerDoesNotDependOnWhatTheTableHeldBefore() {
        val rng = java.util.Random(0xD1F7)
        val warm = HashMap<Int, SleepStagerV2.RespDft>()
        repeat(200) {
            val beats = windowForTest(rng, 200 + rng.nextInt(10), 80)
            val fromWarm = SleepStagerV2.respRegularity(beats, warm)
            val fromCold = SleepStagerV2.respRegularity(beats, HashMap())
            assertEquals(fromCold?.toRawBits(), fromWarm?.toRawBits())
        }
    }
}
