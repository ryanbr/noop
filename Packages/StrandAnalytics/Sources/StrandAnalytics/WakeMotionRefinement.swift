import Foundation
import WhoopProtocol

// WakeMotionRefinement.swift — motion-aware wake refinement (#364 "Proposal 2", a follow-up to the
// sleep-presentation work in #364; density-gate precedent from #345).
//
// THE PROBLEM. Both stagers (`SleepStager` V1, `SleepStagerV2`) call "wake" primarily from HR / HR
// variability — neither consults locomotion or posture. On a strap night with pharmacologically- or
// metabolically-elevated resting HR (a supplement protocol, a hot room, alcohol — anything that keeps HR
// up without the wearer actually getting up), that HR-led call misreads hot-but-asleep as wake. A real
// anonymized night (5.0 strap, elevated HR from a supplement protocol, not illness) scored 194 min wake
// across ~6.4h in bed (efficiency 0.50) though the wearer reported sleeping through. Minute-level review of
// the four largest wake blocks found ZERO walking cadence: each block was a single-minute turn-over burst
// (20-36 step-motion-counter ticks, a posture-variance spike) bracketed by minutes of complete stillness
// (posture variance < 0.01, zero ticks) — recurring on a ~90-min rhythm consistent with hot-but-atonic REM
// being scored as wake, not a real awakening. A genuine get-up looks entirely different: sustained
// multi-minute walking cadence, not an isolated single-minute blip.
//
// THE FIX. A POST-PASS over the already-staged `[StageSegment]` output of either stager (V1 or V2 — this
// file never touches their HR-led emission models). For each scored wake segment of at least
// `minWakeSegmentSeconds`, look at the SAME two signals a human reviewer used above: per-minute
// step-motion-counter cadence (`StepSample.counter`, wrap-aware, `activityClass` 1=walk/2=run only — see
// `walkClassTicksPerMinute`) and per-minute gravity posture variance (`postureVariance`). A segment with NO
// locomotion evidence (`hasNoLocomotion`) and posture stable outside a minority of isolated burst minutes
// (`isPostureStable`) is a hot-but-still wake call: every non-burst minute is reclassified to `light`,
// while burst minutes (plus a ±`burstPadMinutes` buffer) are KEPT as wake — the pass only ever shrinks
// wake time, it never invents wake the incumbent stager didn't already call.
//
// THE DENSITY SELF-GATE (#345). `SleepStagerV2`'s own header notes the WHOOP 4.0 gravity stream is often
// too sparse to tell "restless in bed" from "out of bed" — the same limitation applies here even harder,
// because a per-minute posture VARIANCE needs multiple samples inside each minute to mean anything (a
// single sample has zero variance by construction, which would silently read as "stable" and rubber-stamp
// every wake block on a sparse night). And a WHOOP 4.0 never emits `StepSample` at all — `steps` is
// permanently empty on that model, so a naive "zero ticks = no locomotion" read would ALWAYS pass. Rather
// than branch on strap family/model (which the maintainer flagged in #345 as too coarse — a "4.0" string
// tells you nothing about how dense THIS night's data actually is), `isMotionDense` measures the OBSERVED
// stream directly: at least `minDenseMinuteCoverageFraction` of the night's minutes must carry
// `>= minGravitySamplesPerMinuteForVariance` gravity samples AND `>= minStepSamplesPerMinuteForDensity`
// step records. A 4.0 night fails this on the data (empty steps, ~1 gravity vector/min) every time,
// exactly as a synthetically-sparse 5.0/MG night would; a real 5.0/MG night — which streams both channels
// densely — is this refinement's expected beneficiary and clears the gate on its own merits.
//
// SAFETY POSTURE. Default-off `Experimental` toggle (`PuffinExperiment.motionAwareWakeEnabled` /
// `Strand/Screens/SettingsView.swift`), consistent with CLAUDE.md's rule for a derived physiological
// signal: land it as an opt-in refinement, never the default, until it has more than this one reference
// night behind it. All thresholds below are NAMED CONSTANTS fixed a-priori from that reference night, not
// fit to labels. Pure, deterministic, no I/O — the Kotlin twin is `WakeMotionRefinement.kt`.
public enum WakeMotionRefinement {

    // MARK: - Tunables (named, documented constants — see the header for where each one comes from)

    /// Only wake segments at least this long are considered. A short HR blip is either a real brief
    /// arousal or too short to say anything reliable about locomotion/posture from per-minute buckets.
    public static let minWakeSegmentSeconds: Int = 5 * 60

    /// A minute with at least this many walk-class ticks, held for `sustainedWalkMinConsecutiveMinutes`
    /// in a row, is real ambulation (a get-up), not a turn-over.
    public static let sustainedWalkTicksPerMinute: Int = 10
    public static let sustainedWalkMinConsecutiveMinutes: Int = 2

