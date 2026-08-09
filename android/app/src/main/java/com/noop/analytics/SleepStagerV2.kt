package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * SleepStagerV2.kt — the DEFAULT sleep-staging recipe. It became the default over the older percentile-band
 * stager [SleepStager] (V1) after a 44-subject cross-subject benchmark; V1 stays available behind the
 * PuffinExperiment flag.
 *
 * Byte-identical-logic Kotlin twin of StrandAnalytics/SleepStagerV2.swift, itself reimplemented clean from
 * @sunny-noop's contributor recipe (pre-fork PR #600 — NOT this repo's #600, which is an iOS
 * notification). We took only the per-session STAGING engine,
 * not the CLI runner the PR shipped with it. Session DETECTION (the in-bed [start, end] spans) still comes
 * entirely from V1 — this file only re-stages a window someone already decided is sleep, so it is a true
 * drop-in for [SleepStager.stageSession]: SAME signature, SAME List<StageSegment> return shape.
 *
 * HONEST HEDGING (same spirit as V1): these stages are APPROXIMATIONS, not PSG-validated, not medical
 * advice. The recipe first shipped with only its author's n=1 validation; it is now the default because a
 * 44-subject leave-one-subject-out benchmark (AAUWSS + Walch sleep-accel) showed it strictly dominates V1
 * (kappa 0.35 vs 0.03, deep recall 55% vs 1%). The per-epoch coefficients are still fixed a-priori from
 * sleep physiology + population base rates, not fit to labels.
 *
 * Recipe (per 30 s epoch, all coefficients fixed a-priori from sleep physiology + population base rates,
 * NOT fit to labels):
 *   1. per-night z-scored cardiorespiratory emissions (HR / HR-variability / movement);
 *   2. a per-night DEEP gate on the 11-min HR-flatness percentile (strongest deep-vs-light separator);
 *   3. a soft sleep-cycle prior (deep concentrated early as a fraction of the session; REM rising with
 *      that same fraction, minus a REM-latency guard that decays over the first 60 MINUTES after onset);
 *   4. a peak-motion (jerk) wake gate, thresholded RELATIVE to the night's own quiescent jerk floor — so it
 *      self-calibrates to the strap's gravity-decode scale and the wearer's fit, not a fixed g;
 *   5. an RR-RSA respiration-regularity term (regular breathing → deep, irregular → REM);
 *   6. Viterbi/HMM transition smoothing with a sticky transition matrix.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); math is done in Double throughout, matching
 * the Swift twin.
 */
object SleepStagerV2 {

    /**
     * Build a 30 s hypnogram for [start, end] with this recipe and return [StageSegment]s tiling the span.
     * DROP-IN: same signature + return type as [SleepStager.stageSession], so a caller can switch V1↔V2 on a
     * flag with no other change. [resp] (raw resp ADC) is accepted for signature-parity but not consumed —
     * respiration regularity is recovered from the R-R stream (RSA), the path available on both WHOOP 4 and
     * 5. The recipe stages "wake" naturally (no separate pre-onset / post-wake forcing).
     *
     * PERF (v7.0.2 / #707): this is a thin cache veneer over [stageSessionUncached]. The full recipe
     * (per-epoch z-scores + a band-limited DFT per epoch + a 4-state Viterbi over the whole night) is the
     * single heaviest thing the V2 path does, and it was being re-run for EVERY detected night on EVERY
     * [IntelligenceEngine.analyzeRecent] — i.e. ~21× per post-sync pass, AGAIN per sleep edit, and up to
     * thousands of nights on the one-shot full-history Effort rescore (maxDays=4000) — the traced cause of
     * the #707 OOM (Sleep V2 on). Staging is a pure function of (start, end, samples), so we memoize it via
     * the shared bounded [StagerCache] (keyed per recipe, so V1 and V2 never collide). The result: each
     * distinct night stages AT MOST ONCE, peak heap stays flat across repeated passes, and the
     * appearance/behaviour is byte-identical (the cached value is the same StageSegment list the recipe
     * produced — returned as a fresh copy so a caller that extends a segment in place can never poison the
     * cache). Edits invalidate naturally: a moved bed/wake time changes start/end → new key; newly-banked
     * samples change the per-stream count/edge-ts/checksum → new key. `resp` is excluded from the V2 key on
     * purpose — [stageSessionUncached] never consumes it (RSA comes from `rr`), so folding it in would only
     * cause false misses.
     */
    fun stageSession(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): List<StageSegment> {
        // PERF CLIP (v7.0.2 / #707): bound the grav/hr/rr streams to the only seconds any Epoch feature can
        // possibly READ before doing ANYTHING else — both the fingerprint and the compute then operate on the
        // clipped window, so neither walks the whole multi-day (~54 h / 200 k-sample) stream. `features()`
        // only ever reads seconds in [start − PAD_LO, end + PAD_HI): the farthest-reaching feature is the
        // 11-min HR-flatness std `stdOfSeconds(e − 330, e + 30 + 360)`, whose loop touches `e − 330` at the
        // low edge (smallest epoch start `e == firstE ≥ start` → ≥ start − 330) and `e + 389` at the high
        // edge (largest `e ≤ end − 1` → ≤ end + 388); the 5-min std (±150/180) and the RSA beat window
        // (e − 90 … e + 120) are strictly inside that. PAD_LO/PAD_HI add a full-epoch (30 s) safety margin
        // over those exact reaches, so EVERY second any feature consults is still present — samples outside
        // the window are allocated-but-never-read, so dropping them leaves every feature and the staging
        // output byte-identical (V1's SleepStager already clips equivalently via rowsBetween; this only
        // brings V2 in line, and also stops the cache fingerprint walking the full stream — a known
        // low-severity audit finding). Sort defensively first (same precondition stageSessionUncached
        // already establishes) so the binary-search bounds are correct even if a caller violates the
        // already-sorted-by-ts contract; the clip itself is a single O(log n) lower/upper-bound sublist, not
        // a linear filter.
        val gravC = clipSorted(grav.sortedBy { it.ts }, start - PAD_LO, end + PAD_HI) { it.ts }
        val hrC = clipSorted(hr.sortedBy { it.ts }, start - PAD_LO, end + PAD_HI) { it.ts }
        val rrC = clipSorted(rr.sortedBy { it.ts }, start - PAD_LO, end + PAD_HI) { it.ts }

        val key = StagerCache.fingerprint(StagerCache.Version.V2, start, end, gravC, hrC, rrC)
        StagerCache.get(key)?.let { return StagerCache.copyOf(it) }
        val segments = stageSessionUncached(start, end, gravC, hrC, rrC, resp)
        StagerCache.put(key, segments)
        return StagerCache.copyOf(segments)
    }

