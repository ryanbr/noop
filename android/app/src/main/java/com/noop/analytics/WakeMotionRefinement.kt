package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.StepSample

/**
 * WakeMotionRefinement.kt — motion-aware wake refinement (#364 "Proposal 2" follow-up; density-gate
 * precedent #345). Direct Kotlin port of the Swift `WakeMotionRefinement`
 * (Packages/StrandAnalytics/Sources/StrandAnalytics/WakeMotionRefinement.swift) — same constants, same
 * algorithm, same [StageSegment] shape.
 *
 * THE PROBLEM. Both stagers ([SleepStager] V1, [SleepStagerV2]) call "wake" primarily from HR / HR
 * variability — neither consults locomotion or posture. On a strap night with pharmacologically- or
 * metabolically-elevated resting HR (a supplement protocol, a hot room, alcohol — anything that keeps HR
 * up without the wearer actually getting up), that HR-led call misreads hot-but-asleep as wake. A real
 * anonymized night (5.0 strap, elevated HR from a supplement protocol, not illness) scored 194 min wake
 * across ~6.4h in bed (efficiency 0.50) though the wearer reported sleeping through. Minute-level review of
 * the four largest wake blocks found ZERO walking cadence: each block was a single-minute turn-over burst
 * (20-36 step-motion-counter ticks, a posture-variance spike) bracketed by minutes of complete stillness
 * (posture variance < 0.01, zero ticks) — recurring on a ~90-min rhythm consistent with hot-but-atonic REM
 * being scored as wake, not a real awakening. A genuine get-up looks entirely different: sustained
 * multi-minute walking cadence, not an isolated single-minute blip.
 *
 * THE FIX. A POST-PASS over the already-staged [StageSegment] output of either stager (V1 or V2 — this
 * file never touches their HR-led emission models). For each scored wake segment of at least
 * [MIN_WAKE_SEGMENT_SECONDS], look at the SAME two signals a human reviewer used above: per-minute
 * step-motion-counter cadence ([StepSample.counter], wrap-aware, `activityClass` 1=walk/2=run only — see
 * [walkClassTicksPerMinute]) and per-minute gravity posture variance ([postureVariance]). A segment with NO
 * locomotion evidence ([hasLocomotion]) and posture stable outside a minority of isolated burst minutes
 * ([stableBurstMinutes]) is a hot-but-still wake call: every non-burst minute is reclassified to `light`,
 * while burst minutes (plus a ±[BURST_PAD_MINUTES] buffer) are KEPT as wake — the pass only ever shrinks
 * wake time, it never invents wake the incumbent stager didn't already call.
 *
 * THE DENSITY SELF-GATE (#345). A per-minute posture VARIANCE needs multiple samples inside each minute to
 * mean anything (a single sample has zero variance by construction, which would silently read as "stable"
 * and rubber-stamp every wake block on a sparse night). And a WHOOP 4.0 never emits [StepSample] at all —
 * `steps` is permanently empty on that model, so a naive "zero ticks = no locomotion" read would ALWAYS
 * pass. Rather than branch on strap family/model (which the maintainer flagged in #345 as too coarse — a
 * "4.0" string tells you nothing about how dense THIS night's data actually is), [isMotionDense] measures
 * the OBSERVED stream directly: at least [MIN_DENSE_MINUTE_COVERAGE_FRACTION] of the night's minutes must
 * carry `>= MIN_GRAVITY_SAMPLES_PER_MINUTE_FOR_VARIANCE` gravity samples AND
 * `>= MIN_STEP_SAMPLES_PER_MINUTE_FOR_DENSITY` step records. A 4.0 night fails this on the data (empty
 * steps, ~1 gravity vector/min) every time, exactly as a synthetically-sparse 5.0/MG night would; a real
 * 5.0/MG night — which streams both channels densely — is this refinement's expected beneficiary and
 * clears the gate on its own merits.
 *
 * SAFETY POSTURE. Default-off Experimental toggle
 * ([com.noop.ble.PuffinExperiment.motionAwareWake]), consistent with the repo rule for a derived
 * physiological signal: land it as an opt-in refinement, never the default, until it has more than this
 * one reference night behind it. All thresholds below are NAMED CONSTANTS fixed a-priori from that
 * reference night, not fit to labels. Pure, deterministic, no I/O.
 */
