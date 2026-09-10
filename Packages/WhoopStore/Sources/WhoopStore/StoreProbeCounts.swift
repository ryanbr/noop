import Foundation

/// Per-pass call/time counters for the per-day lookups `analyzeRecent` makes, rendered by
/// `StrandAnalytics.StoreProbeTally`. Twin of the Kotlin `StoreProbeTally` counters.
///
/// Counted one level down from the call sites, which is what makes the counts attribute themselves:
/// counting at the call sites would mean threading an accumulator through a `nonisolated static` resolver
/// and a detached task, and on Android through a method with no ratchet margin to spend.
///
/// Drained per pass, which is exact for `gravityFingerprint` (the steps loop is its only caller) but NOT
/// quite for the other two: `IntelligenceEngine.resolveDayOwner` has a second Swift caller in
/// `SkinTempBackfillWalker`, a manual Test Centre action. Run it while a scoring pass is in flight and its
/// lookups and presence probes land in that pass's line. The Kotlin twin's resolver is private to the
/// engine, so this is one-sided as well as imprecise.
///
/// Left as-is deliberately: suppressing it would have to reach through the resolver into the store's own
/// probe, and a global "stop counting" switch would UNDERCOUNT a genuine concurrent pass, which is the
/// worse failure. The CALL COUNT is the tell instead, which is why it prints beside the time. A clean pass
/// over a 21-day scoring window and a 60-day steps window resolves 81 owners; a line reporting many more
/// than that had company, and should be read as contaminated rather than as a slow lookup.
///
/// Instrumentation only: nothing reads these but the diagnostic line.
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

    /// `DeviceRegistryStore.dayOwner` — the resolver's LOCKED-override lookup, which runs on every call
    /// before any presence probe. Measured because the first cut of this instrumentation counted the probe
    /// and not the lookup in front of it, so it reported the cheap half of owner resolution while a warm
    /// pass still had seconds unaccounted for.
    public var dayOwner = Probe()
    /// `hasHrInWindow` — the day-owner resolver's per-candidate presence probe, in BOTH the scoring loop
    /// and the sixty-day steps loop. Skipped entirely on a default single-strap install (#970).
    public var ownerHr = Probe()
    /// `gravityFingerprint` — the steps loop's per-day motion witness. Steps-only.
    public var gravityFp = Probe()

    public init() {}
}

/// Process-wide recorder for `StoreProbeCounts`.
///
/// Nonisolated and lock-guarded rather than actor state, because the three call sites cannot share one
/// isolation: `gravityFingerprint` and `hasHrInWindow` are `WhoopStore` actor methods, while the day-owner
/// lookup runs inside `IntelligenceEngine.resolveDayOwner`, which is `nonisolated static` precisely so the
/// day loop does not hop back to the main actor on every iteration. A recorder only the actor could reach
/// would have measured two of the three and left the third invisible, which is the exact gap this round of
/// instrumentation exists to close. It also makes the shape identical to the Kotlin twin's `object` of
/// atomics rather than merely equivalent.
public enum StoreProbeRecorder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = StoreProbeCounts()

    /// Which probe a measurement belongs to.
    public enum Probe: Sendable { case dayOwner, ownerHr, gravityFp }

    /// Record one call. `elapsed` must come from a monotonic source.
    public static func record(_ probe: Probe, nanos elapsed: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        switch probe {
        case .dayOwner: counts.dayOwner.record(nanos: elapsed)
        case .ownerHr: counts.ownerHr.record(nanos: elapsed)
        case .gravityFp: counts.gravityFp.record(nanos: elapsed)
        }
    }

    /// Read the counters and zero them, so a line describes ONE pass and never accumulates across the
    /// back-to-back passes an offload storm is made of.
    public static func take() -> StoreProbeCounts {
        lock.lock()
        defer { lock.unlock() }
        let taken = counts
        counts = StoreProbeCounts()
        return taken
    }
}
