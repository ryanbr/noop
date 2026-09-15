package com.noop.analytics

import com.noop.data.LiftMuscle

/**
 * Training metrics for the Lift Log.
 *
 * Kotlin twin of `StrandAnalytics.LiftMetrics` (#2099), so both platforms report the same numbers
 * from the same sets. Pinned by `LiftMetricsParityOracleTest`, whose expected values are the Swift
 * build's own stdout.
 *
 * Every figure here is arithmetic the user can redo by hand from their own logged sets. That is the
 * design constraint: NOOP shows a few honest numbers rather than one invented score.
 *
 * PURE. No store, no clock, no UI — rows in, numbers out.
 *
 * WHAT IS DELIBERATELY ABSENT, and must stay absent:
 *
 *  - Anything feeding `workout.strain` or daily Effort. NOOP's strain is HR-measured (Karvonen
 *    %HRR into Edwards TRIMP). There is no validated public path from typed sets/reps/weight to a
 *    cardiovascular-strain equivalent, and inventing one is the case CLAUDE.md warns about after
 *    the withdrawn PPG-to-HR estimate (#194).
 *  - Per-exercise muscle weightings ("bench press = 0.7 triceps"). No published table exists to
 *    take them from. The direct/indirect split is the resolution the evidence supports.
 *  - Acute:chronic workload ratios or any injury-risk warning. The construct's validity is disputed,
 *    and a health warning from a non-medical app is either ignored or believed, both bad.
 */
object LiftMetrics {

    /**
     * The fields of a logged set this file needs. Mirrors Swift `LiftSetRow`'s countable surface,
     * INCLUDING its invariant: the secondary list is normalised at construction, so it never
     * repeats a muscle and never contains the primary.
     *
     * Swift gets that from `LiftSetRow.init`, which runs the secondaries it is handed through
     * `decodeList(encodeList(_:excluding:))` before storing them. The normalisation has to live
     * here rather than in [muscleCounts] because it is the row that carries the guarantee on the
     * other side, and any future reader of `secondaryMuscles` should see the same list Swift would.
     *
     * Measured rather than assumed: for a set with `[triceps, triceps, chest]` secondary and
     * `chest` primary, Swift credits triceps 0.5 across one indirect set. Before this step Kotlin
     * credited it 1.0 across two, double-counting the muscle.
     *
     * Not a `data class`: the generated `copy()` would rebuild the object through the constructor
     * it bypasses, reintroducing an unnormalised list.
     */
    class Row(
        val ord: Int,
        val exercise: String,
        val isWarmup: Boolean,
        val weightKg: Double? = null,
        val reps: Int? = null,
        val rpe: Double? = null,
        val primaryMuscle: LiftMuscle? = null,
        secondaryMuscles: List<LiftMuscle> = emptyList(),
    ) {
        val secondaryMuscles: List<LiftMuscle> =
            LiftMuscle.decodeList(LiftMuscle.encodeList(secondaryMuscles, primaryMuscle))
    }

    // MARK: - Performed or not

    /**
     * Whether a set was performed, from its rep count. A set with ZERO reps was not: that is how a
     * finished session keeps the sets the user discards, so they can still be filled in later, and it
     * is what a user types for a planned set they skipped. Every figure leaves such a set out, since
     * counting it would add a set nobody did. A set with no rep count (null) still counts: it was
     * done, the number just was not typed.
     * The Swift twin is `LiftMetrics.isPerformed`.
     */
    fun isPerformed(reps: Int?): Boolean = reps != 0

    // MARK: - Volume load (tonnage)

    /**
     * Sum of (weight x reps) over WORKING sets, in kilograms. Null when nothing countable was logged.
     *
     * Warm-ups are excluded because the literature counts working sets, and a warm-up double counted
     * as volume would flatter every session. A set missing either weight or reps contributes nothing
     * rather than a guess.
     * The Swift twin is `LiftMetrics.volumeLoadKg`.
     */
    fun volumeLoadKg(sets: List<Row>): Double? {
        var total = 0.0
        for (s in sets) {
            if (s.isWarmup) continue
            val w = s.weightKg ?: continue
            val r = s.reps ?: continue
            if (w <= 0 || r <= 0) continue
            total += w * r.toDouble()
        }
        return if (total > 0) total else null
    }

    // MARK: - Session load (Foster sRPE-TL)

