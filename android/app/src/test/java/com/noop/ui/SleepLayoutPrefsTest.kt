package com.noop.ui

import org.junit.Assert.assertEquals
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
            SleepSection.STAGES, SleepSection.NAPS, SleepSection.SLEEP_DEBT,
            SleepSection.STAGES_VS_TYPICAL,
        )
        val encoded = SleepLayoutPrefs.encode(reordered)
        assertEquals(
            "nightDetail,sleepMarks,asleepDuration,stages,naps,sleepDebt,stagesVsTypical",
            encoded,
        )
        assertEquals(reordered, SleepLayoutPrefs.decodeOrder(encoded))
    }

    /** A saved order that explicitly ends on `sleepMarks` and leads with `asleepDuration` must keep those
     *  two placements while every card missing from the save inserts at its default position (all before
     *  asleepDuration, since each has a lower default index). */
    @Test
    fun decode_insertsMissingCardsAtDefaultPositionRelativeToSaved_neverHides() {
        val partial = "asleepDuration,sleepMarks"
        val decoded = SleepLayoutPrefs.decodeOrder(partial)
        assertEquals(SleepSection.entries.size, decoded.size)
        assertEquals(
            listOf(
                SleepSection.STAGES, SleepSection.NAPS, SleepSection.NIGHT_DETAIL,
                SleepSection.SLEEP_DEBT, SleepSection.STAGES_VS_TYPICAL,
                SleepSection.ASLEEP_DURATION, SleepSection.SLEEP_MARKS,
            ),
            decoded,
        )
    }

    @Test
    fun decode_dropsUnknownTokensAndCollapsesDuplicates() {
        val messy = "nightDetail,BOGUS,nightDetail,naps, ,naps"
        val decoded = SleepLayoutPrefs.decodeOrder(messy)
        assertEquals(SleepSection.entries.size, decoded.size)
        assertEquals(
            listOf(
                // sleepMarks(0), stages(1) precede nightDetail(3) → insert before it in default order;
                // the saved nightDetail→naps order is preserved; sleepDebt(4)/stagesVsTypical(5)/
                // asleepDuration(6) all follow naps(2) but nightDetail(3) precedes them, so they append.
                SleepSection.SLEEP_MARKS, SleepSection.STAGES, SleepSection.NIGHT_DETAIL,
                SleepSection.NAPS, SleepSection.SLEEP_DEBT, SleepSection.STAGES_VS_TYPICAL,
                SleepSection.ASLEEP_DURATION,
            ),
            decoded,
        )
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(SleepSection.defaultOrder, SleepLayoutPrefs.decodeOrder("nope,,zzz"))
    }

    @Test
    fun hiddenSections_areExplicitReversibleAndDeduplicated() {
        val hidden = SleepLayoutPrefs.decodeHidden("naps,BOGUS,naps,sleepDebt")
        assertEquals(listOf(SleepSection.NAPS, SleepSection.SLEEP_DEBT), hidden)
        assertEquals("naps,sleepDebt", SleepLayoutPrefs.encodeHidden(hidden))
    }

    @Test
    fun visibleOrder_filtersHiddenWithoutChangingSavedOrder() {
        val order = "nightDetail,sleepMarks,asleepDuration,stages,naps,sleepDebt,stagesVsTypical"
        assertEquals(
            listOf(
                SleepSection.NIGHT_DETAIL, SleepSection.SLEEP_MARKS, SleepSection.STAGES,
                SleepSection.SLEEP_DEBT, SleepSection.STAGES_VS_TYPICAL,
            ),
            SleepLayoutPrefs.visibleOrder(order, "asleepDuration,naps"),
        )
        assertEquals(SleepSection.entries.size, SleepLayoutPrefs.decodeOrder(order).size)
    }

    @Test
    fun newOrPreviouslyMissingCards_defaultToVisible() {
        val visible = SleepLayoutPrefs.visibleOrder("stages,nightDetail,sleepDebt", "nightDetail")
        assertEquals(true, SleepSection.NAPS in visible)
        assertEquals(true, SleepSection.SLEEP_MARKS in visible)
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
            listOf(
                "sleepMarks", "stages", "naps", "nightDetail",
                "sleepDebt", "stagesVsTypical", "asleepDuration",
            ),
            raws,
        )
    }
}
