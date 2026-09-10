package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Log-map denominator behavior outside the map's domain, against the compiled Swift twin.
 *
 * D ≤ 1 has no ln-based score: ln(1) = 0 divides to ±∞, ln(D) < 0 below 1 flips the sign, and ln(D)
 * is NaN at or below 0. Before the guard, Swift returned `+Inf` for D = 1 while this side's
 * `roundToLong()` saturated to 9.223372036854776E16 — the same input, two different answers.
 *
 * Every expected value below is the verbatim stdout of `StrainScorer.swift`'s `trimpToStrain`,
 * extracted and compiled standalone on Linux (`swiftc -O main.swift -o t && ./t`), printed as
 * `trimp|D|effort` with `%.17g`:
 *
 * ```
 * 1.0000|1|0
 * 1.0000|0.5|0
 * 1.0000|0|0
 * 1.0000|-3|0
 * 1.0000|nan|0
 * 0.0000|7201|0
 * 1.0000|7201|7.7999999999999998
 * 100.0000|7201|51.960000000000001
 * 7200.0000|7201|100
 * 1.0000|1.0000000000000002|3.1216573840826803e+17
 * 1.0000|2|100
 * ```
 */
class StrainScorerDenominatorDomainTest {

    @Test
    fun `denominator at or below one scores zero`() {
        for (denominator in listOf(1.0, 0.5, 0.0, -3.0, Double.NaN)) {
            val s = StrainScorer.trimpToStrain(1.0, denominator)
            assertTrue("D = $denominator produced a non-finite Effort", s.isFinite())
            assertEquals("D = $denominator", 0.0, s, 0.0)
        }
    }

    @Test
    fun `valid denominators are unchanged`() {
        assertEquals(7.7999999999999998, StrainScorer.trimpToStrain(1.0, 7201.0), 1e-9)
        assertEquals(51.960000000000001, StrainScorer.trimpToStrain(100.0, 7201.0), 1e-9)
        assertEquals(100.0, StrainScorer.trimpToStrain(7200.0, 7201.0), 1e-9)
        assertEquals(100.0, StrainScorer.trimpToStrain(1.0, 2.0), 1e-9)
    }

    /**
     * Just above the boundary the score is enormous but finite, and it must stay a Double on both
     * platforms — this is the value `roundToLong()` clipped to Long.MAX / 100.
     *
     * Loosely toleranced on purpose: ln(1 + 2⁻⁵²) is ~2.2e-16, so a 1-ulp difference between the
     * JVM's and Darwin's `log` moves the quotient by ~±30 absolute. Linux observes exactly
     * 3.1216573840826803e+17 on both sides; the assertion checks the magnitude, not the last bits.
     */
    @Test
    fun `denominator just above one stays finite`() {
        val s = StrainScorer.trimpToStrain(1.0, 1.0000000000000002)
        assertTrue(s.isFinite())
        assertEquals(3.1216573840826803e+17, s, 1e4)
    }

    /**
     * Non-finite TRIMP propagates rather than being caught by the domain guard — the guard is about
     * D, not TRIMP. Both platforms agree here only because this side no longer rounds through Long
     * (`roundToLong()` mapped +∞ to Long.MAX), so pin the non-finite propagation behavior. Swift
     * oracle, same formula:
     * `inf|7201.0|inf`, `nan|7201.0|nan`.
     */
    @Test
    fun `non-finite trimp propagates`() {
        val inf = StrainScorer.trimpToStrain(Double.POSITIVE_INFINITY, 7201.0)
        assertTrue(!inf.isFinite())
        assertTrue(!inf.isNaN())
        assertTrue(inf > 0)
        assertTrue(StrainScorer.trimpToStrain(Double.NaN, 7201.0).isNaN())
    }
}
