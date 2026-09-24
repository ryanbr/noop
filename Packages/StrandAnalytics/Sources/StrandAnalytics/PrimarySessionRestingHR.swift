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
/// ## WIRED as of #2358 — this sets the shipped daily resting HR
/// It was landed pure and unwired, on the reasoning that switching the consumers is a re-baselining of core
/// scores and that the issue asks for a larger multi-participant holdout first. #2358 made the switch anyway,
/// as a maintainer call: `AnalyticsEngine.restingHRDaily` now prefers a device-provided primary-session value,
/// then THIS mean, and falls back to the old `restingHR.min()` floor only when coverage is sparse. So the
/// headline resting HR and everything reading it — recovery, strain, workout detection, energy — come from
/// here on any day with a covered primary session.
///
/// What that means for the evidence below: the MAE figures are from ONE participant over five nights against
/// a pre-declared split, which is the holdout the issue says is not yet large enough. They justified building
/// the metric; they are thinner than the change they now carry. #2284 separately replaces what a session's
/// `restingHR` IS (deep-sleep mean rather than lowest 5-minute bin), which moves the `.min()` fallback under
/// this, so the comparison baseline those numbers were measured against no longer exists unchanged.
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

    /// #1169 coverage INPUTS for the same primary session `meanHR` averages: its valid-sample count and its
    /// duration. The fixed `minValidSamples` gate is cadence-blind, so the accruing shadow dataset needs to
    /// weight/filter each night's mean by how well-covered it was — but this deliberately records the raw
    /// inputs, NOT a derived coverage fraction, so the later multi-participant holdout can pick its own
    /// coverage definition rather than inheriting one. Same longest-session selection + gate as `meanHR`
    /// (returns `nil` in lockstep with it), so the mean and its coverage are always emitted together. Still
    /// pure + unwired — shadow instrumentation only. Twin of Kotlin `PrimarySessionRestingHR.coverage`.
    public struct Coverage: Sendable, Equatable {
        /// Valid HR samples in the primary session (the count the `minValidSamples` gate saw).
        public let validSamples: Int
        /// The primary (longest) session's duration in seconds.
        public let durationSec: Double
        public init(validSamples: Int, durationSec: Double) {
            self.validSamples = validSamples
            self.durationSec = durationSec
        }
    }

    /// The primary session's valid-sample count + duration, or `nil` in lockstep with `meanHR` (no session
    /// clears `minValidSamples`). Selection + gate mirror `meanHR` exactly.
    public static func coverage(sessions: [Session],
                                validBpm: ClosedRange<Int> = defaultValidBpm,
                                minValidSamples: Int = defaultMinValidSamples) -> Coverage? {
        guard let primary = sessions.max(by: { $0.durationSec < $1.durationSec }) else { return nil }
        let valid = primary.bpm.filter { validBpm.contains($0) }
        guard valid.count >= minValidSamples else { return nil }
        return Coverage(validSamples: valid.count, durationSec: primary.durationSec)
    }
}