    /** Widest second-offset before `start` that any [features] window reads (11-min flatness low edge = 330),
     *  plus a 30 s epoch of safety margin. */
    private const val PAD_LO = 360L

    /** Widest second-offset after `end` that any [features] window reads (11-min flatness high edge ≈ 389),
     *  plus margin to a clean 420. The clip window is half-open [start − PAD_LO, end + PAD_HI). */
    private const val PAD_HI = 420L

    /**
     * Half-open [lo, hi) sublist of an ALREADY-ts-sorted [rows] via binary search on the `ts` key — O(log n)
     * to find each bound, then a view-backed [List.subList] (no element copy). Equivalent in result to a
     * `rows.filter { ts(it) in lo until hi }` but without the full linear scan, so the whole multi-day stream
     * is never traversed just to keep the night's window. Standard lower/upper bound: `loIdx` = first index
     * with `ts ≥ lo`, `hiIdx` = first index with `ts ≥ hi`.
     */
    private inline fun <T> clipSorted(rows: List<T>, lo: Long, hi: Long, ts: (T) -> Long): List<T> {
        if (rows.isEmpty()) return rows
        var a = 0; var b = rows.size                 // lower bound: first ts ≥ lo
        while (a < b) { val mid = (a + b) ushr 1; if (ts(rows[mid]) < lo) a = mid + 1 else b = mid }
        val loIdx = a
        var c = loIdx; var d = rows.size             // upper bound: first ts ≥ hi
        while (c < d) { val mid = (c + d) ushr 1; if (ts(rows[mid]) < hi) c = mid + 1 else d = mid }
        val hiIdx = c
        return if (loIdx == 0 && hiIdx == rows.size) rows else rows.subList(loIdx, hiIdx)
    }

    /** The pure recipe, exactly as before — extracted so [stageSession] can memoize it. */
    @Suppress("UNUSED_PARAMETER") // `resp` keeps this a drop-in for SleepStager.stageSession(…resp:) (parity)
    private fun stageSessionUncached(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): List<StageSegment> {
        // Sort defensively so the windowed features behave regardless of caller ordering.
        val gravS = grav.sortedBy { it.ts }
        val hrS = hr.sortedBy { it.ts }
        val rrS = rr.sortedBy { it.ts }

        val feats = features(start, end, gravS, hrS, rrS)
        if (feats.isEmpty()) return listOf(StageSegment(start = start, end = end, stage = "light"))
        val labels = stageEpochs(feats)

        // Tile [start, end] with one segment per staged epoch. The first segment back-fills [start, firstEpoch)
        // and the last extends to `end`. "awake" is renamed to the canonical "wake" used by V1 / StageSegment.
        val segments = ArrayList<StageSegment>()
        for ((i, f) in feats.withIndex()) {
            val stage = if (labels[i] == "awake") "wake" else labels[i]
            val segStart = if (i == 0) start else f.start
            val segEnd = if (i == feats.size - 1) end else feats[i + 1].start
            val last = segments.lastOrNull()
            if (last != null && last.stage == stage) {
                segments[segments.size - 1].end = segEnd
            } else {
                segments.add(StageSegment(start = segStart, end = segEnd, stage = stage))
            }
        }
        return segments
    }

    // ── Recipe constants (all fixed a-priori — NOT fit to labels) ────────────────────────────────────

    private val stageNames = listOf("deep", "rem", "light", "awake")

    /** Population sleep-architecture base rates as log-priors (adult TST ≈ light 50 / deep 18 / rem 22 /
     *  waso 10 %). Calibrates the boundary so light wins weak-evidence epochs. */
    private val baseLogPrior: Map<String, Double> = mapOf(
        "light" to ln(0.50), "deep" to ln(0.18), "rem" to ln(0.22), "awake" to ln(0.10))