object WakeMotionRefinement {

    // ── Tunables (named, documented constants — see the header for where each one comes from) ──────────

    /** Only wake segments at least this long are considered (seconds). */
    const val MIN_WAKE_SEGMENT_SECONDS: Long = 5 * 60L

    /**
     * A minute with at least this many walk-class ticks, held for
     * [SUSTAINED_WALK_MIN_CONSECUTIVE_MINUTES] in a row, is real ambulation (a get-up), not a turn-over.
     */
    const val SUSTAINED_WALK_TICKS_PER_MINUTE: Int = 10
    const val SUSTAINED_WALK_MIN_CONSECUTIVE_MINUTES: Int = 2

    /**
     * A single minute this busy is vigorous enough to count as locomotion on its own, no second minute
     * required — the reference get-up example (3 consecutive minutes at 25 ticks/min) clears both this
     * and the sustained rule; this constant exists for a single very busy minute with a quiet neighbour.
     */
    const val SINGLE_MINUTE_WALK_TICKS: Int = 40

    /**
     * Per-minute gravity posture variance (g², see [postureVariance]) below this reads as "stable" — the
     * reference night's motionless stretches measured < 0.01; 0.05 leaves headroom above strap/decode
     * noise while still well below the reference night's turn-over spikes.
     */
    const val STABLE_POSTURE_VARIANCE_G2: Double = 0.05

    /**
     * At least this fraction of a candidate segment's minutes must be posture-stable (i.e. NOT a burst
     * minute) before the segment is trusted as "hot-but-still" rather than a real restless stretch.
     */
    const val MIN_STABLE_MINUTE_FRACTION: Double = 0.80

    /**
     * Minutes kept as wake around a burst minute (the turn-over itself, plus this many minutes on each
     * side) so a reclassified block doesn't shave the couple of seconds of real motion right at its edge.
     */
    const val BURST_PAD_MINUTES: Long = 1L

    /**
     * A minute's posture variance is only meaningful with at least this many gravity samples inside it
     * (one sample has zero variance by construction and would trivially read as "stable").
     */
    const val MIN_GRAVITY_SAMPLES_PER_MINUTE_FOR_VARIANCE: Int = 2

    /**
     * A minute needs at least this many step records to say its tick cadence is a real (possibly zero)
     * reading rather than a gap in the stream.
     */
    const val MIN_STEP_SAMPLES_PER_MINUTE_FOR_DENSITY: Int = 1

    /**
     * Density self-gate (#345): the fraction of the WHOLE scored window's minutes that must clear both
     * per-minute density floors above before ANY segment in this call is touched. Gates on the observed
     * stream, never on strap family/model — see the header.
     */
    const val MIN_DENSE_MINUTE_COVERAGE_FRACTION: Double = 0.80

    /**
     * WHOOP [StepSample.activityClass] codes (community finding #316) that count as locomotion. 0 = still
     * (a turn-over, NOT ambulation) is deliberately excluded; null (unknown/invalid byte) is also
     * excluded — unattributed ticks feed the posture-variance half of the gate instead.
     */
    private val LOCOMOTION_ACTIVITY_CLASSES = setOf(1, 2) // walk, run

    // ── Public entry points ──────────────────────────────────────────────────────────────────────────

    /**
     * The core pass: reclassify non-burst minutes of eligible wake segments to `light`. `segments` must
     * tile a single contiguous window in order (as every `stageSession` in this package returns); `grav`/
     * `steps` should cover at least that window. Byte-identical passthrough when `segments` is empty, the
     * window is degenerate, or the density self-gate declines.
     */
    fun refine(segments: List<StageSegment>, grav: List<GravitySample>, steps: List<StepSample>): List<StageSegment> {
        val windowStart = segments.firstOrNull()?.start ?: return segments
        val windowEnd = segments.lastOrNull()?.end ?: return segments
        if (windowEnd <= windowStart) return segments
        if (!isMotionDense(windowStart, windowEnd, grav, steps)) return segments

        val gravByMinute = bucketByMinute(grav) { it.ts }
        val ticksByMinute = walkClassTicksPerMinute(steps)

        val out = mutableListOf<StageSegment>()
        for (seg in segments) {
            for (piece in refineSegment(seg, gravByMinute, ticksByMinute)) {
                appendMerging(piece, out)
            }
        }
        return out
    }

