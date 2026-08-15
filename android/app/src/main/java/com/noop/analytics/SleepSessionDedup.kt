package com.noop.analytics

import com.noop.data.SleepSession

/**
 * Overlap-aware de-duplication of banked sleep sessions (#899).
 *
 * An unstable strap clock can re-bank the SAME night's raw data under a shifted timebase across
 * syncs, so successive analyze passes detect the night at shifted bounds and the sleepSession
 * table accumulates two (or more) OVERLAPPING copies of one night under different [SleepSession.startTs]
 * keys. The exact (deviceId, startTs) primary-key upsert cannot collapse them (the keys differ), day
 * assignment then keys the stale copy to the wrong wake day, and Charge/Rest pin to the old night.
 *
 * This is the shared collapse rule, applied wherever banked sessions are assembled before day
 * assignment / scoring (habitual-midsleep learning, band sleep-state consumption, and the
 * post-upsert store heal in [IntelligenceEngine]). Pure + deterministic so it is unit-tested
 * directly. Faithful twin of the Swift `WhoopStore.SleepSessionDedup`.
 */
object SleepSessionDedup {

    /**
     * Absolute overlap (seconds) at or above which two sessions are copies of the same night.
     * On one honest timeline two REAL sleeps can never overlap at all; material overlap only
     * arises from re-detected bound drift or a timebase-shifted re-bank. 30 min keeps the rule
     * conservative at the seams: sub-30-min grazes from boundary jitter are never collapsed.
     */
    const val MIN_OVERLAP_SECONDS: Long = 30L * 60L

    /**
     * Fractional overlap of the SHORTER session at or above which two sessions are duplicates.
     * Catches a short duplicate fragment swallowed by a longer copy of the same night even when
     * the absolute overlap is under the 30 min bar (e.g. a 40 min fragment 60% inside the night).
     */
    const val MIN_OVERLAP_FRACTION_OF_SHORTER: Double = 0.5

    /**
     * Edge gap (seconds) at or below which two DISJOINT sessions are still one night (#1284 residual 3).
     * The Oura SleepNet burst runs a few epochs before the `0x49` onset, so its pre-onset piece can bank
     * as a short session ending seconds before the anchored night begins with NO overlap — the overlap
     * rule misses it (measured 69 s on 08-10/11; the pre-onset run is ~7 min / 14 codes per OuraLiveSource).
     * A gap this small can only be one interrupted night, never two real sleeps: a genuine nap is hours
     * from the main sleep, so it never trips this. 15 min is ~2x the observed pre-onset span.
     */
    const val NEAR_ADJACENT_SECONDS: Long = 15L * 60L

    /** The collapse outcome: canonical survivors + the duplicates dropped, both sorted by startTs. */
    data class Result(val kept: List<SleepSession>, val dropped: List<SleepSession>)

    /** Seconds of overlap between the two sessions' EFFECTIVE spans (edited onsets honoured,
     *  mirroring how display / day assignment place the block). 0 when disjoint. */
    internal fun overlapSeconds(a: SleepSession, b: SleepSession): Long =
        maxOf(0L, minOf(a.endTs, b.endTs) - maxOf(a.effectiveStartTs, b.effectiveStartTs))

    /** Edge gap (seconds) between two DISJOINT sessions (the later start minus the earlier end); 0 when
     *  they touch or overlap. Only meaningful when [overlapSeconds] is 0. */
    internal fun edgeGapSeconds(a: SleepSession, b: SleepSession): Long =
        maxOf(0L, maxOf(a.effectiveStartTs, b.effectiveStartTs) - minOf(a.endTs, b.endTs))

    /**
     * True when [a] and [b] are copies of the same night: overlap of at least [MIN_OVERLAP_SECONDS]
     * absolute, OR at least [MIN_OVERLAP_FRACTION_OF_SHORTER] of the shorter session's duration, OR (when
     * disjoint) an edge gap within [NEAR_ADJACENT_SECONDS] (#1284, the non-overlapping pre-onset fragment).
     * All terms use only (effectiveStartTs, endTs), the only time fields the data model carries.
     */
    fun isDuplicate(a: SleepSession, b: SleepSession): Boolean {
        val overlap = overlapSeconds(a, b)
        if (overlap <= 0L) {
            // Disjoint: a same-night fragment banked just before/after the anchored night (#1284).
            return edgeGapSeconds(a, b) <= NEAR_ADJACENT_SECONDS
        }
        if (overlap >= MIN_OVERLAP_SECONDS) return true
        val shorter = minOf(
            maxOf(a.endTs - a.effectiveStartTs, 0L),
            maxOf(b.endTs - b.effectiveStartTs, 0L),
        )
        return shorter > 0L && overlap.toDouble() >= MIN_OVERLAP_FRACTION_OF_SHORTER * shorter.toDouble()
    }

    /**
     * Collapse overlapping duplicates to one canonical survivor per night, deterministically.
     *
     * Canonical preference, highest first:
     *   1. [SleepSession.userEdited]: a hand-corrected night is never dropped (matching the
     *      engine's existing edited-window upsert guard, where the user's correction always
     *      outranks re-detection).
     *   2. Bank recency: startTs in [freshStarts]. The row model has no banked-at column, so
     *      recency is witnessed by the CALLER passing the keys it banked this pass; the freshly
     *      detected copy reflects the strap's current timebase and is the truth to keep.
     *   3. Longest effective duration: the fullest capture of the night.
     *   4. Latest endTs, then latest startTs: a stable total order so ties break the same way on
     *      every run and platform.
     *
     * Greedy sweep in preference order: a session is kept unless it overlap-duplicates an
     * already-kept one (edited rows are exempt and always kept). Both outputs are sorted by
     * startTs. Read-side callers with no bank witness pass no [freshStarts].
     */
    fun dedupe(sessions: List<SleepSession>, freshStarts: Set<Long> = emptySet()): Result {
        if (sessions.size < 2) return Result(sessions, emptyList())
        val ordered = sessions.sortedWith(
            compareByDescending<SleepSession> { it.userEdited }
                .thenByDescending { it.startTs in freshStarts }
                .thenByDescending { it.endTs - it.effectiveStartTs }
                .thenByDescending { it.endTs }
                .thenByDescending { it.startTs },
        )
        val kept = ArrayList<SleepSession>()
        val dropped = ArrayList<SleepSession>()
        for (s in ordered) {
            if (!s.userEdited && kept.any { isDuplicate(it, s) }) dropped.add(s) else kept.add(s)
        }
        return Result(kept.sortedBy { it.startTs }, dropped.sortedBy { it.startTs })
    }
}
