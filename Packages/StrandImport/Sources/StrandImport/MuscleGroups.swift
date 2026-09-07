import Foundation

// MARK: - Exercise → muscle attribution
//
// Groundwork for a per-muscle strength view. NOOP already imports lifting sessions (Hevy CSV,
// Liftosaur JSON) but aggregates them to a set count and a volume figure, so nothing downstream can
// say WHICH muscles did the work. This maps an exercise name to the muscles that move it.
//
// Keyword matching on a normalised name, NOT an exhaustive catalogue. Lifting trackers let people
// type anything, so a closed list would silently mis-attribute everything it did not recognise. The
// rule here is the project's usual one: an exercise this cannot place returns NOTHING, and the
// caller shows no attribution rather than a guess. A wrong muscle is worse than a blank one, because
// a blank invites the user to look while a wrong one does not.
//
// PRIMARY movers only. A barbell squat loads glutes and hamstrings too, and a bench press loads
// triceps and shoulders — but attributing every synergist would make every session light up the
// whole body and stop distinguishing a push day from a leg day. The screen this feeds is about where
// the work went, not about what was innervated.

/// The muscle groups a strength view can attribute work to.
///
/// Deliberately coarse. These are the granularity a lifting log can actually support: an exercise
/// name can tell you "lats", it cannot honestly tell you which head of which muscle.
public enum MuscleGroup: String, CaseIterable, Sendable, Equatable {
    case chest
    case upperBack
    case lats
    case shoulders
    case biceps
    case triceps
    case forearms
    case abs
    case lowerBack
    case glutes
    case quadriceps
    case hamstrings
    case calves
}

public enum MuscleAttribution {

    /// Normalise a logged exercise name for matching.
    ///
    /// Trackers append equipment in parentheses ("Squat (Barbell)"), use hyphens and en-dashes
    /// inconsistently ("Seated Cable Row - V Grip"), and vary in case. The parenthetical is KEPT
    /// rather than stripped, because it can carry the distinguishing word: a "Row (Machine)" and a
    /// "Row (Dumbbell)" are the same muscles, but "Curl (Barbell)" and "Leg Curl" are not.
    public static func normalise(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Real exercises this vocabulary has no group for, which must attribute NOTHING rather than
    /// fall through to a generic rule that would be wrong.
    ///
    /// "Neck Curl" contains "curl" and came out as BICEPS. These thirteen groups have no neck, so a
    /// blank is the only honest answer, and a blank is what the whole table is supposed to prefer: it
    /// invites a look, where a wrong muscle does not.
    ///
    /// Kept separate from `rules` because a rule must name at least one group. An entry here is the
    /// deliberate absence of one, which is a different statement from "not recognised".
    static let unattributable: [String] = ["neck"]

    /// The primary movers for a logged exercise name, or an empty array when it cannot be placed.
    ///
    /// Order matters: the first rule that matches wins, so the more specific phrase has to be tested
    /// before the word it contains. "leg curl" is hamstrings and must be decided before "curl" sends
    /// it to biceps; "front raise" is shoulders and must beat "raise"; "calf raise" likewise.
    public static func muscles(for exercise: String) -> [MuscleGroup] {
        let n = normalise(exercise)
        guard !n.isEmpty else { return [] }
        guard !unattributable.contains(where: { n.contains($0) }) else { return [] }
        for (needle, groups) in rules where n.contains(needle) {
            return groups
        }
        return []
    }

    /// Longest-phrase-first, so a specific lift is decided before the generic word inside it. Held as
    /// an ordered array rather than a dictionary precisely because that order is the logic.
    static let rules: [(String, [MuscleGroup])] = [
        // legs — the specific curls and raises must precede the generic ones
        ("leg curl", [.hamstrings]),
        ("romanian deadlift", [.hamstrings, .glutes]),
        ("stiff leg deadlift", [.hamstrings, .glutes]),
        ("good morning", [.hamstrings, .lowerBack]),
        ("leg extension", [.quadriceps]),
        ("hack squat", [.quadriceps]),
        ("front squat", [.quadriceps]),
        ("bulgarian", [.quadriceps, .glutes]),
        ("lunge", [.quadriceps, .glutes]),
        ("leg press", [.quadriceps, .glutes]),
        ("squat", [.quadriceps, .glutes]),
        ("hip thrust", [.glutes]),
        ("glute bridge", [.glutes]),
        ("calf raise", [.calves]),
        ("calf press", [.calves]),
        // hinge / back
        ("deadlift", [.lowerBack, .glutes, .hamstrings]),
        ("back extension", [.lowerBack]),
        ("hyperextension", [.lowerBack]),
        ("pull up", [.lats, .biceps]),
        ("pullup", [.lats, .biceps]),
        ("chin up", [.lats, .biceps]),
        ("chinup", [.lats, .biceps]),
        ("lat pulldown", [.lats]),
        ("pulldown", [.lats]),
        ("pullover", [.lats]),
        ("face pull", [.upperBack, .shoulders]),
        ("shrug", [.upperBack]),
        // Before the generic row: an upright row is a shoulder movement, and every
        // upright row contains "row", so the generic rule would swallow it.
        ("upright row", [.shoulders, .upperBack]),
        ("row", [.upperBack, .lats]),
        // push
        ("bench press", [.chest, .triceps]),
        ("chest press", [.chest, .triceps]),
        ("chest fly", [.chest]),
        ("pec deck", [.chest]),
        // Before the generic fly: a reverse fly and a rear-delt fly are REAR movements, and both
        // contain "fly", so the generic rule would file the opposite side of the body. Order is the
        // whole contract here, not a stylistic choice.
        ("rear delt", [.shoulders, .upperBack]),
        ("reverse fly", [.shoulders, .upperBack]),
        ("fly", [.chest]),
        ("push up", [.chest, .triceps]),
        ("pushup", [.chest, .triceps]),
        ("dip", [.chest, .triceps]),
        ("overhead press", [.shoulders, .triceps]),
        ("shoulder press", [.shoulders, .triceps]),
        ("military press", [.shoulders, .triceps]),
        ("arnold press", [.shoulders]),
        ("lateral raise", [.shoulders]),
        ("front raise", [.shoulders]),
        // arms
        // Hevy writes it as one word; the two-word rule missed the spelling the catalogue uses.
        ("skullcrusher", [.triceps]),
        ("skull crusher", [.triceps]),
        ("tricep", [.triceps]),
        ("pushdown", [.triceps]),
        ("kickback", [.triceps]),
        ("hammer curl", [.biceps, .forearms]),
        ("preacher curl", [.biceps]),
        ("bicep", [.biceps]),
        // Before the generic curl: a nordic curl is a hamstring movement and a jefferson curl is a
        // spinal one. Both contain "curl", so the generic rule would call them biceps.
        ("nordic curl", [.hamstrings]),
        ("jefferson curl", [.lowerBack, .hamstrings]),
        // Before the generic curl: a wrist curl is forearms, and "Wrist Curl" is how the exercise is
        // normally written, so the rule below was unreachable for the title it exists to catch.
        ("wrist", [.forearms]),
        ("curl", [.biceps]),
        ("farmer", [.forearms]),
        // trunk
        ("plank", [.abs]),
        ("crunch", [.abs]),
        ("sit up", [.abs]),
        ("situp", [.abs]),
        ("leg raise", [.abs]),
        ("hanging raise", [.abs]),
        ("ab wheel", [.abs]),
        ("russian twist", [.abs]),
    ]
}
