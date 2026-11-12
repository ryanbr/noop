package com.noop.analytics

/**
 * Decides which single device owns a given day's displayed/scored metrics, so scores are never
 * computed from a mix of sources (invariant I2). Pure — the caller supplies the candidates (each
 * device with any data near the day, plus a priority) and any locked override from the dayOwnership
 * table. Port of the Swift `DayOwnerResolver` in Packages/StrandAnalytics.
 */
object DayOwnerResolver {
    /** A device in contention for owning [day]. [priority]: 0 = active strap, 1 = other live straps,
     *  2 = imports (lower wins). [hasData] = the device actually has data for the day. */
    data class Candidate(val deviceId: String, val priority: Int, val hasData: Boolean)

    /** The owning deviceId, or null if no candidate has data for the day. A non-null [lockedOwner]
     *  (an explicit dayOwnership decision) always wins, regardless of priority or data. */
    @Suppress("UNUSED_PARAMETER") // `day` mirrors the Swift DayOwnerResolver.resolve signature (parity)
    fun resolve(day: String, lockedOwner: String?, candidates: List<Candidate>): String? =
        if (lockedOwner != null) lockedOwner
        else candidates.filter { it.hasData }.minByOrNull { it.priority }?.deviceId

    /** #2880: the active strap won the day, but archived rows for the SAME physical strap (same
     *  peripheralId, left behind by Remove + re-add) may hold the night. The one with the most HR rows
     *  owns the day; a tie keeps the active id, then the earlier sibling. [siblings] are (id, hrRows).
     *  Twin of the Swift `DayOwnerResolver.sameStrapOwner`. */
    fun sameStrapOwner(activeId: String, activeHrRows: Int, siblings: List<Pair<String, Int>>): String {
        var best = activeId to activeHrRows
        for (s in siblings) if (s.second > best.second) best = s
        return best.first
    }
}