    /// A single minute this busy is vigorous enough to count as locomotion on its own, no second minute
    /// required — the reference get-up example (3 consecutive minutes at 25 ticks/min) clears both this
    /// and the sustained rule; this constant exists for a single very busy minute with a quiet neighbour.
    public static let singleMinuteWalkTicks: Int = 40

    /// Per-minute gravity posture variance (g², see `postureVariance`) below this reads as "stable" — the
    /// reference night's motionless stretches measured < 0.01; 0.05 leaves headroom above strap/decode
    /// noise while still well below the reference night's turn-over spikes.
    public static let stablePostureVarianceG2: Double = 0.05

    /// At least this fraction of a candidate segment's minutes must be posture-stable (i.e. NOT a burst
    /// minute) before the segment is trusted as "hot-but-still" rather than a real restless stretch.
    public static let minStableMinuteFraction: Double = 0.80

    /// Minutes kept as wake around a burst minute (the turn-over itself, plus this many minutes on each
    /// side) so a reclassified block doesn't shave the couple of seconds of real motion right at its edge.
    public static let burstPadMinutes: Int = 1

    /// A minute's posture variance is only meaningful with at least this many gravity samples inside it
    /// (one sample has zero variance by construction and would trivially read as "stable").
    public static let minGravitySamplesPerMinuteForVariance: Int = 2

    /// A minute needs at least this many step records to say its tick cadence is a real (possibly zero)
    /// reading rather than a gap in the stream.
    public static let minStepSamplesPerMinuteForDensity: Int = 1

    /// Density self-gate (#345): the fraction of the WHOLE scored window's minutes that must clear both
    /// per-minute density floors above before ANY segment in this call is touched. Gates on the observed
    /// stream, never on strap family/model — see the header.
    public static let minDenseMinuteCoverageFraction: Double = 0.80

    /// WHOOP StepSample `activityClass` codes (community finding #316) that count as locomotion.
    /// 0 = still (a turn-over, NOT ambulation) is deliberately excluded; nil (unknown/invalid byte) is
    /// also excluded — unattributed ticks feed the posture-variance half of the gate instead.
    private static let locomotionActivityClasses: Set<Int> = [1 /* walk */, 2 /* run */]

    // MARK: - Public entry points

    /// The core pass: reclassify non-burst minutes of eligible wake segments to `light`. `segments` must
    /// tile a single contiguous window in order (as every `stageSession` in this module returns); `grav`/
    /// `steps` should cover at least that window. Byte-identical passthrough when `segments` is empty, the
    /// window is degenerate, or the density self-gate declines.
    public static func refine(_ segments: [StageSegment], grav: [GravitySample], steps: [StepSample]) -> [StageSegment] {
        guard let windowStart = segments.first?.start, let windowEnd = segments.last?.end, windowEnd > windowStart else {
            return segments
        }
        guard isMotionDense(start: windowStart, end: windowEnd, grav: grav, steps: steps) else { return segments }

        let gravByMinute = bucketByMinute(grav) { $0.ts }
        let ticksByMinute = walkClassTicksPerMinute(steps)

        var out: [StageSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            for piece in refineSegment(seg, gravByMinute: gravByMinute, ticksByMinute: ticksByMinute) {
                appendMerging(piece, into: &out)
            }
        }
        return out
    }

    /// Toggle-shaped convenience: `enabled = false` is a guaranteed byte-identical passthrough (the
    /// `PuffinExperiment.motionAwareWakeEnabled` off-path), `enabled = true` runs `refine`.
    public static func apply(_ segments: [StageSegment], grav: [GravitySample], steps: [StepSample],
                             enabled: Bool) -> [StageSegment] {
        enabled ? refine(segments, grav: grav, steps: steps) : segments
    }

    /// Session-level convenience: refines `session.stages` and recomputes `efficiency` from the result
    /// (efficiency is derived from wake time, so reclassifying wake -> light changes it). `restingHR` and
    /// `avgHRV` are independent of stage labels and are carried over unchanged. Identity passthrough
    /// (same instance's fields, no allocation of a changed copy beyond the equality check) when `refine`
    /// makes no change to the stages.
    public static func refine(_ session: SleepSession, grav: [GravitySample], steps: [StepSample]) -> SleepSession {
        let newStages = refine(session.stages, grav: grav, steps: steps)
        guard newStages != session.stages else { return session }
        let newEfficiency = SleepStager.efficiency(start: session.start, end: session.end, stages: newStages)
        return SleepSession(start: session.start, end: session.end, efficiency: newEfficiency,
                            stages: newStages, restingHR: session.restingHR, avgHRV: session.avgHRV)
    }

