import Foundation

// MARK: - The muscle-group vocabulary (v45)
//
// Exercise NAMES are free text — whatever the user types, kept verbatim. Muscle GROUPS are not:
// they are a closed, fixed set of canonical tokens, because a per-muscle rollup is only meaningful
// if the same muscle always lands in the same bucket. Free-text groups would scatter "Quads",
// "quads" and "Legs" across three counts and quietly make the weekly view a lie.
//
// These raw values are a STORED-DATA CONTRACT. They are written into `liftExercise.primaryMuscle`,
// `liftExercise.secondaryMuscles`, `liftSet.primaryMuscle` and `liftSet.secondaryMuscles`, and an
// Android twin must use byte-identical tokens. So:
//   • NEVER rename or remove a case — stored rows would stop resolving.
//   • Adding a case is safe and additive.
//   • Tokens are deliberately locale-independent; the display name is localized at the app layer,
//     never here (WhoopStore holds no UI strings).
//
// Granularity matches the resolution the volume literature measures at — the muscles hypertrophy
// trials actually image (pectoralis, latissimus, the deltoid heads, biceps, triceps, quadriceps,
// hamstrings, glutes, erectors, gastrocnemius…), plus the few that are trained in practice but
// rarely studied (adductors, abductors, forearms, neck). Coarser ("Legs") would hide hamstrings
// that never got trained; finer (individual heads of each muscle) would make every bucket look
// starved and turn logging into taxonomy homework.
//
// There is deliberately NO "full body" and NO "other". Both are escape hatches that contribute to
// no muscle's count while looking like they did — a clean is quads-direct with upper back, traps,
// glutes and hamstrings indirect, and saying so is both more accurate and more useful. An exercise
// the user has not classified simply has a nil primary: it still counts toward volume and session
// load, it just does not claim a muscle it was never assigned.

/// A muscle group a set can be attributed to. Raw values are stored; do not rename them.
public enum LiftMuscle: String, CaseIterable, Codable, Sendable {

    // Push
    case chest
    case frontDelts
    case sideDelts
    case rearDelts
    case triceps

    // Pull
    case lats
    case upperBack
    case traps
    case biceps
    case forearms

    // Legs
    case quads
    case hamstrings
    case glutes
    case adductors
    case abductors
    case calves

    // Trunk
    case abs
    case obliques
    case lowerBack
    case neck

    /// Coarse section, used only to group the picker. Not stored, not counted — purely presentation
    /// scaffolding, so changing it is free.
    public enum Region: String, CaseIterable, Sendable {
        case push, pull, legs, trunk
    }

    public var region: Region {
        switch self {
        case .chest, .frontDelts, .sideDelts, .rearDelts, .triceps:
            return .push
        case .lats, .upperBack, .traps, .biceps, .forearms:
            return .pull
        case .quads, .hamstrings, .glutes, .adductors, .abductors, .calves:
            return .legs
        case .abs, .obliques, .lowerBack, .neck:
            return .trunk
        }
    }

    /// Cases in picker order: by region, in the order declared above.
    public static var ordered: [LiftMuscle] { allCases }

    /// Cases in one region, in declaration order.
    public static func inRegion(_ region: Region) -> [LiftMuscle] {
        allCases.filter { $0.region == region }
    }

    /// What one set contributes to this muscle's weekly count.
    ///
    /// The 2025 Sports Medicine dose-response meta-regression compared three ways of counting a set
    /// for a muscle that was only an indirect mover — "total" (count it as 1), "fractional" (count
    /// it as 0.5) and "direct" (count it as 0) — and found the evidence strongest for FRACTIONAL,
    /// which is what its primary models use. So 0.5 here is not a house convention; it is the
    /// operationalisation with the best empirical support, and the reference doses NOOP shows are
    /// derived under it. Change one and you must change the other.
    public static let directSetCredit: Double = 1.0
    public static let indirectSetCredit: Double = 0.5

    // MARK: - The secondary-muscle list, as stored
    //
    // A comma-joined token list in one TEXT column rather than a join table: the list is short,
    // never queried on its own, and one column is trivially mirrorable in Room. Order is preserved
    // as the user set it; duplicates and the primary itself are stripped on encode so a set can
    // never be counted twice for one muscle.

    /// Encode a secondary list for storage. Returns nil for an empty list so the column stays NULL
    /// rather than holding an empty string (two spellings of "none" is a bug waiting to happen).
    public static func encodeList(_ muscles: [LiftMuscle], excluding primary: LiftMuscle? = nil) -> String? {
        var seen = Set<LiftMuscle>()
        if let primary { seen.insert(primary) }
        var kept: [LiftMuscle] = []
        for m in muscles where !seen.contains(m) {
            seen.insert(m)
            kept.append(m)
        }
        return kept.isEmpty ? nil : kept.map(\.rawValue).joined(separator: ",")
    }

    /// Decode a stored secondary list. Unknown tokens are skipped rather than failing the read: a
    /// database written by a newer build must stay readable by an older one.
    public static func decodeList(_ stored: String?) -> [LiftMuscle] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored.split(separator: ",").compactMap { LiftMuscle(rawValue: String($0)) }
    }
}
