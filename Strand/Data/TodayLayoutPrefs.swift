import Foundation
import SwiftUI

// MARK: - Reorderable Today sections (#today-layout)
//
// The liquid Today's sections — the Charge/Effort/Rest hero, the Start-session entry, Synthesis, Key
// Metrics, Workouts, Heart Rate, Recovery Vitals, Your Cards — rendered in one fixed order. This lets the
// user REORDER or HIDE them, with the default being the original order so nothing changes for anyone who
// never customizes Today. Display-only — no metric is computed or stored differently; this only decides
// which already-built sections render and in what sequence.
//
// Stored as a single comma-joined string of section keys in @AppStorage("today.sectionOrder"), the same
// mechanism KeyMetricPrefs uses. The Android side mirrors this byte-identically in TodayLayoutPrefs.kt
// (SharedPreferences "today.sectionOrder"). Every known section stays in the ORDER registry: unknown tokens
// are dropped, and any known section missing from the saved order is INSERTED at its default-order position
// relative to the saved sections — so a section added in a later version surfaces where users expect it
// rather than teleporting to the bottom of an existing saved order.
//
// User visibility is stored separately in "today.hiddenSections". Keeping order and visibility separate is
// intentional: hiding is reversible, a hidden section keeps its stable identity, and a section introduced by
// a future version defaults to visible because it is absent from the explicit hidden set.

/// One reorderable Today section. The rawValue is the stable persisted identifier — keep it byte-identical
/// to the Android `TodaySection` enum so a backup/restore reads the same layout on either OS.
enum TodaySection: String, CaseIterable, Identifiable {
    case hero
    case liveSession
    case synthesis
    case keyMetrics
    case workouts
    case heartRate
    case recoveryVitals
    case yourCards
    case menstrualCycle
    case journal
    /// Cards hosted from the Trends / Sleep tabs (#today-hosted-cards). Renders the `HostedCardPrefs`
    /// selection in order; empty (and effectively invisible) until the user adds a card in Customise.
    /// Appended LAST so `decodeOrder`'s back-fill lands it predictably for existing saved orders.
    case addedCards

    var id: String { rawValue }

    /// The section's display label in the Arrange sheet — matches the Android `TodaySection.title`.
    var title: String {
        switch self {
        case .hero:           return String(localized: "Charge / Effort / Rest")
        case .liveSession:    return String(localized: "Start session")
        case .synthesis:      return String(localized: "Synthesis")
        case .keyMetrics:     return String(localized: "Key Metrics")
        case .workouts:       return String(localized: "Workouts")
        case .heartRate:      return String(localized: "Heart Rate")
        case .recoveryVitals: return String(localized: "Recovery Vitals")
        case .yourCards:      return String(localized: "Your Cards")
        case .menstrualCycle: return String(localized: "Menstrual Cycle")
        case .journal:        return String(localized: "Journal")
        case .addedCards:     return String(localized: "Added Cards")
        }
    }

    /// The original, hard-coded section order — the default when the layout isn't customised. The journal
    /// widget (#656) is last by default, where it was first added, above the data-sources card.
    static let defaultOrder: [TodaySection] = [
        .hero, .liveSession, .synthesis, .keyMetrics, .workouts, .heartRate, .recoveryVitals, .yourCards,
        .menstrualCycle, .journal, .addedCards,
    ]
}

/// One per-row data chip on the Latest Workouts feed rows — the same four chips the "More > Workouts"
/// rows carry: the Effort ring, the duration, the average heart rate, and the calories burned. The rawValue
/// is the stable persisted identifier — keep it byte-identical to the Android `WorkoutField` enum so a
/// backup/restore shows the same chips on either OS.
enum WorkoutField: String, CaseIterable {
    case strain
    case duration
    case heartRate
    case calories
}

/// Display-only persistence for the Today section order and visibility. The order registry always contains
/// every known section; `hiddenKey` stores the explicit reversible hidden set. Mirrors Android byte-for-byte.
enum TodayLayoutPrefs {
    /// UserDefaults key — a comma-joined list of `TodaySection` rawValues in display order.
    static let orderKey = "today.sectionOrder"
    /// UserDefaults key — a comma-joined list of explicitly hidden `TodaySection` rawValues.
    static let hiddenKey = "today.hiddenSections"
    /// UserDefaults key — the user-edited Latest Workouts feed length (how many recent workouts the
    /// Today feed lists). One Int under the same key on both platforms; each platform's default
    /// preserves its historical feed cap (6 on the Apple platform, 4 on Android).
    static let workoutsCountKey = "today.workoutsCount"
    static let defaultWorkoutsCount = 6
    static let minWorkoutsCount = 1
    static let maxWorkoutsCount = 14

