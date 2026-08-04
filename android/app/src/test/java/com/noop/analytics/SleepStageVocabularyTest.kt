package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #979 — both spellings of the wake stage occur in stored hypnograms, and five segment comparisons
 * only recognised one of them.
 *
 * The damaging shape is `stage != "wake"`, used to mean "asleep": an imported `"awake"` segment fell
 * through it and was counted as SLEEP, inflating the efficiency figure. The mirror shape,
 * `stage == "wake"`, under-counted wake time and made the #987 wake refinement skip those segments.
 *
 * Twin of the Swift `SleepStageVocabularyTests`; same cases in the same order.
 */
class SleepStageVocabularyTest {

    /** Both spellings are wake. This is the whole point. */
    @Test fun bothSpellingsAreWake() {
        assertTrue(SleepStageVocabulary.isWake("wake"))
        assertTrue(SleepStageVocabulary.isWake("awake"))
    }

    /** Sleep stages are not wake — the predicate must not swallow the rest of the vocabulary. */
    @Test fun sleepStagesAreNotWake() {
        for (s in listOf("deep", "light", "rem")) {
            assertFalse("$s must not read as wake", SleepStageVocabulary.isWake(s))
        }
    }

    /** Imported JSON is not guaranteed tidy; casing and padding must not decide a sleep score. */
    @Test fun casingAndWhitespaceAreFolded() {
        assertTrue(SleepStageVocabulary.isWake("Awake"))
        assertTrue(SleepStageVocabulary.isWake("  WAKE "))
        assertTrue(SleepStageVocabulary.isWake("\tAwAkE"))
    }

    /**
     * An absent or unknown stage is NOT wake, which preserves the existing behaviour of the callers
     * that treat "anything that is not wake" as asleep. Widening that would be a separate change.
     */
    @Test fun unknownAndEmptyAreNotWake() {
        assertFalse(SleepStageVocabulary.isWake(""))
        assertFalse(SleepStageVocabulary.isWake("   "))
        assertFalse(SleepStageVocabulary.isWake("restless"))
    }

    /**
     * The regression itself, in the shape the importers use: a night of `awake` + `deep` must count
     * only the `deep` span as asleep. Before the fix the `awake` span fell through `!= "wake"` and was
     * added to the asleep total, so this asserted 2x the true value.
     */
    @Test fun awakeSegmentIsNotCountedAsAsleep() {
        val segs = listOf("awake" to 1800, "deep" to 1800)
        val asleep = segs.filter { !SleepStageVocabulary.isWake(it.first) }.sumOf { it.second }
        assertEquals(1800, asleep)
    }

    /** And the mirror shape: wake time must include the `awake` span, which `== "wake"` dropped. */
    @Test fun wakeTotalIncludesBothSpellings() {
        val segs = listOf("wake" to 600, "awake" to 300, "rem" to 1200)
        val wake = segs.filter { SleepStageVocabulary.isWake(it.first) }.sumOf { it.second }
        assertEquals(900, wake)
    }

    /**
     * INTEGRATION, not the predicate. The tests above pass whether or not the five call sites were
     * actually changed — they exercise the rule, not its users. This one exercises a real caller, so it
     * is the test that fails if a site is reverted. Twin of the Swift
     * `testWasoAndDisturbancesCountAnAwakeSegment`.
     *
     * `tst` is computed from a POSITIVE list (light/deep/rem) so it is immune either way at 1080 s;
     * WASO and the disturbance count are not, and read 0 before the fix.
     */
    @Test fun wasoAndDisturbancesCountAnAwakeSegment() {
        val stages = listOf(
            StageSegment(0L, 60L, "wake"),      // pre-onset, clipped out of WASO
            StageSegment(60L, 600L, "light"),
            StageSegment(600L, 900L, "deep"),
            StageSegment(900L, 960L, "awake"),  // the other spelling — 60 s of WASO
            StageSegment(960L, 1200L, "rem"),
        )
        val session = DetectedSleep(0L, 1200L, 0.95, stages, 50, 60.0)
        val m = SleepStager.hypnogramMetrics(session)
        assertEquals("sleep total must be unaffected either way", 1080.0, m.tstS, 1e-9)
        assertEquals("an awake segment is wake after sleep onset", 60.0, m.wasoS, 1e-9)
        assertEquals("and counts as one disturbance", 1, m.disturbances)
    }
}