    /** Deep is eligible only in the night's lowest ~25 % HR-flatness epochs (≈ deep base rate + margin).
     *  Widened 0.20 -> 0.25 by the multi-subject (AAUWSS + sleep-accel LOSO) deep-boundary tune, which
     *  recovers the deep recall the other deep-tightening edits shed while keeping precision up. */
    internal const val deepGateThresh = 0.25
    private const val deepGateSlope = 5.0

    /** Motion thresholds are RELATIVE to each night's own quiescent jerk floor (median per-second jerk over
     *  the session), NOT an absolute g — self-calibrates to the strap's gravity-decode scale + the fit. */
    private const val jerkFloorMoveMult = 38.0  // a per-second jerk counts as "moving" above floor × this
    private const val jerkFloorGateMult = 55.0  // wake-boost when an epoch's peak jerk exceeds floor × this
    private const val motionGateBoost = 2.0

    /**
     * Motion-corroborated wake (elevated-but-flat-HR nights, #462). An epoch is MOTION-QUIESCENT when it shows
     * no observed movement (`moveFrac == 0`) AND its peak per-second jerk sits at/below the night's own
     * quiescent floor × [jerkFloorGateMult] — i.e. the wrist did not move this epoch, on the same
     * night-relative scale the wake jerk-gate uses. On such epochs the AWAKE emission keeps any wake-SUPPRESSING
     * cardiac evidence (a low, flat HR) but discards the wake-PROMOTING half: a raised HR / HR-variability with
     * the wrist motionless is a supplement / fever / hot-room / alcohol artefact, not wakefulness, and must not
     * vote the epoch awake on its own. Never invents wake and never removes pro-sleep cardiac evidence, so a
     * genuinely still low-HR sleep epoch is byte-identical; only a still epoch whose ELEVATED HR was about to
     * push it awake is held. Motion (`zmvv`) and the jerk gate — which by construction cannot fire on a
     * quiescent epoch (`jerkMax ≤ floor × gateMult`) — still drive wake on any epoch that actually moved.
     * Internal so the predicate test can call it, matching the Swift `motionQuiescent` visibility.
     */
    internal fun motionQuiescent(f: Epoch): Boolean =
        f.moveFrac <= 0.0 && f.jerkMax <= f.jerkScale * jerkFloorGateMult

    /** Weight of the RSA respiration-regularity term (regular → deep, irregular → REM). */
    private const val respWeight = 0.6

    /** Transition matrix (rows = from, cols = to). Self-transitions dominate; deep↔rem rare; wake mostly
     *  to/from light. A priori, not fit.
     *
     *  The AWAKE row encodes sleep-onset physiology directly: a sleeper does not enter N3 or REM straight
     *  out of wakefulness — descent runs through N1/N2 — so wake→deep and wake→rem are ZERO rather than the
     *  small non-zero values they used to carry, and the freed mass goes to the wake self-loop, which makes
     *  a WASO episode span several epochs instead of flickering back to sleep after one. This row is the one
     *  part of PR #348's DREAMT re-tune that survives measurement on a de-contaminated reference set; the
     *  rest of that PR (its base priors, motion-gate multipliers, deep gate, awake dead-zone, emission
     *  coefficients and the deep/rem/light transition rows) was reverted by #437 and stays reverted, having
     *  measured neutral-to-negative here. See the header note on [viterbi] for why a zero is safe — and note
     *  that ZERO is a strong prior rather than a prohibition: the viterbi floor turns it into ≈ -20.7 against
     *  wake→light's ≈ -2.3, an ~18.4 log-unit penalty a sufficiently strong emission can still cross, so a
     *  genuine sleep-onset REM period stays representable instead of structurally impossible.
     *
     *  Measured on one wearer's 36 recorded nights, against the strap's own band `sleep_state` (an
     *  independent reference the recipe cannot contaminate — 21 nights, 15 554 epochs): sleep/wake kappa
     *  0.105 → 0.118 and wake sensitivity 16.0 % → 17.6 %, with the healthy-stratum wake fraction essentially
     *  unmoved (9.43 % → 9.96 %, i.e. no repeat of the #437 blow-out). Confirmed afterwards against
     *  human-scored PSG hypnograms (PhysioNet sleep-accel, 31 subjects / 26 773 epochs, #991): 4-class kappa
     *  0.356 → 0.363, REM F1 0.569 → 0.575, wake sensitivity 30.42 % → 30.84 %, and the #437 stage-fraction
     *  guard holds against truth as well. n = 1 wearer for the band figures; see `Tools/SleepBench` and the
     *  PR for the full ablation and its limits. */
    internal val transition: Map<String, Map<String, Double>> = mapOf(
        "deep" to mapOf("deep" to 0.86, "rem" to 0.007, "light" to 0.126, "awake" to 0.007),
        "rem" to mapOf("deep" to 0.005, "rem" to 0.88, "light" to 0.10, "awake" to 0.015),
        "light" to mapOf("deep" to 0.06, "rem" to 0.06, "light" to 0.85, "awake" to 0.03),
        "awake" to mapOf("deep" to 0.0, "rem" to 0.0, "light" to 0.10, "awake" to 0.90))

