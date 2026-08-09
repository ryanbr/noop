import Foundation

/// #1169: an alternative headline resting-HR definition — the arithmetic MEAN of valid HR samples in the
/// LONGEST (primary) sleep session, rather than the lowest-per-session floor `AnalyticsEngine` ships today.
///
/// ## Why (issue #1169, artemc)
/// The shipped daily RHR is `restingHRDaily = matched…restingHR.min()` (`AnalyticsEngine`) — a nightly HR
/// FLOOR, and the `.min()` lets a short low-HR nap replace the main overnight session. A clean-room,
/// single-participant 5-night experiment (official WHOOP RHR + a Polar H10 ECG mean as independent
/// references, a pre-declared dev/holdout split, no fitted offset) found the primary-session sample mean
/// tracked both references far better: rounded MAE vs the official target 6.0→2.0 (dev) / 7.5→0.8 (holdout).
///
/// ## Deliberately PURE and UNWIRED
/// This computes the metric and is unit-tested, but **nothing consumes it yet**. The shipped headline AND the
/// recovery / strain / workout-detection / energy inputs all read `restingHRDaily` (the floor) in
/// `AnalyticsEngine`, so switching them is a re-baselining of core scores — which the issue itself says needs
/// a larger multi-participant, pre-declared holdout first. That is out of scope here; this lands the
/// transparent, testable definition so that validation and any later wiring have something concrete to use.
///
/// ## Definition (documented per the issue)
/// - **Primary session**: the LONGEST session by duration; ties resolve to the FIRST (stable). A shorter nap
///   never replaces the main night — this is the half the shipped `.min()` gets wrong.
/// - **Valid sample**: bpm within `validBpm` (default 30…220, matching `AnalyticsEngine`'s worn-HR range).
///   Anything outside the range — or a missing sample (simply absent from the array) — is excluded.
/// - **Mean**: the arithmetic SAMPLE mean (unweighted). The experiment validated the sample mean; a
///   time-weighted variant behaves differently under irregular cadence and must be evaluated separately.
/// - **Coverage**: returns `nil` unless the primary session has at least `minValidSamples` valid samples.
/// - The result is an APPROXIMATION, not a clinically validated measurement.
///
/// Twin of Kotlin `PrimarySessionRestingHR`. Keep byte-identical.
public enum PrimarySessionRestingHR {

    /// One sleep session for a wake day: its duration and its raw (possibly-invalid) HR samples in bpm.
    /// Wake-day assignment and session building stay in the caller (`AnalyticsEngine`); this type is the
    /// minimal input the pure metric needs, so it is testable with no engine, DB, or clock.
    public struct Session: Sendable, Equatable {
        public let durationSec: Double
        public let bpm: [Int]
        public init(durationSec: Double, bpm: [Int]) {
            self.durationSec = durationSec
            self.bpm = bpm
        }
    }

    /// The worn-HR range `AnalyticsEngine` uses when deciding a sample is real; reused so validity is one rule.
    public static let defaultValidBpm: ClosedRange<Int> = 30...220
    /// Provisional minimum valid-sample coverage before a value is returned. A sample count is cadence-blind;
    /// the exact rule is a tuning parameter for the multi-participant validation the issue calls for.
    public static let defaultMinValidSamples = 30

    /// Mean valid HR of the LONGEST session, or `nil` when no session clears `minValidSamples` valid samples.
    public static func meanHR(sessions: [Session],
                              validBpm: ClosedRange<Int> = defaultValidBpm,
                              minValidSamples: Int = defaultMinValidSamples) -> Double? {
        // Primary = longest by duration. `max(by:)` keeps the FIRST of equal-duration sessions (only a
        // strictly-longer one replaces it); Kotlin `maxByOrNull` resolves ties the same way, so parity holds.
        guard let primary = sessions.max(by: { $0.durationSec < $1.durationSec }) else { return nil }
        let valid = primary.bpm.filter { validBpm.contains($0) }
        guard valid.count >= minValidSamples else { return nil }
        return Double(valid.reduce(0, +)) / Double(valid.count)
    }
}
