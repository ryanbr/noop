import Foundation
import WhoopStore

/// The Sleep screen's "Deleted sleep windows" list (#515 on Android, iOS and macOS since): every night the user
/// deleted whose deletion marker still stands, newest first, minus the ones hidden from the list.
///
/// A deleted night keeps its marker (`DismissedSleepSpans`) so the detector does not bring it back, and the undo
/// strip lasts seconds. Without this list a night deleted by mistake could only come back in those seconds. A row
/// either reopens the night (the marker goes, the night is re-detected from raw) or is hidden: hiding takes the row
/// off the list and leaves the marker, so a mistaken sleep stays deleted. Android stores that as the
/// `managementVisible` column of its `dismissedSleep` table; here it is a second token list beside the markers,
/// because the markers themselves live in the defaults, not in the store.
///
/// Pure, so `StrandTests` covers it; the Repository persists both lists.
enum DeletedSleepList {

    /// The windows to list: each marker in `tokens` that parses and is not in `hidden`, newest end first.
    static func visible(tokens: [String], hidden: [String]) -> [(start: Int, end: Int)] {
        let hiddenSet = Set(hidden)
        let shown = tokens.filter { !hiddenSet.contains($0) }
        return DismissedSleepSpans.windows(from: shown).sorted { $0.end > $1.end }
    }

    /// `hidden` with the window `(startTs, endTs)` added, keeping only tokens that still name a marker in `tokens`:
    /// a hidden entry is meaningless once its marker is gone, so the list can never outgrow the markers.
    static func hiding(startTs: Int, endTs: Int, hidden: [String], tokens: [String]) -> [String] {
        let token = DismissedSleepSpans.token(startTs: startTs, endTs: endTs)
        let markers = Set(tokens)
        var out = hidden.filter { markers.contains($0) && $0 != token }
        if markers.contains(token) { out.append(token) }
        return out
    }

    /// `hidden` with the window's entry removed, for when its marker is lifted.
    static func unhiding(startTs: Int, endTs: Int, hidden: [String]) -> [String] {
        let token = DismissedSleepSpans.token(startTs: startTs, endTs: endTs)
        return hidden.filter { $0 != token }
    }
}
