package com.noop.analytics

/**
 * PRE-STORAGE census of a decoded R-R batch (#1008/#1118 instrumentation). Byte-parity twin of Swift
 * `RrEmissionStats`.
 *
 * Every existing R-R number — `rrCoverage`, `collapsedCoverage`, the `hrv diag` line — is measured
 * AFTER the rows are stored, so it cannot distinguish the two candidate causes of the WHOOP 4.0
 * over-count:
 *
 *  * the strap/decoder EMITS more beat-time than elapsed (a decode or protocol reading), or
 *  * the same beats are STORED twice because two ingest passes both wrote them.
 *
 * [Result.ratio] settles it: Σ(rrMs) over the batch's own wall span, computed on the decoded batch
 * before a single row reaches the database. Near ~1.7 already means no storage-side de-dup can be the
 * fix and the defect is upstream of the DB; near 1.0 while the stored night still reads 1.7 means the
 * duplication is in ingest. Nothing in the shipped path reads any of this — instrumentation only.
 *
 * [Result.perSecond] characterises the shape rather than the size: at ~69 bpm a one-second record should
 * carry ONE interval (occasionally two, when two beats end inside the same second), so a fat 3-4 tail is
 * what a rolling/overlapping strap buffer would look like.
 *
 * There is deliberately NO cross-second repeat counter. Counting an interval that reappears verbatim one
 * second later cannot distinguish a re-sent beat from a STEADY HEART — at rest, consecutive real intervals
 * are near-identical by definition, so such a counter reads high on perfectly clean data and answers
 * nothing. [Result.ratio] carries the signal instead: it is bounded by physics, not by resemblance.
 */
object RrEmissionStats {

    data class Result(
        /** Distinct timestamps carrying at least one interval (≈ records that reported R-R). */
        val secondsWithRr: Int,
        /** Total intervals offered by the decoder, before any storage de-dup. */
        val intervals: Int,
        /** Σ of every interval, in milliseconds. */
        val sumRrMs: Int,
        /** Wall span the batch covers, inclusive, in seconds. */
        val spanSec: Int,
        /** Beat-time per second of wall time. >1 is physically impossible and so a defect, not a heart. */
        val ratio: Double,
        /** Intervals-per-second histogram: index 0 = exactly 1, 1 = 2, 2 = 3, 3 = 4 or more. */
        val perSecond: List<Int>,
    )

    /** Census a decoded batch. [rr] is the decoder's output order; nothing is mutated or sorted in place. */
    fun compute(rr: List<Pair<Int, Int>>): Result {
        if (rr.isEmpty()) {
            return Result(0, 0, 0, 0, 0.0, listOf(0, 0, 0, 0))
        }
        val bySecond = LinkedHashMap<Int, MutableList<Int>>()
        var sum = 0
        var minTs = Int.MAX_VALUE
        var maxTs = Int.MIN_VALUE
        for ((ts, rrMs) in rr) {
            bySecond.getOrPut(ts) { mutableListOf() }.add(rrMs)
            sum += rrMs
            if (ts < minTs) minTs = ts
            if (ts > maxTs) maxTs = ts
        }
        // Inclusive span: a single-second batch spans 1 s, not 0, so the ratio stays finite.
        val span = maxTs - minTs + 1
        val hist = mutableListOf(0, 0, 0, 0)
        for (vals in bySecond.values) {
            val i = minOf(vals.size, 4) - 1
            if (i >= 0) hist[i] = hist[i] + 1
        }
        val ratio = if (span > 0) sum / 1000.0 / span else 0.0
        return Result(bySecond.size, rr.size, sum, span, ratio, hist)
    }

    /**
     * One compact log line. [offered]/[inserted] come from the caller: [inserted] is what the store
     * actually wrote after its conflict key, so `offered - inserted` is how much the primary key already
     * absorbs — the third number needed to tell emission from ingest.
     */
    fun logLine(path: String, offered: Int, inserted: Int, r: Result): String {
        val ratio = String.format(java.util.Locale.US, "%.2f", r.ratio)
        val h = r.perSecond
        return "rr emit path=$path offered=$offered inserted=$inserted secs=${r.secondsWithRr} " +
            "sumRr=${r.sumRrMs / 1000}s span=${r.spanSec}s ratio=$ratio " +
            "perSec[1/2/3/4+]=${h[0]}/${h[1]}/${h[2]}/${h[3]}"
    }
}
