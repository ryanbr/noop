import Foundation
import WhoopStore

// Training metrics for the Lift Log.
//
// Every figure here is arithmetic the user can redo by hand from their own logged sets. That is the
// whole design constraint: NOOP shows six honest numbers rather than one invented score, because a
// composite "workout score out of 100" feels satisfying and tells you nothing about what to change.
//
// PURE. No store, no clock, no UI — the inputs are rows and the outputs are numbers, so the whole
// surface is unit-testable with no strap, no database and no simulator.
//
// WHAT IS DELIBERATELY ABSENT, and must stay absent:
//
//  • Anything that feeds `workout.strain` or daily Effort. NOOP's strain is HR-measured (Karvonen
//    %HRR -> Edwards TRIMP). There is no validated public path from typed sets/reps/weight to a
//    cardiovascular-strain equivalent — WHOOP's own muscular load runs velocity-based algorithms
//    over strap accelerometer/gyroscope under an unpublished model — and deriving one here is the
//    exact case `CLAUDE.md` warns about after the withdrawn PPG->HR estimate (#194).
//
//  • Per-exercise muscle weightings ("bench press = 0.7 triceps"). There is no published table to
//    take them from. Inventing one would make every downstream per-muscle figure fiction wearing
//    the costume of precision. The direct/indirect split is the resolution the evidence supports.
//
//  • Acute:chronic workload ratios or any injury-risk / overtraining warning. The construct's
//    validity is actively disputed, and a health warning from a non-medical app is either ignored
//    or believed — both bad.

public enum LiftMetrics {

    // MARK: - Volume load (tonnage)

    /// Σ (weight × reps) over WORKING sets, in kilograms. Nil when nothing countable was logged.
    ///
    /// Warm-ups are excluded because the training literature counts working sets, and a warm-up
    /// double counted as volume would flatter every session. A set missing either its weight or its
    /// reps contributes nothing rather than a guess.
    ///
    /// Good for: tracking progression WITHIN one exercise across weeks. Not comparable between
    /// exercises — 100 kg of leg press is not 100 kg of squat — and not comparable between people.
    public static func volumeLoadKg(_ sets: [LiftSetRow]) -> Double? {
        let total = sets.reduce(into: 0.0) { sum, s in
            guard !s.isWarmup, let w = s.weightKg, let r = s.reps, w > 0, r > 0 else { return }
            sum += w * Double(r)
        }
        return total > 0 ? total : nil
    }

    // MARK: - Session load (Foster sRPE-TL)

    /// Session RPE × duration in minutes.
    ///
    /// Foster's session-RPE training load. The reason it earns a place next to volume: it is
    /// validated across BOTH resistance and endurance training, which makes it the only figure in
    /// the app that puts a leg day and a run on one comparable scale.
    ///
    /// Nil when the session was not rated — a skipped rating must never be read as an effortless 0.
    public static func sessionLoad(sessionRpe: Double?, durationSec: Int) -> Double? {
        guard let rpe = sessionRpe, rpe > 0, durationSec > 0 else { return nil }
        return rpe * (Double(durationSec) / 60.0)
    }

    // MARK: - Work versus rest

    public struct WorkRest: Equatable {
        /// Seconds actually spent performing sets (warm-ups included — a warm-up is still time under
        /// load, even though it is not counted as training volume).
        public let workSec: Int
        /// Seconds spent resting between sets, as MEASURED from the taps rather than as planned.
        public let restSec: Int
        /// Rest ÷ work. Nil when no work was recorded. A leg day at 1:4 and a circuit at 1:1 are
        /// different training even at identical volume, and only a tap-through log can know it.
        public let restToWorkRatio: Double?

        public init(workSec: Int, restSec: Int) {
            self.workSec = workSec
            self.restSec = restSec
            self.restToWorkRatio = workSec > 0 ? Double(restSec) / Double(workSec) : nil
        }
    }

    public static func workRest(_ sets: [LiftSetRow]) -> WorkRest {
        var work = 0, rest = 0
        for s in sets {
            if let start = s.startTs, let end = s.endTs, end > start { work += end - start }
            if let r = s.restSec, r > 0 { rest += r }
        }
        return WorkRest(workSec: work, restSec: rest)
    }

    // MARK: - Estimated one-rep max (Epley)

    /// The rep ceiling above which a 1RM estimate stops being worth showing.
    ///
    /// Every 1RM formula is a straight-line fit to a curved relationship, and the error grows with
    /// reps: a 20-rep set says far more about endurance than about maximal strength. Twelve is the
    /// conventional upper bound where the formulas are least unreliable.
    public static let oneRepMaxRepCeiling = 12