    /// Toggle-shaped convenience for the session-level overload (see `apply(_:grav:steps:enabled:)`).
    public static func apply(_ session: SleepSession, grav: [GravitySample], steps: [StepSample],
                             enabled: Bool) -> SleepSession {
        enabled ? refine(session, grav: grav, steps: steps) : session
    }

    // MARK: - Density self-gate (#345)

    /// True when both the gravity and step streams are dense enough, OVER THE OBSERVED DATA, to trust
    /// per-minute locomotion/posture evidence across `[start, end)`. See the file header for why this
    /// checks the streams themselves rather than a strap family/model string.
    static func isMotionDense(start: Int, end: Int, grav: [GravitySample], steps: [StepSample]) -> Bool {
        let gravDensity = denseMinuteFraction(grav, from: start, to: end,
                                              minPerMinute: minGravitySamplesPerMinuteForVariance, ts: { $0.ts })
        let stepDensity = denseMinuteFraction(steps, from: start, to: end,
                                              minPerMinute: minStepSamplesPerMinuteForDensity, ts: { $0.ts })
        return gravDensity >= minDenseMinuteCoverageFraction && stepDensity >= minDenseMinuteCoverageFraction
    }

    /// Fraction of the wall-clock minutes tiling `[start, end)` that carry at least `minPerMinute` samples
    /// of `samples`. 0 for a degenerate (empty or inverted) window.
    static func denseMinuteFraction<T>(_ samples: [T], from start: Int, to end: Int, minPerMinute: Int,
                                       ts: (T) -> Int) -> Double {
        guard end > start else { return 0 }
        let firstMinute = start / 60
        let lastMinute = (end - 1) / 60
        guard lastMinute >= firstMinute else { return 0 }
        var counts: [Int: Int] = [:]
        for s in samples {
            let m = ts(s) / 60
            if m >= firstMinute && m <= lastMinute { counts[m, default: 0] += 1 }
        }
        let totalMinutes = lastMinute - firstMinute + 1
        var denseMinutes = 0
        for m in firstMinute...lastMinute where (counts[m] ?? 0) >= minPerMinute { denseMinutes += 1 }
        return Double(denseMinutes) / Double(totalMinutes)
    }

    // MARK: - Per-segment refinement

    /// Refine one `StageSegment`. Non-wake segments, and wake segments shorter than
    /// `minWakeSegmentSeconds`, pass through unchanged (wrapped in a single-element array). An eligible
    /// segment that fails EITHER the locomotion gate or the stability gate also passes through unchanged —
    /// this pass only ever acts when BOTH read "hot-but-still".
    static func refineSegment(_ seg: StageSegment, gravByMinute: [Int: [GravitySample]],
                              ticksByMinute: [Int: Int]) -> [StageSegment] {
        guard SleepStageVocabulary.isWake(seg.stage), seg.end - seg.start >= minWakeSegmentSeconds else { return [seg] }
        let mins = minutes(from: seg.start, to: seg.end)
        guard !mins.isEmpty else { return [seg] }

        guard !hasLocomotion(mins, ticksByMinute: ticksByMinute) else { return [seg] }

        guard let burstMinutes = stableBurstMinutes(mins, gravByMinute: gravByMinute) else { return [seg] }

        // Keep every burst minute plus a ±burstPadMinutes buffer as wake, clamped to this segment's own
        // bounds (never grows wake past what the stager already called); reclassify everything else.
        let firstMinute = mins[0], lastMinute = mins[mins.count - 1]
        var keepWake: Set<Int> = []
        for m in burstMinutes {
            let lo = max(firstMinute, m - burstPadMinutes)
            let hi = min(lastMinute, m + burstPadMinutes)
            if lo <= hi { for p in lo...hi { keepWake.insert(p) } }
        }

        var result: [StageSegment] = []
        for (idx, m) in mins.enumerated() {
            let stage = keepWake.contains(m) ? "wake" : "light"
            let minuteStart = idx == 0 ? seg.start : m * 60
            let minuteEnd = idx == mins.count - 1 ? seg.end : (m + 1) * 60
            appendMerging(StageSegment(start: minuteStart, end: minuteEnd, stage: stage), into: &result)
        }
        return result
    }

    /// The locomotion gate: true when `mins` contains either a single minute at/above
    /// `singleMinuteWalkTicks`, or `sustainedWalkMinConsecutiveMinutes` consecutive minutes each at/above
    /// `sustainedWalkTicksPerMinute`. A minute absent from `ticksByMinute` (no step coverage that minute)
    /// reads as 0 ticks and breaks a building streak, matching "no evidence of walking" rather than
    /// crediting it.
    static func hasLocomotion(_ mins: [Int], ticksByMinute: [Int: Int]) -> Bool {
        var consecutive = 0
        for m in mins {
            let ticks = ticksByMinute[m] ?? 0
            if ticks >= singleMinuteWalkTicks { return true }
            if ticks >= sustainedWalkTicksPerMinute {
                consecutive += 1
                if consecutive >= sustainedWalkMinConsecutiveMinutes { return true }
            } else {
                consecutive = 0
            }
        }
        return false
    }

