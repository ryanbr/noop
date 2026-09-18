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
/// #2322 extends that from the same strap to the same ARM. `alarm.lastReportedEpoch` is written ONLY when
/// the readback frame decodes; the decode-failure branch logs raw hex and leaves the old value standing.
/// So an arm whose readback never decoded leaves a FRESH sent epoch beside a STALE reported one, and the
/// export then prints a confident "strap didn't accept the time" assembled from two different arms.
/// Decode failures are not hypothetical: the strap log attached to issue #2302 carries one on a
/// neighbouring frame, which is where this was noticed. That issue is about HRV, not alarms.
///
/// The arrival times were already persisted for both halves (`alarm.lastArmAt`, `alarm.lastReportedAt`) and
/// simply were not consulted; comparing them is the whole guard.
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
        /// The readback on hand is OLDER than the arm it is being compared against, so it answered an
        /// EARLIER arm. Same strap, but not the same question, and nothing can be concluded.
        case staleReadback
    }

    /// `sentAt` and `reportedAt` are WALL-CLOCK arrival stamps for the two halves, in whatever unit this
    /// platform's store already holds (Apple: `Date().timeIntervalSince1970`). Only their ORDER is read,
    /// never their difference, so the unit does not have to match the Kotlin twin's; both sides compare
    /// two stamps taken from their OWN clock. `nil` on either means "not recorded" (an install that
    /// predates the keys), and staleness is then not judged rather than guessed.
    public static func verdict(
        sentEpoch: Int,
        reportedEpoch: Int,
        sentDeviceId: String?,
        reportedDeviceId: String?,
        // Ordered to match the Kotlin twin, where `toleranceS` has to keep its historical position
        // because Kotlin permits positional calls. Labels make the order harmless here; matching it
        // keeps the two signatures readable side by side.
        toleranceS: Int = AlarmReadback.toleranceS,
        sentAt: Double? = nil,
        reportedAt: Double? = nil
    ) -> Verdict {
        guard let sentDeviceId, !sentDeviceId.isEmpty,
              let reportedDeviceId, !reportedDeviceId.isEmpty else { return .unattributed }
        guard sentDeviceId == reportedDeviceId else { return .differentStrap }
        // Ordered AFTER attribution on purpose: a cross-strap pair is unusable whether or not it is also
        // stale, and naming the strap problem first sends the reader to the real one.
        if let sentAt, let reportedAt, sentAt > 0, reportedAt > 0, reportedAt < sentAt {
            return .staleReadback
        }
        return abs(reportedEpoch - sentEpoch) > toleranceS ? .mismatch : .matches
    }

    /// The suffix the debug export appends after the reported time. Byte-identical to the Kotlin twin.
    public static func suffix(_ verdict: Verdict) -> String {
        switch verdict {
        case .matches: return "  ✓ matches"
        case .mismatch: return "  ⚠️ MISMATCH — strap didn't accept the time"
        case .differentStrap: return "  (readback is from a different strap — not comparable)"
        case .unattributed: return "  (no strap recorded for one of these — not comparable)"
        case .staleReadback: return "  (readback predates this arm — not comparable)"
        }
    }

    /// Whether this verdict may advance the consecutive-rejection streak. Only a proven same-strap,
    /// same-arm disagreement counts: an unattributed, cross-strap or stale reading must leave the streak
    /// untouched rather than reset it, since none of the three is evidence either way.
    public static func countsAsRejection(_ verdict: Verdict) -> Bool { verdict == .mismatch }

    /// Whether this verdict is evidence the strap DID accept, which clears the streak.
    public static func clearsRejectionStreak(_ verdict: Verdict) -> Bool { verdict == .matches }
}
