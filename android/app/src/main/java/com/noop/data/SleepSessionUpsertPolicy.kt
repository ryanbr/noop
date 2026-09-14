package com.noop.data

import com.noop.analytics.HypnogramCoverage

/**
 * Decides how a cache refresh may replace an existing sleep-session row.
 *
 * A strap can serve the same night more than once, and a resumed drain can carry a thinner stage
 * timeline than the row already on disk. Dropping that candidate whole keeps `endTs`, `efficiency`
 * and `stagesJSON` describing one coherent decode. The 0/1/2 rank is the same rule the display merge
 * uses and mirrors `WhoopStore.SleepMerge.richness`.
 *
 * Hand-edited bounds and stages belong to the user, so a normal refresh preserves them while still
 * updating derived vitals and `stagingSparse`. Motion and band-state arrays have dedicated writers;
 * they are retained on every cache refresh just as the Swift upsert leaves those columns untouched.
 */
internal object SleepSessionUpsertPolicy {
    /** The accepted replacement row, or null when [candidate] is poorer than [existing]. */
    fun merge(existing: SleepSession, candidate: SleepSession): SleepSession? {
        if (!candidate.userEdited && !existing.userEdited &&
            richness(candidate) < richness(existing)
        ) {
            return null
        }

        return candidate.copy(
            endTs = if (existing.userEdited) existing.endTs else candidate.endTs,
            stagesJSON = if (existing.userEdited) existing.stagesJSON else candidate.stagesJSON,
            userEdited = existing.userEdited,
            startTsAdjusted = if (existing.userEdited) existing.startTsAdjusted else candidate.startTsAdjusted,
            motionJSON = existing.motionJSON,
            sleepStateJSON = existing.sleepStateJSON,
        )
    }

    /** 0 = no stages, 1 = stages with holes, 2 = stages covering the claimed span. */
    fun richness(session: SleepSession): Int {
        val stages = session.stagesJSON?.trim() ?: return 0
        if (stages.isEmpty() || stages == "[]") return 0
        val span = (session.endTs - session.startTs).toDouble()
        return if (HypnogramCoverage.isHoled(stages, span)) 1 else 2
    }
}
