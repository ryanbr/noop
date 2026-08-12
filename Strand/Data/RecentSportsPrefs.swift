import Foundation

// MARK: - Recently selected workout types (#297)
//
// Picking a workout type meant scanning/searching the full catalogue every time, even though most
// people cycle through the same 2-3 activities. Both sport pickers (the manual add/edit field and the
// live "Start a workout" sheet) now surface the user's most recent selections above the full list.
//
// Stored as a single comma-joined string of sport names in UserDefaults, most-recent-first, capped at
// three, deduplicated case-insensitively — the same mechanism as the other display prefs
// (KeyMetricPrefs / MoreSectionPrefs). The Android side mirrors this exactly in RecentSportsPrefs.kt
// (SharedPreferences "workout.recentSports"). Display-only: no WorkoutRow, analytics value or
// migration changes, so like the other layout prefs it stays OUT of the .noopbak settings whitelist.

/// Persistence for the "Recent" section of the sport pickers. The stored value is an ordered,
/// comma-joined list of sport-name strings exactly as selected — free-typed, off-catalogue sports
/// included (each picker decides what it can display; see the callers).
enum RecentSportsPrefs {
    /// UserDefaults key. The Android twin persists the same "workout.recentSports" name.
    static let key = "workout.recentSports"

    /// Most-recent-first cap. Bumped 3 → 5 now the catalogue is large (~78 sports): a wider rotation
    /// surfaces without scrolling, still short enough to stay above the full list. Twin of Android.
    static let maxCount = 5

    /// Encode an ordered list of names into the stored comma-joined string.
    static func encode(_ names: [String]) -> String { names.joined(separator: ",") }

    /// Decode the stored string back to the ordered name list. Blank tokens are dropped; an
    /// empty/unset string yields no recents (the section simply doesn't render).
    static func decode(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Pure fold of one selection into the list: front-inserted, deduplicated case-insensitively
    /// (a re-selection moves the entry to the front and adopts the new casing), capped at `maxCount`.
    /// A blank name is a no-op; so is a name containing a comma — it can't ride the comma-joined
    /// encoding, and skipping the record beats corrupting the whole list for a theoretical edge case.
    static func recording(_ name: String, into current: [String]) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(",") else { return current }
        var list = current.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        return Array(list.prefix(maxCount))
    }

    /// The persisted recents, most-recent-first.
    static func recent(_ defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: key) ?? "")
    }

    /// Fold a confirmed selection into the persisted list. Called on confirm (Save / Start / Merge),
    /// never on keystrokes or list taps, so an abandoned sheet leaves the recents untouched.
    static func recordSelection(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.set(encode(recording(name, into: recent(defaults))), forKey: key)
    }
}
