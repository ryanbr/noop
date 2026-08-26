import Foundation
import WhoopStore

// Display names for the stored `LiftMuscle` vocabulary.
//
// `WhoopStore` deliberately holds no UI strings: `LiftMuscle`'s raw values are a stored-data
// contract (an Android twin must one day write byte-identical tokens), so the human-readable name
// has to live at the app layer, where it can be localized without touching what is written to the
// database. Renaming a label here is free; renaming a token is not — see the header of
// `LiftMuscle.swift`.
//
// Names are the ones lifters use, not the anatomical Latin: "Lats", not "latissimus dorsi". The
// vocabulary is meant to be picked from in a gym in a few seconds, and the granularity is already
// justified in the enum — the label's only job is to be recognised instantly.

extension LiftMuscle {
    /// Localized display name, e.g. "Front delts".
    ///
    /// A computed `String` rather than a `LocalizedStringKey` because callers interpolate it — into
    /// a picker row, a summary line, an accessibility label — and an interpolated
    /// `LocalizedStringKey` would look up the *interpolated* result as a key and miss.
    var displayName: String {
        switch self {
        // Push
        case .chest:       return String(localized: "Chest")
        case .frontDelts:  return String(localized: "Front delts")
        case .sideDelts:   return String(localized: "Side delts")
        case .rearDelts:   return String(localized: "Rear delts")
        case .triceps:     return String(localized: "Triceps")
        // Pull
        case .lats:        return String(localized: "Lats")
        case .upperBack:   return String(localized: "Upper back")
        case .traps:       return String(localized: "Traps")
        case .biceps:      return String(localized: "Biceps")
        case .forearms:    return String(localized: "Forearms")
        // Legs
        case .quads:       return String(localized: "Quads")
        case .hamstrings:  return String(localized: "Hamstrings")
        case .glutes:      return String(localized: "Glutes")
        case .adductors:   return String(localized: "Adductors")
        case .abductors:   return String(localized: "Abductors")
        case .calves:      return String(localized: "Calves")
        // Trunk
        case .abs:         return String(localized: "Abs")
        case .obliques:    return String(localized: "Obliques")
        case .lowerBack:   return String(localized: "Lower back")
        case .neck:        return String(localized: "Neck")
        }
    }
}

extension LiftMuscle.Region {
    /// Localized section title for the muscle picker. Presentation-only, like the region itself.
    var displayName: String {
        switch self {
        case .push:  return String(localized: "Push")
        case .pull:  return String(localized: "Pull")
        case .legs:  return String(localized: "Legs")
        case .trunk: return String(localized: "Trunk")
        }
    }
}

// MARK: - Summarising a classification

enum LiftMuscleSummary {

    /// One line describing how an exercise is classified, for a program row or a picker subtitle:
    /// "Chest · Front delts, Triceps", or "Not classified" when it has no primary.
    ///
    /// The primary is listed first and separated from the secondaries, because the direct/indirect
    /// split is what makes the per-muscle counts computable at all — collapsing them into one list
    /// would hide the distinction the whole rollup rests on.
    static func line(primary: LiftMuscle?, secondaries: [LiftMuscle]) -> String {
        guard let primary else { return String(localized: "Not classified") }
        let secondary = secondaries.filter { $0 != primary }
        guard !secondary.isEmpty else { return primary.displayName }
        let joined = secondary.map(\.displayName).joined(separator: ", ")
        return "\(primary.displayName) · \(joined)"
    }
}