    /** One 30 s epoch's recipe features. Nullable means "no measurement"; the z-score / percentile treat a
     *  missing value as the neutral centre so a sparse channel never blocks a stage. Internal (not private) so
     *  the motion-corroborated-wake predicate test can construct one, matching the Swift `Epoch` visibility. */
    internal data class Epoch(
        val start: Long,        // epoch start (unix seconds, multiple of 30)
        val hr: Double?,        // epoch-mean HR (bpm)
        val hrVar: Double?,     // std of per-second HR over a centred 5-min window
        val hrFlat11: Double?,  // std of per-second HR over a centred 11-min window (deep/light separator)
        val moveFrac: Double,   // fraction of in-epoch per-second jerks above the night-relative move threshold
        val jerkMax: Double,    // peak in-epoch per-second jerk (g) — wake is bursty
        val respReg: Double?,   // RSA spectral peakedness in the 0.15–0.40 Hz band (breathing regularity)
        val clock: Double,      // time-of-night fraction in [0, 1]
        val jerkScale: Double,  // night quiescent jerk floor (median per-second jerk over the session)
        /** Elapsed MINUTES from the session window start to this epoch's centre — the minute-domain twin of
         *  [clock] (#930). [features] cannot know where sleep actually began, so it fills this relative to the
         *  window start; [stageEpochs] re-bases it onto the sleep onset its own first pass found, and falls
         *  back to this window-relative value when a night never sustains sleep. Only the REM-latency guard
         *  reads it — the deep term and the REM ramp stay fractions of the session, which is what they are. */
        val minutesSinceOnset: Double,
    )

    // ── Feature extraction ───────────────────────────────────────────────────────────────────────────

    /** Prefix-sum bundle over the integer-second HR axis (one O(1) windowed population std each).
     *  `axisLo` = first covered second; the three arrays are length (coveredSeconds + 1), index i holding the
     *  cumulative total over [axisLo, axisLo+i). Destructured by [features]. */
    private data class StdPrefix(
        val axisLo: Long, val sum: DoubleArray, val sumSq: DoubleArray, val cnt: IntArray,
    )

