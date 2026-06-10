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
}
