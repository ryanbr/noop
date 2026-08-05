package com.noop.analytics

import com.noop.data.RrInterval
import kotlin.math.abs
import kotlin.math.sqrt

/*
 * HrvAnalyzer.kt — RMSSD + SDNN from RR intervals with cleaning.
 *
 * Faithful Kotlin port of StrandAnalytics/HRVAnalyzer.swift (verified on macOS).
 * The Task Force (1996) RMSSD and SDNN definitions are reproduced exactly:
 *
 *   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )           (Task Force 1996)
 *   SDNN  = sample standard deviation of NN (ddof = 1)     (Task Force 1996)
 *
 * Cleaning pipeline:
 *   1. Range filter: drop intervals outside [RR_MIN_MS, RR_MAX_MS] = [300, 2000] ms.
 *   2. Ectopic rejection: drop beats whose RR deviates > ~20% from a local median
 *      (Malik-style filter).
 *   3. Require >= MIN_BEATS (20) valid intervals before a trustworthy result.
 *
 * Gap-aware successive differences: cleaning DROPS beats, which makes two beats that were not
 * adjacent in the source become neighbours in the cleaned list. A successive-difference metric
 * (RMSSD, pNN50) must NOT count the difference across such a splice, or one removed beat injects a
 * spurious large delta that dominates the mean. [cleanRRGapAware] cleans while remembering where beats
 * were dropped, and [rmssdGapAware] / [pnn50GapAware] skip any difference that straddles a gap. On a
 * series with no drops these are identical to the plain versions, so clean data is unchanged. Kept in
 * lockstep with the Swift twin `StrandAnalytics/HRVAnalyzer.cleanRRGapAware` / `rmssdGapAware` /
 * `pnn50GapAware` (ported alongside; both platforms are gap-aware).
 *
 * Named [HrvAnalyzer] (NOT Hrv) to avoid clashing with the existing
 * com.noop.analytics.Hrv object in Analytics.kt. The two compute RMSSD the same
 * way (sqrt of mean successive squared diffs); HrvAnalyzer additionally cleans
 * the RR series and reports SDNN / meanNN / pNN50.
 */
object HrvAnalyzer {

    /** Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm. */
    const val RR_MIN_MS: Double = 300.0

    /** Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm. */
    const val RR_MAX_MS: Double = 2000.0

    /** Minimum valid intervals required for a trustworthy RMSSD/SDNN. */
    const val MIN_BEATS: Int = 20

    /**
     * Malik-style ectopic threshold: a beat deviating more than this fraction
     * from the local median is rejected. 0.20 == 20%.
     */
    const val ECTOPIC_THRESHOLD: Double = 0.20

    /**
     * Half-width (in beats) of the local-median window used for ectopic rejection.
     * A window of 2*radius+1 beats (5 beats at radius 2) matches the common Malik
     * moving-window implementations.
     */
    const val ECTOPIC_WINDOW_RADIUS: Int = 2

    /**
     * Default ceiling on the fraction of input beats the cleaning pipeline may reject before a SPOT
     * reading is refused as too noisy (#585). Spot-only: passed by the on-demand callers, never by the
     * nightly windowed path. 0.35 == refuse once more than 35% of beats were dropped as out-of-range or
     * ectopic, even if [MIN_BEATS] clean intervals survive — a quiet honesty gate on a short live capture.
     */
    const val DEFAULT_SPOT_MAX_REJECTED_FRACTION: Double = 0.35