    /**
     * Toggle-shaped convenience: `enabled = false` is a guaranteed byte-identical passthrough (the
     * [com.noop.ble.PuffinExperiment.motionAwareWake] off-path), `enabled = true` runs [refine].
     */
    fun apply(
        segments: List<StageSegment>,
        grav: List<GravitySample>,
        steps: List<StepSample>,
        enabled: Boolean,
    ): List<StageSegment> = if (enabled) refine(segments, grav, steps) else segments

    /**
     * Session-level convenience: refines `session.stages` and recomputes `efficiency` from the result
     * (efficiency is derived from wake time, so reclassifying wake -> light changes it). `restingHR` and
     * `avgHRV` are independent of stage labels and are carried over unchanged (via [DetectedSleep.copy]).
     * Identity passthrough when [refine] makes no change to the stages.
     */
    fun refine(session: DetectedSleep, grav: List<GravitySample>, steps: List<StepSample>): DetectedSleep {
        val newStages = refine(session.stages, grav, steps)
        if (newStages == session.stages) return session
        val newEfficiency = SleepStager.efficiency(session.start, session.end, newStages)
        return session.copy(efficiency = newEfficiency, stages = newStages)
    }

    /** Toggle-shaped convenience for the session-level overload (see [apply] above). */
    fun apply(
        session: DetectedSleep,
        grav: List<GravitySample>,
        steps: List<StepSample>,
        enabled: Boolean,
    ): DetectedSleep = if (enabled) refine(session, grav, steps) else session

    // ── Density self-gate (#345) ─────────────────────────────────────────────────────────────────────

    /**
     * True when both the gravity and step streams are dense enough, OVER THE OBSERVED DATA, to trust
     * per-minute locomotion/posture evidence across `[start, end)`. See the file header for why this
     * checks the streams themselves rather than a strap family/model string.
     */
    fun isMotionDense(start: Long, end: Long, grav: List<GravitySample>, steps: List<StepSample>): Boolean {
        val gravDensity = denseMinuteFraction(grav, start, end, MIN_GRAVITY_SAMPLES_PER_MINUTE_FOR_VARIANCE) { it.ts }
        val stepDensity = denseMinuteFraction(steps, start, end, MIN_STEP_SAMPLES_PER_MINUTE_FOR_DENSITY) { it.ts }
        return gravDensity >= MIN_DENSE_MINUTE_COVERAGE_FRACTION && stepDensity >= MIN_DENSE_MINUTE_COVERAGE_FRACTION
    }

    /**
     * Fraction of the wall-clock minutes tiling `[start, end)` that carry at least `minPerMinute` samples
     * of `samples`. 0 for a degenerate (empty or inverted) window.
     */
    fun <T> denseMinuteFraction(samples: List<T>, start: Long, end: Long, minPerMinute: Int, ts: (T) -> Long): Double {
        if (end <= start) return 0.0
        val firstMinute = start / 60
        val lastMinute = (end - 1) / 60
        if (lastMinute < firstMinute) return 0.0
        val counts = HashMap<Long, Int>()
        for (s in samples) {
            val m = ts(s) / 60
            if (m in firstMinute..lastMinute) counts[m] = (counts[m] ?: 0) + 1
        }
        val totalMinutes = lastMinute - firstMinute + 1
        var denseMinutes = 0L
        for (m in firstMinute..lastMinute) if ((counts[m] ?: 0) >= minPerMinute) denseMinutes++
        return denseMinutes.toDouble() / totalMinutes.toDouble()
    }