    /**
     * Session RPE x duration in minutes. Foster's session-RPE training load.
     *
     * It earns its place next to volume because it is validated across BOTH resistance and endurance
     * training, making it the only figure here that puts a leg day and a run on one scale.
     *
     * Null when the session was not rated: a skipped rating must never read as an effortless 0.
     * The Swift twin is `LiftMetrics.sessionLoad`.
     */
    fun sessionLoad(sessionRpe: Double?, durationSec: Int): Double? {
        val rpe = sessionRpe ?: return null
        if (rpe <= 0 || durationSec <= 0) return null
        return rpe * (durationSec.toDouble() / 60.0)
    }

    // MARK: - Estimated one-rep max (Epley)

    /**
     * The rep ceiling above which a 1RM estimate stops being worth showing. Every 1RM formula is a
     * straight-line fit to a curved relationship and the error grows with reps; twelve is the
     * conventional bound where the formulas are least unreliable.
     */
    const val oneRepMaxRepCeiling: Int = 12

    /**
     * Epley: `w * (1 + reps/30)`. Null for a set that cannot support an estimate.
     *
     * A single rep returns the weight itself. The formula's own +3.3% at one rep is an artefact of
     * the fit, not a claim that a single you just completed was really 3% heavier.
     * The Swift twin is `LiftMetrics.estimatedOneRepMaxKg`.
     */
    fun estimatedOneRepMaxKg(weightKg: Double?, reps: Int?): Double? {
        val w = weightKg ?: return null
        val r = reps ?: return null
        if (w <= 0 || r <= 0 || r > oneRepMaxRepCeiling) return null
        if (r <= 1) return w
        return w * (1.0 + r.toDouble() / 30.0)
    }

    // MARK: - Per-exercise summary

    data class ExerciseSummary(
        val exercise: String,
        /** Working sets only: the tally the dose-response literature is built on. */
        val workingSets: Int,
        val warmupSets: Int,
        val volumeKg: Double?,
        /**
         * The session's best set for this exercise, ranked by ESTIMATED 1RM rather than raw weight:
         * 90 kg x 10 is a better set than 100 kg x 5, and ranking by weight alone would hide that.
         * Falls back to the heaviest set when no set supports an estimate.
         */
        val bestWeightKg: Double?,
        val bestReps: Int?,
        val bestEstimatedOneRepMaxKg: Double?,
    )

    /**
     * One summary per exercise, in the order the exercises were first performed, because that is how
     * a session reads back. A set that was not performed ([isPerformed]) appears nowhere, and neither
     * does an exercise with only such sets.
     *
     * Assumes `ord` is unique across the rows handed in, which holds because it is assigned 0-based
     * within one session and the only caller passes one session's sets. If that ever stops being
     * true the two platforms can disagree on ties: `sortedBy` is stable, Swift's `sorted(by:)` is
     * not, so Swift would also stop agreeing with itself. Fix it by making `ord` unique rather than
     * by matching an unspecified order here.
     * The Swift twin is `LiftMetrics.perExercise`.
     */
    fun perExercise(sets: List<Row>): List<ExerciseSummary> {
        val order = ArrayList<String>()
        val grouped = LinkedHashMap<String, MutableList<Row>>()
        for (s in sets.sortedBy { it.ord }) {
            if (!isPerformed(s.reps)) continue
            if (grouped[s.exercise] == null) {
                order.add(s.exercise)
                grouped[s.exercise] = ArrayList()
            }
            grouped.getValue(s.exercise).add(s)
        }
        return order.map { name ->
            val rows = grouped[name] ?: emptyList<Row>()
            val working = rows.filter { !it.isWarmup }

            // Rank by estimated 1RM where possible, otherwise raw weight, so an exercise logged only
            // at high reps still reports a best set rather than nothing. `maxWithOrNull` keeps the
            // FIRST of equals, matching Swift's `max(by:)`.
            val best = working.maxWithOrNull { a, b ->
                val ea = estimatedOneRepMaxKg(a.weightKg, a.reps)
                val eb = estimatedOneRepMaxKg(b.weightKg, b.reps)
                when {
                    ea != null && eb != null -> ea.compareTo(eb)
                    ea != null -> 1      // a ranks above b
                    eb != null -> -1     // b ranks above a
                    else -> (a.weightKg ?: 0.0).compareTo(b.weightKg ?: 0.0)
                }
            }
            ExerciseSummary(
                exercise = name,
                workingSets = working.size,
                warmupSets = rows.size - working.size,
                volumeKg = volumeLoadKg(rows),
                bestWeightKg = best?.weightKg,
                bestReps = best?.reps,
                bestEstimatedOneRepMaxKg = estimatedOneRepMaxKg(best?.weightKg, best?.reps),
            )
        }
    }

    // MARK: - RPE profile