    /// UserDefaults key — the reach of the Latest Workouts feed in days (how far back it reaches).
    /// One Int under the same key on both platforms, with the SAME option list, so the header label
    /// and the cutoff agree on either OS (a backup/restore reads the same window).
    static let workoutsWindowDaysKey = "today.workoutsWindowDays"
    static let defaultWorkoutsWindowDays = 14
    static let workoutsWindowOptions = [14, 30, 365]

    /// UserDefaults key — a comma-joined list of `WorkoutField` rawValues in canonical order: the per-row
    /// chips the Latest Workouts feed shows. One string under the same key on both platforms; an unset/empty
    /// value means EVERY chip is enabled (the historical behaviour, so existing users see no change).
    /// Mirrors the Android `today.workoutsFields` prefs.
    static let workoutsFieldsKey = "today.workoutsFields"

    /// Encode the enabled chips as a comma-joined string in canonical `WorkoutField` order (deterministic
    /// regardless of toggle order). Twin of the Kotlin `encodeWorkoutFields`.
    static func encodeWorkoutFields(_ fields: Set<WorkoutField>) -> String {
        WorkoutField.allCases.filter { fields.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into the enabled chip set. An empty/unset string means every chip is enabled
    /// (the default); unknown tokens are ignored and duplicates collapsed, and an all-unknown string degrades
    /// to the same default. Twin of the Kotlin `decodeWorkoutFields`.
    static func decodeWorkoutFields(_ raw: String) -> Set<WorkoutField> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Set(WorkoutField.allCases) }
        let fields = Set(trimmed.split(separator: ",").compactMap { WorkoutField(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
        return fields.isEmpty ? Set(WorkoutField.allCases) : fields
    }

    /// Snap an arbitrary day count onto the selectable windows (a hand-edited default can never
    /// render a window the header cannot name).
    static func snapWorkoutsWindowDays(_ days: Int) -> Int {
        workoutsWindowOptions.contains(days) ? days : defaultWorkoutsWindowDays
    }

    /// Clamp a saved/edited feed length into the editable range (a hand-edited default can never
    /// render a zero-row or unbounded feed).
    static func clampedWorkoutsCount(_ count: Int) -> Int {
        Swift.max(minWorkoutsCount, Swift.min(count, maxWorkoutsCount))
    }

    /// Encode an ordered section list into the stored comma-joined string.
    static func encode(_ sections: [TodaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Encode the explicit hidden set in stable list order. The editor passes its Hidden-section order;
    /// rendering treats the decoded value as a set.
    static func encodeHidden(_ sections: [TodaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into the FULL ordered section list. An empty/unset string yields the
    /// default order. Unknown tokens are ignored, duplicates collapsed, and any known section missing from
    /// the saved order is INSERTED at its default-order position relative to the saved sections (before the
    /// first saved section that follows it in the default order; appended when none does) — so every
    /// section always renders, and one added in a later app version surfaces where users expect it instead
    /// of teleporting to the bottom of an existing saved order. Twin of the Kotlin `decodeOrder`.
    static func decodeOrder(_ raw: String) -> [TodaySection] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return TodaySection.defaultOrder }
        var saved: [TodaySection] = []
        for token in trimmed.split(separator: ",") {
            if let s = TodaySection(rawValue: token.trimmingCharacters(in: .whitespaces)), !saved.contains(s) {
                saved.append(s)
            }
        }
        guard !saved.isEmpty else { return TodaySection.defaultOrder }
        // Iterate allCases (not defaultOrder) so a future case accidentally left out of defaultOrder can
        // never be silently hidden; a section without a default index sorts after everything (no crash —
        // the Kotlin twin's indexOf(-1) degrades the same way). defaultOrder covering allCases is pinned
        // by TodayLayoutPrefsTests on both platforms.
        func defIdx(_ s: TodaySection) -> Int {
            TodaySection.defaultOrder.firstIndex(of: s) ?? TodaySection.defaultOrder.count
        }
        for missing in TodaySection.allCases where !saved.contains(missing) {
            let insertAt = saved.firstIndex { defIdx($0) > defIdx(missing) }
            if let insertAt { saved.insert(missing, at: insertAt) } else { saved.append(missing) }
        }
        return saved
    }

    /// Decode explicitly hidden sections. Empty/unset means nothing is hidden. Unknown tokens are ignored
    /// and duplicates collapsed; unlike `decodeOrder`, missing cases are NOT inserted because absence here
    /// means visible (including a section introduced by a future app version).
    static func decodeHidden(_ raw: String) -> [TodaySection] {
        var seen = Set<TodaySection>()
        var hidden: [TodaySection] = []
        for token in raw.split(separator: ",") {
            if let section = TodaySection(rawValue: token.trimmingCharacters(in: .whitespaces)),
               seen.insert(section).inserted {
                hidden.append(section)
            }
        }
        return hidden
    }

    /// The sections Today should render, preserving the full saved order while filtering only the user's
    /// explicit hidden set. At least one visible section is enforced by the editor, not the decoder.
    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [TodaySection] {
        let hidden = Set(decodeHidden(hiddenRaw))
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
