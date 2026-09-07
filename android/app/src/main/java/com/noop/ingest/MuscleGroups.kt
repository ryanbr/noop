package com.noop.ingest

// MARK: - Exercise → muscle attribution
//
// Groundwork for a per-muscle strength view. NOOP already imports lifting sessions (Hevy CSV,
// Liftosaur JSON) but aggregates them to a set count and a volume figure, so nothing downstream can
// say WHICH muscles did the work. This maps an exercise name to the muscles that move it.
//
// Kotlin mirror of the macOS/iOS source of truth
//   Packages/StrandImport/Sources/StrandImport/MuscleGroups.swift
// The rule table is the logic here, so the two must stay identical ROW FOR ROW AND IN ORDER: the
// first match wins, and a row moved on one platform silently attributes a different muscle there.
//
// Keyword matching on a normalised name, NOT an exhaustive catalogue. Lifting trackers let people
// type anything, so a closed list would silently mis-attribute everything it did not recognise. The
// rule here is the project's usual one: an exercise this cannot place returns NOTHING, and the
// caller shows no attribution rather than a guess. A wrong muscle is worse than a blank one, because
// a blank invites the user to look while a wrong one does not.
//
// PRIMARY movers only. A barbell squat loads glutes and hamstrings too, and a bench press loads
// triceps and shoulders — but attributing every synergist would make every session light up the
// whole body and stop distinguishing a push day from a leg day. The screen this feeds is about where
// the work went, not about what was innervated.

/**
 * The muscle groups a strength view can attribute work to.
 *
 * Deliberately coarse. These are the granularity a lifting log can actually support: an exercise
 * name can tell you "lats", it cannot honestly tell you which head of which muscle.
 */
enum class MuscleGroup {
    CHEST,
    UPPER_BACK,
    LATS,
    SHOULDERS,
    BICEPS,
    TRICEPS,
    FOREARMS,
    ABS,
    LOWER_BACK,
    GLUTES,
    QUADRICEPS,
    HAMSTRINGS,
    CALVES,
}

object MuscleAttribution {

    /**
     * Normalise a logged exercise name for matching.
     *
     * Trackers append equipment in parentheses ("Squat (Barbell)"), use hyphens and en-dashes
     * inconsistently ("Seated Cable Row - V Grip"), and vary in case. The parenthetical is KEPT
     * rather than stripped, because it can carry the distinguishing word: a "Row (Machine)" and a
     * "Row (Dumbbell)" are the same muscles, but "Curl (Barbell)" and "Leg Curl" are not.
     */
    fun normalise(raw: String): String {
        val out = StringBuilder(raw.length)
        var lastWasSpace = false
        for (ch in raw.lowercase()) {
            if (ch.isLetterOrDigit()) {
                out.append(ch)
                lastWasSpace = false
            } else if (!lastWasSpace) {
                out.append(' ')
                lastWasSpace = true
            }
        }
        return out.toString().trim()
    }

    /**
     * Real exercises this vocabulary has no group for, which must attribute NOTHING rather than fall
     * through to a generic rule that would be wrong.
     *
     * "Neck Curl" contains "curl" and came out as BICEPS. These thirteen groups have no neck, so a
     * blank is the only honest answer, and a blank is what the whole table is supposed to prefer: it
     * invites a look, where a wrong muscle does not.
     *
     * Kept separate from [rules] because a rule must name at least one group. An entry here is the
     * deliberate absence of one, which is a different statement from "not recognised".
     */
    internal val unattributable: List<String> = listOf("neck")

    /**
     * The primary movers for a logged exercise name, or an empty list when it cannot be placed.
     *
     * Order matters: the first rule that matches wins, so the more specific phrase has to be tested
     * before the word it contains. "leg curl" is hamstrings and must be decided before "curl" sends
     * it to biceps; "front raise" is shoulders and must beat "raise"; "calf raise" likewise.
     */
    fun muscles(exercise: String): List<MuscleGroup> {
        val n = normalise(exercise)
        if (n.isEmpty()) return emptyList()
        if (unattributable.any { n.contains(it) }) return emptyList()
        for ((needle, groups) in rules) if (n.contains(needle)) return groups
        return emptyList()
    }

