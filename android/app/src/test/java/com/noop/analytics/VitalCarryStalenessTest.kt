package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of `VitalCarryStalenessTests.swift` — the two must agree case for case, since the
 * staleness bound decides what number a tile shows and the platforms may not disagree about that.
 *
 * The regression: NOOP showed "Respiratory 15.6" every day for a fortnight, which was the last value
 * of a WHOOP CSV import that ended 2026-07-30, carried forward unbounded by two "latest vital"
 * resolvers.
 */
class VitalCarryStalenessTest {

    // ── cutoffKey ────────────────────────────────────────────────────────────

    @Test
    fun cutoffKeyIsTodayMinusCarryDays() {
        assertEquals("2026-08-06", Baselines.cutoffKey("2026-08-13", 7))
        assertEquals("2026-08-13", Baselines.cutoffKey("2026-08-13", 0))
    }

    @Test
    fun cutoffKeyCrossesMonthAndYearBoundaries() {
        assertEquals("2026-02-24", Baselines.cutoffKey("2026-03-03", 7))
        assertEquals("2025-12-27", Baselines.cutoffKey("2026-01-03", 7))
    }

    /** Leap day is a real calendar step, not a 365-day assumption. */
    @Test
    fun cutoffKeyHandlesLeapYear() {
        assertEquals("2028-02-27", Baselines.cutoffKey("2028-03-05", 7))
    }

    /** Fail CLOSED: an unparseable key admits only today rather than opening the carry wide. */
    @Test
    fun cutoffKeyFailsClosedOnGarbage() {
        assertEquals("not-a-day", Baselines.cutoffKey("not-a-day", 7))
    }

    // ── freshestCarried ──────────────────────────────────────────────────────

    @Test
    fun carriesAValueInsideTheWindow() {
        val points = listOf("2026-08-01" to 16.0, "2026-08-10" to 15.6)
        val got = Baselines.freshestCarried(points, "2026-08-13", 7)
        assertEquals(15.6, got?.second!!, 1e-9)
        assertEquals("2026-08-10", got.first)
    }

    /**
     * THE REPORTED BUG: the import's last day is 2026-07-30 and "today" is 2026-08-13 — 14 days.
     * It must not be presented as the latest reading.
     */
    @Test
    fun dropsTheFourteenDayOldImportThatShowed156() {
        val points = listOf(
            "2026-07-28" to 16.0,
            "2026-07-29" to 16.2,
            "2026-07-30" to 15.6,
        )
        assertNull(Baselines.freshestCarried(points, "2026-08-13", 7))
    }

    /** The window is inclusive at its edge and exclusive one day past it. */
    @Test
    fun windowEdgeIsInclusive() {
        assertEquals(
            15.6,
            Baselines.freshestCarried(listOf("2026-08-06" to 15.6), "2026-08-13", 7)?.second!!,
            1e-9,
        )
        assertNull(Baselines.freshestCarried(listOf("2026-08-05" to 15.6), "2026-08-13", 7))
    }

    /**
     * Only the NEWEST point is judged: an old value is not rescued by a fresh one, and a fresh value
     * is not blocked by old ones sitting behind it in the series.
     */
    @Test
    fun judgesOnlyTheNewestPoint() {
        val points = listOf("2026-07-30" to 15.6, "2026-08-12" to 14.1)
        assertEquals(14.1, Baselines.freshestCarried(points, "2026-08-13", 7)?.second!!, 1e-9)
    }

    @Test
    fun todaysOwnValueAlwaysCarries() {
        assertEquals(
            14.1,
            Baselines.freshestCarried(listOf("2026-08-13" to 14.1), "2026-08-13", 7)?.second!!,
            1e-9,
        )
    }

    @Test
    fun emptySeriesCarriesNothing() {
        assertNull(Baselines.freshestCarried(emptyList<Pair<String, Double>>(), "2026-08-13", 7))
    }

    /**
     * A future-dated row (a bad-clock strap) is newer than the cutoff, so it still resolves — the
     * future-clock guard is the caller's `day < todayKey` bound, not this one. Pinned so the division
     * of responsibility is explicit rather than accidental.
     */
    @Test
    fun futureDatedRowIsNotFilteredHere() {
        assertEquals(
            14.1,
            Baselines.freshestCarried(listOf("2026-09-01" to 14.1), "2026-08-13", 7)?.second!!,
            1e-9,
        )
    }

    // ── the constant itself ──────────────────────────────────────────────────

    /**
     * The bound must stay well inside [Baselines.staleDays] — past that the personal baseline judging
     * the value is itself stale, so presenting the value as "latest" is doubly wrong. The literal 7
     * pins the cross-platform contract: this number must equal the Swift `vitalCarryDays`.
     */
    @Test
    fun carryWindowIsShorterThanBaselineStaleness() {
        assertTrue(Baselines.vitalCarryDays < Baselines.staleDays)
        assertEquals(7, Baselines.vitalCarryDays)
    }
}
