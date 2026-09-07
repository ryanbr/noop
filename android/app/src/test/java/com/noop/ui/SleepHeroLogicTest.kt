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
        // Today is the day after the newest night, so the newest night IS last night. Stated rather
        // than implied: the count is now measured from today, so a test that does not say what day it
        // is would be asserting against the machine's clock.
        val today = LocalDate.of(2026, 8, 13)
        assertEquals(0, calendarNightsAgo(nav, 0, utc, today))   // last night
        assertEquals(3, calendarNightsAgo(nav, 1, utc, today))   // 3 calendar nights ago, NOT index 1
        assertEquals("3 nights ago", nightRelativeLabel(calendarNightsAgo(nav, 1, utc, today)))
    }

    @Test
    fun matchesIndex_whenNightsAreConsecutive() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(
            nightOn(LocalDate.of(2026, 8, 13)),
            nightOn(LocalDate.of(2026, 8, 12)),
            nightOn(LocalDate.of(2026, 8, 11)),
        )
        val today = LocalDate.of(2026, 8, 13)
        assertEquals(0, calendarNightsAgo(nav, 0, utc, today))
        assertEquals(1, calendarNightsAgo(nav, 1, utc, today))
        assertEquals(2, calendarNightsAgo(nav, 2, utc, today))
    }

    @Test
    fun fallsBackToIndex_whenOutOfRangeOrEmpty() {
        val utc = TimeZone.getTimeZone("UTC")
        val today = LocalDate.of(2026, 8, 13)
        assertEquals(5, calendarNightsAgo(emptyList(), 5, utc, today))
        assertEquals(9, calendarNightsAgo(nightOn(LocalDate.of(2026, 8, 13)).let { listOf(it) }, 9, utc, today))
    }

    /**
     * The bug this anchoring exists for. Measured from the newest RECORDED night, offset 0 was always
     * zero, so the hero read "Last night" over a night that could be days old.
     *
     * A reporter whose newest night was Saturday saw it titled "Last night" on Monday, directly above
     * the correct date in accent colour: two adjacent labels contradicting each other. That is what
     * read as bad processing and sent the investigation into the sleep stager. The stager question was
     * real and separate; this line was simply naming the wrong night.
     */
    @Test
    fun aStaleNewestNightIsNotCalledLastNight() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(nightOn(LocalDate.of(2026, 9, 5)))     // woke Saturday morning
        val monday = LocalDate.of(2026, 9, 7)
        assertEquals(2, calendarNightsAgo(nav, 0, utc, monday))
        assertEquals("2 nights ago", nightRelativeLabel(calendarNightsAgo(nav, 0, utc, monday)))
    }

    /** A night that genuinely ended this morning still reads "Last night". */
    @Test
    fun theNightThatEndedThisMorningIsStillLastNight() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(nightOn(LocalDate.of(2026, 9, 7)))
        assertEquals(0, calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 7)))
        assertEquals("Last night", nightRelativeLabel(calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 7))))
    }

    /**
     * A night ending in the small hours belongs to the PREVIOUS logical day (#144's 04:00 roll), so
     * both sides of the comparison are put on that scale. Mixing them would report such a night one
     * further back than it is.
     */
    @Test
    fun aNightEndingBeforeFourAmCountsAgainstThePreviousLogicalDay() {
        val utc = TimeZone.getTimeZone("UTC")
        // Woke at 02:00 on the 7th: logically that is the 6th's night.
        val endTs = LocalDate.of(2026, 9, 7).atStartOfDay(ZoneOffset.UTC).plusHours(2).toEpochSecond()
        val nav = listOf(listOf(SleepSession(deviceId = "d", startTs = endTs - 6 * 3600, endTs = endTs)))
        // And it is now 02:00 on the 7th too, which is still logically the 6th.
        assertEquals(0, calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 6)))
    }

    /** A future-dated night must not produce a negative count; it falls back to the index. */
    @Test
    fun aFutureNightFallsBackToTheIndex() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(nightOn(LocalDate.of(2026, 9, 20)))
        assertEquals(0, calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 7)))
    }
}
