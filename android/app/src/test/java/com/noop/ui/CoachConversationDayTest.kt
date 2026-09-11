package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/**
 * Pins [CoachViewModel.isStaleConversation] — the day boundary that retires the coach transcript.
 *
 * The bug it guards: the ViewModel outlives a night (Android keeps the process alive for days), so a
 * question asked today was answered inside yesterday's conversation. The data context is rebuilt from
 * the store on every send, so the numbers were current, but the assistant's own earlier turns state
 * yesterday's figures and the model stays consistent with them — the coach "only talks about the
 * imported data" even after a night of fresh strap data. Force-quitting was the only cure.
 */
class CoachConversationDayTest {

    private fun day(y: Int, m: Int, d: Int) = LocalDate.of(y, m, d).toEpochDay()

    @Test
    fun freshSessionIsNeverStale() {
        // Nothing sent yet this session: there is no transcript to retire.
        assertFalse(CoachViewModel.isStaleConversation(null, day(2026, 8, 22)))
    }

    @Test
    fun sameDayKeepsTheConversation() {
        val today = day(2026, 8, 22)
        assertFalse(CoachViewModel.isStaleConversation(today, today))
    }

    @Test
    fun overnightRetiresTheConversation() {
        // The reported case: last turn yesterday evening, next question this morning.
        assertFalse(CoachViewModel.isStaleConversation(day(2026, 8, 21), day(2026, 8, 21)))
        assertTrue(CoachViewModel.isStaleConversation(day(2026, 8, 21), day(2026, 8, 22)))
    }

    @Test
    fun longGapRetiresTheConversation() {
        assertTrue(CoachViewModel.isStaleConversation(day(2026, 6, 11), day(2026, 8, 22)))
    }

    @Test
    fun clockMovingBackwardsKeepsTheConversation() {
        // Flying west, a timezone change or an NTP correction can move the local day BACKWARDS
        // mid-conversation. That must not wipe a transcript the user is in the middle of, which is
        // why the rule is strictly forward (`>`) and not `!=`.
        assertFalse(CoachViewModel.isStaleConversation(day(2026, 8, 22), day(2026, 8, 21)))
    }

    @Test
    fun yearBoundaryIsJustAnotherDay() {
        assertTrue(CoachViewModel.isStaleConversation(day(2025, 12, 31), day(2026, 1, 1)))
        assertFalse(CoachViewModel.isStaleConversation(day(2026, 1, 1), day(2025, 12, 31)))
    }

    // ── localEpochDay: recovering a RESTORED transcript's day from its rows (#2087) ──────────────
    //
    // conversationDay lives in memory, so a process restart brought it back null. isStaleConversation
    // treats null as "never stale" by design, so a conversation restored from any previous day was
    // never retired, and the scheduled brief, which only surfaces onto an EMPTY transcript, could
    // never appear again after the first day. The day has to come back from the rows themselves.

    private val utc: ZoneId = ZoneId.of("UTC")

    @Test
    fun `an instant maps to its local day`() {
        // 2026-09-11T00:00:00Z
        val midnightUtc = LocalDate.of(2026, 9, 11).atStartOfDay(utc).toEpochSecond()
        assertEquals(day(2026, 9, 11), CoachViewModel.localEpochDay(midnightUtc, utc))
        assertEquals(day(2026, 9, 11), CoachViewModel.localEpochDay(midnightUtc + 86_399, utc))
        assertEquals(day(2026, 9, 12), CoachViewModel.localEpochDay(midnightUtc + 86_400, utc))
    }

    /** The zone decides the day, not the instant: the same second is two different local days either
     *  side of a date line. A transcript is retired against the user's calendar, not UTC's. */
    @Test
    fun `the same instant can be two different local days`() {
        val instant = LocalDate.of(2026, 9, 11).atStartOfDay(utc).toEpochSecond()
        assertEquals(day(2026, 9, 11), CoachViewModel.localEpochDay(instant, utc))
        assertEquals(day(2026, 9, 10), CoachViewModel.localEpochDay(instant, ZoneId.of("America/New_York")))
    }

    /**
     * A local day is not always 86 400 seconds, which is why this goes through the calendar rather
     * than dividing. On a spring-forward day the local day is 23 hours: an instant 23 hours after
     * local midnight is already the NEXT day, and arithmetic on 86 400 would still call it the same one.
     */
    @Test
    fun `a short day from daylight saving still counts as one day`() {
        val ny = ZoneId.of("America/New_York")
        // 2026-03-08 is the US spring-forward date: 02:00 local jumps to 03:00, so the day is 23h long.
        val localMidnight = LocalDate.of(2026, 3, 8).atStartOfDay(ny).toEpochSecond()
        assertEquals(day(2026, 3, 8), CoachViewModel.localEpochDay(localMidnight, ny))
        assertEquals(day(2026, 3, 8), CoachViewModel.localEpochDay(localMidnight + 23 * 3_600 - 1, ny))
        assertEquals(day(2026, 3, 9), CoachViewModel.localEpochDay(localMidnight + 23 * 3_600, ny))
    }

    /** The NEWEST row dates the transcript, not the oldest: a conversation started last night and
     *  carried past midnight belongs to today, and must not be retired out from under the user.
     *  Twin of the Swift `testTheNewestRowDecidesTheTranscriptDay`. */
    @Test
    fun `the newest row decides the transcript day`() {
        fun at(y: Int, m: Int, d: Int, h: Int) =
            LocalDate.of(y, m, d).atStartOfDay(utc).toEpochSecond() + h * 3_600L
        val rows = listOf(at(2026, 9, 10, 23), at(2026, 9, 11, 0))
        val lastDay = CoachViewModel.localEpochDay(rows.max(), utc)
        assertEquals(day(2026, 9, 11), lastDay)
        assertFalse(CoachViewModel.isStaleConversation(lastDay, day(2026, 9, 11)))
    }

    /** The two rules together, which is how the restore path uses them: a transcript last written late
     *  last night is stale the moment the local date rolls over, even minutes later. */
    @Test
    fun `a transcript written last night is stale after local midnight`() {
        val lastNight = LocalDate.of(2026, 9, 10).atStartOfDay(utc).toEpochSecond() + 23 * 3_600
        val lastDay = CoachViewModel.localEpochDay(lastNight, utc)
        assertEquals(day(2026, 9, 10), lastDay)
        assertTrue(CoachViewModel.isStaleConversation(lastDay, day(2026, 9, 11)))
        assertFalse(CoachViewModel.isStaleConversation(lastDay, day(2026, 9, 10)))
    }
}
