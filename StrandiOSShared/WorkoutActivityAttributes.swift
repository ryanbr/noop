#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for a live-tracked workout (a run, ride, walk, or any sport started from the
/// workout picker) — elapsed time, GPS distance, pace and heart rate, on the Lock Screen and in the Dynamic Island.
///
/// Deliberately a SEPARATE activity type from `NOOPActivityAttributes` (live HR) and `LiftActivityAttributes`
/// (Lift Log), with its own switch: it lives exactly as long as the workout, and a person can keep it while the
/// everyday heart-rate banner is off. While it shows, it carries the heart rate itself, so the live-HR banner
/// stands aside for it, as it does for the Lift Log banner.
///
/// Everything the widget prints arrives as text resolved APP-SIDE: the widget extension ships no string catalog
/// and has no unit preference, so labels are localized and distance / pace are unit-formatted in the app.
/// Time travels as a date, rendered with `Text(_:style: .timer)`, so the clock ticks on the Lock Screen without
/// the app pushing anything.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Live heart rate; nil while the strap is not connected or has not reported one.
        public var bpm: Int?
        /// The workout start shifted by the time spent paused, so the widget's timer counts up ACTIVE time.
        /// Constant while running; it moves only on a resume.
        public var timerStart: Date
        /// Whole seconds of active time while paused (nil while running): the widget shows it frozen.
        public var pausedElapsed: Int?
        /// Formatted GPS distance ("3.2 km"); nil before the first accepted fix.
        public var distance: String?
        /// Formatted average pace ("5:12 /km"); nil while undefined.
        public var pace: String?

        public init(bpm: Int?, timerStart: Date, pausedElapsed: Int?, distance: String?, pace: String?) {
            self.bpm = bpm
            self.timerStart = timerStart
            self.pausedElapsed = pausedElapsed
            self.distance = distance
            self.pace = pace
        }
    }

    /// The catalogue sport name ("Running"), verbatim: sport names are stored data and never localized.
    public var sport: String
    /// Whether this workout records a GPS route. Without one the banner shows no distance / pace columns at all,
    /// rather than dashes that would never fill in.
    public var tracksRoute: Bool
    /// Column labels and the pause tag, localized app-side (see the type comment).
    public var durationLabel: String
    public var distanceLabel: String
    public var paceLabel: String
    public var pausedLabel: String

    public init(sport: String, tracksRoute: Bool, durationLabel: String, distanceLabel: String,
                paceLabel: String, pausedLabel: String) {
        self.sport = sport
        self.tracksRoute = tracksRoute
        self.durationLabel = durationLabel
        self.distanceLabel = distanceLabel
        self.paceLabel = paceLabel
        self.pausedLabel = pausedLabel
    }
}
#endif
