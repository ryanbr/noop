package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic coverage for the Today section-order persistence (#today-layout): default order, encode/decode
 * round-trip, reorder, and the never-hide "insert missing section at its default position" invariant. No
 * Android context — these are the pure functions the editor + Today render rely on. Mirrors the macOS
 * TodayLayoutPrefs tests.
 */
class TodayLayoutPrefsTest {

    @Test
    fun emptyOrUnset_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(null))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(""))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("   "))
    }

    @Test
    fun encodeDecode_roundTripsAReorderedList() {
        val reordered = listOf(
            TodaySection.HEART_RATE, TodaySection.HERO, TodaySection.YOUR_CARDS,
            TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
            TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.JOURNAL,
            TodaySection.MENSTRUAL_CYCLE, TodaySection.DATA_SOURCES,
            TodaySection.ADDED_CARDS,
        )
        val encoded = TodayLayoutPrefs.encode(reordered)
        assertEquals(
            "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal,menstrualCycle,dataSources,addedCards",
            encoded,
        )
        assertEquals(reordered, TodayLayoutPrefs.decodeOrder(encoded))
    }

    /** The v1 upgrade path: an order saved by the FIRST cut (6 sections — no hero/liveSession, which were
     *  pinned then) must surface the two new sections at the TOP (their default position), not teleport
     *  them to the bottom of the user's saved order. */
    @Test
    fun decode_savedOrderFromFirstCut_insertsHeroAndSessionAtTheirDefaultPosition() {
        val firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        assertEquals(
            listOf(
                TodaySection.HERO, TodaySection.LIVE_SESSION,
                TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.WORKOUTS,
                TodaySection.HEART_RATE, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS,
                TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES,
                TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.decodeOrder(firstCut),
        )
    }

    @Test
    fun decode_insertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved_neverHides() {
        // A saved order that omits WORKOUTS + YOUR_CARDS (and the newer hero/liveSession) must still
        // surface all of them, each before the first saved section that follows it in the default order.
        val partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        val decoded = TodayLayoutPrefs.decodeOrder(partial)
        assertEquals(TodaySection.entries.size, decoded.size)
        assertEquals(
            listOf(
                // hero(0), liveSession(1), workouts(4) all precede heartRate(5) in default order, so all
                // insert before the saved heartRate, in default order among themselves:
                TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.WORKOUTS,
                TodaySection.HEART_RATE, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                TodaySection.RECOVERY_VITALS,
                TodaySection.YOUR_CARDS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL,
                TodaySection.DATA_SOURCES,
                TodaySection.ADDED_CARDS,
            ),
            decoded,
        )
    }

    @Test
    fun decode_dropsUnknownTokensAndCollapsesDuplicates() {
        val messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        val decoded = TodayLayoutPrefs.decodeOrder(messy)
        assertEquals(TodaySection.entries.size, decoded.size)
        assertEquals(
            listOf(
                // Every missing section's default index precedes yourCards(7), so each inserts before it,
                // accumulating in default order; the saved yourCards→heartRate order is preserved at the end.
                TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS,
                TodaySection.KEY_METRICS, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS,
                TodaySection.YOUR_CARDS, TodaySection.HEART_RATE,
                TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES,
                TodaySection.ADDED_CARDS,
            ),
            decoded,
        )
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("nope,,zzz"))
    }

    @Test
    fun hiddenSections_areExplicitReversibleAndDeduplicated() {
        val hidden = TodayLayoutPrefs.decodeHidden("workouts,BOGUS,workouts,journal")
        assertEquals(listOf(TodaySection.WORKOUTS, TodaySection.JOURNAL), hidden)
        assertEquals("workouts,journal", TodayLayoutPrefs.encodeHidden(hidden))
    }

    @Test
    fun visibleOrder_filtersHiddenWithoutChangingSavedOrder() {
        val order = "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal"
        assertEquals(
            listOf(
                TodaySection.HEART_RATE, TodaySection.YOUR_CARDS, TodaySection.LIVE_SESSION,
                TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.RECOVERY_VITALS,
                TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES,
                TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.visibleOrder(order, "hero,workouts"),
        )
        assertEquals(TodaySection.entries.size, TodayLayoutPrefs.decodeOrder(order).size)
    }

    @Test
    fun newOrPreviouslyMissingSections_defaultToVisible() {
        val visible = TodayLayoutPrefs.visibleOrder(
            "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards",
            "workouts",
        )
        assertEquals(true, TodaySection.JOURNAL in visible)
    }

    /** defaultOrder must cover EVERY entry: the never-hide merge sorts by default index, so an entry
     *  missing from the default order could otherwise be dropped or mis-sorted. Twin of the Swift test. */
    @Test
    fun defaultOrderCoversEveryEntry() {
        assertEquals(TodaySection.entries.toSet(), TodaySection.defaultOrder.toSet())
        assertEquals(TodaySection.entries.size, TodaySection.defaultOrder.size)
    }

    /** The user-edited Latest Workouts feed length bounds, pinned on both platforms. */
    @Test
    fun workoutsCountBoundsArePinned() {
        assertEquals(1, TodayLayoutPrefs.minWorkoutsCount)
        assertEquals(14, TodayLayoutPrefs.maxWorkoutsCount)
        assertEquals(4, TodayLayoutPrefs.defaultWorkoutsCount)
    }

    /** Unset/empty fields mean EVERY chip is enabled (the historical default — existing users see no
     *  change). Unknown tokens are ignored; an all-junk string degrades to the same default. */
    @Test
    fun workoutFields_unsetMeansAllEnabled() {
        assertEquals(WorkoutField.entries.toSet(), TodayLayoutPrefs.decodeWorkoutFields(null))
        assertEquals(WorkoutField.entries.toSet(), TodayLayoutPrefs.decodeWorkoutFields(""))
        assertEquals(WorkoutField.entries.toSet(), TodayLayoutPrefs.decodeWorkoutFields("   "))
        assertEquals(WorkoutField.entries.toSet(), TodayLayoutPrefs.decodeWorkoutFields("nope,,zzz"))
    }

    /** The stored string is the deterministic canonical-order encoding — a Set toggle order can never
     *  produce two spellings of the same chip set. */
    @Test
    fun workoutFields_encodeIsCanonicalOrder() {
        val fields = setOf(WorkoutField.CALORIES, WorkoutField.STRAIN, WorkoutField.DURATION)
        assertEquals("strain,duration,calories", TodayLayoutPrefs.encodeWorkoutFields(fields))
        assertEquals(fields, TodayLayoutPrefs.decodeWorkoutFields("strain,duration,calories"))
    }

    /** A partial set round-trips; unknown tokens are dropped and duplicates collapsed. */
    @Test
    fun workoutFields_decodeDropsUnknownAndDedupes() {
        val decoded = TodayLayoutPrefs.decodeWorkoutFields("heartRate,BOGUS,heartRate,calories")
        assertEquals(setOf(WorkoutField.HEART_RATE, WorkoutField.CALORIES), decoded)
    }

    /** The four chip raw keys are the persisted identity — pinned byte-identical to macOS. */
    @Test
    fun workoutFieldRawKeysArePinned() {
        assertEquals(
            listOf("strain", "duration", "heartRate", "calories"),
            WorkoutField.entries.map { it.raw },
        )
    }

    /** The user-edited Latest Workouts feed window options, pinned on both platforms. */
    @Test
    fun workoutsWindowOptionsArePinned() {
        assertEquals(14, TodayLayoutPrefs.defaultWorkoutsWindowDays)
        assertEquals(listOf(14, 30, 365), TodayLayoutPrefs.workoutsWindowOptions)
        // The snap keeps every option and rejects everything else (the header can only name options).
        assertEquals(14, TodayLayoutPrefs.snapWorkoutsWindowDays(45))
        assertEquals(30, TodayLayoutPrefs.snapWorkoutsWindowDays(30))
        assertEquals(365, TodayLayoutPrefs.snapWorkoutsWindowDays(365))
    }

    @Test
    fun sectionRawKeysAreStableAndUnique() {
        val raws = TodaySection.entries.map { it.raw }
        assertEquals("raw keys must be unique (they're the persisted identity)", raws.size, raws.toSet().size)
        // Pin the exact wire strings — they cross the .noopbak boundary and must match macOS byte-for-byte.
        assertEquals(
            listOf(
                "hero", "liveSession", "synthesis", "keyMetrics",
                "workouts", "heartRate", "recoveryVitals", "yourCards", "menstrualCycle", "journal",
                "dataSources", "addedCards",
            ),
            raws,
        )
    }
}
