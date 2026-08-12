import Foundation

/// The named-sport catalogue for the workout pickers (manual add/edit + live tracking), the Apple-side
/// mirror of Android's `WorkoutSport.all` (built from `ExerciseTypes.NAMES` + `EXTRA`). The two lists
/// MUST stay in lockstep , the stored `WorkoutRow.sport` is a cross-platform value (it round-trips
/// through CSV / Apple-Health export), so a sport named here must read identically on Android and
/// vice-versa.
///
/// Apple has no Health Connect, so unlike Android we carry no exercise-type int , just the display
/// name and whether a route makes sense (drives the "· GPS" hint and a sensible GPS default, parity
/// with Android's `Sport.isDistanceSport`). The names are DATA, not UI literals: they're persisted
/// verbatim as the sport label and must never be localised (a translated name would split one sport
/// into two). Free-text stays allowed everywhere , this catalogue is the suggestion set, not a
/// whitelist (#519).
enum WorkoutCatalog {

    /// One selectable activity. `name` is the verbatim stored/display label.
    struct Sport: Identifiable, Hashable {
        let name: String
        /// Types where a route makes sense → GPS hint / default on.
        let isDistanceSport: Bool
        var id: String { name }
    }

    /// Ordered to match Android `WorkoutSport.all`: common / distance first, the rest, the EXTRA
    /// sports HC has no type for (Padel , #77/#152), then the generic "Other" last. Distance flags
    /// mirror Android `ExerciseTypes.DISTANCE_TYPES`.
    static let all: [Sport] = [
        Sport(name: "Running", isDistanceSport: true),
        Sport(name: "Walking", isDistanceSport: true),
        Sport(name: "Hiking", isDistanceSport: true),
        Sport(name: "Cycling", isDistanceSport: true),
        Sport(name: "Open-water swim", isDistanceSport: true),
        Sport(name: "Rowing", isDistanceSport: true),
        Sport(name: "Treadmill run", isDistanceSport: false),
        // Indoor treadmill walk (#714). Distance off so GPS stays defaulted off, like Treadmill run.
        Sport(name: "Treadmill walk", isDistanceSport: false),
        Sport(name: "Indoor cycle", isDistanceSport: false),
        Sport(name: "Pool swim", isDistanceSport: false),
        Sport(name: "Row machine", isDistanceSport: false),
        Sport(name: "Elliptical", isDistanceSport: false),
        Sport(name: "Strength", isDistanceSport: false),
        // Bodybuilding (#714). A strength-style session with no route, so GPS off.
        Sport(name: "Bodybuilding", isDistanceSport: false),
        Sport(name: "Weightlifting", isDistanceSport: false),
        Sport(name: "HIIT", isDistanceSport: false),
        Sport(name: "Yoga", isDistanceSport: false),
        Sport(name: "Pilates", isDistanceSport: false),
        Sport(name: "Boxing", isDistanceSport: false),
        Sport(name: "Basketball", isDistanceSport: false),
        Sport(name: "Soccer", isDistanceSport: false),
        Sport(name: "Baseball", isDistanceSport: false),
        Sport(name: "Badminton", isDistanceSport: false),
        Sport(name: "Tennis", isDistanceSport: false),
        Sport(name: "Squash", isDistanceSport: false),
        Sport(name: "Racquetball", isDistanceSport: false),
        Sport(name: "Table tennis", isDistanceSport: false),
        Sport(name: "Volleyball", isDistanceSport: false),
        // Martial arts covers the user-requested Jiu-Jitsu plus karate/judo/MMA etc. (#768)
        Sport(name: "Martial arts", isDistanceSport: false),
        Sport(name: "Dancing", isDistanceSport: false),
        Sport(name: "Golf", isDistanceSport: false),
        Sport(name: "Climbing", isDistanceSport: false),
        Sport(name: "Stretching", isDistanceSport: false),
        // Snow sports cover ground → a route makes sense, so GPS defaults on. (#768)
        Sport(name: "Skiing", isDistanceSport: true),
        Sport(name: "Snowboarding", isDistanceSport: true),
        // EXTRA , no Health Connect type, still first-class here. (#77/#152, #768)
        Sport(name: "Padel", isDistanceSport: false),
        Sport(name: "Pickleball", isDistanceSport: false),
        // Bowling (D#850): light lane sport, no route, so GPS stays off.
        Sport(name: "Bowling", isDistanceSport: false),
        // #222 follow-up batch. Names + distance flags kept byte-identical to Android
        // WorkoutSport / ExerciseTypes (Ice Hockey closes a pre-existing Android-only gap). Only the
        // native-HC distance sports (paddling/sailing/skating/snowshoeing) default GPS on.
        Sport(name: "Ice Hockey", isDistanceSport: false),
        Sport(name: "American football", isDistanceSport: false),
        Sport(name: "Australian football", isDistanceSport: false),
        Sport(name: "Rugby", isDistanceSport: false),
        Sport(name: "Cricket", isDistanceSport: false),
        Sport(name: "Softball", isDistanceSport: false),
        Sport(name: "Handball", isDistanceSport: false),
        Sport(name: "Water polo", isDistanceSport: false),
        Sport(name: "Frisbee", isDistanceSport: false),
        Sport(name: "Surfing", isDistanceSport: false),
        Sport(name: "Kayaking", isDistanceSport: true),
        Sport(name: "Sailing", isDistanceSport: true),
        Sport(name: "Scuba diving", isDistanceSport: false),
        Sport(name: "Ice skating", isDistanceSport: false),
        Sport(name: "Inline skating", isDistanceSport: true),
        Sport(name: "Snowshoeing", isDistanceSport: true),
        Sport(name: "Gymnastics", isDistanceSport: false),
        Sport(name: "Fencing", isDistanceSport: false),
        Sport(name: "Calisthenics", isDistanceSport: false),
        Sport(name: "Stair climber", isDistanceSport: false),
        Sport(name: "Boot camp", isDistanceSport: false),
        Sport(name: "Lacrosse", isDistanceSport: false),
        Sport(name: "Field hockey", isDistanceSport: false),
        Sport(name: "CrossFit", isDistanceSport: false),
        Sport(name: "Kickboxing", isDistanceSport: false),
        Sport(name: "Mountain biking", isDistanceSport: false),
        Sport(name: "Skateboarding", isDistanceSport: false),
        Sport(name: "Stand-up paddleboard", isDistanceSport: false),
        Sport(name: "Spinning", isDistanceSport: false),
        Sport(name: "Jump rope", isDistanceSport: false),
        Sport(name: "Powerlifting", isDistanceSport: false),
        Sport(name: "Other", isDistanceSport: false),
    ]

