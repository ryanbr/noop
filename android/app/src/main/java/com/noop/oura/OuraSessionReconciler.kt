package com.noop.oura

/**
 * Pure session-identity reconciler for the Oura live hypnogram path (#1284 residual 3).
 *
 * THE PROBLEM. `OuraLiveSource.persistHypnogramBurst` sets a session's `startTs` from the matched
 * `0x49` sleep-summary onset and banks under `PK = (deviceId, startTs)`. The ring serves more than one
 * decode of the same night — measured by @pipiche38 over four nights — in two distinct modes:
 *
 *   - Re-anchor (08-12/13): the same hypnogram laid backwards from two different `0x49` onsets,
 *     boundary-for-boundary identical, offset by a fixed lag (554 s). Two onsets -> two startTs -> two rows.
 *   - Partial drain (08-13/14): a genuinely shorter, divergent decode from an earlier partial burst,
 *     with its OWN `0x49` anchor (494 min/89 seg vs 234 min/35 seg, diverging at segment 5).
 *
 * `PK=(deviceId,startTs)` mints a second row in both modes; the #899 heal only cleans up afterward.
 *
 * THE FIX (validated against the corpus — option (2) collapses 4/4 nights, the 30-min grid only 1/4).
 * Group a ring's sessions by the noon-anchored sleep-day (`date(startTs_local + 12h)`), then within a
 * day treat two sessions as the SAME session when they overlap or sit within `mergeGapS` (~60 min), and
 * keep the FULLER one (the completeness guard, which adjudicates the partial-drain mode — the fuller row
 * is the WHOOP-matching one on every measured night). Sessions further apart than `mergeGapS` on the
 * same sleep-day are DISTINCT (an afternoon nap is hours from that night's sleep) and each keeps its row.
 *
 * Noon-anchor, not plain wake-day: on 08-10/11 the 40-min fragment 22:09:40 -> 22:49:40 ENDS before
 * midnight, so its wake-day (Aug 10) differs from the night it belongs to (Aug 11); the noon anchor maps
 * both to the same sleep-day. Not a grid: two starts 6.25 min apart straddle a 30-min boundary and fail
 * to collapse, and a grid spends the bedtime precision that let 08-13/14 be checked against WHOOP to
 * -10 s/+50 s. Proximity needs no estimate of the jitter it corrects (242 s healthy .. 2469 s worst).
 *
 * PURE (no store, no BLE) so the decision is unit-testable headlessly. The caller (`OuraLiveSource`)
 * supplies the day's already-persisted sessions (read from the DB at persist time — the read that lets
 * the check see cross-connection duplicates a per-connection list cannot) and acts on the decision.
 * Byte-identical twin: Swift `OuraSessionReconciler`.
 */
object OuraSessionReconciler {

    /** A persisted (or about-to-persist) Oura sleep session, reduced to the fields the reconciler needs.
     *  `codeCount` is the number of laid 30-s stage epochs — the completeness signal. Ties break toward
     *  the NEW session (see [reconcile]). */
    data class SessionWindow(val startTs: Int, val endTs: Int, val codeCount: Int)

    /** What the caller should do with the new session relative to the day's existing rows. */
    sealed class Decision {
        /** No existing session is the same as the new one — persist it as a fresh row. */
        object Insert : Decision()
        /** An existing same-session row is at least as complete — drop the new one, keep what's stored. */
        object Skip : Decision()
        /** The new session is the fullest decode of a same-session it collides with — persist it and
         *  delete the superseded rows at these `startTs` keys (the earlier/shorter duplicates). */
        data class Replace(val supersededStartTs: List<Int>) : Decision()
    }

    /** Default same-session proximity: within this many seconds (or overlapping) is the same night's
     *  sleep; further apart on the same sleep-day is a distinct session (nap). 60 min clears the widest
     *  measured duplicate gap (2469 s) with margin and is far below any real nap-to-sleep gap. */
    const val defaultMergeGapSeconds = 3600

    /** The noon-anchored sleep-day integer (days since the Unix epoch) a session belongs to:
     *  `date(startTs_local + 12h)`. Sessions sharing this value are candidates to be the same night; it
     *  is the grouping key the caller uses to read "this night's" existing rows. `tzOffsetSeconds` is the
     *  wearer's UTC offset at the session — the day boundary is LOCAL noon. */
    fun noonAnchoredSleepDay(startTs: Int, tzOffsetSeconds: Int): Int {
        val local = startTs + tzOffsetSeconds + 12 * 3600
        return Math.floorDiv(local, 86_400)
    }

    /** Decide how to persist [new] given the ring's already-stored sessions FOR THE SAME NOON-ANCHORED
     *  SLEEP-DAY ([existing]). The caller must pass only same-sleep-day rows; this does the proximity +
     *  completeness adjudication. Overlap OR gap < [mergeGapS] => same session; [new] at least as complete
     *  (`codeCount >=`) as every same-session it hits => Replace them (ties break toward [new]); else a
     *  stored same-session is fuller => Skip; no same-session => Insert. */
    fun reconcile(
        new: SessionWindow,
        existing: List<SessionWindow>,
        mergeGapS: Int = defaultMergeGapSeconds,
    ): Decision {
        val sameSession = existing.filter { isSameSession(new, it, mergeGapS) }
        if (sameSession.isEmpty()) return Decision.Insert
        val fullestStored = sameSession.maxOf { it.codeCount }
        return if (new.codeCount >= fullestStored) {
            Decision.Replace(sameSession.map { it.startTs })
        } else {
            Decision.Skip
        }
    }

    /** Two windows are the same session when they overlap, or the nearest edge gap is under [mergeGapS].
     *  Symmetric. */
    internal fun isSameSession(a: SessionWindow, b: SessionWindow, mergeGapS: Int): Boolean {
        if (a.startTs < b.endTs && b.startTs < a.endTs) return true // overlap
        val gap = if (a.startTs >= b.endTs) a.startTs - b.endTs else b.startTs - a.endTs
        return gap < mergeGapS
    }
}
