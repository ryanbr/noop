import Foundation

/// How the Sleep hero names the night it is showing.
///
/// Extracted from `SleepView` so it can be tested. The Kotlin twin has lived in `SleepHeroLogic.kt`
/// as a pure function with its own suite from the start; the Swift side kept it private inside the
/// view, which is why a defect here went uncaught on this platform until a report arrived. This
/// package's tests run in ordinary CI, unlike the app-target bundle, so the logic is verified on
/// every change rather than only when the on-demand app build is dispatched.
///
/// Only the arithmetic lives here. The WORDING deliberately stays in the view: it returns a
/// `LocalizedStringKey`, so the literals have to remain in source for extraction, and pulling them
/// into a `String` helper here would quietly drop them out of the catalogue. The Kotlin twin can share
/// both halves because Android localises through resource ids instead.
///
/// Kotlin twin: `calendarNightsAgo`.
public enum SleepNightLabel {

    /// How many nights back the carousel entry at `offset` is FROM TODAY.
    ///
    /// Measured from today, not from the newest recorded night. Anchoring on the newest record made
    /// offset 0 always land on zero, so the hero read "Last night" over a night that could be days
    /// old, printed directly above the correct date: two adjacent labels contradicting each other.
    ///
    /// `wakeTimestamps` is newest-first, one per carousel entry, each the entry's wake instant. It is
    /// timestamps rather than sessions so this stays free of view types, and OPTIONAL so an entry with
    /// no session falls back to the offset instead of being read as 1970.
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
        wakeTimestamps: [Int?],
        offset: Int,
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard offset >= 0, offset < wakeTimestamps.count,
              let shownTs = wakeTimestamps[offset] else { return offset }
        let shown = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(shownTs)))
        let todayStart = calendar.startOfDay(for: today)
        let d = calendar.dateComponents([.day], from: shown, to: todayStart).day ?? offset
        return d >= 0 ? d : offset
    }
}