    /** Result of an HRV computation over a window. Mirrors Swift `HRVResult`. */
    data class HrvResult(
        /** RMSSD in milliseconds, or null when too few valid beats. */
        val rmssd: Double?,
        /** SDNN (sample SD, ddof=1) in milliseconds, or null when too few valid beats. */
        val sdnn: Double?,
        /** Mean NN interval (ms) over the cleaned beats, or null. */
        val meanNN: Double?,
        /** pNN50: % of successive |ΔNN| > 50 ms, or null. */
        val pnn50: Double?,
        /** Count of RR intervals supplied to the analysis (before cleaning). */
        val nInput: Int,
        /** Count of clean NN intervals after range + ectopic filtering. */
        val nClean: Int,
    ) {
        companion object {
            /** An empty/insufficient-data result that preserves the input count. */
            fun empty(nInput: Int): HrvResult =
                HrvResult(rmssd = null, sdnn = null, meanNN = null, pnn50 = null,
                    nInput = nInput, nClean = 0)
        }
    }

    // ── Primitive Task Force statistics (no filtering) ───────────────────────

    /**
     * Task Force (1996) RMSSD over already-clean NN intervals (ms). Returns null
     * when fewer than 2 values (no successive differences). No filtering applied.
     */
    fun rmssdRaw(nn: List<Double>): Double? {
        if (nn.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until nn.size) {
            val d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return sqrt(sumSq / (nn.size - 1).toDouble())
    }

    /**
     * Sample standard deviation (ddof = 1) of NN intervals (ms). Returns null for
     * fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
     */
    fun sdnnRaw(nn: List<Double>): Double? {
        if (nn.size < 2) return null
        val mean = nn.sum() / nn.size.toDouble()
        var ss = 0.0
        for (v in nn) {
            val d = v - mean
            ss += d * d
        }
        return sqrt(ss / (nn.size - 1).toDouble())
    }

    // ── Cleaning ─────────────────────────────────────────────────────────────

    /** Range filter: keep only intervals in [RR_MIN_MS, RR_MAX_MS], preserving order. */
    fun rangeFilter(rr: List<Double>): List<Double> =
        rr.filter { it >= RR_MIN_MS && it <= RR_MAX_MS }

    /**
     * Malik-style ectopic rejection: drop any beat that deviates from its local
     * median by more than [ECTOPIC_THRESHOLD] (20%). The local median is taken
     * over a centered window of `2*ECTOPIC_WINDOW_RADIUS+1` beats (excluding the
     * beat under test). Beats with too small a neighbourhood are kept.
     */
    fun rejectEctopic(nn: List<Double>): List<Double> {
        if (nn.size <= ECTOPIC_WINDOW_RADIUS) return nn
        val kept = ArrayList<Double>(nn.size)
        for (i in nn.indices) {
            val lo = maxOf(0, i - ECTOPIC_WINDOW_RADIUS)
            val hi = minOf(nn.size - 1, i + ECTOPIC_WINDOW_RADIUS)
            val neighbours = ArrayList<Double>(hi - lo)
            for (j in lo..hi) {
                if (j != i) neighbours.add(nn[j])
            }
            if (neighbours.size < 2) {
                kept.add(nn[i])
                continue
            }
            val med = median(neighbours)
            if (med <= 0) {
                kept.add(nn[i])
                continue
            }
            val deviation = abs(nn[i] - med) / med
            if (deviation <= ECTOPIC_THRESHOLD) {
                kept.add(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /** Full clean: range filter → ectopic rejection. Returns the clean NN series. */
    fun cleanRR(rr: List<Double>): List<Double> = rejectEctopic(rangeFilter(rr))

    // ── Gap-aware cleaning (successive-difference safety) ─────────────────────

    /**
     * A cleaned NN series that remembers where beats were dropped. [nn] is byte-identical to [cleanRR]
     * over the same input. [contiguous] has the same length: `contiguous[i]` is true when `nn[i]` and
     * `nn[i - 1]` were adjacent beats in the ORIGINAL series (no beat removed between them by the range
     * or ectopic filter) and false when a beat was dropped in between (a splice). Index 0 is always
     * false: the first beat has no predecessor.
     */
    data class CleanSeries(val nn: List<Double>, val contiguous: List<Boolean>)

    /**
     * Clean the RR series (range filter then Malik ectopic rejection, exactly like [cleanRR]) while
     * tracking which original beats were dropped, so a downstream successive-difference metric can skip
     * the difference across a removed beat. [CleanSeries.nn] equals [cleanRR] value for value.
     */
    fun cleanRRGapAware(rr: List<Double>): CleanSeries {
        // Pass 1: range filter, keeping each survivor's index in the ORIGINAL series.
        val rangedIdx = ArrayList<Int>(rr.size)
        val rangedVal = ArrayList<Double>(rr.size)
        for (i in rr.indices) {
            val v = rr[i]
            if (v >= RR_MIN_MS && v <= RR_MAX_MS) { rangedIdx.add(i); rangedVal.add(v) }
        }
        // Pass 2: Malik ectopic rejection over the range-filtered values, mirroring [rejectEctopic]
        // (same windows, same median, same threshold) so the kept values match cleanRR exactly, while
        // carrying each survivor's original index forward.
        val keptOrig = ArrayList<Int>(rangedVal.size)
        val keptVal = ArrayList<Double>(rangedVal.size)
        if (rangedVal.size <= ECTOPIC_WINDOW_RADIUS) {
            // rejectEctopic returns the input unchanged for a series this short.
            for (k in rangedVal.indices) { keptOrig.add(rangedIdx[k]); keptVal.add(rangedVal[k]) }
        } else {
            for (i in rangedVal.indices) {
                val lo = maxOf(0, i - ECTOPIC_WINDOW_RADIUS)
                val hi = minOf(rangedVal.size - 1, i + ECTOPIC_WINDOW_RADIUS)
                val neighbours = ArrayList<Double>(hi - lo)
                for (j in lo..hi) if (j != i) neighbours.add(rangedVal[j])
                val keep = when {
                    neighbours.size < 2 -> true
                    else -> {
                        val med = median(neighbours)
                        if (med <= 0) true else abs(rangedVal[i] - med) / med <= ECTOPIC_THRESHOLD
                    }
                }
                if (keep) { keptOrig.add(rangedIdx[i]); keptVal.add(rangedVal[i]) }
            }
        }
        // A survivor is contiguous with its predecessor only when their ORIGINAL indices are adjacent.
        val contiguous = ArrayList<Boolean>(keptVal.size)
        for (i in keptVal.indices) contiguous.add(i > 0 && keptOrig[i] == keptOrig[i - 1] + 1)
        return CleanSeries(keptVal, contiguous)
    }

    /**
     * Task Force RMSSD that counts a successive difference only when the two beats were adjacent in the
     * source ([CleanSeries.contiguous]). A difference spanning a dropped beat is skipped, so removing an
     * out-of-range or ectopic beat cannot splice its neighbours into a spurious delta. Identical to
     * [rmssdRaw] when there are no gaps. Returns null when no valid successive difference exists.
     */
    fun rmssdGapAware(nn: List<Double>, contiguous: List<Boolean>): Double? {
        require(nn.size == contiguous.size) { "nn and contiguous must be the same length" }
        var sumSq = 0.0
        var count = 0
        for (i in 1 until nn.size) {
            if (!contiguous[i]) continue
            val d = nn[i] - nn[i - 1]
            sumSq += d * d
            count += 1
        }
        return if (count < 1) null else sqrt(sumSq / count.toDouble())
    }

    /**
     * pNN50 (% of successive |ΔNN| > 50 ms) counting only gap-free pairs, mirroring [rmssdGapAware].
     * Identical to the plain pNN50 when there are no gaps. Returns null when no valid pair exists.
     */
    fun pnn50GapAware(nn: List<Double>, contiguous: List<Boolean>): Double? {
        require(nn.size == contiguous.size) { "nn and contiguous must be the same length" }
        var nn50 = 0
        var pairs = 0
        for (i in 1 until nn.size) {
            if (!contiguous[i]) continue
            if (abs(nn[i] - nn[i - 1]) > 50.0) nn50 += 1
            pairs += 1
        }
        return if (pairs < 1) null else nn50.toDouble() / pairs.toDouble() * 100.0
    }

    // ── Windowed analysis ────────────────────────────────────────────────────

    /**
     * Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
     * in [windowStart, windowEnd] (inclusive). Pass null bounds to use all rows.
     *
     * Applies the range filter, Malik ectopic rejection, then requires [MIN_BEATS]
     * clean intervals; otherwise returns an empty result.
     *
     * Window bounds are unix SECONDS (Long), matching the com.noop.data layer.
     */
    fun analyze(rr: List<RrInterval>, windowStart: Long? = null, windowEnd: Long? = null): HrvResult {
        val inWindow = rr.filter { sample ->
            if (windowStart != null && sample.ts < windowStart) return@filter false
            if (windowEnd != null && sample.ts > windowEnd) return@filter false
            true
        }
        val raw = inWindow.map { it.rrMs.toDouble() }
        return analyzeRaw(raw)
    }

    /**
     * Compute HRV from raw RR-interval values (ms), applying the full cleaning
     * pipeline. Returns an empty result when fewer than [MIN_BEATS] survive.
     *
     * @param maxRejectedFraction SPOT-ONLY honesty gate (#585). When non-null, the reading is ALSO refused
     *   (empty result) if the fraction of input beats dropped by cleaning exceeds this value — even when
     *   [MIN_BEATS] clean intervals survive — because a short live capture that threw away most of its
     *   beats is too noisy to trust. null (the default, and what the NIGHTLY windowed path passes) skips
     *   the gate entirely, so the nightly RMSSD is byte-identical to before this parameter existed.
     */
    fun analyzeRaw(rawRR: List<Double>, maxRejectedFraction: Double? = null): HrvResult {
        val nInput = rawRR.size
        val cleaned = cleanRRGapAware(rawRR)
        val clean = cleaned.nn
        if (clean.size < MIN_BEATS) {
            return HrvResult.empty(nInput)
        }
        // Spot-only: refuse when too large a fraction of beats was noise (out-of-range or ectopic). Only
        // applied when a ceiling is supplied; nInput > 0 holds implicitly (clean.size ≥ MIN_BEATS > 0).
        if (maxRejectedFraction != null && nInput > 0) {
            val rejectedFraction = 1.0 - clean.size.toDouble() / nInput.toDouble()
            if (rejectedFraction > maxRejectedFraction) {
                return HrvResult.empty(nInput)
            }
        }
        // RMSSD and pNN50 are gap-aware: a successive difference across a dropped beat is skipped so a
        // removed out-of-range/ectopic beat cannot splice its neighbours into a spurious delta. SDNN and
        // meanNN use every clean beat (no successive differences), so they are unchanged.
        val rmssd = rmssdGapAware(cleaned.nn, cleaned.contiguous)
        val sdnn = sdnnRaw(clean)
        val mean = clean.sum() / clean.size.toDouble()
        val pnn50 = pnn50GapAware(cleaned.nn, cleaned.contiguous)

        return HrvResult(rmssd = rmssd, sdnn = sdnn, meanNN = mean, pnn50 = pnn50,
            nInput = nInput, nClean = clean.size)
    }

    /**
     * What a night's R-R coverage pair says about the capture (#550).
     *
     * [rrCoverage] above 1.0 is physically impossible, and [collapsedCoverage] previews what a
     * same-second de-dup would leave. Reading the two together is what tells you WHICH over-count you
     * have — a rule that until now lived only in a comment, so anyone triaging an "HRV reads ~2x high"
     * report had to know it. Encoding it means the log states the conclusion instead of the evidence.
     * Byte-parity twin of Swift `HRVAnalyzer.RrCoverageVerdict`.
     */
    enum class RrCoverageVerdict(val raw: String) {
        /** At or near 1.0 — the beat-time fits the wall clock. Nothing to explain. */
        PLAUSIBLE("plausible"),
        /** Materially BELOW 1.0: beat-time is missing from the window. Not a clean night, and not an
         *  over-count either — the analysis window silently is not the window it appears to be, because
         *  beats that never arrived cannot be distinguished from beats that were never there. Same
         *  principle as [UNMEASURABLE] below: claiming a capture was fine when a seventh of it is absent
         *  is the opposite of what this verdict exists to do. (#977) */
        UNDER_COVERED("underCovered"),
        /** Over-covered, but collapsing same-second duplicates brings it back in range: the extra beats
         *  share a timestamp, so a de-dup at that granularity would fix it. */
        SAME_SECOND_OVER_COUNT("sameSecondOverCount"),
        /** Over-covered AND still over-covered after the same-second collapse: the duplicates straddle
         *  second boundaries, so a same-second de-dup would NOT be enough. */
        CROSS_SECOND_OVER_COUNT("crossSecondOverCount"),
        /** No usable coverage figure — [rrCoverage] returns 0.0 for < 2 beats or a zero span. Absence of
         *  evidence, NOT a clean night: reporting those as plausible would claim the capture was fine when
         *  nothing was measurable, which is the opposite of what this verdict exists to do. */
        UNMEASURABLE("unmeasurable"),
    }

    /** Tolerance above 1.0 treated as "fits". R-R timestamps are whole seconds while beats are not, so a
     *  clean night can round fractionally over. This is a ROUNDING allowance, deliberately not a tuned
     *  threshold — where the real boundary sits needs coverage figures from several wearers, which is the
     *  point of logging the verdict in the first place. Twin of Swift `coveragePlausibleCeiling`. */
    const val COVERAGE_PLAUSIBLE_CEILING: Double = 1.10

    /**
     * Tolerance BELOW 1.0 treated as "fits", the mirror of [COVERAGE_PLAUSIBLE_CEILING]. Same allowance,
     * same caveat: a ROUNDING allowance rather than a tuned threshold, because whole-second timestamps
     * under-report as easily as they over-report. Where the real boundary sits still needs coverage
     * figures from several wearers — IntelligenceEngine already logs `coverage` in the `hrv diag` line,
     * so that distribution can be gathered from traces that already exist. (#977)
     *
     * Deliberately symmetric rather than fitted: picking a number between the reported 0.859 and the
     * 0.89 of #803's capture would be choosing a threshold to match one corpus, which is what the
     * ceiling's own comment warns against.
     *
     * DERIVED rather than written as 0.90 so it cannot drift if the ceiling moves. IEEE-754 makes the
     * result 0.8999999999999999, not exactly 0.90, because 1.10 - 1.0 is not exactly 0.10 - harmless
     * (a night at exactly 0.90 is still above it) and identical on both platforms, since both fold the
     * same double arithmetic. Symmetry with the ceiling is the property worth keeping; the last bit is
     * not. Byte-parity twin of Swift `coveragePlausibleFloor`.
     */
    const val COVERAGE_PLAUSIBLE_FLOOR: Double = 1.0 - (COVERAGE_PLAUSIBLE_CEILING - 1.0)

    /**
     * Whether a window's BEAT-SPREAD statistics — SDNN, and anything derived from it — can be trusted,
     * given that window's coverage verdict. Pure. Byte-parity twin of Swift `beatSpreadIsTrustworthy`.
     *
     * SDNN is the standard deviation of EVERY NN interval in the window, so a capture that holds some
     * beats twice reports a spread no heart produced. It is not a subtle bias: measured on a ring whose
     * banked R-R covers 1.25x the wall-clock it spans, a sleeping night reads **197 ms** against a
     * 40-100 ms physiological range, and the app had no way to refuse the number — [classifyCoverage]
     * already knew the capture was over-counted, but nothing acted on it.
     *
     * Only the two OVER-COUNT verdicts gate. UNDER_COVERED and UNMEASURABLE stay trusted: neither
     * duplicates a beat. UNMEASURABLE in particular is what a LIVE spot reading looks like — beats
     * arriving in real time, carrying no timestamps to measure coverage with — and suppressing those
     * would refuse honest readings, the opposite of the point.
     *
     * Successive-difference statistics (RMSSD, pNN50) are deliberately NOT gated here. Their dominant
     * error on a banked stream was the lost within-second emission order (#823, root-caused in #1072),
     * which is fixed at the write path; whether they need a gate of their own is a question for a
     * post-fix capture to answer, not an assumption to bake in now.
     */
    fun beatSpreadIsTrustworthy(verdict: RrCoverageVerdict): Boolean = when (verdict) {
        RrCoverageVerdict.SAME_SECOND_OVER_COUNT, RrCoverageVerdict.CROSS_SECOND_OVER_COUNT -> false
        RrCoverageVerdict.PLAUSIBLE, RrCoverageVerdict.UNDER_COVERED,
        RrCoverageVerdict.UNMEASURABLE -> true
    }

    /** Classify a night from its coverage pair. Pure. Byte-parity twin of Swift `classifyCoverage`.
     *
     *  Both platforms use the NEGATED `>` form rather than `<=` so a non-finite input lands identically:
     *  every IEEE-754 comparison with NaN is false, so `<=` and `>` are not each other's inverse there and
     *  the twins would otherwise disagree. NaN falls to UNMEASURABLE on both. */
    fun classifyCoverage(coverage: Double, collapsed: Double): RrCoverageVerdict {
        if (!(coverage > 0.0)) return RrCoverageVerdict.UNMEASURABLE
        // #977: the floor is tested BEFORE the ceiling so the negated-`>` NaN convention above still
        // holds — a non-finite coverage has already left via UNMEASURABLE and cannot reach here.
        if (!(coverage >= COVERAGE_PLAUSIBLE_FLOOR)) return RrCoverageVerdict.UNDER_COVERED
        if (!(coverage > COVERAGE_PLAUSIBLE_CEILING)) return RrCoverageVerdict.PLAUSIBLE
        return if (collapsed > COVERAGE_PLAUSIBLE_CEILING) RrCoverageVerdict.CROSS_SECOND_OVER_COUNT
        else RrCoverageVerdict.SAME_SECOND_OVER_COUNT
    }

    /** #257: total heartbeat-time (sum of NN intervals, ms) ÷ wall-clock span of the R-R window (ms).
     *  A value > ~1.0 is physically impossible — you can't record more beat-time than elapsed time — so
     *  it directly flags DOUBLE-COUNTED / overlapping R-R (e.g. a live + historical merge storing the same
     *  beat under two timestamps, which inflates HRV and drags resting HR down, #257). Returns 0.0 for
     *  < 2 beats or a zero span. Byte-parity twin of Swift `HRVAnalyzer.rrCoverage`. */
    fun rrCoverage(tsSec: List<Long>, rrMs: List<Double>): Double {
        if (tsSec.size < 2 || rrMs.isEmpty()) return 0.0
        val hi = tsSec.maxOrNull() ?: return 0.0
        val lo = tsSec.minOrNull() ?: return 0.0
        val spanMs = (hi - lo) * 1000.0
        if (spanMs <= 0.0) return 0.0
        return rrMs.sum() / spanMs
    }

    /** #257: how many R-R rows are EXACT duplicates of another — same (ts, rrMs). Extra copies of one
     *  beat; `total − distinct(ts, rrMs)`. Points at the double-insert mechanism when [rrCoverage] > 1.
     *  Byte-parity twin of Swift `HRVAnalyzer.duplicateBeatCount`. */
    fun duplicateBeatCount(tsSec: List<Long>, rrMs: List<Double>): Int {
        val n = minOf(tsSec.size, rrMs.size)
        val seen = HashSet<Pair<Long, Double>>()
        var dups = 0
        for (i in 0 until n) if (!seen.add(tsSec[i] to rrMs[i])) dups++
        return dups
    }

    /** #550: coverage AFTER collapsing SAME-SECOND near-duplicate beats (equal ts AND |Δrr| ≤ [rrTolMs])
     *  to a single representative — a PREVIEW of what an R-R de-duplication fix would achieve, for the
     *  always-on #257 diag ONLY. It does NOT feed the shipped nightly HRV. On clean data (no same-second
     *  duplicates) it equals [rrCoverage]; when a live+historical merge double-stamps the same beat WITHIN
     *  one second, it falls toward ~1. If it stays well above 1, the duplication is CROSS-second (the two
     *  copies land in adjacent seconds), which a same-second collapse cannot catch — telling us the real
     *  fix must reconcile the two ingest paths rather than dedup within a second. The collapse is
     *  deliberately same-second-ONLY: R-R ts are stored at second resolution, and at rest genuine
     *  consecutive beats are ~1 s apart, so collapsing ACROSS a second would drop real beats. Deterministic
     *  (ts, rr, index) ordering. Byte-parity twin of Swift `HRVAnalyzer.collapsedCoverage`. */
    fun collapsedCoverage(tsSec: List<Long>, rrMs: List<Double>, rrTolMs: Double = 30.0): Double {
        val n = minOf(tsSec.size, rrMs.size)
        if (n < 2) return 0.0
        val order = (0 until n).sortedWith(compareBy({ tsSec[it] }, { rrMs[it] }, { it }))
        val keptTs = ArrayList<Long>(n)
        val keptRr = ArrayList<Double>(n)
        for (idx in order) {
            val t = tsSec[idx]
            val r = rrMs[idx]
            var dup = false
            var j = keptTs.size - 1
            while (j >= 0 && keptTs[j] == t) {      // inspect only beats already kept in the SAME second
                if (abs(keptRr[j] - r) <= rrTolMs) { dup = true; break }
                j--
            }
            if (!dup) { keptTs.add(t); keptRr.add(r) }
        }
        return rrCoverage(keptTs, keptRr)
    }

    // ── Rolling / windowed rMSSD (#803) ──────────────────────────────────────
    //
    // The Deep Timeline's "HRV" trace used to plot RAW RR-interval values (ms) and label them "HRV",
    // which is dishonest: an RR interval is NOT an HRV number, and the spikiness it shows is just the
    // beat-to-beat heart period, not variability. [rollingRmssd] is the pure, on-device twin of the
    // Swift HRVAnalyzer.rollingRmssd: it slides a [windowSec] window across the cleaned RR series and,
    // for each RR sample, emits the Task-Force rMSSD over the beats inside that trailing window. The
    // SAME Malik/range artifact filter the nightly path uses ([cleanRR]) is applied first, so an
    // ectopic beat or an out-of-range RR can't inflate the curve. The Deep Timeline plots THIS, relabelled
    // to honest windowed rMSSD. Pure: no clock, no IO. (#803)

    /** Default rolling-window width (seconds) for the Deep Timeline windowed rMSSD trace. ~5 min, the
     *  shortest span the Task Force calls a short-term recording, so the curve has enough beats to mean
     *  something without smoothing away the within-night swings. */
    const val DEFAULT_ROLLING_WINDOW_SEC: Int = 300

    /**
     * Rolling/windowed rMSSD over an RR series. For each input sample (ascending by ts), computes the
     * Task-Force rMSSD over the cleaned beats whose ts falls in the trailing window `(ts - windowSec, ts]`,
     * emitting `(ts, rmssd)` only when at least [minBeatsPerWindow] clean beats survive in that window (a
     * 2-beat window is one successive difference = a noisy spike, not HRV — matches the Swift twin's
     * minBeatsPerWindow gate). Range + Malik ectopic filtering ([cleanRR]) is applied to the WHOLE series
     * once, so artifacts never enter any window. Empty when fewer than [minBeatsPerWindow] input rows.
     * Pure, deterministic.
     *
     * @param rr the RR intervals (each carries a ts in unix SECONDS and rrMs); the Android twin of the
     *   Swift `[RRSample]`.
     * @param windowSec the trailing window width in seconds (defaults to [DEFAULT_ROLLING_WINDOW_SEC]).
     * @param stepSec emit at most one point per this many seconds of advance — a thinning stride so a 1 Hz
     *   RR stream does not emit a point per beat (and flood the chart). 0 (the default) emits at every
     *   qualifying window. Mirrors the Swift HRVAnalyzer.rollingRmssd `stepSec`.
     * @param minBeatsPerWindow minimum clean beats required inside a window before it emits (default 8,
     *   matching the Swift twin) — a smaller window is a noisy spike, not a trustworthy rMSSD.
     *
     * Android parity port of ryanbr's #1035 (minBeatsPerWindow gate) + #1036 (stepSec thinning stride).
     */
    fun rollingRmssd(
        rr: List<RrInterval>,
        windowSec: Int = DEFAULT_ROLLING_WINDOW_SEC,
        stepSec: Int = 0,
        minBeatsPerWindow: Int = 8,
    ): List<Pair<Long, Double>> {
        if (rr.size < minBeatsPerWindow || windowSec <= 0) return emptyList()
        // Ascending by ts so the trailing-window scan is monotone (the table read is already ordered, but
        // we don't assume it). Stable on equal ts.
        val sorted = rr.sortedBy { it.ts }
        // Clean the WHOLE series first (range + Malik ectopic), keeping each surviving beat's ts so a
        // window can be cut by timestamp. cleanRR works on the raw ms values; we re-pair to ts by walking
        // the same filters here so the kept ts/ms stay aligned (cleanRR drops items, losing the index map).
        val ranged = sorted.filter { it.rrMs.toDouble() in RR_MIN_MS..RR_MAX_MS }
        if (ranged.size < 2) return emptyList()
        val cleanMs = rejectEctopic(ranged.map { it.rrMs.toDouble() })
        // rejectEctopic preserves order and only drops items, so re-pair by walking both in lockstep: a
        // kept ms value corresponds to the next not-yet-consumed ranged beat with that value.
        val kept = ArrayList<RrInterval>(cleanMs.size)
        var ri = 0
        for (ms in cleanMs) {
            while (ri < ranged.size && ranged[ri].rrMs.toDouble() != ms) ri++
            if (ri < ranged.size) { kept.add(ranged[ri]); ri++ }
        }
        if (kept.size < 2) return emptyList()
        val window = windowSec.toLong()
        val out = ArrayList<Pair<Long, Double>>(kept.size)
        var lo = 0
        var lastEmitTs: Long? = null
        for (hi in kept.indices) {
            val tEnd = kept[hi].ts
            val tStart = tEnd - window
            // Advance the trailing edge so only beats with ts in (tStart, tEnd] remain.
            while (lo < hi && kept[lo].ts <= tStart) lo++
            // Thinning stride (#1036): skip emitting until at least [stepSec] has passed since the last
            // EMITTED point (measured against emits, not candidates), matching the Swift twin's stepSec branch.
            val last = lastEmitTs
            if (stepSec > 0 && last != null && tEnd - last < stepSec) continue
            val span = kept.subList(lo, hi + 1).map { it.rrMs.toDouble() }
            // A window with too few clean beats is a noisy spike, not a trustworthy rMSSD — require
            // [minBeatsPerWindow] survivors (#1035), matching the Swift HRVAnalyzer.rollingRmssd default (8).
            if (span.size < minBeatsPerWindow) continue
            val r = rmssdRaw(span) ?: continue
            out.add(tEnd to r)
            lastEmitTs = tEnd
        }
        return out
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Median of a non-empty array. (Caller guarantees non-empty.) Returns 0.0 for
     * an empty input, matching the Swift `n == 0 → 0` guard.
     *
     * Shared with SleepStager / AnalyticsEngine ports (Swift `HRVAnalyzer.median`).
     */
    fun median(values: List<Double>): Double {
        val s = values.sorted()
        val n = s.size
        if (n == 0) return 0.0
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
