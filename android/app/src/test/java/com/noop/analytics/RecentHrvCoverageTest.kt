package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #1853-adjacent: the counts behind "N of the last M nights recorded no HRV".
 *
 * The line only helps if both numbers are right, and both are Ints with the same units, so an inverted
 * pair reads as "5 of the last 3 nights" — absurd to a person, invisible to a compiler. These pin the
 * order as well as the arithmetic. Byte-identical twin: Swift `BaselinesRecentHrvCoverageTests`.
 */
class RecentHrvCoverageTest {

    /** The reported shape: five observed nights, three of them empty. */
    @Test fun `counts observed nights and the empty ones among them`() {
        val days = listOf("2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05", "2026-09-06")
        val hrv = listOf(44.0, null, null, 47.0, null)
        val cov = Baselines.recentHrvCoverage(days, hrv, "2026-09-06")
        assertEquals(5, cov.observed)
        assertEquals(3, cov.missing)
    }

    /** Only days the app has a row for, so a fresh install is not charged for nights it never saw. */
    @Test fun `a day outside the window is not observed`() {
        val days = listOf("2026-08-01", "2026-09-06")
        val hrv = listOf<Double?>(null, null)
        val cov = Baselines.recentHrvCoverage(days, hrv, "2026-09-06", window = 14)
        assertEquals("the August night is 36 days back, outside the window", 1, cov.observed)
        assertEquals(1, cov.missing)
    }

    /** A future-dated row cannot be a night that already happened. */
    @Test fun `a day after today is ignored`() {
        val cov = Baselines.recentHrvCoverage(listOf("2026-09-07"), listOf(null), "2026-09-06")
        assertEquals(0, cov.observed)
        assertEquals(0, cov.missing)
    }

    /** Every night counted: the caller must then say nothing extra. */
    @Test fun `a complete window reports nothing missing`() {
        val days = listOf("2026-09-05", "2026-09-06")
        val cov = Baselines.recentHrvCoverage(days, listOf(50.0, 51.0), "2026-09-06")
        assertEquals(2, cov.observed)
        assertEquals(0, cov.missing)
    }

    /** No rows, and an unparseable today, both yield zeroes rather than a fabricated count. */
    @Test fun `empty and unparseable inputs are zero`() {
        assertEquals(0, Baselines.recentHrvCoverage(emptyList(), emptyList(), "2026-09-06").observed)
        assertEquals(0, Baselines.recentHrvCoverage(listOf("2026-09-06"), listOf(null), "not-a-day").observed)
    }
}