    data class RpeProfile(
        val mean: Double?,
        val ratedSets: Int,
        val unratedSets: Int,
        val setsAtOrAboveThreshold: Int,
        val threshold: Double,
    )

    /** The default "this set was close to failure" line. Informational only. */
    const val hardSetRpeThreshold: Double = 8.0

    /**
     * How close to failure the working sets were.
     *
     * Reported SEPARATELY from the set counts and never as a filter on them. The tempting move is to
     * count only sets at RPE >= 7 toward a muscle's weekly total, since proximity to failure is what
     * makes a set count biologically. Doing that would compare a smaller number against reference
     * doses derived from UNFILTERED working-set counts, quietly changing the scale. `unratedSets` is
     * surfaced so a mean computed from three of twelve sets is visibly thin.
     * The Swift twin is `LiftMetrics.rpeProfile`.
     */
    fun rpeProfile(sets: List<Row>, threshold: Double = hardSetRpeThreshold): RpeProfile {
        val working = sets.filter { !it.isWarmup && isPerformed(it.reps) }
        val rated = working.mapNotNull { it.rpe }
        val mean = if (rated.isEmpty()) null else rated.sum() / rated.size.toDouble()
        return RpeProfile(
            mean = mean,
            ratedSets = rated.size,
            unratedSets = working.size - rated.size,
            setsAtOrAboveThreshold = rated.count { it >= threshold },
            threshold = threshold,
        )
    }

    // MARK: - Sets per muscle

    data class MuscleCounts(
        /** direct x 1.0 + indirect x 0.5, the published fractional method. */
        val fractional: Map<LiftMuscle, Double>,
        val direct: Map<LiftMuscle, Int>,
        val indirect: Map<LiftMuscle, Int>,
    )

    /**
     * Fractional set counts per muscle over the given sets.
     *
     * The 0.5 for an indirect set is NOT a house convention: the 2025 Sports Medicine dose-response
     * meta-regression compared counting a secondary mover's set as 1.0 ("total"), 0.5 ("fractional")
     * and 0.0 ("direct"), found the evidence strongest for fractional, and used it in its primary
     * models. The reference doses in [ReferenceDose] were derived under that same operationalisation,
     * so the credit and the doses have to move together or the comparison stops meaning anything.
     *
     * Warm-ups and sets never performed ([isPerformed]) are excluded; nothing else is. An unclassified
     * exercise (null primary) contributes to volume and session load but claims no muscle it was never
     * assigned.
     * The Swift twin is `LiftMetrics.muscleCounts`.
     */
    fun muscleCounts(sets: List<Row>): MuscleCounts {
        val fractional = LinkedHashMap<LiftMuscle, Double>()
        val direct = LinkedHashMap<LiftMuscle, Int>()
        val indirect = LinkedHashMap<LiftMuscle, Int>()
        for (s in sets) {
            if (s.isWarmup || !isPerformed(s.reps)) continue
            s.primaryMuscle?.let { p ->
                direct[p] = (direct[p] ?: 0) + 1
                fractional[p] = (fractional[p] ?: 0.0) + LiftMuscle.directSetCredit
            }
            for (m in s.secondaryMuscles) {
                if (m == s.primaryMuscle) continue
                indirect[m] = (indirect[m] ?: 0) + 1
                fractional[m] = (fractional[m] ?: 0.0) + LiftMuscle.indirectSetCredit
            }
        }
        return MuscleCounts(fractional = fractional, direct = direct, indirect = indirect)
    }

    // MARK: - The reference band

    /**
     * Weekly fractional sets per muscle, from the same dose-response meta-regression the 0.5 credit
     * comes from.
     *
     * PRESENTED AS A BAND WITH ITS SOURCE NAMED, NEVER AS A PERSONAL PRESCRIPTION. NOOP is not a
     * medical device and does not tell anyone what their body needs; it says what the research
     * associates with growth and leaves the conclusion to the reader.
     */
    object ReferenceDose {
        /** Below roughly this, hypertrophy is not reliably detectable. */
        const val hypertrophyMinimumSetsPerWeek: Double = 4.0

        /** Strength keeps improving from a single weekly set. */
        const val strengthMinimumSetsPerWeek: Double = 1.0

        /**
         * Beyond roughly this, added volume stops reliably beating the smallest detectable effect
         * FOR STRENGTH. Hypertrophy has no identified ceiling: gains continue with strongly
         * diminishing returns, and the uncertainty widens as volume rises.
         */
        const val strengthPlateauSetsPerWeek: Double = 4.0
    }
}
