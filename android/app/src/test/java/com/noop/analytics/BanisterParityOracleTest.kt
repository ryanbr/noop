package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-identical parity oracle for the #1624 Banister baseline, against the compiled Swift twin.
 *
 * The expected block is the verbatim stdout of `StrainScorer.swift`'s own functions, extracted and
 * compiled standalone on Linux and run over the same eight intensities. Analytics is the strictest half
 * of the parity contract — the numbers must agree, not merely the approach — and this change edited the
 * same formula by hand on both platforms, which is exactly when they drift.
 *
 * Calls the low-level functions with explicit durations rather than going through `strain()`, so the two
 * sides are fed identical inputs and any difference is the formula's, not the sampling's.
 */
class BanisterParityOracleTest {
    @Test
    fun `every intensity matches the compiled Swift twin`() {
        val rest = 50.0
        val mx = 190.0
        val reserve = mx - rest
        val b = StrainScorer.banisterBMen
        val floor = StrainScorer.banisterBaselineRatePerMinute(b)
        val denom = StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, "male")

        val out = StringBuilder()
        for (f in listOf(0.0, 0.05, 0.10, 0.15, 0.20, 0.35, 0.60, 1.00)) {
            val bpm = (rest + f * (mx - rest)).toInt()
            val hr = (0 until 24 * 60 * 60).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = bpm) }
            val durs = List(hr.size) { 1.0 / 60.0 }
            val trimp = StrainScorer.banisterTRIMP(hr, rest, reserve, durs, b, floorRatePerMinute = floor)
            val score = StrainScorer.trimpToStrain(trimp, denom)
            out.append(String.format(java.util.Locale.ROOT, "%.2f=%.6f%n", f, score))
        }
        assertEquals(SWIFT.trimStart('\n'), out.toString().replace(System.lineSeparator(), "\n"))
    }

    private companion object {
        const val SWIFT = """
0.00=0.000000
0.05=0.000000
0.10=0.000000
0.15=49.270000
0.20=58.140000
0.35=71.670000
0.60=84.800000
1.00=100.000000
"""
    }
}
