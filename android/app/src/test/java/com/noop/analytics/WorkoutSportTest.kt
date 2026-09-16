package com.noop.analytics

import androidx.health.connect.client.records.ExerciseSessionRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutSportTest {
    @Test fun catalogue_isNonEmpty_andSearchable() {
        assertTrue(WorkoutSport.all.size >= 20)
        val running = WorkoutSport.all.first { it.name == "Running" }
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, running.exerciseType)
    }

    @Test fun running_isDistanceSport_strength_isNot() {
        assertTrue(WorkoutSport.all.first { it.name == "Running" }.isDistanceSport)
        assertTrue(WorkoutSport.all.first { it.name == "Cycling" }.isDistanceSport)
        assertFalse(WorkoutSport.all.first { it.name == "Strength" }.isDistanceSport)
        assertFalse(WorkoutSport.all.first { it.name == "Yoga" }.isDistanceSport)
    }

    /** Asked for by a user. Pinned because the label is what NOOP stores and shows, while the type is
     *  only what Health Connect is told: a rename of either half silently changes one of those. */
    @Test fun nordicWalking_isOffered_andWritesBackAsWalking() {
        val sport = WorkoutSport.all.first { it.name == "Nordic walking" }
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_WALKING, sport.exerciseType)
    }

    /** The batch added for WHOOP parity. Pins the writeback type per sport, because a wrong one is
     *  invisible in NOOP and only shows up in whatever reads Health Connect afterwards. */
    @Test fun whoopParitySports_writeBackAsTheTypeTheyBelongTo() {
        fun typeOf(name: String) = WorkoutSport.all.first { it.name == name }.exerciseType
        // Martial arts, not "other": these are the three most-logged styles under that umbrella.
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS, typeOf("Jiu jitsu"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS, typeOf("Judo"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS, typeOf("Muay Thai"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_DANCING, typeOf("Ballet"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_DANCING, typeOf("Breakdancing"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS, typeOf("Cheerleading"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_FRISBEE_DISC, typeOf("Disc golf"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_SURFING, typeOf("Kiteboarding"))
        // Deliberately generic: no HC type is close enough to claim.
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, typeOf("Parkour"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, typeOf("Hurling/Camogie"))
    }

    @Test fun unknownType_fallsBackToOther() {
        assertEquals("Workout", WorkoutSport.nameFor(Int.MIN_VALUE))
    }

    @Test fun everyDistanceSport_hasValidHcType() {
        WorkoutSport.all.filter { it.isDistanceSport }.forEach {
            assertTrue(it.exerciseType > 0)
        }
    }

    @Test fun default_isOther() {
        assertEquals("Other", WorkoutSport.default.name)
    }

    /** #1195: the manual-workout HC writeback maps a stored sport NAME to its exercise type — case- and
     *  whitespace-tolerant, OTHER_WORKOUT for a free-typed sport not in the catalogue. */
    @Test fun exerciseTypeForName_mapsKnownAndFallsBackForFreeText() {
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, WorkoutSport.exerciseTypeForName("Running"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, WorkoutSport.exerciseTypeForName("  running "))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, WorkoutSport.exerciseTypeForName("Quidditch"))
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, WorkoutSport.exerciseTypeForName(""))
    }

    /** #768: the newly requested presets are present, spelled byte-for-byte the way iOS persists them. */
    @Test fun newPresets_arePresent() {
        val names = WorkoutSport.all.map { it.name }
        listOf(
            "Racquetball", "Volleyball", "Martial arts", "Dancing", "Golf",
            "Climbing", "Stretching", "Skiing", "Snowboarding", "Pickleball",
        ).forEach { assertTrue("$it must be in the catalogue", names.contains(it)) }
    }

    /** Snow sports cover ground, so GPS defaults on; racket/court sports have no route. */
    @Test fun snowSports_areDistance_racketSports_areNot() {
        assertTrue(WorkoutSport.all.first { it.name == "Skiing" }.isDistanceSport)
        assertTrue(WorkoutSport.all.first { it.name == "Snowboarding" }.isDistanceSport)
        assertFalse(WorkoutSport.all.first { it.name == "Racquetball" }.isDistanceSport)
        assertFalse(WorkoutSport.all.first { it.name == "Volleyball" }.isDistanceSport)
    }

    /** Pickleball is an EXTRA (no HC type) → rides on "Other" for writeback but keeps its own label. */
    @Test fun pickleball_isExtra_fallsBackToOther() {
        val pickle = WorkoutSport.all.first { it.name == "Pickleball" }
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, pickle.exerciseType)
    }

    /** Extras (Padel, Pickleball, ...) sit before the generic "Other" catch-all. */
    @Test fun extras_precedeOther() {
        val names = WorkoutSport.all.map { it.name }
        assertTrue(names.indexOf("Pickleball") < names.indexOf("Other"))
        assertEquals("Other", names.last())
    }

    /** Bowling (D#850) is an EXTRA (no HC type) → rides on "Other" for writeback but keeps its own
     *  label, has no route (GPS off), and sits before the generic "Other" catch-all. */
    @Test fun bowling_isExtra_fallsBackToOther() {
        val bowling = WorkoutSport.all.first { it.name == "Bowling" }
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, bowling.exerciseType)
        assertFalse(bowling.isDistanceSport)
        val names = WorkoutSport.all.map { it.name }
        assertTrue(names.indexOf("Bowling") < names.indexOf("Other"))
    }
}
