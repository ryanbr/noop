package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Positioning by date is what makes breaking the line across a missing day mean anything. With index
 * spacing a gap has ZERO width, so the break reads as a chopped line and an isolated day as an orphan dot
 * floating in space, which is exactly what shipping the break without the spacing produced.
 */
class ChartXSpacingTest {

    private fun day(s: String) = java.time.LocalDate.parse(s).toEpochDay() * 86_400L

    /** No timestamps: every existing chart keeps the even spacing it has always had. */
    @Test
    fun `without timestamps the points stay evenly spaced`() {
        assertEquals(listOf(0f, 0.5f, 1f), xFractions(3, null))
    }

    /**
     * The reported shape. 3 Sep, 5 Sep, 6 Sep: the first gap is TWO days and the second is one, so the
     * first must occupy twice the width. Under index spacing both were half the chart.
     */
    @Test
    fun `a two-day gap takes twice the width of a one-day step`() {
        val f = xFractions(3, listOf(day("2026-09-03"), day("2026-09-05"), day("2026-09-06")))
        assertEquals(0f, f[0], 1e-6f)
        assertEquals(2f / 3f, f[1], 1e-6f)   // two days of three
        assertEquals(1f, f[2], 1e-6f)
    }

    /** Consecutive days are evenly spaced, so a fully-measured stretch is unchanged. */
    @Test
    fun `consecutive days are evenly spaced`() {
        val f = xFractions(3, listOf(day("2026-09-01"), day("2026-09-02"), day("2026-09-03")))
        assertEquals(listOf(0f, 0.5f, 1f), f)
    }

    // --- refusing rather than guessing ---

    @Test
    fun `a length mismatch falls back to index spacing`() {
        assertEquals(listOf(0f, 0.5f, 1f), xFractions(3, listOf(day("2026-09-01"))))
    }

    /** Every reading at the same instant has no time order to use. */
    @Test
    fun `a zero span falls back to index spacing`() {
        val t = day("2026-09-01")
        assertEquals(listOf(0f, 0.5f, 1f), xFractions(3, listOf(t, t, t)))
    }

    /** Out-of-order timestamps would place points backwards; index spacing is the honest fallback. */
    @Test
    fun `a non-ascending sequence falls back to index spacing`() {
        val f = xFractions(3, listOf(day("2026-09-03"), day("2026-09-01"), day("2026-09-05")))
        assertEquals(listOf(0f, 0.5f, 1f), f)
    }

    @Test
    fun `fractions always span the full width`() {
        val f = xFractions(4, listOf(day("2026-09-01"), day("2026-09-04"), day("2026-09-05"), day("2026-09-09")))
        assertEquals(0f, f.first(), 1e-6f)
        assertEquals(1f, f.last(), 1e-6f)
        assertTrue(f.zipWithNext().all { (a, b) -> b > a })
    }

    // --- the day-key conversion ---

    /** All-or-nothing: one unparseable day makes the whole chart fall back rather than mixing rules. */
    @Test
    fun `an unparseable day disables date spacing entirely`() {
        assertNull(
            dayEpochSeconds(
                listOf(VitalReading("2026-09-01", 1.0, "d"), VitalReading("nope", 2.0, "d")),
            ),
        )
    }

    @Test
    fun `parseable days convert to ascending epoch seconds`() {
        val t = dayEpochSeconds(
            listOf(VitalReading("2026-09-01", 1.0, "d"), VitalReading("2026-09-03", 2.0, "d")),
        )
        assertEquals(listOf(day("2026-09-01"), day("2026-09-03")), t)
    }

    /**
     * The geometry and the hit-testing must agree, or the chart highlights one day and labels another.
     * Both now derive from this one function, so pinning it pins the pairing: the nearest index to a
     * point's own x is that point.
     */
    @Test
    fun `each point is the nearest index to its own position`() {
        val ts = listOf(day("2026-08-26"), day("2026-09-01"), day("2026-09-05"), day("2026-09-08"))
        val f = xFractions(4, ts)
        val width = 1000f
        f.forEachIndexed { i, frac ->
            val x = frac * width
            val nearest = f.withIndex().minByOrNull { kotlin.math.abs(it.value * width - x) }!!.index
            assertEquals("point $i", i, nearest)
        }
    }
}
