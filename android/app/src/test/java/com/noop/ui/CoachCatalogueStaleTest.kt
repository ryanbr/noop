package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins when the Coach model catalogue is pulled again.
 *
 * The rule decides how often the app talks to a provider without being asked, so it is worth holding
 * still. Written against the companion function rather than the ViewModel, which needs an Application:
 * the same split [CoachConversationDayTest] uses for [CoachViewModel.isStaleConversation].
 */
class CoachCatalogueStaleTest {

    private val week = CoachViewModel.MODEL_REFRESH_INTERVAL_MS
    private val now = 1_800_000_000_000L

    @Test
    fun `a catalogue never pulled is stale`() {
        // The first visit has to fetch, or the live list never arrives for anyone.
        assertTrue(CoachViewModel.isCatalogueStale(0L, now))
    }

    @Test
    fun `a catalogue pulled just now is fresh`() {
        assertFalse(CoachViewModel.isCatalogueStale(now, now))
    }

    @Test
    fun `one millisecond short of the interval is still fresh`() {
        assertFalse(CoachViewModel.isCatalogueStale(now - week + 1, now))
    }

    @Test
    fun `exactly the interval is due`() {
        // The boundary is inclusive, so a weekly visitor refreshes rather than never qualifying.
        assertTrue(CoachViewModel.isCatalogueStale(now - week, now))
    }

    @Test
    fun `well past the interval is due`() {
        assertTrue(CoachViewModel.isCatalogueStale(now - week * 5, now))
    }

    @Test
    fun `a clock moved backwards keeps the cached list`() {
        // A negative age must not read as "very stale" and refetch on every single visit until the
        // clock catches up. Same direction isStaleConversation takes for a backwards clock.
        assertFalse(CoachViewModel.isCatalogueStale(now + week, now))
    }

    @Test
    fun `the interval is a week`() {
        assertTrue(week == 7L * 24 * 60 * 60 * 1000)
    }
}