    /// Epley: `w × (1 + reps/30)`. Nil for a set that cannot support an estimate.
    ///
    /// A single rep returns the weight itself — the formula's own +3.3% at one rep is an artefact of
    /// the fit, not a claim that a single you just completed was really 3% heavier.
    public static func estimatedOneRepMaxKg(weightKg: Double?, reps: Int?) -> Double? {
        guard let w = weightKg, let r = reps, w > 0, r > 0, r <= oneRepMaxRepCeiling else { return nil }
        guard r > 1 else { return w }
        return w * (1.0 + Double(r) / 30.0)
    }

    // MARK: - Per-exercise summary

    public struct ExerciseSummary: Equatable {
        public let exercise: String
        /// Working sets only — the tally the dose-response literature is built on.
        public let workingSets: Int
        public let warmupSets: Int
        public let volumeKg: Double?
        /// The session's best set for this exercise, ranked by ESTIMATED 1RM rather than by raw
        /// weight: 90 kg × 10 is a better set than 100 kg × 5, and ranking by weight alone would
        /// hide that. Falls back to the heaviest set when no set supports an estimate.
        public let bestWeightKg: Double?
        public let bestReps: Int?
        public let bestEstimatedOneRepMaxKg: Double?

        public init(exercise: String, workingSets: Int, warmupSets: Int, volumeKg: Double?,
                    bestWeightKg: Double?, bestReps: Int?, bestEstimatedOneRepMaxKg: Double?) {
            self.exercise = exercise
            self.workingSets = workingSets
            self.warmupSets = warmupSets
            self.volumeKg = volumeKg
            self.bestWeightKg = bestWeightKg
            self.bestReps = bestReps
            self.bestEstimatedOneRepMaxKg = bestEstimatedOneRepMaxKg
        }
    }

    /// One summary per exercise, in the order the exercises were first performed — which is the
    /// order they were done in, not alphabetical, because that is how a session reads back.
    public static func perExercise(_ sets: [LiftSetRow]) -> [ExerciseSummary] {
        var order: [String] = []
        var grouped: [String: [LiftSetRow]] = [:]
        for s in sets.sorted(by: { $0.ord < $1.ord }) {
            if grouped[s.exercise] == nil { order.append(s.exercise) }
            grouped[s.exercise, default: []].append(s)
        }
        return order.map { name in
            let rows = grouped[name] ?? []
            let working = rows.filter { !$0.isWarmup }

            // Rank by estimated 1RM where possible; otherwise by raw weight, so an exercise logged
            // only at high reps still reports a best set rather than nothing.
            let best = working.max { a, b in
                let ea = estimatedOneRepMaxKg(weightKg: a.weightKg, reps: a.reps)
                let eb = estimatedOneRepMaxKg(weightKg: b.weightKg, reps: b.reps)
                if let ea, let eb { return ea < eb }
                if ea != nil { return false }
                if eb != nil { return true }
                return (a.weightKg ?? 0) < (b.weightKg ?? 0)
            }
            return ExerciseSummary(
                exercise: name,
                workingSets: working.count,
                warmupSets: rows.count - working.count,
                volumeKg: volumeLoadKg(rows),
                bestWeightKg: best?.weightKg,
                bestReps: best?.reps,
                bestEstimatedOneRepMaxKg: estimatedOneRepMaxKg(weightKg: best?.weightKg,
                                                               reps: best?.reps))
        }
    }

    // MARK: - RPE profile

    public struct RpeProfile: Equatable {
        public let mean: Double?
        public let ratedSets: Int
        public let unratedSets: Int
        public let setsAtOrAboveThreshold: Int
        public let threshold: Double

        public init(mean: Double?, ratedSets: Int, unratedSets: Int,
                    setsAtOrAboveThreshold: Int, threshold: Double) {
            self.mean = mean
            self.ratedSets = ratedSets
            self.unratedSets = unratedSets
            self.setsAtOrAboveThreshold = setsAtOrAboveThreshold
            self.threshold = threshold
        }
    }

    /// The default "this set was close to failure" line. Informational only.
    public static let hardSetRpeThreshold = 8.0