    /// The stability gate. Returns the set of "burst" (not posture-stable) minutes when at least
    /// `minStableMinuteFraction` of `mins` ARE posture-stable, so the caller can keep those burst minutes
    /// (± padding) as wake; returns `nil` when the segment isn't stable enough to trust (too many/too
    /// little-understood unstable minutes), telling the caller to leave the segment untouched. A minute
    /// with too few gravity samples to compute a variance (`postureVariance` returns nil) is conservatively
    /// treated as a burst minute — silence is not proof of stillness.
    static func stableBurstMinutes(_ mins: [Int], gravByMinute: [Int: [GravitySample]]) -> Set<Int>? {
        var burstMinutes: Set<Int> = []
        var stableCount = 0
        for m in mins {
            if let variance = postureVariance(gravByMinute[m] ?? []), variance < stablePostureVarianceG2 {
                stableCount += 1
            } else {
                burstMinutes.insert(m)
            }
        }
        guard Double(stableCount) / Double(mins.count) >= minStableMinuteFraction else { return nil }
        return burstMinutes
    }

    // MARK: - Signal extraction

    /// Per-minute posture variance: the trace of the covariance matrix of a minute's gravity samples (the
    /// mean squared deviation of each sample from the minute's own mean vector, summed over x/y/z). Near 0
    /// when the wrist orientation barely moves within the minute; spikes when the strap rotates through
    /// positions inside the minute (a turn-over). `nil` below `minGravitySamplesPerMinuteForVariance`
    /// samples — too few to say anything (see `stableBurstMinutes`'s nil handling).
    static func postureVariance(_ samples: [GravitySample]) -> Double? {
        guard samples.count >= minGravitySamplesPerMinuteForVariance else { return nil }
        let n = Double(samples.count)
        var sx = 0.0, sy = 0.0, sz = 0.0
        for s in samples { sx += s.x; sy += s.y; sz += s.z }
        let mx = sx / n, my = sy / n, mz = sz / n
        var sumSq = 0.0
        for s in samples {
            let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        return sumSq / n
    }

    /// Per-minute walk-class tick cadence: the wrap-aware u16 counter delta between consecutive
    /// `StepSample`s, attributed to the LATER sample's minute, kept only when that later sample's
    /// `activityClass` is walk (1) or run (2) — see `locomotionActivityClasses`. A still-class (0) or
    /// unknown-class (nil) delta is real counter movement (a turn-over jostles the accelerometer too) but
    /// is deliberately NOT counted as locomotion; it still shows up in `postureVariance` instead. Minutes
    /// with no qualifying tick are simply absent from the result (callers read `?? 0`).
    static func walkClassTicksPerMinute(_ steps: [StepSample]) -> [Int: Int] {
        let sorted = steps.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [:] }
        var out: [Int: Int] = [:]
        for i in 1..<sorted.count {
            let cur = sorted[i]
            guard let cls = cur.activityClass, locomotionActivityClasses.contains(cls) else { continue }
            let delta = (cur.counter - sorted[i - 1].counter) & 0xFFFF   // wrap-aware u16 increment
            out[cur.ts / 60, default: 0] += delta
        }
        return out
    }

    // MARK: - Small shared helpers

    /// The wall-clock minute indices (unix seconds / 60) tiling `[start, end)`. Empty for a degenerate
    /// (empty or inverted) window.
    static func minutes(from start: Int, to end: Int) -> [Int] {
        guard end > start else { return [] }
        let first = start / 60
        let last = (end - 1) / 60
        guard last >= first else { return [] }
        return Array(first...last)
    }

    static func bucketByMinute<T>(_ samples: [T], ts: (T) -> Int) -> [Int: [T]] {
        var out: [Int: [T]] = [:]
        for s in samples { out[ts(s) / 60, default: []].append(s) }
        return out
    }

    /// Append `piece`, merging into the previous element when the stage matches AND the two are
    /// time-contiguous (defensive: every caller here produces pieces in strict chronological order with
    /// no gaps, so this is always a merge when the stage repeats).
    static func appendMerging(_ piece: StageSegment, into out: inout [StageSegment]) {
        if let lastIdx = out.indices.last, out[lastIdx].stage == piece.stage, out[lastIdx].end == piece.start {
            out[lastIdx].end = piece.end
        } else {
            out.append(piece)
        }
    }
}
