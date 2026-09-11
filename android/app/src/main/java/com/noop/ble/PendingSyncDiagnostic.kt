package com.noop.ble

/**
 * Why the Rest card's "Pending sync" state is on or off (#2012).
 *
 * That state is `backfilling || historyPendingSync`, and only the first half leaves a trace: an offload
 * announces itself with "Backfill: session started" and a run of bursts. The second half flipped in
 * silence, so a report of the note showing hours after waking could not be answered from a strap log at
 * all. #2012 is exactly that: a log arrived, and it could only be read by inferring from what else was
 * happening at the timestamp, which settles nothing.
 *
 * So the line names the DECIDING input rather than just the verdict. Four things can decide it, and they
 * mean different bugs: a future-dated strap clock, a phantom gap that advertises records it never banks,
 * being genuinely caught up, or being genuinely behind. Reading "behind by 34210s" in the afternoon is
 * the evidence that the trigger is not scoped to the night being scored, which is the open half of #2012.
 *
 * Pure so it is unit-tested directly; byte-identical to the Swift twin.
 */
object PendingSyncDiagnostic {

    /** Where the flag was recomputed. The two sites weigh different evidence, so the line says which. */
    const val SITE_CONNECT = "connect"
    const val SITE_POST_OFFLOAD = "post-offload"

    /**
     * One line for a CHANGE of the flag; callers log it only on a flip, never per evaluation.
     *
     * @param persistedRows null at [SITE_CONNECT], which cannot weigh it: no offload has run, so there is
     *   no row evidence yet. Naming that rather than printing a misleading "no".
     */
    fun line(
        pending: Boolean,
        site: String,
        newestUnix: Long?,
        frontierUnix: Long?,
        futureDated: Boolean,
        persistedRows: Boolean?,
        thresholdSec: Long,
    ): String {
        // NULLABLE deliberately. The flag flips to false when either input is missing, so requiring them
        // here would have left that flip silent, which is the exact hole this whole line exists to close.
        // It is reachable: an unanswered GET_DATA_RANGE ("requesting history anyway (fail-open)") leaves
        // no newest to compare, and a first-ever session leaves no frontier.
        if (newestUnix == null || frontierUnix == null) {
            return "pending-sync ${if (pending) "ON" else "OFF"} ($site): no range to compare " +
                "[newest=${newestUnix ?: "unknown"} frontier=${frontierUnix ?: "unknown"}]"
        }
        val gap = newestUnix - frontierUnix
        val why = when {
            futureDated -> "strap clock reads ahead of now, so the gap could never close (#928/#1012)"
            persistedRows == false -> "strap advertises newer records but banked no rows — phantom gap (#1144)"
            gap > thresholdSec -> "strap is ${gap}s ahead of our frontier, over the ${thresholdSec}s threshold"
            else -> "caught up — ${gap}s gap, within the ${thresholdSec}s threshold"
        }
        val rows = when (persistedRows) {
            null -> "n/a at connect"
            true -> "yes"
            false -> "no"
        }
        return "pending-sync ${if (pending) "ON" else "OFF"} ($site): $why " +
            "[newest=$newestUnix frontier=$frontierUnix gap=${gap}s futureDated=$futureDated rowsBanked=$rows]"
    }
}
