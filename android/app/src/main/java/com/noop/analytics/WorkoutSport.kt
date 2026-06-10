package com.noop.analytics

import com.noop.ingest.ExerciseTypes

/** One selectable activity. [exerciseType] is a Health Connect EXERCISE_TYPE_* constant. */
data class Sport(val exerciseType: Int, val name: String, val isDistanceSport: Boolean)

object WorkoutSport {
    val all: List<Sport> = ExerciseTypes.NAMES.map { (type, name) ->
        Sport(type, name, isDistanceSport = type in ExerciseTypes.DISTANCE_TYPES)
    }
    fun nameFor(type: Int) = ExerciseTypes.nameFor(type)

    /** The default when none is chosen ("Other"). */
    val default: Sport get() = all.first { it.name == "Other" }
}
