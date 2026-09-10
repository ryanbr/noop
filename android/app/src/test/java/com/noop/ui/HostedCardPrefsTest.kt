package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic coverage for the Today-hosted card selection (#today-hosted-cards): the origin-namespaced
 * rawValues (a byte-identical cross-platform contract), the EMPTY opt-in default, and the encode/decode
 * idiom (JSON array, unknown-id drop, de-dupe, order-preserving). Mirrors the macOS HostedCardPrefs tests;
 * a drift on either side fails one of the twins.
 */
class HostedCardPrefsTest {

    /** The rawValues are persisted + cross the .noopbak wire, so they are frozen. Origin-namespaced. */
    @Test
    fun rawValues_areTheFrozenNamespacedContract() {
        assertEquals("sleep.sleepMarks", HostedCard.SLEEP_MARKS.raw)
        assertEquals("sleep.asleepDuration", HostedCard.ASLEEP_DURATION.raw)
        // Origin-namespaced on a tab other than Sleep, and frozen for the same reason: this id rides
        // .noopbak, so the Swift twin has to spell it identically or a restore drops the card.
        assertEquals("stress.today", HostedCard.STRESS_TODAY.raw)
        // Trends-origin ids, frozen for the same reason: they ride .noopbak, so the Swift twin has to
        // spell each one identically or a restore silently drops that card from the selection.
        assertEquals("trends.hrv", HostedCard.TREND_HRV.raw)
        assertEquals("trends.restingHr", HostedCard.TREND_RESTING_HR.raw)
        assertEquals("trends.effort", HostedCard.TREND_EFFORT.raw)
        // Every id must be origin-namespaced so it routes to the right provider and can't collide with a
        // Today DashboardCard id.
        HostedCard.entries.forEach { card ->
            assertTrue("hosted id must be namespaced: ${card.raw}", card.raw.contains('.'))
        }
    }

    /**
     * Every hosted card opens the thing it mirrors, and the tap-to-log card opens nothing.
     *
     * Worth pinning because the failure is silent: a card wired to the wrong destination still renders,
     * still taps, and simply lands somewhere else. Nothing about the screen looks wrong. Twin of the
     * Swift `testEachHostedCardOpensItsOwnTab`.
     */
    @Test
    fun eachHostedCardOpensItsOwnThing() {
        // The tap-to-log card must NOT navigate: its buttons are its purpose, and a wrapper would put a
        // second meaning behind the same press.
        assertEquals(HostedDestination.None, HostedCard.SLEEP_MARKS.destination)
        HostedCard.entries.filter { it != HostedCard.SLEEP_MARKS }.forEach {
            assertTrue("${it.raw} taps through to nothing", it.destination != HostedDestination.None)
        }
        // Sleep-origin cards land on the Sleep tab; the trends land on their own metric page, which is
        // where the Charge and Effort key tiles already send you.
        HostedCard.entries.filter { it.origin == "Sleep" && it != HostedCard.SLEEP_MARKS }.forEach {
            assertEquals("${it.raw} should open Sleep", HostedDestination.Sleep, it.destination)
        }
        assertEquals(HostedDestination.Stress, HostedCard.STRESS_TODAY.destination)
        assertEquals(HostedDestination.Metric("hrv"), HostedCard.TREND_HRV.destination)
        assertEquals(HostedDestination.Metric("rhr"), HostedCard.TREND_RESTING_HR.destination)
        assertEquals(HostedDestination.Metric("strain"), HostedCard.TREND_EFFORT.destination)
    }

    /** Opt-in surface: nothing is hosted until the user adds a card. */
    @Test
    fun default_isEmpty() {
        assertEquals(emptyList<HostedCard>(), HostedCard.defaultSelection)
        assertEquals(emptyList<HostedCard>(), HostedCardPrefs.decodeEnabled(null))
        assertEquals(emptyList<HostedCard>(), HostedCardPrefs.decodeEnabled(""))
        assertEquals(emptyList<HostedCard>(), HostedCardPrefs.decodeEnabled("   "))
    }

    @Test
    fun encodeDecode_roundTripsInOrder() {
        val selection = listOf(HostedCard.SLEEP_MARKS)
        val encoded = HostedCardPrefs.encode(selection)
        assertEquals("[\"sleep.sleepMarks\"]", encoded)
        assertEquals(selection, HostedCardPrefs.decodeEnabled(encoded))
    }

    /** Unknown ids are dropped, duplicates collapsed — and an all-unknown decode stays EMPTY (unlike the
     *  dashboard, an opt-in surface has no sensible non-empty default to back-fill). */
    @Test
    fun decode_dropsUnknownAndDedupes_neverBackfills() {
        assertEquals(
            listOf(HostedCard.SLEEP_MARKS),
            HostedCardPrefs.decodeEnabled("[\"sleep.sleepMarks\",\"trends.bogus\",\"sleep.sleepMarks\"]"),
        )
        assertEquals(emptyList<HostedCard>(), HostedCardPrefs.decodeEnabled("[\"nope\",\"also.nope\"]"))
    }

    /** Accepts the legacy comma-joined form as well as the canonical JSON array. */
    @Test
    fun decode_acceptsLegacyCommaForm() {
        assertEquals(listOf(HostedCard.SLEEP_MARKS), HostedCardPrefs.decodeEnabled("sleep.sleepMarks"))
    }
}
