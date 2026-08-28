package com.noop.analytics

/**
 * How to satisfy one day's windowed stream read given what the previous day already read (#1538).
 *
 * `analyzeRecent`'s pass-1 loop walks BACKWARDS — `dayStart = nowLocalMidnight - offset * 24h` — and reads
 * a 54-hour window around each night (`dayStart - 30h` .. next local midnight). On a 24-hour stride that
 * makes consecutive windows overlap by 30 hours, so every row is materialised about 2.25 times per pass.
 * The `analyzeRecent cost prep=…ms score=…ms` line exists to decide whether that is worth narrowing, and a
 * field log answered it: prep 48129ms against score 31516ms on a cold 21-day pass, so the reads are the
 * larger half and the overlap is worth removing.
 *
 * This is the DECISION half, kept pure so both platforms can be pinned against one oracle. Splicing the
 * rows is mechanical and stays with the caller. Twin of Swift `WindowedStreamPlan`.
 *
 * The planner REFUSES rather than guesses. Every case it cannot prove safe returns [FullRead], which is
 * byte-for-byte the behaviour that shipped before this existed — the same stance `daySliceFromNight` takes
 * when it declines. An optimisation on the scoring path may only ever skip work, never change a number.
 */
object WindowedStreamPlan {

    /**
     * What the sliding windows saved, for the line emitted beside `analyzeRecent`'s `prep`/`score` split
     * — the measurement the decision to build them was made from.
     *
     * `read` is rows fetched from the store, `served` rows a buffer supplied instead. A pass where
     * `served` is ~0 means the windows are declining — truncation, an owner flip, or a gap left by a
     * dayCache hit — and the reads are back to exactly what they were. That is the honest outcome rather
     * than a silent one, which is why the counters ship rather than just the speedup.
     *
     * `truncated` separates the one of those causes that is also a BUG. The reads are
     * `ORDER BY ts ASC LIMIT`, so a read at the cap drops the NEWEST rows and the day is scored on a
     * window missing its tail, with nothing else in the log to say so. A field log showed a strap at
     * 192,680 rows against the 200,000 cap — 96% — with `served` near zero on one stream and half on the
     * other, and no way to tell which cause fired. Hence this counter rather than a guess.
     *
     * Lives HERE rather than on the engine so both platforms put it in the same place and both are
     * covered by default CI. Byte-identical to the Swift `WindowedStreamPlan.logLine`.
     */
    fun logLine(
        hrRead: Long,
        hrServed: Long,
        hrTruncated: Long,
        rrRead: Long,
        rrServed: Long,
        rrTruncated: Long,
    ): String =
        "analyzeRecent windows hr[read=$hrRead served=$hrServed truncated=$hrTruncated] " +
            "rr[read=$rrRead served=$rrServed truncated=$rrTruncated]"

    /** What the caller should do to obtain rows for the requested window. */
    sealed interface Plan {
        /** Read the whole window from the store; nothing usable is buffered. */
        data object FullRead : Plan
        /** The buffer already covers the window; slice it, read nothing. */
        data object Serve : Plan
        /**
         * Read only `[readFrom, readTo]` (inclusive, both ends) and prepend it to the buffer. `readTo` is
         * one second BELOW the buffer's current start, so the boundary row is never read twice — the
         * store's range predicate is inclusive at both ends.
         */
        data class Extend(val readFrom: Long, val readTo: Long) : Plan
    }

    /**
     * Plan the read for `[from, to]` against a buffer holding `[cachedFrom, cachedTo]` for [cachedOwner].
     *
     * [cachedOwner] null means nothing is buffered. [cachedTruncated] means the buffered read hit the
     * store's row limit, so its contents do not represent its range — that buffer can never be sliced, for
     * the reason `daySliceFromNight` gives.
     *
     * After the caller acts on the plan the buffer covers exactly `[from, to]`: rows above `to` are
     * dropped, which is what keeps the peak footprint at one window rather than the whole pass. A backward
     * walk never asks for them again.
     */
    fun plan(
        cachedOwner: String?,
        cachedFrom: Long,
        cachedTo: Long,
        cachedTruncated: Boolean,
        owner: String,
        from: Long,
        to: Long,
    ): Plan {
        // Nothing buffered, a different strap owns this day, or the buffered read was cut off at the row
        // limit — none of these can be sliced, and a wrong slice is a wrong score.
        if (cachedOwner == null || cachedOwner != owner || cachedTruncated) return Plan.FullRead
        // A degenerate or inverted buffer holds nothing meaningful.
        if (cachedFrom > cachedTo) return Plan.FullRead
        // An inverted request is not this planner's business to repair.
        if (from > to) return Plan.FullRead
        // The buffer covers the request outright.
        if (from >= cachedFrom && to <= cachedTo) return Plan.Serve
        // The ONLY extension this walk produces: the window moved earlier, and its tail is still inside
        // what is buffered. Anything else (a window that moved forward, or one disjoint from the buffer)
        // is not the backward stride this exists for, so it reads in full rather than being reasoned about.
        if (from < cachedFrom && to in cachedFrom..cachedTo) return Plan.Extend(from, cachedFrom - 1)
        return Plan.FullRead
    }
}