    // ── Per-segment refinement ───────────────────────────────────────────────────────────────────────

    /**
     * Refine one [StageSegment]. Non-wake segments, and wake segments shorter than
     * [MIN_WAKE_SEGMENT_SECONDS], pass through unchanged (wrapped in a single-element list). An eligible
     * segment that fails EITHER the locomotion gate or the stability gate also passes through unchanged —
     * this pass only ever acts when BOTH read "hot-but-still".
     */
    fun refineSegment(
        seg: StageSegment,
        gravByMinute: Map<Long, List<GravitySample>>,
        ticksByMinute: Map<Long, Int>,
    ): List<StageSegment> {
        if (!SleepStageVocabulary.isWake(seg.stage) || seg.end - seg.start < MIN_WAKE_SEGMENT_SECONDS) return listOf(seg)
        val mins = minutes(seg.start, seg.end)
        if (mins.isEmpty()) return listOf(seg)

        if (hasLocomotion(mins, ticksByMinute)) return listOf(seg)

        val burstMinutes = stableBurstMinutes(mins, gravByMinute) ?: return listOf(seg)

        // Keep every burst minute plus a +/-BURST_PAD_MINUTES buffer as wake, clamped to this segment's
        // own bounds (never grows wake past what the stager already called); reclassify everything else.
        val firstMinute = mins.first()
        val lastMinute = mins.last()
        val keepWake = HashSet<Long>()
        for (m in burstMinutes) {
            val lo = maxOf(firstMinute, m - BURST_PAD_MINUTES)
            val hi = minOf(lastMinute, m + BURST_PAD_MINUTES)
            if (lo <= hi) for (p in lo..hi) keepWake.add(p)
        }

        val result = mutableListOf<StageSegment>()
        for ((idx, m) in mins.withIndex()) {
            val stage = if (keepWake.contains(m)) "wake" else "light"
            val minuteStart = if (idx == 0) seg.start else m * 60
            val minuteEnd = if (idx == mins.size - 1) seg.end else (m + 1) * 60
            appendMerging(StageSegment(minuteStart, minuteEnd, stage), result)
        }
        return result
    }

    /**
     * The locomotion gate: true when `mins` contains either a single minute at/above
     * [SINGLE_MINUTE_WALK_TICKS], or [SUSTAINED_WALK_MIN_CONSECUTIVE_MINUTES] consecutive minutes each
     * at/above [SUSTAINED_WALK_TICKS_PER_MINUTE]. A minute absent from `ticksByMinute` (no step coverage
     * that minute) reads as 0 ticks and breaks a building streak, matching "no evidence of walking"
     * rather than crediting it.
     */
    fun hasLocomotion(mins: List<Long>, ticksByMinute: Map<Long, Int>): Boolean {
        var consecutive = 0
        for (m in mins) {
            val ticks = ticksByMinute[m] ?: 0
            if (ticks >= SINGLE_MINUTE_WALK_TICKS) return true
            if (ticks >= SUSTAINED_WALK_TICKS_PER_MINUTE) {
                consecutive++
                if (consecutive >= SUSTAINED_WALK_MIN_CONSECUTIVE_MINUTES) return true
            } else {
                consecutive = 0
            }
        }
        return false
    }

    /**
     * The stability gate. Returns the set of "burst" (not posture-stable) minutes when at least
     * [MIN_STABLE_MINUTE_FRACTION] of `mins` ARE posture-stable, so the caller can keep those burst
     * minutes (+/- padding) as wake; returns `null` when the segment isn't stable enough to trust (too
     * many/too little-understood unstable minutes), telling the caller to leave the segment untouched. A
     * minute with too few gravity samples to compute a variance ([postureVariance] returns `null`) is
     * conservatively treated as a burst minute — silence is not proof of stillness.
     */
    fun stableBurstMinutes(mins: List<Long>, gravByMinute: Map<Long, List<GravitySample>>): Set<Long>? {
        val burstMinutes = HashSet<Long>()
        var stableCount = 0
        for (m in mins) {
            val variance = postureVariance(gravByMinute[m] ?: emptyList())
            if (variance != null && variance < STABLE_POSTURE_VARIANCE_G2) {
                stableCount++
            } else {
                burstMinutes.add(m)
            }
        }
        if (stableCount.toDouble() / mins.size.toDouble() < MIN_STABLE_MINUTE_FRACTION) return null
        return burstMinutes
    }