    /// The default sport for a live workout when the user starts one without picking , the generic
    /// "Other", matching Android `WorkoutSport.default`. (The auto-detector relabels detected bouts;
    /// this is only the manual-start fallback.)
    static let defaultSportName = "Other"

    /// Case-insensitive lookup of the suggestion matching a (possibly free-typed) label, or nil for
    /// an off-catalogue sport , which is still valid, just not in the suggestion set.
    static func sport(named name: String) -> Sport? {
        let q = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Catalogue filtered by a search query (empty → the whole list). Names only, case-insensitive.
    static func matching(_ query: String) -> [Sport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    /// Sports where a step count is meaningful , feet on the ground , so the workout summary can show
    /// steps (#398). Deliberately narrow: outdoor + treadmill run/walk and hiking, NOT cycling/rowing/
    /// swimming (no footfalls) or gym/court sports (a step tally would be noise). Kept in lockstep with
    /// the Android `WorkoutCatalog.ON_FOOT_SPORTS`.
    static let onFootSportNames: Set<String> = [
        "Running", "Walking", "Hiking", "Treadmill run", "Treadmill walk",
    ]

    /// Whether `sportName` (a catalogue name, possibly free-typed) is an on-foot sport that should show a
    /// step count. Case-insensitive, whitespace-trimmed.
    static func isOnFoot(_ sportName: String) -> Bool {
        let q = sportName.trimmingCharacters(in: .whitespaces)
        return onFootSportNames.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }
}
