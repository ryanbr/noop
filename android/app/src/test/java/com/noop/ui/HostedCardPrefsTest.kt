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
        // Every id must be origin-namespaced so it routes to the right provider and can't collide with a
        // Today DashboardCard id.
        HostedCard.entries.forEach { card ->
            assertTrue("hosted id must be namespaced: ${card.raw}", card.raw.contains('.'))
        }
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