    // ── Signal extraction ────────────────────────────────────────────────────────────────────────────

    /**
     * Per-minute posture variance: the trace of the covariance matrix of a minute's gravity samples (the
     * mean squared deviation of each sample from the minute's own mean vector, summed over x/y/z). Near 0
     * when the wrist orientation barely moves within the minute; spikes when the strap rotates through
     * positions inside the minute (a turn-over). `null` below [MIN_GRAVITY_SAMPLES_PER_MINUTE_FOR_VARIANCE]
     * samples — too few to say anything (see [stableBurstMinutes]'s null handling).
     */
    fun postureVariance(samples: List<GravitySample>): Double? {
        if (samples.size < MIN_GRAVITY_SAMPLES_PER_MINUTE_FOR_VARIANCE) return null
        val n = samples.size.toDouble()
        var sx = 0.0
        var sy = 0.0
        var sz = 0.0
        for (s in samples) { sx += s.x; sy += s.y; sz += s.z }
        val mx = sx / n
        val my = sy / n
        val mz = sz / n
        var sumSq = 0.0
        for (s in samples) {
            val dx = s.x - mx
            val dy = s.y - my
            val dz = s.z - mz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        return sumSq / n
    }

    /**
     * Per-minute walk-class tick cadence: the wrap-aware u16 counter delta between consecutive
     * [StepSample]s, attributed to the LATER sample's minute, kept only when that later sample's
     * `activityClass` is walk (1) or run (2) — see [LOCOMOTION_ACTIVITY_CLASSES]. A still-class (0) or
     * unknown-class (null) delta is real counter movement (a turn-over jostles the accelerometer too) but
     * is deliberately NOT counted as locomotion; it still shows up in [postureVariance] instead. Minutes
     * with no qualifying tick are simply absent from the result (callers read `?: 0`).
     */
    fun walkClassTicksPerMinute(steps: List<StepSample>): Map<Long, Int> {
        val sorted = steps.sortedBy { it.ts }
        if (sorted.size < 2) return emptyMap()
        val out = HashMap<Long, Int>()
        for (i in 1 until sorted.size) {
            val cur = sorted[i]
            val cls = cur.activityClass ?: continue
            if (cls !in LOCOMOTION_ACTIVITY_CLASSES) continue
            val delta = (cur.counter - sorted[i - 1].counter) and 0xFFFF // wrap-aware u16 increment
            val m = cur.ts / 60
            out[m] = (out[m] ?: 0) + delta
        }
        return out
    }

    // ── Small shared helpers ─────────────────────────────────────────────────────────────────────────

    /**
     * The wall-clock minute indices (unix seconds / 60) tiling `[start, end)`. Empty for a degenerate
     * (empty or inverted) window.
     */
    fun minutes(start: Long, end: Long): List<Long> {
        if (end <= start) return emptyList()
        val first = start / 60
        val last = (end - 1) / 60
        if (last < first) return emptyList()
        return (first..last).toList()
    }

    fun <T> bucketByMinute(samples: List<T>, ts: (T) -> Long): Map<Long, List<T>> {
        val out = HashMap<Long, MutableList<T>>()
        for (s in samples) out.getOrPut(ts(s) / 60) { mutableListOf() }.add(s)
        return out
    }

    /**
     * Append `piece`, merging into the previous element when the stage matches AND the two are
     * time-contiguous (defensive: every caller here produces pieces in strict chronological order with
     * no gaps, so this is always a merge when the stage repeats).
     */
    fun appendMerging(piece: StageSegment, out: MutableList<StageSegment>) {
        val last = out.lastOrNull()
        if (last != null && last.stage == piece.stage && last.end == piece.start) {
            last.end = piece.end
        } else {
            out.add(piece)
        }
    }
}
