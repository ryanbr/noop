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
     * Edge distance (seconds) at or below which a same-night FRAGMENT is still one night (#1284 residual 3).
     * The Oura SleepNet burst runs a few epochs before the `0x49` onset, so its pre-onset piece can bank as
     * a short session ending just before — or, when the backward lay overshoots the onset, grazing just
     * into — the anchored night. This bar catches it on EITHER side of the touch point (see the fragment
     * rule in [isDuplicate]); 15 min is ~2x the observed pre-onset span, well below any real inter-sleep gap.
     */
    const val NEAR_ADJACENT_SECONDS: Long = 15L * 60L

    /**
     * A shorter session at or below this fraction of the longer one is a re-decode FRAGMENT of that night,
     * not a second sleep (#1284 residual 3). It separates a fragment hugging a night (26 min beside a
     * 390 min night = 6.7 % -> collapse; a 40 min pre-onset piece beside an 8 h night = 8.3 % -> collapse)
     * from two GENUINE adjacent naps of comparable length (20 min beside 33 min = 61 % -> kept), which must
     * never merge. Ratio, not an absolute cap: real naps and re-decode fragments overlap in absolute length
     * (both ~20-30 min), so only the ratio to the partner night tells them apart. Deliberately conservative
     * (0.10): the durable fix is generation-side `0x49`-onset keying — this only heals what still slips through.
     */
    const val FRAGMENT_FRACTION_OF_LONGER: Double = 0.10

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
     * True when [a] and [b] are copies of the same night: a substantial overlap ([MIN_OVERLAP_SECONDS]
     * absolute, OR [MIN_OVERLAP_FRACTION_OF_SHORTER] of the shorter session), OR a same-night FRAGMENT — a
     * session no more than [FRAGMENT_FRACTION_OF_LONGER] of the longer one — sitting at its edge, whether it
     * grazes in (small overlap) or falls just short (gap within [NEAR_ADJACENT_SECONDS]).
     *
     * The fragment term is deliberately continuous across the overlap==0 seam: a pre-onset piece that
     * overshoots the anchored onset by seconds must not be treated as MORE distinct than one ending seconds
     * short of it (that discontinuity left a 121 s-grazing fragment un-collapsed on 08-13/14 while a 69 s gap
     * collapsed — #1284). The ratio gate keeps two GENUINE adjacent naps (comparable length) apart.
     * All terms use only (effectiveStartTs, endTs), the only time fields the data model carries.
     */
    fun isDuplicate(a: SleepSession, b: SleepSession): Boolean {
        val overlap = overlapSeconds(a, b)
        if (overlap >= MIN_OVERLAP_SECONDS) return true
        val aDur = maxOf(a.endTs - a.effectiveStartTs, 0L)
        val bDur = maxOf(b.endTs - b.effectiveStartTs, 0L)
        val shorter = minOf(aDur, bDur)
        if (overlap > 0L && shorter > 0L &&
            overlap.toDouble() >= MIN_OVERLAP_FRACTION_OF_SHORTER * shorter.toDouble()
        ) {
            return true
        }
        // Same-night fragment: short relative to the longer night AND hugging its edge (either side).
        val longer = maxOf(aDur, bDur)
        val isFragment = shorter > 0L && shorter.toDouble() <= FRAGMENT_FRACTION_OF_LONGER * longer.toDouble()
        return isFragment && (overlap > 0L || edgeGapSeconds(a, b) <= NEAR_ADJACENT_SECONDS)
    }

    /** The canonical preference comparator (see [dedupe]): higher ranks first (descending). Shared by
     *  [dedupe] and the at-persist keying ([planBank]) so both adjudicate a night with the IDENTICAL rule. */
    private fun rankComparator(freshStarts: Set<Long>): Comparator<SleepSession> =
        compareByDescending<SleepSession> { it.userEdited }
            .thenByDescending { it.startTs in freshStarts }
            .thenByDescending { it.endTs - it.effectiveStartTs }
            .thenByDescending { it.endTs }
            .thenByDescending { it.startTs }

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
        val ordered = sessions.sortedWith(rankComparator(freshStarts))
        val kept = ArrayList<SleepSession>()
        val dropped = ArrayList<SleepSession>()
        for (s in ordered) {
            if (!s.userEdited && kept.any { isDuplicate(it, s) }) dropped.add(s) else kept.add(s)
        }
        return Result(kept.sortedBy { it.startTs }, dropped.sortedBy { it.startTs })
    }

    // ── #1284 residual 3: generation-side 0x49-onset keying (at-persist, no schema migration) ─────

    /**
     * The grid (seconds) the 0x49 onset is rounded to before it becomes a session's startTs. The ring
     * re-serves one night's 0x49 summary many times as its END chases wall-clock; the ONSET is stable
     * across those re-serves (measured 21 s spread over 11 servings on 08-16), so rounding it to a coarse
     * grid gives every re-serve of one night the SAME startTs → the (deviceId, startTs) PK collapses them
     * instead of minting a row per drain. 60 s >> the 21 s jitter (re-serves land in one bucket) yet keeps
     * the displayed bedtime accurate to the minute — and the bedtime becomes the TRUE onset, fixing the
     * current end-anchored drift (startTs = end - laidCodes*30 s).
     */
    const val ONSET_KEY_GRID_SECONDS: Long = 60L

    /** Round a 0x49 onset (Unix seconds) to [ONSET_KEY_GRID_SECONDS] — the stable per-night key. Rounds to
     *  nearest so a jittering onset lands in one bucket; a rare straddle at a bucket edge is caught by the
     *  completeness guard ([planBank]), which matches the night by overlap, not by the PK. */
    fun keyedStart(onsetUnixSeconds: Long, gridSeconds: Long = ONSET_KEY_GRID_SECONDS): Long {
        val g = maxOf(1L, gridSeconds)
        return ((onsetUnixSeconds + g / 2) / g) * g
    }

    /** The bank decision, mirroring the Swift twin. */
    data class BankPlan(val bank: Boolean, val supersededStarts: List<Long>)

    /**
     * Decide, at persist time, whether a freshly reconstructed [candidate] night should be banked and which
     * already-stored rows it supersedes — the generation-side twin of the [dedupe] heal, so a duplicate is
     * suppressed BEFORE it is banked (closing the window where the wrong night shows until the next analyze
     * pass). Same collapse rule as [dedupe] with NO bank-recency witness (ring rows fall back to longest-,
     * then latest-end-wins): bank the candidate unless an existing same-night row is at least as complete
     * (ties keep the stored row); when it wins, delete the same-night rows it supersedes. Pure; the caller
     * does the store delete + upsert only when [BankPlan.bank] is true.
     *
     * [existing] MUST be the UNFILTERED stored set for the night's window — INCLUDING a row already at the
     * candidate's keyed startTs. Keying rounds re-serves of one night to the same bucket, so that same-PK
     * row is the common collision and must be weighed here, else the upsert would replace a fuller stored
     * night with a partial re-drain by PK. [BankPlan.supersededStarts] EXCLUDE the candidate's own startTs —
     * the upsert replaces that row in place, so listing it would delete the row just banked.
     */
    fun planBank(candidate: SleepSession, existing: List<SleepSession>): BankPlan {
        val sameNight = existing.filter { isDuplicate(candidate, it) }
        val cmp = rankComparator(emptySet())
        // Suppress the candidate if any stored same-night row (same PK or not) ties or outranks it.
        if (sameNight.any { cmp.compare(it, candidate) <= 0 }) return BankPlan(false, emptyList())
        return BankPlan(true, sameNight.filter { it.startTs != candidate.startTs }.map { it.startTs })
    }
}
