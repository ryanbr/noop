package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

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
}
