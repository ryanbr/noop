import Foundation

// BreathPacer.swift — turn a breathing pace into a deterministic inhale/exhale haptic cue list you can
// "feel" with your eyes closed, screen-off. PURE + unit-tested; the BLE layer maps each `BreathCue` onto
// the strap's actual haptic command (`AppModel.buzz(loops:)` / `send(.runHapticsPattern)`) and schedules
// the gaps with the proven `HapticClock` asyncAfter walk. No I/O here.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L1 "Act (the pacer)").
//
// Felt language (identical to the shipped Breathe screen, so existing users already know it):
//   • Inhale onset → ONE light pulse  (loops: 1)
//   • Exhale onset → TWO pulses       (loops: 2)
// Each WHOOP notification buzz is a FIXED-LENGTH motor pulse — we can't vary on-time per pulse, only the
// *count* (stacked loops) and the *timing*. So the cue is encoded purely as "fire N loops at offset T".
//
// A breath cycle of `bpm` breaths/min lasts 60000/bpm ms; `inhaleFraction` splits it into inhale vs
// exhale (the calming long-exhale ratio Breathe's "Relax" preset uses is ~0.4 inhale : 0.6 exhale).
// Mirrors `HapticClockEncoder.pulses` in shape: a pure `(params) -> [Cue]` list, walkable by the BLE seam.

/// Which phase of the breath a cue marks. The on-screen orb (when the screen is on) is driven by the
/// same phase clock; screen-off, the buzz is the whole cue.
public enum BreathPhase: String, Equatable, Sendable {
    /// The start of an inhale — a single light pulse.
    case inhale
    /// The start of an exhale — a heavier (two-pulse) cue.
    case exhale
}

/// One element of a paced-breathing haptic schedule: fire `loops` buzz loops at `offsetMs` from session
/// start, marking the onset of `phase`. The BLE layer schedules the wait then calls the proven buzz.
public struct BreathCue: Equatable, Sendable {
    /// Milliseconds from the start of the session at which to fire this cue.
    public let offsetMs: Int
    /// Which breath phase this cue marks (inhale = light, exhale = heavy).
    public let phase: BreathPhase
    /// How many buzz loops to play — the felt-strength language (1 = inhale, 2 = exhale).
    public let loops: Int

    public init(offsetMs: Int, phase: BreathPhase, loops: Int) {
        self.offsetMs = offsetMs
        self.phase = phase
        self.loops = loops
    }
}

public enum BreathPacer {

    // MARK: - Tunables (Breathe parity)

    /// Loops for an inhale onset — one light pulse, as Breathe fires today.
    public static let inhaleLoops: Int = 1
    /// Loops for an exhale onset — two pulses (heavier), as Breathe fires today.
    public static let exhaleLoops: Int = 2
    /// Default inhale fraction of the cycle — the calming long-exhale ratio (≈40:60) the "Relax" preset
    /// uses. Exhale gets the remaining 0.6.
    public static let defaultInhaleFraction: Double = 0.4
    /// Slowest / fastest paces we ever schedule (the resonance sweep band, 4.5–7 br/min). Out-of-range
    /// `bpm` is clamped so the pacer never traps or emits absurd offsets.
    public static let minBpm: Double = 3.0
    public static let maxBpm: Double = 12.0

    // MARK: - Pacer

    /// Build the haptic cue list for `cycles` full breaths at `bpm` breaths/min, splitting each cycle into
    /// inhale (`inhaleFraction`) and exhale (the remainder). One inhale cue + one exhale cue per cycle, in
    /// time order. Pure: identical inputs → identical list (the `HapticClock` precedent).
    ///
    /// `bpm` is clamped to [minBpm, maxBpm] and `inhaleFraction` to a safe (0.1…0.9) interior so each
    /// phase always carries some duration. `cycles` below 1 yields an empty schedule.
    public static func schedule(bpm: Double,
                                inhaleFraction: Double = defaultInhaleFraction,
                                cycles: Int) -> [BreathCue] {
        guard cycles >= 1 else { return [] }
        let safeBpm = min(max(bpm, minBpm), maxBpm)
        let frac = min(max(inhaleFraction, 0.1), 0.9)

        // Cycle length in ms; integer so offsets are exact and platform-identical (no float drift).
        let cycleMs = Int((60_000.0 / safeBpm).rounded())
        let inhaleMs = Int((Double(cycleMs) * frac).rounded())

        var out: [BreathCue] = []
        out.reserveCapacity(cycles * 2)
        for c in 0..<cycles {
            let base = c * cycleMs
            out.append(BreathCue(offsetMs: base, phase: .inhale, loops: inhaleLoops))
            out.append(BreathCue(offsetMs: base + inhaleMs, phase: .exhale, loops: exhaleLoops))
        }
        return out
    }

    /// Total scheduled duration (ms) of a `cycles`-breath session at `bpm` — `cycles` whole cycles. Handy
    /// for the keep-awake / session-length UI without re-deriving the cycle math.
    public static func sessionDurationMs(bpm: Double, cycles: Int) -> Int {
        guard cycles >= 1 else { return 0 }
        let safeBpm = min(max(bpm, minBpm), maxBpm)
        let cycleMs = Int((60_000.0 / safeBpm).rounded())
        return cycleMs * cycles
    }
}
