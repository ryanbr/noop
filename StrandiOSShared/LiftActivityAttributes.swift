#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for a running Lift Log session — the minimised session bar, on the Lock
/// Screen and in the Dynamic Island.
///
/// Deliberately a SEPARATE activity type from `NOOPActivityAttributes` (live HR). They answer
/// different questions and have different lifetimes: the HR activity lives as long as the strap is
/// streaming, this one as long as a gym session is open. While a session is running this one is the
/// useful surface — it carries the heart rate too — so the app suppresses the HR activity rather
/// than stacking two banners on the Lock Screen.
///
/// TIME IS CARRIED AS DATES, NOT AS A FORMATTED STRING. The widget renders them with
/// `Text(timerInterval:)`, which ticks on its own without the app pushing anything. Pushing a new
/// content state every second to animate a clock would burn the Live Activity update budget and
/// still look worse.
public struct LiftActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Amber rest vs green working — the same colour language as the sheet and the bar.
        public var isResting: Bool
        /// The exercise being worked, or rested from.
        public var exercise: String
        /// "Set 2" / "Resting after set 2" — resolved app-side so the wording matches the bar.
        public var status: String
        /// "8 x 30 kg", already unit-converted, because the unit preference lives in the app.
        /// Nil when neither reps nor weight is known.
        public var detail: String?
        public var bpm: Int?
        /// "Next: Set 3 · Bench press", localized APP-SIDE (`LiftSessionController.nextLine`). The widget
        /// extension ships no string catalog, so every word it renders has to arrive already translated
        /// — the same reason `status` and `detail` are strings rather than numbers.
        public var next: String
        /// When the current stage began — the widget counts UP from here while working.
        public var stageStartedAt: Date
        /// When the running rest is due to end; the widget counts DOWN to it. Nil while working.
        public var restEndsAt: Date?

        public init(isResting: Bool, exercise: String, status: String, detail: String?,
                    bpm: Int?, next: String,
                    stageStartedAt: Date, restEndsAt: Date?) {
            self.isResting = isResting
            self.exercise = exercise
            self.status = status
            self.detail = detail
            self.bpm = bpm
            self.next = next
            self.stageStartedAt = stageStartedAt
            self.restEndsAt = restEndsAt
        }
    }

    /// Nothing is fixed for the life of a session: everything the banner shows can change mid-session and
    /// travels in `ContentState`.
    public init() {}
}
#endif
