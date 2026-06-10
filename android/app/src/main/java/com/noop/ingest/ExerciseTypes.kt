package com.noop.ingest

import androidx.health.connect.client.records.ExerciseSessionRecord as EX

/**
 * Single source of truth for Health Connect exercise-type <-> label, shared by [HealthConnectImporter]
 * (int -> label) and [com.noop.analytics.WorkoutSport] (the picker + writeback). Reference the library
 * constants, never hardcoded ints — the ints have changed / been wrong before (#53).
 */
object ExerciseTypes {
    /** Ordered for the picker: common / distance first, then the rest, then Other. */
    val NAMES: Map<Int, String> = linkedMapOf(
        EX.EXERCISE_TYPE_RUNNING to "Running",
        EX.EXERCISE_TYPE_WALKING to "Walking",
        EX.EXERCISE_TYPE_HIKING to "Hiking",
        EX.EXERCISE_TYPE_BIKING to "Cycling",
        EX.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "Open-water swim",
        EX.EXERCISE_TYPE_ROWING to "Rowing",
        EX.EXERCISE_TYPE_RUNNING_TREADMILL to "Treadmill run",
        EX.EXERCISE_TYPE_BIKING_STATIONARY to "Indoor cycle",
        EX.EXERCISE_TYPE_SWIMMING_POOL to "Pool swim",
        EX.EXERCISE_TYPE_ROWING_MACHINE to "Row machine",
        EX.EXERCISE_TYPE_ELLIPTICAL to "Elliptical",
        EX.EXERCISE_TYPE_STRENGTH_TRAINING to "Strength",
        EX.EXERCISE_TYPE_WEIGHTLIFTING to "Weightlifting",
        EX.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "HIIT",
        EX.EXERCISE_TYPE_YOGA to "Yoga",
        EX.EXERCISE_TYPE_PILATES to "Pilates",
        EX.EXERCISE_TYPE_BOXING to "Boxing",
        EX.EXERCISE_TYPE_BASKETBALL to "Basketball",
        EX.EXERCISE_TYPE_SOCCER to "Soccer",
        EX.EXERCISE_TYPE_BASEBALL to "Baseball",
        EX.EXERCISE_TYPE_BADMINTON to "Badminton",
        EX.EXERCISE_TYPE_OTHER_WORKOUT to "Other",
    )

    /** Types where a route makes sense -> GPS defaults on. */
    val DISTANCE_TYPES: Set<Int> = setOf(
        EX.EXERCISE_TYPE_RUNNING,
        EX.EXERCISE_TYPE_WALKING,
        EX.EXERCISE_TYPE_HIKING,
        EX.EXERCISE_TYPE_BIKING,
        EX.EXERCISE_TYPE_SWIMMING_OPEN_WATER,
        EX.EXERCISE_TYPE_ROWING,
    )

    fun nameFor(type: Int): String = NAMES[type] ?: "Workout"
}
