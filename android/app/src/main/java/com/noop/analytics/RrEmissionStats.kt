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
        /**
         * Gap between consecutive records THAT CARRIED R-R, in seconds: index 0 = 1 s … index 7 = 8 s or
         * more. Not the strap's raw record cadence — a record banking no interval is invisible here — but
         * that is exactly the right set, because ratioRep divides by the same one: healthy ratioRep ~ the
         * mean of these gaps, whose mode this reports. A strap banking R-R every 5 s reads ratioRep ~5
         * while perfectly healthy, so reading it against 1.0 would invent a defect (#1451). Ties resolve to
         * the smaller gap on both platforms.
         */
        val gapHist: List<Int> = listOf(0, 0, 0, 0, 0, 0, 0, 0),
        /**
         * Per-record FILL: that record's sum of rrMs over its own slot (the gap to the next record).
         * Index 0 = <=1.0, 1 = <=1.5, 2 = <=2.0, 3 = >2.0. This is the measurement a timeline fix needs and
         * no aggregate can supply: whether ONE record carries more beat-time than the interval it covers.
         * Fill ~1.0 means records tile the timeline and each interval can be placed at its own
         * reconstructed beat time; a fat tail means the records themselves overflow and no placement scheme
         * built on the record timestamp can be correct. The final record has no successor and is excluded.
         * Known bias: the slot is the gap to the next R-R-carrying record, so if a strap interleaves
         * records without intervals the slot spans more than one record period and fill reads LOW. It can
         * therefore understate overflow, never manufacture it.
         */
        val fill: List<Int> = listOf(0, 0, 0, 0),
    ) {
        /**
         * Modal record gap in seconds — the mode of [gapHist], 8 meaning "8 or more". 0 when the batch held
         * fewer than two records. This is the healthy baseline for the reporting-second ratio.
         */
        val modalGapSec: Int
            get() {
                val m = gapHist.maxOrNull() ?: 0
                return if (m <= 0) 0 else gapHist.indexOf(m) + 1
            }
    }

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
        // Per-record cadence and fill (#1451). A record's SLOT is the gap to the next record, so the last
        // record is excluded — it has no successor to bound it.
        val stamps = bySecond.keys.sorted()
        val gapHist = mutableListOf(0, 0, 0, 0, 0, 0, 0, 0)
        val fill = mutableListOf(0, 0, 0, 0)
        for (i in 0 until maxOf(stamps.size - 1, 0)) {
            val gap = stamps[i + 1] - stamps[i]
            if (gap < 1) continue
            gapHist[minOf(gap, 8) - 1] = gapHist[minOf(gap, 8) - 1] + 1
            val recSum = bySecond[stamps[i]]?.sum() ?: 0
            val f = recSum / 1000.0 / gap
            val b = if (f <= 1.0) 0 else if (f <= 1.5) 1 else if (f <= 2.0) 2 else 3
            fill[b] = fill[b] + 1
        }
        val ratio = if (span > 0) sum / 1000.0 / span else 0.0
        return Result(bySecond.size, rr.size, sum, span, ratio, hist, gapHist, fill)
    }

    /**
     * Should a LIVE census line be emitted now? (#1118 instrumentation.)
     *
     * The historical census is emitted once per offload SESSION, which is naturally rare. The two live
     * paths flush roughly every 30 readings, so emitting per flush would put a line on the strap log
     * every ~30 seconds all night — a volume that buries the very evidence it exists to provide. One
     * line per path per [minGapSec] is plenty: a single flush already spans enough seconds to make
     * `ratioRep` meaningful (the historical line settles it on 39 s), and what matters is comparing the
     * paths, not sampling either densely.
     *
     * [lastEmitSec] is 0 before the first line, so the first flush of a connection always reports.
     * A clock that moves BACKWARDS emits rather than suppresses: the alternative wedges the census
     * shut until wall time catches up, and a silent instrument is worse than a duplicated line.
     */
    fun shouldEmitLiveCensus(lastEmitSec: Int, nowSec: Int, minGapSec: Int = LIVE_CENSUS_MIN_GAP_SEC): Boolean {
        // The "never emitted" sentinel is checked EXPLICITLY. Falling through to the gap arithmetic
        // gets the right answer in production only because a real unix `nowSec` is ~1.8e9 and so
        // trivially clears any gap — an accident of magnitude, not a rule. It also made the helper
        // untestable with small timestamps, which is how this was caught.
        if (lastEmitSec <= 0) return true
        if (nowSec < lastEmitSec) return true
        return nowSec - lastEmitSec >= minGapSec
    }

    /** 15 minutes: rare enough not to bury the log, frequent enough to sample a night several times. */
    const val LIVE_CENSUS_MIN_GAP_SEC: Int = 900

    /**
     * One compact log line. [offered]/[inserted] come from the caller: [inserted] is what the store
     * actually wrote after its conflict key, so `offered - inserted` is how much the primary key already
     * absorbs — the third number needed to tell emission from ingest.
     *
     * TWO ratios are printed because [Result.ratio] alone can be read the wrong way round on a whole
     * SESSION. A session that drains a gap — the strap off the wrist, or on the charger — spans wall time
     * carrying no beats at all, which inflates the denominator and pulls `ratio` DOWN. That is the
     * dangerous direction of error: a diluted 0.9 reads as "emission is fine" on the one number this
     * instrumentation exists to answer. `ratioRep` divides by the seconds that actually REPORTED R-R
     * rather than by the wall span, so it is immune to gaps; the two agreeing means the batch is gapless,
     * and `ratioRep` is the one to trust when they disagree.
     */
    fun logLine(path: String, offered: Int, inserted: Int?, r: Result): String {
        val ratio = String.format(java.util.Locale.US, "%.2f", r.ratio)
        // NULL renders "n/a", never a number. Only the historical path can see what the store's conflict
        // key actually kept; the live paths census BEFORE the insert and have no such count. Echoing
        // `offered` there would print `offered=N inserted=N`, which reads as "the primary key absorbed
        // nothing" — a measurement neither path made. Same reason GpsSession passes rawFixes = null.
        val ins = inserted?.toString() ?: "n/a"
        val rep = if (r.secondsWithRr > 0) r.sumRrMs / 1000.0 / r.secondsWithRr else 0.0
        val h = r.perSecond
        return "rr emit path=$path offered=$offered inserted=$ins secs=${r.secondsWithRr} " +
            "sumRr=${r.sumRrMs / 1000}s span=${r.spanSec}s ratio=$ratio " +
            "ratioRep=${String.format(java.util.Locale.US, "%.2f", rep)} " +
            "perSec[1/2/3/4+]=${h[0]}/${h[1]}/${h[2]}/${h[3]} " +
            "modalGap=${r.modalGapSec}s " +
            "fill[<=1/<=1.5/<=2/>2]=${r.fill[0]}/${r.fill[1]}/${r.fill[2]}/${r.fill[3]}"
    }
}
