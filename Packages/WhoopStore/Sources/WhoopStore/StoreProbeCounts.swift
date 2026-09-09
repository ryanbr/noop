import Dispatch
import Foundation

/// Per-pass call/time counters for the two per-day PROBE reads, rendered by
/// `StrandAnalytics.StoreProbeTally`. Twin of the Kotlin `StoreProbeTally` counters.
///
/// Lives on the store because that is where each probe has exactly ONE call site, which is what makes the
/// counts attribute themselves: `hasHrInWindow` is only ever the day-owner resolver's presence probe and
/// `gravityFingerprint` only ever the steps loop's per-day motion witness. Counting at the call sites
/// instead would mean threading an accumulator through a `nonisolated static` resolver and a detached task,
/// and on Android through a method with no ratchet margin to spend.
///
/// Actor-isolated by living on `WhoopStore`, so no lock and no `Sendable` gymnastics. Instrumentation only:
/// nothing reads these but the diagnostic line.
public struct StoreProbeCounts: Sendable, Equatable {
    /// One probe's calls and accumulated time.
    public struct Probe: Sendable, Equatable {
        public private(set) var calls = 0

        /// Accumulated INTEGER nanoseconds, divided to seconds once when read rather than per call.
        ///
        /// The Kotlin twin sums `System.nanoTime()` deltas into an `AtomicLong` and divides once at render.
        /// Converting each call to `Double` seconds instead would spend sixty to eighty roundings where the
        /// twin spends none, and the two would then disagree in the last bits — which survives into the
        /// rendered line whenever the true total sits near a half-millisecond boundary, the exact boundary
        /// `StoreProbeTallyTests` pins. Integer accumulation makes the two provably the same arithmetic.
        public private(set) var nanos: UInt64 = 0

        /// Accumulated seconds, for the renderer. One division, matching the twin.
        public var seconds: Double { Double(nanos) / 1_000_000_000 }

        /// Add one call of `nanos` monotonic nanoseconds.
        ///
        /// Nanoseconds from a MONOTONIC source, not a `Date()` difference, and that is the whole point of
        /// the type. These counters exist to decide whether the per-day round trips are worth batching, so
        /// a number that a clock correction can move is worse than no number: `Date()` steps in BOTH
        /// directions, and while a backwards step is clamped away, a forward NTP jump mid-probe would
        /// silently add itself to that probe's time and inflate the very total the decision reads. The
        /// Kotlin twin counts `System.nanoTime()` for the same reason, so the two measure the same thing.
        mutating func record(nanos elapsed: UInt64) {
            calls += 1
            nanos &+= elapsed
        }
    }

    /// `hasHrInWindow` — the day-owner resolver's per-candidate presence probe, in BOTH the scoring loop
    /// and the sixty-day steps loop. Skipped entirely on a default single-strap install (#970).
    public var ownerHr = Probe()
    /// `gravityFingerprint` — the steps loop's per-day motion witness. Steps-only.
    public var gravityFp = Probe()

    public init() {}
}

public extension WhoopStore {
    /// Read the counters and zero them, so a line describes ONE pass and never accumulates across the
    /// back-to-back passes an offload storm is made of.
    func takeProbeCounts() -> StoreProbeCounts {
        let counts = probeCounts
        probeCounts = StoreProbeCounts()
        return counts
    }
}
