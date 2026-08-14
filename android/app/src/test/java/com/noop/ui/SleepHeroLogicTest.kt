package com.noop.ui

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.TimeZone

/**
 * #1311: the Sleep → Stages carousel steps by RECORDED night, so a night with no data (strap
 * off-body) is skipped. Labelling by the flat carousel index then makes two nights either side of
 * the gap read as consecutive and desyncs the "N nights ago" labels. `calendarNightsAgo` restores
 * the true calendar distance from each night's local wake-day. Mirrors iOS SleepView.nightsAgo.
 */
class SleepHeroLogicTest {

    private fun nightOn(date: LocalDate): List<SleepSession> {
        val endTs = date.atStartOfDay(ZoneOffset.UTC).plusHours(7).toEpochSecond()  // 07:00 UTC wake
        return listOf(SleepSession(deviceId = "d", startTs = endTs - 6 * 3600, endTs = endTs))
    }

    @Test
    fun countsCalendarNights_notCarouselIndex_whenANightIsMissing() {
        val utc = TimeZone.getTimeZone("UTC")
        // Newest night 2026-08-13, then a night 3 calendar days earlier — the two nights between had no
        // data, so they aren't in navDays. navDays is newest-first.
        val navDays = nightOn(LocalDate.of(2026, 8, 13)) to nightOn(LocalDate.of(2026, 8, 10))
        val nav = listOf(navDays.first, navDays.second)
        assertEquals(0, calendarNightsAgo(nav, 0, utc))         // last night
        assertEquals(3, calendarNightsAgo(nav, 1, utc))         // 3 calendar nights ago, NOT index 1
        assertEquals("3 nights ago", nightRelativeLabel(calendarNightsAgo(nav, 1, utc)))
    }

    @Test
    fun matchesIndex_whenNightsAreConsecutive() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(
            nightOn(LocalDate.of(2026, 8, 13)),
            nightOn(LocalDate.of(2026, 8, 12)),
            nightOn(LocalDate.of(2026, 8, 11)),
        )
        assertEquals(0, calendarNightsAgo(nav, 0, utc))
        assertEquals(1, calendarNightsAgo(nav, 1, utc))
        assertEquals(2, calendarNightsAgo(nav, 2, utc))
    }

    @Test
    fun fallsBackToIndex_whenOutOfRangeOrEmpty() {
        val utc = TimeZone.getTimeZone("UTC")
        assertEquals(5, calendarNightsAgo(emptyList(), 5, utc))
        assertEquals(9, calendarNightsAgo(nightOn(LocalDate.of(2026, 8, 13)).let { listOf(it) }, 9, utc))
    }
}
