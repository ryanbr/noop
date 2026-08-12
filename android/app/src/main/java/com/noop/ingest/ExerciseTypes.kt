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
        EX.EXERCISE_TYPE_ICE_HOCKEY to "Ice Hockey",
        EX.EXERCISE_TYPE_BADMINTON to "Badminton",
        EX.EXERCISE_TYPE_TENNIS to "Tennis",
        EX.EXERCISE_TYPE_SQUASH to "Squash",
        EX.EXERCISE_TYPE_RACQUETBALL to "Racquetball",
        EX.EXERCISE_TYPE_TABLE_TENNIS to "Table tennis",
        EX.EXERCISE_TYPE_VOLLEYBALL to "Volleyball",
        // Martial arts covers the user-requested Jiu-Jitsu plus karate/judo/MMA etc. (#768).
        EX.EXERCISE_TYPE_MARTIAL_ARTS to "Martial arts",
        EX.EXERCISE_TYPE_DANCING to "Dancing",
        EX.EXERCISE_TYPE_GOLF to "Golf",
        EX.EXERCISE_TYPE_ROCK_CLIMBING to "Climbing",
        EX.EXERCISE_TYPE_STRETCHING to "Stretching",
        // Snow sports have a route, so they default GPS on (see DISTANCE_TYPES). (#768)
        EX.EXERCISE_TYPE_SKIING to "Skiing",
        EX.EXERCISE_TYPE_SNOWBOARDING to "Snowboarding",
        // Batch of common sports HC enumerates natively, so they round-trip on export (#222 follow-up).
        EX.EXERCISE_TYPE_FOOTBALL_AMERICAN to "American football",
        EX.EXERCISE_TYPE_FOOTBALL_AUSTRALIAN to "Australian football",
        EX.EXERCISE_TYPE_RUGBY to "Rugby",
        EX.EXERCISE_TYPE_CRICKET to "Cricket",
        EX.EXERCISE_TYPE_SOFTBALL to "Softball",
        EX.EXERCISE_TYPE_HANDBALL to "Handball",
        EX.EXERCISE_TYPE_WATER_POLO to "Water polo",
        EX.EXERCISE_TYPE_FRISBEE_DISC to "Frisbee",
        EX.EXERCISE_TYPE_SURFING to "Surfing",
        EX.EXERCISE_TYPE_PADDLING to "Kayaking",
        EX.EXERCISE_TYPE_SAILING to "Sailing",
        EX.EXERCISE_TYPE_SCUBA_DIVING to "Scuba diving",
        EX.EXERCISE_TYPE_ICE_SKATING to "Ice skating",
        EX.EXERCISE_TYPE_SKATING to "Inline skating",
        EX.EXERCISE_TYPE_SNOWSHOEING to "Snowshoeing",
        EX.EXERCISE_TYPE_GYMNASTICS to "Gymnastics",
        EX.EXERCISE_TYPE_FENCING to "Fencing",
        EX.EXERCISE_TYPE_CALISTHENICS to "Calisthenics",
        EX.EXERCISE_TYPE_STAIR_CLIMBING_MACHINE to "Stair climber",
        EX.EXERCISE_TYPE_BOOT_CAMP to "Boot camp",
        EX.EXERCISE_TYPE_OTHER_WORKOUT to "Other",
    )

    /**
     * Sports the user can pick that Health Connect has NO dedicated type for, so they ride on a
     * fallback HC type (here "Other") while keeping their own NOOP label. Kept OUT of [NAMES] because
     * that map is int-keyed — "Padel" and "Other" would collide on EXERCISE_TYPE_OTHER_WORKOUT — and
     * because an inbound HC record of that type must still read back as the generic name, not Padel.
     * Padel (#77 / #152): a racquet sport HC doesn't enumerate yet → writes as "Other", stays "Padel"
     * on our own rows. List the display name + the HC type it falls back to.
     */
    val EXTRA: List<Pair<String, Int>> = listOf(
        "Padel" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // Pickleball (#768): a fast-growing racquet sport HC has no type for → writes as "Other",
        // stays "Pickleball" on our own rows. No route → GPS off.
        "Pickleball" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // Bowling (D#850): HC has no type for it → writes as "Other", stays "Bowling" on our own
        // rows. No route → GPS off.
        "Bowling" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        // #714 indoor treadmill walk. HC has a treadmill-RUN type but no treadmill-WALK type, so this
        // rides on plain WALKING for writeback while keeping its own "Treadmill walk" label. Kept OUT of
        // DISTANCE_TYPES so GPS defaults off (an indoor session has no route).
        "Treadmill walk" to EX.EXERCISE_TYPE_WALKING,
        // #714 bodybuilding. No dedicated HC type, so it rides on STRENGTH_TRAINING for writeback and
        // keeps "Bodybuilding" on our own rows. No route → GPS off.
        "Bodybuilding" to EX.EXERCISE_TYPE_STRENGTH_TRAINING,
        // #222 follow-up: sports HC has no dedicated type for → ride a nearby type for writeback while
        // keeping their own NOOP label. GPS off (EXTRA is kept out of DISTANCE_TYPES).
        "Lacrosse" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Field hockey" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "CrossFit" to EX.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING,
        "Kickboxing" to EX.EXERCISE_TYPE_MARTIAL_ARTS,
        "Mountain biking" to EX.EXERCISE_TYPE_BIKING,
        "Skateboarding" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Stand-up paddleboard" to EX.EXERCISE_TYPE_PADDLING,
        "Spinning" to EX.EXERCISE_TYPE_BIKING_STATIONARY,
        "Jump rope" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Powerlifting" to EX.EXERCISE_TYPE_WEIGHTLIFTING,
        // Long-tail batch: HC has no type → ride a nearby one for writeback, keep the label.
        "Rucking" to EX.EXERCISE_TYPE_WALKING,
        "Sand volleyball" to EX.EXERCISE_TYPE_VOLLEYBALL,
        "Archery" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Fishing" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Hunting" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Curling" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Netball" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Gaelic football" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
        "Spikeball" to EX.EXERCISE_TYPE_OTHER_WORKOUT,
    )

    /** Types where a route makes sense -> GPS defaults on. */
    val DISTANCE_TYPES: Set<Int> = setOf(
        EX.EXERCISE_TYPE_RUNNING,
        EX.EXERCISE_TYPE_WALKING,
        EX.EXERCISE_TYPE_HIKING,
        EX.EXERCISE_TYPE_BIKING,
        EX.EXERCISE_TYPE_SWIMMING_OPEN_WATER,
        EX.EXERCISE_TYPE_ROWING,
        // Snow sports cover ground → a route makes sense, GPS defaults on. (#768)
        EX.EXERCISE_TYPE_SKIING,
        EX.EXERCISE_TYPE_SNOWBOARDING,
        // New distance sports (#222 follow-up): paddling/sailing/skating/snowshoeing cover ground.
        EX.EXERCISE_TYPE_PADDLING,
        EX.EXERCISE_TYPE_SAILING,
        EX.EXERCISE_TYPE_SKATING,
        EX.EXERCISE_TYPE_SNOWSHOEING,
    )

    fun nameFor(type: Int): String = NAMES[type] ?: "Workout"
}