    /**
     * Longest-phrase-first, so a specific lift is decided before the generic word inside it. Held as
     * an ordered list rather than a map precisely because that order is the logic.
     */
    internal val rules: List<Pair<String, List<MuscleGroup>>> = listOf(
        // legs — the specific curls and raises must precede the generic ones
        "leg curl" to listOf(MuscleGroup.HAMSTRINGS),
        "romanian deadlift" to listOf(MuscleGroup.HAMSTRINGS, MuscleGroup.GLUTES),
        "stiff leg deadlift" to listOf(MuscleGroup.HAMSTRINGS, MuscleGroup.GLUTES),
        "good morning" to listOf(MuscleGroup.HAMSTRINGS, MuscleGroup.LOWER_BACK),
        "leg extension" to listOf(MuscleGroup.QUADRICEPS),
        "hack squat" to listOf(MuscleGroup.QUADRICEPS),
        "front squat" to listOf(MuscleGroup.QUADRICEPS),
        "bulgarian" to listOf(MuscleGroup.QUADRICEPS, MuscleGroup.GLUTES),
        "lunge" to listOf(MuscleGroup.QUADRICEPS, MuscleGroup.GLUTES),
        "leg press" to listOf(MuscleGroup.QUADRICEPS, MuscleGroup.GLUTES),
        "squat" to listOf(MuscleGroup.QUADRICEPS, MuscleGroup.GLUTES),
        "hip thrust" to listOf(MuscleGroup.GLUTES),
        "glute bridge" to listOf(MuscleGroup.GLUTES),
        "calf raise" to listOf(MuscleGroup.CALVES),
        "calf press" to listOf(MuscleGroup.CALVES),
        // hinge / back
        "deadlift" to listOf(MuscleGroup.LOWER_BACK, MuscleGroup.GLUTES, MuscleGroup.HAMSTRINGS),
        "back extension" to listOf(MuscleGroup.LOWER_BACK),
        "hyperextension" to listOf(MuscleGroup.LOWER_BACK),
        "pull up" to listOf(MuscleGroup.LATS, MuscleGroup.BICEPS),
        "pullup" to listOf(MuscleGroup.LATS, MuscleGroup.BICEPS),
        "chin up" to listOf(MuscleGroup.LATS, MuscleGroup.BICEPS),
        "chinup" to listOf(MuscleGroup.LATS, MuscleGroup.BICEPS),
        "lat pulldown" to listOf(MuscleGroup.LATS),
        "pulldown" to listOf(MuscleGroup.LATS),
        "pullover" to listOf(MuscleGroup.LATS),
        "face pull" to listOf(MuscleGroup.UPPER_BACK, MuscleGroup.SHOULDERS),
        "shrug" to listOf(MuscleGroup.UPPER_BACK),
        // Before the generic row: an upright row is a shoulder movement, and every
        // upright row contains "row", so the generic rule would swallow it.
        "upright row" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.UPPER_BACK),
        "row" to listOf(MuscleGroup.UPPER_BACK, MuscleGroup.LATS),
        // push
        "bench press" to listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS),
        "chest press" to listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS),
        "chest fly" to listOf(MuscleGroup.CHEST),
        "pec deck" to listOf(MuscleGroup.CHEST),
        // Before the generic fly: a reverse fly and a rear-delt fly are REAR movements, and both
        // contain "fly", so the generic rule would file the opposite side of the body. Order is the
        // whole contract here, not a stylistic choice.
        "rear delt" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.UPPER_BACK),
        "reverse fly" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.UPPER_BACK),
        "fly" to listOf(MuscleGroup.CHEST),
        "push up" to listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS),
        "pushup" to listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS),
        "dip" to listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS),
        "overhead press" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.TRICEPS),
        "shoulder press" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.TRICEPS),
        "military press" to listOf(MuscleGroup.SHOULDERS, MuscleGroup.TRICEPS),
        "arnold press" to listOf(MuscleGroup.SHOULDERS),
        "lateral raise" to listOf(MuscleGroup.SHOULDERS),
        "front raise" to listOf(MuscleGroup.SHOULDERS),
        // arms
        // Hevy writes it as one word; the two-word rule missed the spelling the catalogue uses.
        "skullcrusher" to listOf(MuscleGroup.TRICEPS),
        "skull crusher" to listOf(MuscleGroup.TRICEPS),
        "tricep" to listOf(MuscleGroup.TRICEPS),
        "pushdown" to listOf(MuscleGroup.TRICEPS),
        "kickback" to listOf(MuscleGroup.TRICEPS),
        "hammer curl" to listOf(MuscleGroup.BICEPS, MuscleGroup.FOREARMS),
        "preacher curl" to listOf(MuscleGroup.BICEPS),
        "bicep" to listOf(MuscleGroup.BICEPS),
        // Before the generic curl: a nordic curl is a hamstring movement and a jefferson curl is a
        // spinal one. Both contain "curl", so the generic rule would call them biceps.
        "nordic curl" to listOf(MuscleGroup.HAMSTRINGS),
        "jefferson curl" to listOf(MuscleGroup.LOWER_BACK, MuscleGroup.HAMSTRINGS),
        // Before the generic curl: a wrist curl is forearms, and "Wrist Curl" is how the exercise is
        // normally written, so the rule below was unreachable for the title it exists to catch.
        "wrist" to listOf(MuscleGroup.FOREARMS),
        "curl" to listOf(MuscleGroup.BICEPS),
        "farmer" to listOf(MuscleGroup.FOREARMS),
        // trunk
        "plank" to listOf(MuscleGroup.ABS),
        "crunch" to listOf(MuscleGroup.ABS),
        "sit up" to listOf(MuscleGroup.ABS),
        "situp" to listOf(MuscleGroup.ABS),
        "leg raise" to listOf(MuscleGroup.ABS),
        "hanging raise" to listOf(MuscleGroup.ABS),
        "ab wheel" to listOf(MuscleGroup.ABS),
        "russian twist" to listOf(MuscleGroup.ABS),
    )
}
