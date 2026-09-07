import Foundation

/// How the Sleep hero names the night it is showing.
///
/// Extracted from `SleepView` so it can be tested. The Kotlin twin has lived in `SleepHeroLogic.kt`
/// as a pure function with its own suite from the start; the Swift side kept it private inside the
/// view, which is why a defect here went uncaught on this platform until a report arrived. This
/// package's tests run in ordinary CI, unlike the app-target bundle, so the logic is verified on
/// every change rather than only when the on-demand app build is dispatched.
///
/// Kotlin twin: `calendarNightsAgo` / `nightRelativeLabel`.
public enum SleepNightLabel {

    /// The relative name for a night [offset] positions back in the carousel.
    ///
    /// Kotlin twin: `nightRelativeLabel`.
    public static func relative(_ nightsAgo: Int) -> String {
        switch nightsAgo {
        case 0: return "Last night"
        case 1: return "1 night ago"
        default: return "\(nightsAgo) nights ago"
        }
    }

    /// How many nights back the carousel entry at `offset` is FROM TODAY.
    ///
    /// Measured from today, not from the newest recorded night. Anchoring on the newest record made
    /// offset 0 always land on zero, so the hero read "Last night" over a night that could be days
    /// old, printed directly above the correct date: two adjacent labels contradicting each other.
    ///
    /// `wakeTimestamps` is newest-first, one per carousel entry, each the entry's wake instant. It is
    /// timestamps rather than sessions so this stays free of view types.
    ///
    /// `today` must be the LOGICAL day (the 04:00 roll), and the wake instants must NOT be rolled.
    /// The carousel groups nights by their calendar wake-date, so rolling that side too would let two
    /// distinct entries collapse onto one label: a night ending 07:00 and the next ending 02:00 are
    /// separate entries but the same logical day. Rolling only today is the half that matters, because
    /// at 02:00 the night that ended yesterday morning is still "Last night".
    ///
    /// A NEGATIVE distance is normal, not a clock-skew guard: between waking before 04:00 and the
    /// roll, the night's calendar date is already tomorrow relative to the logical day. Falling back
    /// to the offset is the right answer there, so that branch carries a real case and must not be
    /// narrowed to an error path.
    public static func nightsAgo(
        wakeTimestamps: [Int],
        offset: Int,
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard offset >= 0, offset < wakeTimestamps.count else { return offset }
        let shown = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(wakeTimestamps[offset])))
        let todayStart = calendar.startOfDay(for: today)
        let d = calendar.dateComponents([.day], from: shown, to: todayStart).day ?? offset
        return d >= 0 ? d : offset
    }
}
