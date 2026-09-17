package com.noop.protocol

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Spread a frame's R-R array across the time it actually describes.
 *
 * Every ingest path stamped EVERY interval in a frame's `rr_intervals` array with that frame's single
 * timestamp:
 *
 *     for (rr in rrs) out.rr.add(RrInterval(ts, rr, source))
 *
 * A frame carrying two ~740 ms intervals therefore recorded both beats as having occurred at the same
 * instant, when the array describes roughly 1.5 seconds of heart activity. The beats are real and
 * distinct; only their placement in time was collapsed.
 *
 * ## What this fixes, and what it does not
 *
 * It fixes WHERE a beat sits, which matters for anything reading R-R against a clock: which sleep stage
 * or workout interval a beat is attributed to, and any windowed analysis that slices the night.
 *
 * It does NOT change `rrCoverage`, and the distinction is worth being precise about because the collapse
 * is easy to mistake for the cause of an over-count. Coverage is `sum(rrMs) / (max(ts) - min(ts))`. This
 * function leaves `sum(rrMs)` untouched by construction (no beat is added, dropped or altered) and widens
 * the span by at most one batch width across a whole night. On an 8-hour night of two-interval frames it
 * moves coverage by ~0.0001. A night reading 1.5 still reads 1.5 afterwards, and `classifyCoverage` gates
 * on `coverage` before it consults `collapsed`, so the verdict is unchanged too. Whatever is producing
 * ~2x the plausible beat count on a WHOOP 4.0 is a separate defect and is still open.
 *
 * ## The convention, and why the risk in it is small
 *
 * The array is oldest-first and the MOST RECENT interval ends at the frame timestamp, following the Heart
 * Rate Service shape these frames mirror (`rr_count` then the values). So interval `i` is placed at
 * `frameTs` minus the intervals that follow it.
 *
 * That convention is an inference from the frame shape, not something a capture has proven. If it is
 * backwards and `frameTs` marks the START of the batch, every beat shifts by at most one batch width,
 * under two seconds. RMSSD and SDNN are built from differences between interval VALUES, which this does
 * not touch, so neither moves.
 *
 *
 * ## Ordering holds only while a batch fits the gap
 *
 * Back-dating reaches at most one batch width behind the frame. While that is no more than the gap to
 * the previous frame, the stream stays non-decreasing: at the 4.0's observed coverage of 1.5 to 2.4 the
 * earliest beat lands exactly on the previous frame's second, never before it. A batch that spans MORE
 * than the gap (coverage around 3 and above) emits a timestamp earlier than a row already emitted.
 * Nothing is lost when that happens, since `seq` keys on (ts, rrMs) and distinct beats keep their own
 * key, but reads that sort by ts will interleave the two frames. No shipped device is near that, and the
 * test suite pins both sides of the boundary.
 *
 * ## Safe where there is nothing to spread
 *
 * A single-interval array returns unchanged, so a strap whose frames arrive at about its beat rate is
 * byte-identical through this. Only a batching frame moves, which is the only case that was ever wrong.
 *
 */
object RrBatchTimestamps {

    /** One placed interval: the beat's value, and the second it is attributed to. */
    data class Placed(val ts: Long, val rrMs: Int)

    /**
     * The frame's intervals with a timestamp each, oldest first.
     *
     * Timestamps are whole seconds while beats are not, so a sub-second step sometimes lands two beats in
     * one second and sometimes in adjacent ones. That is inherent to a second-resolution column.
     *
     * Byte-parity twin of Swift `RrBatchTimestamps.spread`. `ts` is `Long` here because that is what
     * `RrRow` stores and what Swift's 64-bit `Int` means; the arithmetic is otherwise identical.
     */
    fun spread(frameTs: Long, rrMs: List<Int>): List<Placed> {
        if (rrMs.size <= 1) return rrMs.map { Placed(frameTs, it) }
        val out = ArrayList<Placed>(rrMs.size)
        // Walk backwards accumulating the intervals AFTER each one: the last ends at `frameTs`, the one
        // before it a beat earlier, and so on. `max(0,)` keeps a malformed negative value from walking the
        // clock forwards.
        var msAfter = 0
        for (value in rrMs.asReversed()) {
            out.add(Placed(frameTs - (msAfter / 1000.0).roundToInt().toLong(), value))
            msAfter += max(0, value)
        }
        return out.asReversed()
    }
}