    /**
     * Build the per-epoch recipe features over a 30 s wall-clock-aligned grid covering [start, end].
     * Streams are clipped by [stageSession] to [start − PAD_LO, end + PAD_HI) — the only seconds these
     * windows ever read — so the 5-/11-min HR windows and the RSA beat window still see every second they
     * need; samples outside that window were never consulted, so the output is unchanged.
     */
    private fun features(
        start: Long, end: Long, grav: List<GravitySample>, hr: List<HrSample>, rr: List<RrInterval>,
    ): List<Epoch> {
        if (end <= start) return emptyList()
        val span = (end - start).coerceAtLeast(1L).toDouble()

        // Per-second aggregation (one value per integer second; mean when a second carries several samples).
        val hrSum = HashMap<Long, Double>(); val hrCnt = HashMap<Long, Int>()
        for (s in hr) { hrSum[s.ts] = (hrSum[s.ts] ?: 0.0) + s.bpm.toDouble(); hrCnt[s.ts] = (hrCnt[s.ts] ?: 0) + 1 }
        val secHR = HashMap<Long, Double>(hrSum.size)
        for ((k, v) in hrSum) secHR[k] = v / hrCnt[k]!!

        val gxSum = HashMap<Long, Double>(); val gySum = HashMap<Long, Double>()
        val gzSum = HashMap<Long, Double>(); val gCnt = HashMap<Long, Int>()
        for (g in grav) {
            gxSum[g.ts] = (gxSum[g.ts] ?: 0.0) + g.x; gySum[g.ts] = (gySum[g.ts] ?: 0.0) + g.y
            gzSum[g.ts] = (gzSum[g.ts] ?: 0.0) + g.z; gCnt[g.ts] = (gCnt[g.ts] ?: 0) + 1
        }
        val secG = HashMap<Long, Triple<Double, Double, Double>>(gCnt.size)
        for ((k, c) in gCnt) { val d = c.toDouble(); secG[k] = Triple(gxSum[k]!! / d, gySum[k]!! / d, gzSum[k]!! / d) }

        // R-R values bucketed by second (for the RSA respiration window).
        val rrBy = HashMap<Long, MutableList<Double>>()
        for (r in rr) rrBy.getOrPut(r.ts) { ArrayList() }.add(r.rrMs.toDouble())

        // PERF (v7.0.2 / #707): stdOfSeconds was called twice per epoch over centred ~300 s and ~720 s
        // windows, each call allocating a fresh boxed ArrayList<Double> and re-walking the window — O(epochs ×
        // windowSeconds) ≈ ~1,000,000 short-lived boxed Doubles per night, a primary heap-churn source under
        // the OOM. Replace it with ONE forward pass of prefix sums over the integer-second axis: cumulative
        // present-count, cumulative HR value, and cumulative HR value². Each window's population std is then
        // O(1): n = countΔ, mean = sumΔ/n, std = sqrt(max(0, sumSqΔ/n − mean²)). The under-root is clamped to
        // 0 only to absorb a tiny floating-point negative on a near-constant window (algebraically it is the
        // variance, never negative). Semantics are preserved exactly: still returns null when fewer than 2
        // present samples fall in the window. The axis spans only present HR seconds; a window edge beyond
        // the data clamps to the axis (those out-of-range seconds carried no sample in the old loop either).
        val (axisLo, sumPx, sumSqPx, cntPx) = run {
            if (secHR.isEmpty()) return@run StdPrefix(0L, DoubleArray(1), DoubleArray(1), IntArray(1))
            var lo = Long.MAX_VALUE; var hi = Long.MIN_VALUE
            for (k in secHR.keys) { if (k < lo) lo = k; if (k > hi) hi = k }
            val len = (hi - lo + 1).toInt()
            // Prefix arrays are length len+1: index i holds the cumulative total over the FIRST i seconds
            // [lo, lo+i), so a half-open window [qlo, qhi) is prefix[qhi-lo] − prefix[qlo-lo].
            val sP = DoubleArray(len + 1); val sqP = DoubleArray(len + 1); val cP = IntArray(len + 1)
            for (i in 0 until len) {
                val v = secHR[lo + i]
                sP[i + 1] = sP[i] + (v ?: 0.0)
                sqP[i + 1] = sqP[i] + (if (v != null) v * v else 0.0)
                cP[i + 1] = cP[i] + (if (v != null) 1 else 0)
            }
            StdPrefix(lo, sP, sqP, cP)
        }
        val axisHiExclusive = axisLo + (cntPx.size - 1)  // one past the last covered second

        fun stdOfSeconds(lo: Long, hi: Long): Double? {
            if (cntPx.size <= 1) return null
            // Clamp the query to the covered axis; out-of-range seconds held no sample in the old loop.
            val qLo = lo.coerceIn(axisLo, axisHiExclusive)
            val qHi = hi.coerceIn(axisLo, axisHiExclusive)
            if (qHi <= qLo) return null
            val a = (qLo - axisLo).toInt(); val b = (qHi - axisLo).toInt()
            val n = cntPx[b] - cntPx[a]
            if (n < 2) return null
            val sum = sumPx[b] - sumPx[a]
            val sumSq = sumSqPx[b] - sumSqPx[a]
            val mean = sum / n
            val variance = sumSq / n - mean * mean
            return sqrt(if (variance < 0.0) 0.0 else variance)
        }

        // PASS 1 — every per-epoch quantity EXCEPT the move fraction, and pool every per-second jerk so the
        // night's quiescent jerk floor (its median) can scale the motion thresholds.
        data class Raw(
            val start: Long, val hr: Double?, val hrVar: Double?, val hrFlat11: Double?,
            val jerks: List<Double>, val gapSec: Int, val jerkMax: Double, val respReg: Double?, val clock: Double,
            val minutes: Double,
        )
        val raws = ArrayList<Raw>()
        val allJerks = ArrayList<Double>()
        val firstE = ((start + 29) / 30) * 30
        var e = firstE
        while (e < end) {
            val hrs = ArrayList<Double>()
            val gseq = ArrayList<Triple<Double, Double, Double>>()
            var s = e
            while (s < e + 30) { secHR[s]?.let { hrs.add(it) }; secG[s]?.let { gseq.add(it) }; s++ }
            if (hrs.isEmpty() && gseq.isEmpty()) { e += 30; continue }   // no coverage → skip the epoch

            // Movement: consecutive per-second gravity jerks within the epoch.
            val jerks = ArrayList<Double>()
            var i = 1
            while (i < maxOf(1, gseq.size)) {
                val a = gseq[i - 1]; val b = gseq[i]
                val dx = a.first - b.first; val dy = a.second - b.second; val dz = a.third - b.third
                jerks.add(sqrt(dx * dx + dy * dy + dz * dz))
                i++
            }
            allJerks.addAll(jerks)
            val jerkMax = jerks.maxOrNull() ?: 0.0

            val hrMean = if (hrs.isEmpty()) null else hrs.sum() / hrs.size
            val hrVar = stdOfSeconds(e - 150, e + 30 + 150)     // 5-min centred window
            val hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360)  // 11-min centred window

            // RSA respiration over a wider beat window [e-90, e+120).
            val beats = ArrayList<Pair<Double, Double>>()
            var bs = e - 90
            while (bs < e + 120) {
                rrBy[bs]?.let { vs -> for (v in vs) beats.add(Pair(bs.toDouble(), v.coerceIn(300.0, 2000.0))) }
                bs++
            }
            beats.sortWith(compareBy({ it.first }, { it.second }))
            val respReg = respRegularity(beats)

            raws.add(Raw(
                start = e, hr = hrMean, hrVar = hrVar, hrFlat11 = hrFlat11,
                jerks = jerks, gapSec = maxOf(1, gseq.size - 1), jerkMax = jerkMax,
                respReg = respReg, clock = (e + 15 - start).toDouble() / span,
                minutes = (e + 15 - start).toDouble() / 60.0))
            e += 30
        }

