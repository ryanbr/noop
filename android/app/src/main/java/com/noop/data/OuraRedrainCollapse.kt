package com.noop.data

import com.noop.protocol.RrSourceChannel

/**
 * Beats a redrain stored a second time, recognised by the record they came in rather than by their
 * timestamps (#2456). Twin of Swift's OuraRedrainCollapse in WhoopProtocol.
 *
 * A ring record is served again whenever history is refetched: after a link drops mid-drain, and also
 * after a night has already drained, which is the case a resume cursor cannot prevent. Each connection
 * adopts its own SyncTime anchor, so the second copy resolves to a wall-clock second one or two off the
 * first and misses the row key instead of colliding with it. Both copies are then stored, the night's
 * R-R coverage rises above 1, and its HRV is refused as an over-count. One reported night went from
 * coverage 0.99 with HRV shown to 1.22 with the night's HRV gone, retroactively, after a redrain added
 * 6,466 channel-3 beats of which 5,471 were an exact copy stamped one second later.
 *
 * What identifies a copy is the RECORD, not the beat. A banked 0x60 record stamps all of its intervals
 * on one timestamp, so a re-served record reappears as the same ordered run of rrMs values on the same
 * channel a second or two later. Single beats are NOT enough to go on: equal successive beats are
 * physiological and are deliberately kept (#163), and on a clean night 2.5% of beats already have an
 * equal neighbour one second away. A whole ordered run repeating is not a coincidence at that rate.
 *
 * Collapsing on read rather than deleting on write is deliberate: it needs no migration, it costs
 * nothing if the ring never re-serves, and it repairs nights that were already double-stored, which a
 * write-side key can never do. It does not reclaim the disk those rows occupy.
 */
object OuraRedrainCollapse {

    /**
     * Beats within [withinSeconds] that repeat an earlier run of at least [minimumRun] beats, dropped.
     *
     * Order is preserved, only Oura channels are considered, and a run is compared against the last run
     * KEPT with that signature, so a record served three times collapses to one rather than to two.
     *
     * Swift twin: `withoutRedrainedRuns`
     */
    fun withoutRedrainedRuns(
        beats: List<RrInterval>,
        withinSeconds: Long = 2,
        minimumRun: Int = 3,
    ): List<RrInterval> {
        if (minimumRun <= 1 || withinSeconds <= 0 || beats.size <= minimumRun) return beats

        val lastKept = HashMap<String, Long>()
        val dropped = HashSet<Int>()

        var index = 0
        while (index < beats.size) {
            val ts = beats[index].ts
            var end = index
            while (end < beats.size && beats[end].ts == ts) end++

            // One timestamp can carry runs from more than one channel; each is its own record.
            val byChannel = LinkedHashMap<Int, MutableList<Int>>()
            for (i in index until end) {
                // The enum's own `isOura`, not a second copy of the channel range here: one more
                // private predicate is one more thing to drift from the Swift side.
                val code = beats[i].srcChannel
                if (RrSourceChannel.fromCode(code)?.isOura != true) continue
                byChannel.getOrPut(code!!) { ArrayList() }.add(i)
            }

            for ((channel, indices) in byChannel) {
                if (indices.size < minimumRun) continue
                val signature = "$channel:" + indices.joinToString(",") { beats[it].rrMs.toString() }
                val previous = lastKept[signature]
                if (previous != null && ts - previous > 0 && ts - previous <= withinSeconds) {
                    dropped.addAll(indices)
                } else {
                    lastKept[signature] = ts
                }
            }
            index = end
        }

        if (dropped.isEmpty()) return beats
        return beats.filterIndexed { i, _ -> i !in dropped }
    }
}
