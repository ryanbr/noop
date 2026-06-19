import Foundation

// HRDownPacer.swift — the L2 "buzz-below-heart-rate" relaxation metronome. Give the heart a felt rhythm a
// few bpm BELOW its current rate; HR tends to drift toward an external rhythmic cue (ISWC 2025). PURE +
// unit-tested; the live controller reads smoothed HR off `AppModel.bpm`, calls `next(...)`, fires ONE
// light buzz per returned interval, and re-asks every recompute window. No I/O / BLE here.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L2).
//
// SAFETY ENVELOPE (a relaxation metronome, NOT cardiac control — bounded, never therapeutic):
//   • Target tempo T = smoothedHR − Δ, where Δ RAMPS from `startDeltaBpm` to `maxDeltaBpm` over the
//     session so the cue trails the heart down rather than yanking it.
//   • T never drops below `hrFloorBpm` (a safe rate) and never more than `maxDeltaBpm` below live HR.
//   • The cue TRAILS the heart: T is recomputed every `recomputeSeconds` from the new smoothed HR, so it
//     follows HR down instead of dragging it.
//   • Auto-stops when HR settles near a calm target, on timeout (`maxDurationSeconds`), or on user stop.
//   • If HR DIDN'T fall, the caller says so plainly — no fabricated success (project evidence-first rule).
//
// We never claim it "lowers your heart rate" as a therapeutic outcome — it offers a rhythm to relax toward.

public enum HRDownPacer {

    // MARK: - Config

    /// The L2 safety + behaviour envelope. Defaults are conservative (spec §L2 / Open Q4); the caller may
    /// expose a subset. All bpm values are beats/min; durations are seconds.
    public struct Config: Equatable, Sendable {
        /// Initial Δ below live HR at session start (gentle).
        public var startDeltaBpm: Double
        /// Maximum Δ below live HR (a felt cue, never a shock).
        public var maxDeltaBpm: Double
        /// Seconds over which Δ ramps from start → max.
        public var deltaRampSeconds: Double
        /// Absolute floor for the target tempo — never pace below this rate.
        public var hrFloorBpm: Double
        /// Recompute the target every this-many seconds from fresh smoothed HR (the cue trails the heart).
        public var recomputeSeconds: Double
        /// Stop once smoothed HR is at/under this calm target (the session has done its job).
        public var calmTargetBpm: Double
        /// Hard cap on session length.
        public var maxDurationSeconds: Double

        public init(startDeltaBpm: Double = 3.0,
                    maxDeltaBpm: Double = 8.0,
                    deltaRampSeconds: Double = 120.0,
                    hrFloorBpm: Double = 50.0,
                    recomputeSeconds: Double = 15.0,
                    calmTargetBpm: Double = 60.0,
                    maxDurationSeconds: Double = 180.0) {
            self.startDeltaBpm = startDeltaBpm
            self.maxDeltaBpm = maxDeltaBpm
            self.deltaRampSeconds = deltaRampSeconds
            self.hrFloorBpm = hrFloorBpm
            self.recomputeSeconds = recomputeSeconds
            self.calmTargetBpm = calmTargetBpm
            self.maxDurationSeconds = maxDurationSeconds
        }

        /// The conservative shipped default envelope.
        public static let `default` = Config()
    }

    // MARK: - Step output

    /// The next step the metronome should take: either fire a pulse at `intervalMs` (one light buzz per
    /// target beat), or `stop` with a reason. When `stop`, `intervalMs` is nil. `targetBpm` is the tempo
    /// the controller settled on this step (for the live "78 → settling" UI / logs).
    public struct Step: Equatable, Sendable {
        /// Inter-pulse interval in ms (60000 / targetBpm), or nil when stopping.
        public let intervalMs: Int?
        /// True when the session should end now.
        public let stop: Bool
        /// The target tempo (bpm) chosen this step, or nil when stopping with no tempo.
        public let targetBpm: Double?
        /// Why we stopped (nil while running) — for an honest outcome line.
        public let stopReason: StopReason?

        public init(intervalMs: Int?, stop: Bool, targetBpm: Double?, stopReason: StopReason?) {
            self.intervalMs = intervalMs; self.stop = stop
            self.targetBpm = targetBpm; self.stopReason = stopReason
        }
    }

    /// Why an L2 session ended — drives the honest outcome copy.
    public enum StopReason: String, Equatable, Sendable {
        /// HR reached the calm target — the session did its job.
        case settled
        /// The max-duration cap was hit.
        case timeout
        /// Live HR was implausible / out of the resting band (caller should gate before starting).
        case invalidHR
    }

    // MARK: - Controller

    /// Compute the next metronome step from the current smoothed HR and the elapsed session time.
    ///
    /// - `currentHR`: latest SMOOTHED live HR (bpm). The caller smooths; the pacer trusts it.
    /// - `elapsed`: seconds since session start (drives both the Δ ramp and the timeout).
    ///
    /// Returns a `Step`: while running, `intervalMs` paces one light pulse per target beat at a tempo
    /// `currentHR − Δ(elapsed)`, BOUNDED below by `hrFloorBpm` and by `currentHR − maxDeltaBpm`. Stops
    /// (settled / timeout / invalidHR). Pure + monotone in the documented sense: for a given config a
    /// non-increasing HR trajectory yields non-increasing target tempos, so the cue only ever trails down.
    public static func next(currentHR: Double, elapsed: Double, config: Config = .default) -> Step {
        // Implausible HR (caller should gate on the resting band; this is the last-ditch guard).
        guard currentHR.isFinite, currentHR > 0 else {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .invalidHR)
        }
        if elapsed >= config.maxDurationSeconds {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .timeout)
        }
        if currentHR <= config.calmTargetBpm {
            return Step(intervalMs: nil, stop: true, targetBpm: nil, stopReason: .settled)
        }

        // Δ ramps linearly start → max over `deltaRampSeconds`, then holds at max.
        let delta = rampedDelta(elapsed: elapsed, config: config)

        // Target = HR − Δ, but never below the floor and never below the calm target either (we'd have
        // stopped). Clamp also guarantees we never pace *above* HR.
        var target = currentHR - delta
        if target < config.hrFloorBpm { target = config.hrFloorBpm }
        if target > currentHR { target = currentHR }   // defensive: never pace at/above live HR
        // Keep the cue meaningfully below the heart: at least 1 bpm under, so it's a "below-HR" metronome.
        if target > currentHR - 1.0 { target = max(config.hrFloorBpm, currentHR - 1.0) }

        let intervalMs = Int((60_000.0 / target).rounded())
        return Step(intervalMs: intervalMs, stop: false, targetBpm: target, stopReason: nil)
    }

    /// The Δ-below-HR for a given elapsed time: linear ramp `startDeltaBpm → maxDeltaBpm` over
    /// `deltaRampSeconds`, clamped to `maxDeltaBpm` after. Exposed for tests / the UI ramp readout.
    public static func rampedDelta(elapsed: Double, config: Config = .default) -> Double {
        guard config.deltaRampSeconds > 0 else { return config.maxDeltaBpm }
        let t = min(max(elapsed, 0), config.deltaRampSeconds) / config.deltaRampSeconds
        return config.startDeltaBpm + (config.maxDeltaBpm - config.startDeltaBpm) * t
    }
}
