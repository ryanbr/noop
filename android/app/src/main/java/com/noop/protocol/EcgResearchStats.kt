package com.noop.protocol

/**
 * #891 / #1100: PURE, NON-DIAGNOSTIC protocol statistics over a captured MG ECG research session.
 *
 * Everything here is a shape/timing observation about bytes on a wire — packet rates, payload sizes,
 * zero-fill, which byte positions move between records. NOTHING here interprets a waveform, and the
 * vocabulary is deliberately neutral: a fast integer stream is a "candidate high-rate signal", never "the
 * ECG". Provenance of any waveform is a question for a human reading the raw bytes, not a statistic.
 *
 * Pure (no Android, no I/O, no clock): every input is passed in, so the whole file is unit-tested without a
 * strap. Consumed by [EcgResearchLog] to build `stats.json` for the export bundle.
 */
object EcgResearchStats {

    /** One inbound frame as the stats see it. [payload] is the on-wire bytes; [packetType] is the decoded
     *  type byte when the framing parser named one, else null; [recognized] is whether the parser mapped it. */
    data class RxRecord(
        val monotonicMs: Long,
        val characteristic: String,
        val payload: ByteArray,
        val packetType: Int?,
        val recognized: Boolean,
    ) {
        val size: Int get() = payload.size

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is RxRecord) return false
            return monotonicMs == other.monotonicMs && characteristic == other.characteristic &&
                packetType == other.packetType && recognized == other.recognized &&
                payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var h = monotonicMs.hashCode()
            h = 31 * h + characteristic.hashCode(); h = 31 * h + (packetType ?: -1)
            h = 31 * h + recognized.hashCode(); h = 31 * h + payload.contentHashCode()
            return h
        }
    }

    /** Fraction (0..1) of bytes in [payload] between [from], inclusive, and [to], exclusive, that are 0x00.
     *  An out-of-range or empty window returns 0.0. */
    fun zeroByteFraction(payload: ByteArray, from: Int = 0, to: Int = payload.size): Double {
        val lo = from.coerceIn(0, payload.size)
        val hi = to.coerceIn(lo, payload.size)
        if (hi <= lo) return 0.0
        var zeros = 0
        for (i in lo until hi) if (payload[i].toInt() == 0) zeros++
        return zeros.toDouble() / (hi - lo)
    }

    /** True when every byte in [payload] over [from, to) is 0x00 (a genuinely empty region — the "is the
     *  big raw area all zeros?" question #891 asks of large records). Empty window is NOT all-zero. */
    fun isAllZero(payload: ByteArray, from: Int = 0, to: Int = payload.size): Boolean {
        val lo = from.coerceIn(0, payload.size)
        val hi = to.coerceIn(lo, payload.size)
        if (hi <= lo) return false
        for (i in lo until hi) if (payload[i].toInt() != 0) return false
        return true
    }

    /** Byte positions where [a] and [b] differ (shared prefix only). A SEQUENCE-COUNTER hunt: a field that
     *  changes between consecutive same-shape records is a counter/timestamp candidate. */
    fun changingBytePositions(a: ByteArray, b: ByteArray): List<Int> {
        val n = minOf(a.size, b.size)
        val out = ArrayList<Int>()
        for (i in 0 until n) if (a[i] != b[i]) out.add(i)
        return out
    }

    /** Union of positions that EVER change across a run of same-length records (the counter/timestamp map). */
    fun changingPositionsAcross(records: List<ByteArray>): List<Int> {
        if (records.size < 2) return emptyList()
        val changing = sortedSetOf<Int>()
        for (i in 1 until records.size) changing.addAll(changingBytePositions(records[i - 1], records[i]))
        return changing.toList()
    }

    /** packets/sec per characteristic across the whole window (count ÷ span seconds; a single packet or a
     *  zero span reports the raw count as a per-second rate so the number is never divided by zero). */
    fun packetsPerSecondByCharacteristic(records: List<RxRecord>): Map<String, Double> {
        val byChar = records.groupBy { it.characteristic }
        return byChar.mapValues { (_, rs) ->
            if (rs.size < 2) rs.size.toDouble()
            else {
                val span = (rs.maxOf { it.monotonicMs } - rs.minOf { it.monotonicMs }).coerceAtLeast(1)
                rs.size.toDouble() * 1000.0 / span
            }
        }
    }

    /** Payload-size histogram: exact size in bytes → how many records had it. */
    fun payloadSizeHistogram(records: List<RxRecord>): Map<Int, Int> {
        val h = HashMap<Int, Int>()
        for (r in records) h[r.size] = (h[r.size] ?: 0) + 1
        return h.toSortedMap()
    }

    /** The [n] largest distinct payload sizes seen, descending. */
    fun largestPayloadSizes(records: List<RxRecord>, n: Int = 5): List<Int> =
        records.map { it.size }.distinct().sortedDescending().take(n)

    /** Count of records whose payload is exactly [size] bytes — e.g. the repeated 1,584-byte record #891
     *  flags as a candidate raw block. */
    fun countOfSize(records: List<RxRecord>, size: Int): Int = records.count { it.size == size }

    /** Packet-type census: decoded type byte (or null for unrecognised) → count. */
    fun packetTypeCounts(records: List<RxRecord>): Map<Int?, Int> {
        val h = LinkedHashMap<Int?, Int>()
        for (r in records) h[r.packetType] = (h[r.packetType] ?: 0) + 1
        return h
    }

    /** How many records the framing parser did NOT recognise — the unknown/rejected tally (Phase 6/7). */
    fun unrecognizedCount(records: List<RxRecord>): Int = records.count { !it.recognized }

    /**
     * Packet types present only AFTER a boundary time [afterMs] (candidate "appeared after Start") and those
     * present only BEFORE it (candidate "disappeared after Stop"). Type identity is the decoded type byte;
     * null (unrecognised) is folded in as its own bucket. Purely descriptive — never asserts causation.
     */
    data class TypeDelta(val appearedAfter: List<Int?>, val disappearedAfter: List<Int?>)

    fun typeDeltaAround(records: List<RxRecord>, afterMs: Long): TypeDelta {
        val before = records.filter { it.monotonicMs < afterMs }.map { it.packetType }.toSet()
        val after = records.filter { it.monotonicMs >= afterMs }.map { it.packetType }.toSet()
        return TypeDelta(
            appearedAfter = (after - before).toList(),
            disappearedAfter = (before - after).toList(),
        )
    }

    /** Largest zero-byte fraction over any record at least [minSize] bytes — surfaces the "large records are
     *  mostly padding" observation. Returns null when no record is that big. */
    fun maxZeroFractionOfLargeRecords(records: List<RxRecord>, minSize: Int = 64): Double? {
        val big = records.filter { it.size >= minSize }
        if (big.isEmpty()) return null
        return big.maxOf { zeroByteFraction(it.payload) }
    }

    /**
     * Estimate beats-per-minute from a waveform by normalised autocorrelation — NON-DIAGNOSTIC, and
     * deliberately willing to return null.
     *
     * ## The trap this is written around (#194)
     *
     * The strap's raw records carry a FIXED sample count ([Whoop5Ecg.SAMPLES_PER_RAW_RECORD] = 101). Anything
     * that repeats per record — a constant sub-header, a re-sent block, a seam where two records join — is
     * periodic at the record period, and at 100 Hz that period is 1.01 s == 59.4 bpm: inside this search band
     * and inside resting heart-rate range. An autocorrelation fed a concatenated record stream will therefore
     * report a confident ~59 bpm out of pure framing, with no cardiac content at all. That is the exact
     * failure mode behind NOOP's withdrawn PPG->HR estimate, so when [excludeLag] is supplied:
     *
     *  1. lags within [excludeLagTolerance] of it cannot win, and
     *  2. the winner must also beat the strength AT the artefact lag ([artefactDominance]). Step 1 alone is
     *     not enough — a broad peak centred on the artefact lag still has strong shoulders just outside the
     *     notch, so a notch by itself just reports the artefact as a slightly different number.
     *
     * The cost is stated rather than hidden: a genuine heart rate that lands in that narrow band is
     * indistinguishable from the artefact and is therefore DECLINED. Null means "this method cannot tell",
     * never "no rhythm".
     *
     * ## Two things that made an earlier version wrong
     *
     * - **Comparability across lags.** A raw lag product sums over `n - lag` terms, so longer lags accumulate
     *   fewer terms and score lower for arithmetic rather than physiological reasons. Each lag is scored as a
     *   true normalised cross-correlation over its own overlap, so lags are comparable and [minStrength]
     *   means the same thing everywhere.
     * - **Octave errors.** A periodic signal correlates just as well at twice its period, and with a
     *   non-integer number of cycles the double-period lag can score marginally higher — reporting 55 bpm for
     *   a 110 bpm input. So the winner is the SHORTEST lag within [octaveTolerance] of the best score, not
     *   the argmax.
     */
    fun estimateBpm(
        samples: IntArray,
        fs: Int = 100,
        minBpm: Int = 40,
        maxBpm: Int = 180,
        minStrength: Double = 0.3,
        excludeLag: Int? = null,
        excludeLagTolerance: Int = 2,
        octaveTolerance: Double = 0.85,
        artefactDominance: Double = 1.0,
    ): Int? {
        if (fs <= 0 || samples.size < fs) return null   // need at least ~1 second
        val n = samples.size
        val mean = samples.average()
        val c = DoubleArray(n) { samples[it] - mean }
        var e0 = 0.0
        for (v in c) e0 += v * v
        if (e0 <= 0.0) return null                      // a flat trace has no period to find
        val loLag = (60.0 * fs / maxBpm).toInt().coerceAtLeast(1)
        val hiLag = (60.0 * fs / minBpm).toInt().coerceAtMost(n - 1)
        if (hiLag <= loLag) return null

        /** True normalised cross-correlation of the series against itself at [lag], over their overlap. */
        fun ncc(lag: Int): Double {
            val overlap = n - lag
            if (overlap <= 1) return 0.0
            var num = 0.0
            var eA = 0.0
            var eB = 0.0
            for (i in 0 until overlap) {
                val a = c[i]
                val b = c[i + lag]
                num += a * b
                eA += a * a
                eB += b * b
            }
            if (eA <= 0.0 || eB <= 0.0) return 0.0
            return num / kotlin.math.sqrt(eA * eB)
        }

        fun notched(lag: Int) = excludeLag != null && kotlin.math.abs(lag - excludeLag) <= excludeLagTolerance

        val strength = DoubleArray(hiLag + 1)
        var best = Double.NEGATIVE_INFINITY
        for (lag in loLag..hiLag) {
            strength[lag] = ncc(lag)
            if (!notched(lag) && strength[lag] > best) best = strength[lag]
        }
        if (best < minStrength) return null

        // Step 2 of the artefact guard: if the record period itself correlates at least as well as the best
        // candidate outside the notch, the candidate is that peak's shoulder and not an independent rhythm.
        if (excludeLag != null) {
            var artefact = Double.NEGATIVE_INFINITY
            for (lag in loLag..hiLag) if (notched(lag) && strength[lag] > artefact) artefact = strength[lag]
            if (artefact != Double.NEGATIVE_INFINITY && best < artefact * artefactDominance) return null
        }

        // Octave correction, over PEAKS only. Taking the shortest lag that merely clears the threshold picks
        // a point on the rising shoulder of the real peak instead of the peak: a 45 bpm input (lag 133) has
        // correlation 0.86 at lag 122, which cleared the floor and reported 49 bpm. A candidate must be a
        // local maximum, and then the shortest such peak is the fundamental rather than a sub-harmonic.
        val floor = best * octaveTolerance
        for (lag in loLag..hiLag) {
            if (notched(lag) || strength[lag] < floor) continue
            val risingInto = lag == loLag || strength[lag] >= strength[lag - 1]
            val fallingAfter = lag == hiLag || strength[lag] >= strength[lag + 1]
            if (risingInto && fallingAfter) return (60.0 * fs / lag).toInt()
        }
        return null
    }
}
