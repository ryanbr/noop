package com.noop.analytics

import com.noop.data.SleepSession

/**
 * Applying a hand-corrected bed/wake window to a BRIDGED night — every fragment of it, not just one.
 *
 * A night the strap split into fragments is displayed as one bridged group: the header's bedtime is the
 * first fragment's onset and its wake is the group's latest end. The editor, though, was anchored to the
 * single WINNING fragment, which on a split night is often neither of those. Correcting a night that was
 * "detected too long" therefore wrote a shorter window onto an interior fragment while the fragments
 * defining both displayed ends stayed exactly where they were — the save succeeded and nothing the user
 * was looking at moved. (#1492)
 *
 * The planner is pure so the semantics are testable without a database: given the group's fragments and
 * the window the user drew, decide what each fragment becomes.
 */
object SleepGroupEdit {

    /**
     * What each fragment becomes under the new window. [clipped] survives with its window re-cut (the
     * outer two to the drawn bounds, the rest narrowed); [dropped] falls entirely outside and must go — a
     * fragment left in place beyond the new bounds would go on defining the night's displayed start or
     * end, which is the bug being fixed.
     */
    data class Plan(
        val clipped: List<SleepSession>,
        val dropped: List<SleepSession>,
    )

    /**
     * Narrow [group] to [newStartTs]..[newEndTs].
     *
     * The OUTER surviving fragments take the drawn bounds outright; interior ones are narrowed to the
     * window. Taking them outright is what lets an edit LENGTHEN a night the strap cut short, not only
     * shorten one it ran long, and it makes the header — which reads the first onset and the latest end —
     * show exactly what was drawn. Each is marked `userEdited`, with the corrected onset in
     * `startTsAdjusted` so the immutable `(deviceId, startTs)` key never moves, matching the single-row
     * edit path. A fragment with no overlap is dropped; the caller retires those through the normal delete
     * path so a detected one is tombstoned and cannot be re-detected straight back into the night.
     *
     * A one-fragment group therefore reproduces the single-row edit exactly — it takes both bounds — so the
     * two paths cannot drift apart.
     *
     * Stage arrays are reclipped per fragment through the same [SleepWindowReclip] the single-row edit
     * uses, so a shortened fragment's hypnogram matches its new bounds instead of overhanging them.
     *
     * Returns an empty plan when the window clears every fragment: that is a window disjoint from the whole
     * night, which the editor's own confirm gate is there to catch, and silently deleting a night is never
     * the right reading of a bed/wake correction.
     */
    fun plan(group: List<SleepSession>, newStartTs: Long, newEndTs: Long): Plan {
        if (group.isEmpty() || newEndTs <= newStartTs) return Plan(emptyList(), emptyList())
        val ordered = group.sortedBy { it.effectiveStartTs }
        val kept = ordered.filter { minOf(it.endTs, newEndTs) > maxOf(it.effectiveStartTs, newStartTs) }
        // Never let a bed/wake correction empty the night — see the doc above.
        if (kept.isEmpty()) return Plan(emptyList(), emptyList())
        val dropped = ordered - kept.toSet()

        val clipped = kept.mapIndexed { i, frag ->
            // The OUTER fragments take the user's bounds outright rather than an intersection, so the edit
            // can lengthen a night the strap cut short as well as shorten one it ran long — and so the
            // header, which reads the first onset and the latest end, shows exactly what was drawn.
            // Interior fragments only ever narrow.
            val start = if (i == 0) newStartTs else maxOf(frag.effectiveStartTs, newStartTs)
            val end = if (i == kept.lastIndex) newEndTs else minOf(frag.endTs, newEndTs)
            val reclipped =
                SleepWindowReclip.reclip(frag.stagesJSON, frag.effectiveStartTs, frag.endTs, start, end)
            frag.copy(
                startTsAdjusted = start,
                endTs = end,
                userEdited = true,
                stagesJSON = reclipped ?: frag.stagesJSON,
            )
        }
        return Plan(clipped, dropped)
    }

    /**
     * The window the editor should open on and validate against: the whole bridged night, first onset to
     * latest wake. The editor previously seeded and coverage-tested from the winning fragment, so on a
     * split night the pickers opened on times that did not match the header the user was correcting, and a
     * window matching the night they could see could read as DISJOINT from that one fragment — routing a
     * perfectly ordinary edit into the "outside the recorded coverage" confirm instead of saving it.
     */
    fun groupWindow(group: List<SleepSession>): Pair<Long, Long>? {
        val start = group.minOfOrNull { it.effectiveStartTs } ?: return null
        val end = group.maxOfOrNull { it.endTs } ?: return null
        return if (end > start) start to end else null
    }
}
