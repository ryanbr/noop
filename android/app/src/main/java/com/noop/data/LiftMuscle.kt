package com.noop.data

/**
 * The muscle vocabulary a logged set is classified under.
 *
 * Kotlin mirror of the macOS/iOS source of truth
 *   Packages/WhoopStore/Sources/WhoopStore/LiftMuscle.swift
 *
 * THE TOKENS ARE A STORED-DATA CONTRACT. `name` is what lands in the `primaryMuscle` column and in
 * the comma-joined `secondaryMuscles` column, and the same tokens cross the `.noopbak` boundary to
 * an Apple install. Never rename or remove one; adding is safe because [decodeList] skips what it
 * does not recognise.
 */
enum class LiftMuscle {
    // Push
    chest,
    frontDelts,
    sideDelts,
    rearDelts,
    triceps,

    // Pull
    lats,
    upperBack,
    traps,
    biceps,
    forearms,

    // Legs
    quads,
    hamstrings,
    glutes,
    adductors,
    abductors,
    calves,

    // Trunk
    abs,
    obliques,
    lowerBack,
    neck,
    ;

    /**
     * Coarse section, used only to group the picker. Not stored, not counted — purely presentation
     * scaffolding, so changing it is free.
     */
    enum class Region { push, pull, legs, trunk }

    val region: Region
        get() = when (this) {
            chest, frontDelts, sideDelts, rearDelts, triceps -> Region.push
            lats, upperBack, traps, biceps, forearms -> Region.pull
            quads, hamstrings, glutes, adductors, abductors, calves -> Region.legs
            abs, obliques, lowerBack, neck -> Region.trunk
        }

    companion object {
        /**
         * A set credits its PRIMARY muscle in full and each SECONDARY at a half.
         *
         * The 0.5 is not a house convention: the dose-response meta-regression the reference doses
         * come from compared 1.0, 0.5 and 0.0 for a secondary mover and found the evidence
         * strongest for fractional, which its primary models use. Change this and the reference
         * doses stop meaning what they claim.
         */
        const val directSetCredit: Double = 1.0
        const val indirectSetCredit: Double = 0.5

        /**
         * Raw token to case, or null when the token is not one this build knows.
         *
         * Kotlin-only by design: Swift gets this free from `RawRepresentable.init(rawValue:)`, so
         * there is no Swift declaration to pair with rather than a missing one.
         */
        fun fromRaw(raw: String?): LiftMuscle? =
            raw?.let { token -> entries.firstOrNull { it.name == token } }

        /**
         * Encode a secondary list for storage. Returns null for an empty list so the column stays
         * NULL rather than holding an empty string: two spellings of "none" is a bug waiting.
         * Duplicates and the primary are stripped so one set can never be counted twice for one
         * muscle, and the user's ordering is preserved.
         *
         * The Swift twin is `LiftMuscle.encodeList`.
         */
        fun encodeList(muscles: List<LiftMuscle>, primary: LiftMuscle? = null): String? {
            val seen = LinkedHashSet<LiftMuscle>()
            if (primary != null) seen.add(primary)
            val kept = ArrayList<LiftMuscle>()
            for (m in muscles) if (seen.add(m)) kept.add(m)
            return if (kept.isEmpty()) null else kept.joinToString(",") { it.name }
        }

        /**
         * Decode a stored secondary list. Unknown tokens are skipped rather than failing the read:
         * a database written by a newer build must stay readable by an older one.
         *
         * The Swift twin is `LiftMuscle.decodeList`.
         */
        fun decodeList(stored: String?): List<LiftMuscle> {
            if (stored.isNullOrEmpty()) return emptyList()
            return stored.split(",").mapNotNull { fromRaw(it) }
        }
    }
}
