package com.noop.analytics

import com.noop.ingest.ExerciseTypes

/** One selectable activity. [exerciseType] is a Health Connect EXERCISE_TYPE_* constant. */
data class Sport(val exerciseType: Int, val name: String, val isDistanceSport: Boolean)

object WorkoutSport {
    // Health-Connect-typed sports + the EXTRA sports HC has no type for (e.g. Padel, #77/#152), which
    // ride a fallback HC type but keep their own NOOP label. The extras are inserted just before
    // "Other" so the picker still ends on the generic catch-all. Shared by the picker (live + manual)
    // AND the HC writeback (Sport.exerciseType).
    val all: List<Sport> = buildList {
        ExerciseTypes.NAMES.forEach { (type, name) ->
            if (name == "Other") return@forEach // re-appended last, after the extras
            add(Sport(type, name, isDistanceSport = type in ExerciseTypes.DISTANCE_TYPES))
        }
        ExerciseTypes.EXTRA.forEach { (name, fallbackType) ->
            add(Sport(fallbackType, name, isDistanceSport = false))
        }
        ExerciseTypes.NAMES.entries.firstOrNull { it.value == "Other" }?.let { (type, name) ->
            add(Sport(type, name, isDistanceSport = type in ExerciseTypes.DISTANCE_TYPES))
        }
    }
    fun nameFor(type: Int) = ExerciseTypes.nameFor(type)

    /** The default when none is chosen ("Other"). */
    val default: Sport get() = all.first { it.name == "Other" }

    /** The Health Connect exercise type for a stored sport NAME (free-text tolerant, case-insensitive),
     *  falling back to [default]'s OTHER_WORKOUT when the name isn't a catalogue sport. Used by the
     *  manual-workout HC writeback so a hand-entered workout maps to the same type the live path uses. */
    fun exerciseTypeForName(name: String): Int =
        (all.firstOrNull { it.name.equals(name.trim(), ignoreCase = true) } ?: default).exerciseType

    /** Sports where a step count is meaningful — feet on the ground — so the workout summary can show
     *  steps (#398). Deliberately narrow: outdoor + treadmill run/walk and hiking, NOT cycling/rowing/
     *  swimming (no footfalls) or gym/court sports (a step tally would be noise). Kept in lockstep with
     *  the Swift `WorkoutCatalog.onFootSportNames`. */
    val ON_FOOT_SPORTS: Set<String> = setOf("Running", "Walking", "Hiking", "Treadmill run", "Treadmill walk")

    /** Whether [sportName] (a catalogue name, possibly free-typed) is an on-foot sport that should show a
     *  step count. Case-insensitive, whitespace-trimmed. Mirrors Swift `WorkoutCatalog.isOnFoot`. */
    fun isOnFoot(sportName: String): Boolean {
        val q = sportName.trim()
        return ON_FOOT_SPORTS.any { it.equals(q, ignoreCase = true) }
    }
}
