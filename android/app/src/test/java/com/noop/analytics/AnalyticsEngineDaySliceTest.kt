package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Locks `AnalyticsEngine.daySliceFromNight` (#997): for a PAST day the calendar-day streams
 * (dayHr/daySteps/dayGravity) are a non-truncated subset of the night window analyzeRecent already read,
 * so re-reading them from the store is redundant — the slice must equal an in-range filter of the night
 * list (which, for a complete night, equals the direct read: same inclusive bounds, same ts-ASC order).
 * And the shortcut must DECLINE (null -> the caller reads directly) in the unsafe cases: TODAY's calendar
 * day runs past the 18 h night cap, and a night read at the stream limit may be truncated inside the day
 * span. If any of that drifts, samples get attributed to the wrong day / dropped, so this is the safety
 * net for the read-skip. Mirrors the macOS `DaySliceFromNightTests` (same bounds fixture).
 */
class AnalyticsEngineDaySliceTest {

    private data class S(val ts: Long)

    // A past day's night window: [dayStart − 30 h, nextMidnight]; the calendar day
    // [dayStart, dayStart + 86400 − 1] sits strictly inside it. Mirrors the real IntelligenceEngine bounds.
    private val dayStart = 1_700_000_000L
    private val nightLo = dayStart - 30 * 3_600L
    private val nightHi = dayStart + 86_400L          // = nextMidnight (a past day's `to`)
    private val dayLo = dayStart
    private val dayHi = dayStart + 86_400L - 1
    private val night = (nightLo..nightHi step 60).map { S(it) }

    @Test fun pastDayReturnsTheInRangeFilterOfTheNightList() {
        val slice = AnalyticsEngine.daySliceFromNight(
            night, nightLo, nightHi, dayLo, dayHi) { it.ts }
        // Byte-identical to filtering the night list (which, for a complete night, equals the direct read).
        assertEquals(night.filter { it.ts in dayLo..dayHi }, slice)
        // Nothing outside the day leaks in; order is preserved (ascending, as the store returned it).
        assertEquals(slice, slice!!.sortedBy { it.ts })
    }

    @Test fun todayDayEndPastTheNightCapDeclines() {
        // TODAY: the night window caps at dayStart + 18 h, so the calendar day (to +24 h) reaches past it.
        val todayNightHi = dayStart + 18 * 3_600L
        assertNull(AnalyticsEngine.daySliceFromNight(
            night, nightLo, todayNightHi, dayLo, dayHi) { it.ts })
    }

    @Test fun dstShiftedDayBeforeTheNightWindowDeclines() {
        // The self-protecting guard the other way: a shifted dayLo that falls before the night window
        // (e.g. a DST-moved local midnight) must decline to the direct read, never slice a partial window.
        assertNull(AnalyticsEngine.daySliceFromNight(
            night, nightLo, nightHi, nightLo - 1, dayHi) { it.ts })
    }

    @Test fun truncatedNightReadDeclines() {
        // A night read that returned exactly `limit` rows may be truncated inside the day span (ORDER BY
        // ts ASC LIMIT drops the LATE rows — exactly where the day sits). Locked at an injected small
        // limit AND at the real 200_000 default the IntelligenceEngine call sites rely on.
        val small = (0L until 10L).map { S(it) }
        assertNull(AnalyticsEngine.daySliceFromNight(
            small, 0, 10, 0, 5, limit = 10) { it.ts })
        val atDefaultLimit = (0L until 200_000L).map { S(it) }
        assertNull(AnalyticsEngine.daySliceFromNight(
            atDefaultLimit, 0, 200_000, 0, 100) { it.ts })
    }

    @Test fun boundsAreInclusiveOnBothEnds() {
        // The store range is inclusive [dayLo, dayHi] (`ts >= from AND ts <= to`); the filter must keep
        // the boundary samples and drop their immediate neighbours.
        val edge = listOf(S(dayLo - 1), S(dayLo), S(dayHi), S(dayHi + 1))
        val slice = AnalyticsEngine.daySliceFromNight(
            edge, nightLo, nightHi, dayLo, dayHi) { it.ts }
        assertEquals(listOf(S(dayLo), S(dayHi)), slice)
    }
}