        // Night quiescent jerk floor = median of all per-second jerks. Tiny epsilon when there's no motion
        // data so the move threshold collapses to ~0 rather than dividing by nothing.
        val jerkScale: Double = if (allJerks.isEmpty()) {
            1e-6
        } else {
            val sj = allJerks.sorted(); val n = sj.size
            if (n % 2 == 1) sj[n / 2] else 0.5 * (sj[n / 2 - 1] + sj[n / 2])
        }
        val moveThr = jerkScale * jerkFloorMoveMult

        // PASS 2 — move fraction against the night-relative threshold; carry the floor on each epoch.
        val feats = ArrayList<Epoch>(raws.size)
        for (r in raws) {
            val moves = r.jerks.count { it > moveThr }
            feats.add(Epoch(
                start = r.start, hr = r.hr, hrVar = r.hrVar, hrFlat11 = r.hrFlat11,
                moveFrac = moves.toDouble() / r.gapSec, jerkMax = r.jerkMax, respReg = r.respReg,
                clock = r.clock, jerkScale = jerkScale, minutesSinceOnset = r.minutes))
        }
        return feats
    }

    /**
     * RSA respiration regularity: tachogram → 4 Hz resample → detrend → power spectrum → peak/sum of the
     * 0.15–0.40 Hz (9–24 brpm) band. Returns spectral peakedness (higher = more regular breathing) or null
     * when there are too few beats. A direct band-limited DFT (only the ~50 in-band bins are needed).
     */
    private fun respRegularity(beats: List<Pair<Double, Double>>): Double? {
        if (beats.size < 12) return null
        val t0 = beats.first().first; val tN = beats.last().first
        if (tN <= t0) return null
        val n = ceil((tN - t0) / 0.25 - 1e-9).toInt()   // np.arange(t0, tN, 0.25) length
        if (n < 16) return null

        // Linear resample onto the uniform 4 Hz grid (clamped within [t0, tN]).
        val y = DoubleArray(n)
        var seg = 0
        for (i in 0 until n) {
            val t = t0 + 0.25 * i
            while (seg < beats.size - 2 && beats[seg + 1].first < t) seg++
            val ta = beats[seg].first; val tb = beats[seg + 1].first
            val va = beats[seg].second; val vb = beats[seg + 1].second
            y[i] = if (tb <= ta) va else va + ((t - ta) / (tb - ta)).coerceIn(0.0, 1.0) * (vb - va)
        }
        val mean = y.sum() / n
        for (i in 0 until n) y[i] -= mean

        // Band bins: f[k] = k / (n·0.25); keep 0.15 ≤ f ≤ 0.40.
        val kLo = ceil(0.15 * 0.25 * n).toInt()
        val kHi = floor(0.40 * 0.25 * n).toInt()
        if (kHi < kLo || kLo < 0) return null
        var maxP = 0.0; var sumP = 0.0
        for (k in kLo..kHi) {
            var re = 0.0; var im = 0.0
            val w = -2.0 * PI * k / n
            for (j in 0 until n) { val a = w * j; re += y[j] * cos(a); im += y[j] * sin(a) }
            val p = re * re + im * im
            sumP += p
            if (p > maxP) maxP = p
        }
        if (sumP == 0.0) return null
        return maxP / sumP
    }

    // ── Recipe staging ────────────────────────────────────────────────────────────────────────────────

    // ── the REM-latency guard (#930) ──────────────────────────────────────────────────────────────────

    /** Log-odds penalty applied to the REM emission AT sleep onset. Unchanged in magnitude from the
     *  `c < 0.12 ? 3.0 : 0.0` step this replaced: e⁻³ ≈ 0.05 on the REM emission — strong suppression that
     *  sufficient evidence still overcomes, never a veto. Kept at the incumbent value deliberately, because
     *  the sleep-accel grid ({cliff, graded} × {fraction, minutes} × K ∈ 1…8 × threshold, 210 cells) showed
     *  every cell tying on accuracy, so nothing in the data discriminates K — and the smallest correct change
     *  is to fix the UNITS and the SHAPE without also retuning a magnitude no measurement can justify.
     *  Internal so the parity test can pin it, matching the Swift `remLatencyPenalty` visibility. */
    internal const val remLatencyPenalty = 3.0

    /** Minutes over which [remLatencyPenalty] decays linearly to zero, measured from sleep ONSET.
     *  Against PSG truth on sleep-accel (n = 31 subjects), a guard reaching 45 min costs 0.36 % of all real
     *  REM (1 subject affected) and one reaching 90 min costs 6.85 % (15 subjects); 60 min sits inside that
     *  band, and because the penalty is GRADED rather than a cliff it is already down to ≤ 0.75 log-odds
     *  (×0.47, vs ×0.05 at onset) across 45–60 min, so a genuine sleep-onset REM period late in the window is
     *  held back rather than suppressed. 60 min also stops clear of the ~70–100 min population first-REM
     *  latency, so the ramp is fully spent before real REM is expected. */
    internal const val remLatencyMinutes = 60.0

    /** The guard itself: `K` at (and before) sleep onset, decaying linearly to 0 at `M0` minutes after it.
     *  Clamped to `[0, K]` so a PRE-onset epoch — negative elapsed time, and unbounded when detection places
     *  the window start hours early (#271) — can never be penalised harder than the onset instant itself. */
    internal fun remLatencyGuard(minutesSinceOnset: Double): Double =
        remLatencyPenalty * minOf(1.0, maxOf(0.0, 1.0 - minutesSinceOnset / remLatencyMinutes))

    /** Soft sleep-cycle prior added to the log-emission: deep concentrated early (decays, never hard-wiped);
     *  REM suppressed around sleep onset (REM latency) then rising toward morning.
     *
     *  PROVENANCE of the constants: `1.2`, `0.55` and the `1.0` REM slope are hand-picked a priori from sleep
     *  physiology and population base rates, never fit to labels — as is every other coefficient in this file.
     *  [remLatencyPenalty] / [remLatencyMinutes] carry their own derivations above.
     *
     *  UNITS, and why they differ per term (#930). The deep term and the `1.0 * c` REM ramp take `c`, the
     *  fraction of the session — correctly, because both describe *where in the night* you are, a quantity
     *  that is inherently proportional. The REM-LATENCY guard takes `minutesSinceOnset` instead, because
     *  first-REM latency is an absolute physiological interval and not a proportion of how long you slept: on
     *  sleep-accel (n = 30 subjects with a scorable first REM period) true latency is uncorrelated with
     *  session duration (Pearson r = −0.058, Spearman −0.076), and re-expressing latency as a fraction makes
     *  it MORE variable, not less (CV 0.617 as a fraction vs 0.537 in minutes). The `c < 0.12` step this
     *  replaced therefore scaled a fixed physiological interval by session length: across one WHOOP 5 user's
     *  own recorded nights it ranged 7.4–84.5 min, an 11× spread, for the same wearer and the same physiology.
     *  Internal so the parity test can call it, matching the Swift `cyclePrior` visibility. */
    internal fun cyclePrior(c: Double, minutesSinceOnset: Double): Map<String, Double> = mapOf(
        "deep" to 1.2 * maxOf(0.0, 1.0 - c / 0.55),
        "rem" to 1.0 * c - remLatencyGuard(minutesSinceOnset),
        "light" to 0.0, "awake" to 0.0)

    /** Sustained non-wake run, in 30 s epochs, that establishes sleep onset — 10 epochs = 5 minutes.
     *  Measured against PSG onset on sleep-accel (n = 31 subjects): bias −3.8 min, MAE 7.4 min. */
    internal const val onsetSustainedEpochs = 10

    /** Index of the first epoch that begins a run of [onsetSustainedEpochs] consecutive non-"awake" labels,
     *  or null when the hypnogram never sustains sleep that long (a nap shorter than the rule, or an all-wake
     *  window). Runs are counted in epochs, not wall clock, so a coverage gap that drops an epoch cannot
     *  silently satisfy the rule with less evidence. */
    internal fun sustainedSleepOnset(labels: List<String>): Int? {
        var run = 0
        for (i in labels.indices) {
            if (labels[i] == "awake") { run = 0; continue }
            run++
            if (run >= onsetSustainedEpochs) return i - onsetSustainedEpochs + 1
        }
        return null
    }

    /** Viterbi most-likely path over the per-epoch log-emissions with the sticky transition matrix and a
     *  uniform start. Ties resolve to the earlier stage in [stageNames]. */
    private fun viterbi(emSeq: List<Map<String, Double>>): List<String> {
        if (emSeq.isEmpty()) return emptyList()
        // Floor before ln so a zeroed transition entry can never hit ln(0) = -Inf and poison the lattice.
        // LOAD-BEARING, not defensive: the awake row carries wake→deep = wake→rem = 0.0, so this floor is
        // the only thing between those two entries and -Inf. Deleting it does not remove dead code, it
        // breaks the stager. Floored, a zero costs ln(1e-9) ≈ -20.7 against wake→light's ≈ -2.3. The floor
        // arrived with #348 and survived #437; the zeros it now carries arrived later.
        val logT = transition.mapValues { (_, row) -> row.mapValues { (_, v) -> ln(maxOf(v, 1e-9)) } }
        var v = emSeq[0]   // uniform start
        val back = ArrayList<Map<String, String>>()
        for (t in 1 until emSeq.size) {
            val newV = HashMap<String, Double>(); val bp = HashMap<String, String>()
            for (s in stageNames) {
                var bestPrev = stageNames[0]
                var bestVal = v[bestPrev]!! + logT[bestPrev]!![s]!!
                for (p in stageNames.drop(1)) {
                    val value = v[p]!! + logT[p]!![s]!!
                    if (value > bestVal) { bestVal = value; bestPrev = p }
                }
                newV[s] = bestVal + emSeq[t][s]!!
                bp[s] = bestPrev
            }
            v = newV; back.add(bp)
        }
        var last = stageNames[0]; var lastV = v[last]!!
        for (s in stageNames.drop(1)) if (v[s]!! > lastV) { lastV = v[s]!!; last = s }
        val path = ArrayList<String>()
        path.add(last)
        for (bp in back.reversed()) { last = bp[last]!!; path.add(last) }
        return path.reversed()
    }

    /** Run the full recipe over a night's epochs and return one stage label per epoch (incl. "awake").
     *  All normalisation (z-scores, the HR-flatness percentile) is WITHIN the night.
     *
     *  TWO PASSES (#930). The REM-latency guard is measured from sleep ONSET, and onset is itself a staging
     *  output, so the recipe cannot know it while building the emissions. Pass 1 stages the night with the
     *  guard DISABLED (`cyclePrior(c, POSITIVE_INFINITY)`) and reads the first sustained sleep run out of the
     *  result; pass 2 adds the guard, re-based on that onset, and re-runs Viterbi. Only the guard differs
     *  between the passes — every emission term, z-score and percentile is computed ONCE and reused — so the
     *  extra cost is one Viterbi over an already-built lattice, not a second featurisation, and
     *  [stageSession] memoizes the whole thing anyway. When no sustained run exists the origin falls back to
     *  the window start, which is exactly the origin the shipped `c`-based guard used. */
    private fun stageEpochs(feats: List<Epoch>): List<String> {
        if (feats.isEmpty()) return emptyList()

        // Per-night z-score over the present values (population std; 0 std → 1 so a flat channel is neutral).
        fun zfun(vals: List<Double?>): (Double?) -> Double {
            val present = vals.filterNotNull()
            if (present.isEmpty()) return { _ -> 0.0 }
            val m = present.sum() / present.size
            val sd0 = sqrt(present.sumOf { (it - m) * (it - m) } / present.size)
            val sd = if (sd0 == 0.0) 1.0 else sd0
            return { value -> if (value == null) 0.0 else (value - m) / sd }
        }
        val zhr = zfun(feats.map { it.hr })
        val zhv = zfun(feats.map { it.hrVar })
        val zmv = zfun(feats.map { it.moveFrac })  // moveFrac is non-null; widened to Double? by zfun's param
        val zrg = zfun(feats.map { it.respReg })

        // HR-flatness percentile rank within the night (bisect_right / n), neutral 0.5 when missing.
        val fsorted = feats.mapNotNull { it.hrFlat11 }.sorted()
        fun fpct(value: Double?): Double {
            if (value == null || fsorted.isEmpty()) return 0.5
            var lo = 0; var hi = fsorted.size
            while (lo < hi) { val mid = (lo + hi) / 2; if (fsorted[mid] <= value) lo = mid + 1 else hi = mid }
            return lo.toDouble() / fsorted.size
        }

        // Held as the concrete HashMap (not the read-only `Map` view) so pass 2 can add the REM-latency guard
        // in place; `viterbi` still takes `List<Map<…>>`, which this satisfies by List's covariance.
        val seq = ArrayList<HashMap<String, Double>>(feats.size)
        for (f in feats) {
            val zhrv = zhr(f.hr); val zhvv = zhv(f.hrVar); val zmvv = zmv(f.moveFrac)
            val gate = deepGateSlope * maxOf(0.0, fpct(f.hrFlat11) - deepGateThresh)
            // Cardiac contribution to the AWAKE emission. On a motion-quiescent epoch the wrist did not move,
            // so a raised HR / HR-variability alone must NOT promote wake — clamp the cardiac term to ≤ 0,
            // keeping only its wake-SUPPRESSING (pro-sleep) half. Non-quiescent epochs are unchanged and use
            // the same cardiac coefficients verbatim, so a night with any motion stages byte-identical; the
            // correction only ever holds a still, elevated-HR epoch. Mirrors Swift `awakeCardiac`.
            val awakeCardiac0 = 0.8 * zhvv + 0.4 * zhrv
            val awakeCardiac = if (motionQuiescent(f)) minOf(0.0, awakeCardiac0) else awakeCardiac0
            val em = HashMap<String, Double>()
            em["deep"] = -1.1 * zhvv - 0.5 * zmvv - gate + baseLogPrior["deep"]!!
            em["rem"] = 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + baseLogPrior["rem"]!!
            em["light"] = baseLogPrior["light"]!!
            em["awake"] = 1.0 * zmvv + awakeCardiac + baseLogPrior["awake"]!!
            // Guard DISABLED here (infinity ⇒ [remLatencyGuard] = 0); pass 2 below adds it once onset is known.
            val pr = cyclePrior(f.clock, Double.POSITIVE_INFINITY)
            for (s in stageNames) em[s] = em[s]!! + pr[s]!!
            if (f.jerkMax > f.jerkScale * jerkFloorGateMult) em["awake"] = em["awake"]!! + motionGateBoost
            f.respReg?.let { rg -> val z = zrg(rg); em["deep"] = em["deep"]!! + respWeight * z; em["rem"] = em["rem"]!! - respWeight * z }
            seq.add(em)
        }

        // PASS 1 — stage without the REM-latency guard purely to locate sleep onset.
        val provisional = viterbi(seq)
        // Origin for the guard: the centre of the first sustained-sleep epoch, in the same window-relative
        // minutes [features] stamped on every epoch. No sustained run → 0.0, i.e. the window start.
        val originMin = sustainedSleepOnset(provisional)?.let { feats[it].minutesSinceOnset } ?: 0.0

        // PASS 2 — apply the guard against minutes since THAT onset and re-run the lattice.
        for (i in feats.indices) {
            seq[i]["rem"] = seq[i]["rem"]!! - remLatencyGuard(feats[i].minutesSinceOnset - originMin)
        }
        return viterbi(seq)
    }
}
