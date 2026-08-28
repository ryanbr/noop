import Foundation

/// Whether the alarm time a strap reports back can be compared with the one we sent (#1706).
///
/// The two halves are persisted under flat, device-less keys — `alarm.lastArmSentEpoch` and
/// `alarm.lastReportedEpoch`. On an install with more than one strap registered they can therefore
/// describe DIFFERENT devices, and comparing them then produces a confident "strap didn't accept the
/// time" about a strap that was never asked. On Android the readback is written only on the WHOOP 4.0
/// path, so a 5.0-active install could only ever be comparing across straps.
///
/// That verdict is not cosmetic here: it also drives `alarm.rejectStreak`, which raises a warning in
/// SmartAlarmView at two. A cross-strap comparison could climb that streak forever.
///
/// So attribution is required, not assumed: unless both halves are known to come from the same strap,
/// this refuses to judge. Refusing is the same stance `WindowedStreamPlan` takes — a diagnosis that
/// cannot be proven is worse than none, because it sends the reader after the wrong device.
///
/// Twin of Kotlin `AlarmReadback`.
public enum AlarmReadback {

    /// Seconds of slack allowed between what we armed and what the strap reports back.
    public static let toleranceS = 120

    public enum Verdict: Equatable {
        /// Same strap, and the readback agrees within `toleranceS`.
        case matches
        /// Same strap, and it does not. This is the only value that means the strap refused.
        case mismatch
        /// The two halves came from different straps. Nothing can be concluded about either.
        case differentStrap
        /// One or both halves predate device attribution, so they cannot be tied to a strap.
        case unattributed
    }

    public static func verdict(
        sentEpoch: Int,
        reportedEpoch: Int,
        sentDeviceId: String?,
        reportedDeviceId: String?,
        toleranceS: Int = AlarmReadback.toleranceS
    ) -> Verdict {
        guard let sentDeviceId, !sentDeviceId.isEmpty,
              let reportedDeviceId, !reportedDeviceId.isEmpty else { return .unattributed }
        guard sentDeviceId == reportedDeviceId else { return .differentStrap }
        return abs(reportedEpoch - sentEpoch) > toleranceS ? .mismatch : .matches
    }

    /// The suffix the debug export appends after the reported time. Byte-identical to the Kotlin twin.
    public static func suffix(_ verdict: Verdict) -> String {
        switch verdict {
        case .matches: return "  ✓ matches"
        case .mismatch: return "  ⚠️ MISMATCH — strap didn't accept the time"
        case .differentStrap: return "  (readback is from a different strap — not comparable)"
        case .unattributed: return "  (no strap recorded for one of these — not comparable)"
        }
    }

    /// Whether this verdict may advance the consecutive-rejection streak. Only a proven same-strap
    /// disagreement counts: an unattributed or cross-strap reading must leave the streak untouched
    /// rather than reset it, since neither is evidence either way.
    public static func countsAsRejection(_ verdict: Verdict) -> Bool { verdict == .mismatch }

    /// Whether this verdict is evidence the strap DID accept, which clears the streak.
    public static func clearsRejectionStreak(_ verdict: Verdict) -> Bool { verdict == .matches }
}
