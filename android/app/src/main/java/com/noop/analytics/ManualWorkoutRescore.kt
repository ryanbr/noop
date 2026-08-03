package com.noop.analytics

import com.noop.data.HrSample

/**
 * Re-score a manual workout's HR-derived metrics (avg/peak HR, strain, calories) from the HR samples
 * now available for its time window.
 *
 * Why: a manually-started workout is scored at *save* time from the live HR captured during the
 * session. On a WHOOP 5.0/MG the live stream is sparse, so only a handful of samples land in the
 * window — calories collapse toward ~1 kcal, the average is off, and strain is empty (#137). The strap
 * banks its own HR to flash and offloads it on the next sync; once that denser HR covers the window,
 * this recomputes from it.
 *
 * Pure + deterministic (no DB, no I/O) so it's unit-tested directly. The caller (the post-sync scoring
 * pass) decides which workouts to feed it — under-scored `manual` ones — reads the window's HR, and
 * only persists a genuine improvement. The formulas mirror `AppViewModel.endWorkout` exactly (same
 * [StrainScorer] + [Calories.estimateBoutCalories]).
 */
object ManualWorkoutRescore {

    data class Scored(val avgHr: Int, val maxHr: Int, val strain: Double?, val kcal: Double?)

    /** At/under this many kcal a manual workout looks like the #137 symptom (no/negligible energy). */
    const val UNDER_SCORED_KCAL_THRESHOLD = 5.0
    /** A rescore must beat the stored calories by at least this to be persisted — so a still-sparse
     *  window (recompute ≈ current) is a no-op and the pass is idempotent. */
    const val IMPROVEMENT_MARGIN_KCAL = 1.0

    /** Does this manual workout currently look under-scored? The gate the post-sync pass uses so a
     *  well-scored workout (a 4.0's dense live HR) is never touched. */
    fun looksUnderScored(currentKcal: Double?): Boolean =
        (currentKcal ?: 0.0) <= UNDER_SCORED_KCAL_THRESHOLD

    /** Recompute avg/peak HR, strain and calories from [windowSamples] (the HR now stored for the
     *  workout's [start, end]). Returns null when there are too few samples to score meaningfully.
     *
     *  [restingHR] is the wearer's MEASURED resting HR (#950): the strain %HRR denominator needs it, and the
     *  calories model's active-vs-resting threshold sits at resting + 30% HRR, and both used to silently fall back to a hardcoded 60 here while
     *  the DAY total was scored against the measured value — so a fit wearer's workout was systematically
     *  under-scored relative to the very day it sat in. null keeps the old default (a cold start with no
     *  measured resting yet), so existing callers are byte-identical until they thread one. */
    fun scored(
        windowSamples: List<HrSample>,
        profile: UserProfile,
        hrMax: Double,
        restingHR: Double? = null,
    ): Scored? {
        if (windowSamples.size < 2) return null
        val bpms = windowSamples.map { it.bpm }
        // Integer mean, matching AppViewModel.endWorkout (Android truncates; iOS rounds — each mirrors
        // its own platform's save-time formula).
        val avg = bpms.sum() / bpms.size
        val peak = bpms.maxOrNull() ?: 0
        val strain = StrainScorer.strain(
            windowSamples, maxHR = hrMax,
            restingHR = restingHR ?: StrainScorer.defaultRestingHR, sex = profile.sex,
        )
        val kcalRaw = Calories.estimateBoutCalories(windowSamples, profile, hrMax, restingHR).first
        return Scored(avg, peak, strain, if (kcalRaw > 0) kcalRaw else null)
    }

    /** Is [scored] a worthwhile improvement over the stored row? Two ways to qualify:
     *   - Strictly more energy (denser HR ⇒ higher), so a sparse-window recompute that lands ≈ current is
     *     rejected: idempotent, and it can never *lower* a workout's numbers. This is the default and the
     *     ONLY path for a plain 2-arg call.
     *   - A strain-only fill (opt-in via [allowStrainOnlyFill]): the row has NO strain ([currentStrain] ==
     *     null) yet the recompute produced one. This is the merged-row case (#137/merge), a merged
     *     workout's kcal is the SUM of its inputs, so it never looks under-scored, yet its strain is null
     *     forever. When strain is the only gain we still persist so Effort renders, without lowering the
     *     summed kcal (the caller keeps the existing kcal). Gated so a normal rescore's contract is
     *     unchanged: without the flag, only a strict kcal improvement counts. */
    fun improves(
        scored: Scored,
        currentKcal: Double?,
        currentStrain: Double? = null,
        allowStrainOnlyFill: Boolean = false,
    ): Boolean {
        val newK = scored.kcal
        if (newK != null && newK > (currentKcal ?: 0.0) + IMPROVEMENT_MARGIN_KCAL) return true
        // Strain-only improvement: fill a missing strain even when kcal doesn't beat the stored sum.
        return allowStrainOnlyFill && currentStrain == null && scored.strain != null
    }
}
