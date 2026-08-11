package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic coverage for the Sleep card-order persistence (#sleep-layout): default order, encode/decode
 * round-trip, reorder, and the never-hide "insert missing card at its default position" invariant. No
 * Android context — these are the pure functions the Arrange editor + Sleep render rely on. Mirrors the
 * macOS SleepLayoutPrefs tests and the sibling TodayLayoutPrefs tests.
 */
class SleepLayoutPrefsTest {

    @Test
    fun emptyOrUnset_yieldsDefaultOrder() {
        assertEquals(SleepSection.defaultOrder, SleepLayoutPrefs.decodeOrder(null))
        assertEquals(SleepSection.defaultOrder, SleepLayoutPrefs.decodeOrder(""))
        assertEquals(SleepSection.defaultOrder, SleepLayoutPrefs.decodeOrder("   "))
    }

    @Test
    fun encodeDecode_roundTripsAReorderedList() {
        val reordered = listOf(
            SleepSection.NIGHT_DETAIL, SleepSection.SLEEP_MARKS, SleepSection.ASLEEP_DURATION,
            SleepSection.STAGES, SleepSection.SLEEP_DEBT, SleepSection.STAGES_VS_TYPICAL,
            SleepSection.HOURS_VS_NEEDED, SleepSection.CONSISTENCY,
        )
        val encoded = SleepLayoutPrefs.encode(reordered)
        assertEquals("nightDetail,sleepMarks,asleepDuration,stages,sleepDebt,stagesVsTypical,hoursVsNeeded,consistency", encoded)
        assertEquals(reordered, SleepLayoutPrefs.decodeOrder(encoded))
    }

    /** A saved order that leads with `asleepDuration` and ends on `sleepMarks` keeps those two placements
     *  while every card missing from the save inserts at its default position (all before asleepDuration,
     *  since each has a lower default index). */
    @Test
    fun decode_insertsMissingCardsAtDefaultPositionRelativeToSaved_neverHides() {
        val decoded = SleepLayoutPrefs.decodeOrder("asleepDuration,sleepMarks")
        assertEquals(SleepSection.entries.size, decoded.size)
        assertEquals(
            listOf(
                SleepSection.STAGES, SleepSection.NIGHT_DETAIL, SleepSection.SLEEP_DEBT,
                SleepSection.STAGES_VS_TYPICAL, SleepSection.ASLEEP_DURATION, SleepSection.SLEEP_MARKS,
                SleepSection.HOURS_VS_NEEDED, SleepSection.CONSISTENCY,
            ),
            decoded,
        )
    }

    /** Whatever the input, every card always renders — unknown tokens dropped, duplicates collapsed, and
     *  no card is ever hidden by a partial/messy save. */
    @Test
    fun decode_alwaysReturnsEveryCard() {
        for (input in listOf("nightDetail,BOGUS,nightDetail, ,stages", "sleepDebt", "zzz,stages,,stages")) {
            val decoded = SleepLayoutPrefs.decodeOrder(input)
            assertEquals(SleepSection.entries.toSet(), decoded.toSet())
            assertEquals(SleepSection.entries.size, decoded.size)
        }
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(SleepSection.defaultOrder, SleepLayoutPrefs.decodeOrder("nope,,zzz"))
    }

    @Test
    fun hiddenSections_areExplicitReversibleAndDeduplicated() {
        val hidden = SleepLayoutPrefs.decodeHidden("stages,BOGUS,stages,sleepDebt")
        assertEquals(listOf(SleepSection.STAGES, SleepSection.SLEEP_DEBT), hidden)
        assertEquals("stages,sleepDebt", SleepLayoutPrefs.encodeHidden(hidden))
    }

    @Test
    fun visibleOrder_filtersHiddenWithoutChangingSavedOrder() {
        val order = "nightDetail,sleepMarks,asleepDuration,stages,sleepDebt,stagesVsTypical"
        assertEquals(
            listOf(
                SleepSection.NIGHT_DETAIL, SleepSection.SLEEP_MARKS, SleepSection.STAGES,
                SleepSection.STAGES_VS_TYPICAL, SleepSection.HOURS_VS_NEEDED, SleepSection.CONSISTENCY,
            ),
            SleepLayoutPrefs.visibleOrder(order, "asleepDuration,sleepDebt"),
        )
        assertEquals(SleepSection.entries.size, SleepLayoutPrefs.decodeOrder(order).size)
    }

    @Test
    fun newOrPreviouslyMissingCards_defaultToVisible() {
        val visible = SleepLayoutPrefs.visibleOrder("stages,nightDetail", "nightDetail")
        assertTrue(SleepSection.SLEEP_MARKS in visible)
        assertTrue(SleepSection.ASLEEP_DURATION in visible)
    }

    /** defaultOrder must cover EVERY entry: the never-hide merge sorts by default index, so an entry
     *  missing from the default order could otherwise be dropped or mis-sorted. Twin of the Swift test. */
    @Test
    fun defaultOrderCoversEveryEntry() {
        assertEquals(SleepSection.entries.toSet(), SleepSection.defaultOrder.toSet())
        assertEquals(SleepSection.entries.size, SleepSection.defaultOrder.size)
    }

    @Test
    fun sectionRawKeysAreStableAndUnique() {
        val raws = SleepSection.entries.map { it.raw }
        assertEquals("raw keys must be unique (they're the persisted identity)", raws.size, raws.toSet().size)
        // Pin the exact wire strings — they cross the .noopbak boundary and must match macOS byte-for-byte.
        assertEquals(
            listOf("sleepMarks", "stages", "nightDetail", "sleepDebt", "stagesVsTypical", "asleepDuration", "hoursVsNeeded", "consistency"),
            raws,
        )
    }
}