    /// How close to failure the working sets were.
    ///
    /// Reported SEPARATELY from the set counts and never as a filter on them. The tempting move is
    /// to count only sets at RPE >= 7 toward a muscle's weekly total, since proximity to failure is
    /// what makes a set count biologically. Doing that would compare a smaller number against
    /// reference doses derived from UNFILTERED working-set counts — quietly changing the scale.
    /// `unratedSets` is surfaced so a mean computed from three of twelve sets is visibly thin.
    public static func rpeProfile(_ sets: [LiftSetRow],
                                  threshold: Double = hardSetRpeThreshold) -> RpeProfile {
        let working = sets.filter { !$0.isWarmup }
        let rated = working.compactMap(\.rpe)
        let mean = rated.isEmpty ? nil : rated.reduce(0, +) / Double(rated.count)
        return RpeProfile(mean: mean,
                          ratedSets: rated.count,
                          unratedSets: working.count - rated.count,
                          setsAtOrAboveThreshold: rated.filter { $0 >= threshold }.count,
                          threshold: threshold)
    }

    // MARK: - Sets per muscle

    public struct MuscleCounts: Equatable {
        /// direct × 1.0 + indirect × 0.5 — the published fractional method.
        public let fractional: [LiftMuscle: Double]
        public let direct: [LiftMuscle: Int]
        public let indirect: [LiftMuscle: Int]

        public init(fractional: [LiftMuscle: Double], direct: [LiftMuscle: Int],
                    indirect: [LiftMuscle: Int]) {
            self.fractional = fractional
            self.direct = direct
            self.indirect = indirect
        }
    }

    /// Fractional set counts per muscle over the given sets.
    ///
    /// The 0.5 for an indirect set is NOT a house convention: the 2025 Sports Medicine dose-response
    /// meta-regression compared counting a secondary mover's set as 1.0 ("total"), 0.5
    /// ("fractional") and 0.0 ("direct"), found the evidence strongest for fractional, and used it
    /// in its primary models. The reference doses in `ReferenceDose` were derived under that same
    /// operationalisation, so the credit and the doses have to move together or the comparison
    /// silently stops meaning anything.
    ///
    /// Warm-ups are excluded; nothing else is. An unclassified exercise (nil primary) contributes to
    /// volume and session load but claims no muscle it was never assigned.
    public static func muscleCounts(_ sets: [LiftSetRow]) -> MuscleCounts {
        var fractional: [LiftMuscle: Double] = [:]
        var direct: [LiftMuscle: Int] = [:]
        var indirect: [LiftMuscle: Int] = [:]
        for s in sets where !s.isWarmup {
            if let p = s.primaryMuscle {
                direct[p, default: 0] += 1
                fractional[p, default: 0] += LiftMuscle.directSetCredit
            }
            for m in s.secondaryMuscles where m != s.primaryMuscle {
                indirect[m, default: 0] += 1
                fractional[m, default: 0] += LiftMuscle.indirectSetCredit
            }
        }
        return MuscleCounts(fractional: fractional, direct: direct, indirect: indirect)
    }

    // MARK: - The reference band

    /// Weekly fractional sets per muscle, from the same dose-response meta-regression the 0.5
    /// credit comes from.
    ///
    /// PRESENTED AS A BAND WITH ITS SOURCE NAMED, NEVER AS A PERSONAL PRESCRIPTION. NOOP is not a
    /// medical device and does not tell anyone what their body needs; it says what the research
    /// associates with growth and leaves the conclusion to the reader.
    public enum ReferenceDose {
        /// Below roughly this, hypertrophy is not reliably detectable.
        public static let hypertrophyMinimumSetsPerWeek = 4.0
        /// Strength keeps improving from a single weekly set.
        public static let strengthMinimumSetsPerWeek = 1.0
        /// Beyond roughly this, added volume stops reliably beating the smallest detectable effect
        /// FOR STRENGTH. Hypertrophy has no identified ceiling — gains continue with strongly
        /// diminishing returns, and the uncertainty widens as volume rises.
        public static let strengthPlateauSetsPerWeek = 4.0

        /// Where a weekly count sits relative to the hypertrophy band, as a 0...1 fraction of the
        /// minimum effective dose, clamped. Deliberately NOT a percentage score: a muscle at 9 sets
        /// is not "225% complete", it is simply past the point where the evidence thins out.
        public static func fractionOfHypertrophyMinimum(_ weeklySets: Double) -> Double {
            guard hypertrophyMinimumSetsPerWeek > 0 else { return 0 }
            return min(1.0, max(0.0, weeklySets / hypertrophyMinimumSetsPerWeek))
        }
    }
}
