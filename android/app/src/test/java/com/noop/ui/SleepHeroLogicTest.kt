package com.noop.ui

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
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

    // The nav-header date formats in the DEFAULT zone (`clockLabelFor` takes no zone), while these
    // fixtures are built in UTC. Without pinning, an onset at 01:00 UTC formats as the PREVIOUS day
    // anywhere west of UTC, so the date assertions below passed in UTC and Europe and failed in the
    // Americas. Pin it for the class and restore, rather than leaving a suite that depends on where
    // the contributor happens to live.
    private var defaultZone: TimeZone? = null

    @Before
    fun pinZone() {
        defaultZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    @After
    fun restoreZone() {
        defaultZone?.let { TimeZone.setDefault(it) }
    }

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
     * Only TODAY is rolled to the logical day; the shown night keeps its calendar wake-date, because
     * that is the key navDays groups by.
     *
     * Rolling both sides collapsed distinct carousel entries onto one label: a night ending 07:00 and
     * the next ending 02:00 are separate groups but the same logical day, so both printed the same
     * "nights ago". This pins that they stay apart.
     */
    @Test
    fun twoNightsEitherSideOfTheRollKeepDistinctLabels() {
        val utc = TimeZone.getTimeZone("UTC")
        fun wakeAt(d: LocalDate, hour: Long) =
            d.atStartOfDay(ZoneOffset.UTC).plusHours(hour).toEpochSecond()
        val early = wakeAt(LocalDate.of(2026, 9, 7), 2)     // 02:00 on the 7th
        val prior = wakeAt(LocalDate.of(2026, 9, 6), 7)     // 07:00 on the 6th
        val nav = listOf(
            listOf(SleepSession(deviceId = "d", startTs = early - 5 * 3600, endTs = early)),
            listOf(SleepSession(deviceId = "d", startTs = prior - 6 * 3600, endTs = prior)),
        )
        val today = LocalDate.of(2026, 9, 7)               // mid-morning on the 7th
        assertEquals(0, calendarNightsAgo(nav, 0, utc, today))
        assertEquals(1, calendarNightsAgo(nav, 1, utc, today))
    }

    /**
     * The small hours are why today is rolled at all: at 02:00 the logical day has not turned over,
     * so the night that ended yesterday morning is still "Last night" rather than "1 night ago".
     */
    @Test
    fun beforeFourAmYesterdayMorningsNightIsStillLastNight() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(nightOn(LocalDate.of(2026, 9, 6)))          // woke 07:00 on the 6th
        // 02:00 on the 7th: logicalDayNow is still the 6th.
        assertEquals(0, calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 6)))
        assertEquals("Last night", nightRelativeLabel(calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 6))))
    }

    /** A future-dated night must not produce a negative count; it falls back to the index. */
    @Test
    fun aFutureNightFallsBackToTheIndex() {
        val utc = TimeZone.getTimeZone("UTC")
        val nav = listOf(nightOn(LocalDate.of(2026, 9, 20)))
        assertEquals(0, calendarNightsAgo(nav, 0, utc, LocalDate.of(2026, 9, 7)))
    }

    /**
     * The pre-roll window, pinned because it currently lands on the NEGATIVE branch and gets the right
     * answer from what reads like an error fallback.
     *
     * Wake at 02:00 and open the tab at 03:00: the night's calendar date is the 7th while the logical
     * day is still the 6th, so the distance is -1. Offset 0 is genuinely "Last night" there, and the
     * fallback says so — but nothing distinguished this real case from clock skew, so a later tightening
     * of that branch would break it silently.
     */
    @Test
    fun aNightWokenBeforeTheRollStillReadsLastNight() {
        val utc = TimeZone.getTimeZone("UTC")
        val endTs = LocalDate.of(2026, 9, 7).atStartOfDay(ZoneOffset.UTC).plusHours(2).toEpochSecond()
        val nav = listOf(listOf(SleepSession(deviceId = "d", startTs = endTs - 5 * 3600, endTs = endTs)))
        // 03:00 on the 7th: the logical day has not rolled, so it is still the 6th.
        val logicalToday = LocalDate.of(2026, 9, 6)
        assertEquals(0, calendarNightsAgo(nav, 0, utc, logicalToday))
        assertEquals("Last night", nightRelativeLabel(calendarNightsAgo(nav, 0, utc, logicalToday)))
    }

    // MARK: - #2199 nav-header date

    /** The hero's own label always wins; the navDays fallback is only for a night that did not decode. */
    @Test
    fun navHeaderClockLabel_prefersTheHerosOwnLabel() {
        val nav = listOf(nightOn(LocalDate.of(2026, 8, 13)), nightOn(LocalDate.of(2026, 8, 12)))
        assertEquals("hero", navHeaderClockLabel("hero", nav, offset = 1, is24h = true))
    }

    /**
     * The regression itself. With no hero label the header used to borrow the SleepModel's, which is
     * built for the NEWEST night, so browsing to an older stage-less night printed the newest night's
     * date under a correct "N nights ago". The label must describe the BROWSED night, so the two dates
     * here must differ, and the one returned must be the browsed night's own.
     */
    @Test
    fun navHeaderClockLabel_datesTheBrowsedNight_notTheNewestOne() {
        val nav = listOf(nightOn(LocalDate.of(2026, 8, 13)), nightOn(LocalDate.of(2026, 8, 12)))
        val newest = navHeaderClockLabel(null, nav, offset = 0, is24h = true)
        val browsed = navHeaderClockLabel(null, nav, offset = 1, is24h = true)
        assertNotNull(browsed)
        assertNotEquals("a stage-less night must not borrow the newest night's date", newest, browsed)
        // The window is (min effectiveStartTs, max endTs), so the date shown is the ONSET day: a 07:00
        // wake on the 12th was an 01:00 onset the same day in UTC.
        assertTrue("expected the browsed night's own date, got $browsed", browsed!!.startsWith("Wed 12 Aug"))
    }

    /** An offset past the end of navDays has no night to date, so the header shows nothing at all. */
    @Test
    fun navHeaderClockLabel_returnsNullWhenTheOffsetHasNoNight() {
        val nav = listOf(nightOn(LocalDate.of(2026, 8, 13)))
        assertNull(navHeaderClockLabel(null, nav, offset = 5, is24h = true))
    }

    /** A degenerate group (no usable window) also yields nothing rather than a borrowed date. */
    @Test
    fun navHeaderClockLabel_returnsNullForAnEmptyGroup() {
        assertNull(navHeaderClockLabel(null, listOf(emptyList()), offset = 0, is24h = true))
    }
}
