import Foundation

// WeeklyPlan.swift - this week's progress toward the user's own weekly habit goals.
//
// The WHOOP app has a server-driven "weekly plan" (behaviour goals with a per-week check-in; observed in the
// shipped app's model shapes, facts only, no WHOOP code). NOOP has no server, so this is the local
// equivalent over the daily metrics NOOP already stores: "sleep at least X on N nights", "reach Effort Y on
// N days", "walk Z steps on N days", counted over the Monday-to-Sunday week that contains today.
//
// Rules (Kotlin twin: com.noop.analytics.WeeklyPlan, held aligned by mirrored fixtures):
//   - the week is the ISO week (Monday first) containing `today`, by TZ-free civil-day arithmetic;
//   - a day counts once per goal when its value reaches the threshold (>=) and lies inside the plausible
//     range of the metric, so an artefact cannot tick a goal;
//   - `daysLeft` is the days from today through Sunday that have not hit yet; `onTrack` is
//     daysHit + daysLeft >= targetDays; a goal with targetDays 0 is off and is left out.
//
// Pure: no clock, no I/O, no storage. PRESENTATION ONLY: nothing here feeds a score or a stored value.

/// One kind of weekly goal. The raw value matches the Kotlin `WeeklyPlan.Kind.raw`.
public enum WeeklyPlanKind: String, CaseIterable, Sendable {
    case sleep, effort, steps

    /// Inclusive plausibility range of the daily value.
    public var range: ClosedRange<Double> {
        switch self {
        case .sleep: return 60...960      // asleep minutes
        case .effort: return 0...21       // strain
        case .steps: return 1...100_000
        }
    }

    /// Default threshold: 7 h asleep, Effort 10, 8,000 steps.
    public var defaultThreshold: Double {
        switch self {
        case .sleep: return 420
        case .effort: return 10
        case .steps: return 8_000
        }
    }

    /// Default days per week.
    public var defaultTargetDays: Int {
        switch self {
        case .sleep, .steps: return 5
        case .effort: return 3
        }
    }
}

public enum WeeklyPlan {

    public struct Goal: Equatable, Sendable {
        public var kind: WeeklyPlanKind
        public var threshold: Double
        /// Days per week, 0...7 (0 = goal off).
        public var targetDays: Int

        public init(kind: WeeklyPlanKind, threshold: Double, targetDays: Int) {
            self.kind = kind
            self.threshold = threshold
            self.targetDays = targetDays
        }
    }

    /// One goal per kind at its default threshold and days.
    /// Kotlin twin: `WeeklyPlan.defaultGoals`.
    public static func defaultGoals() -> [Goal] {
        WeeklyPlanKind.allCases.map { Goal(kind: $0, threshold: $0.defaultThreshold, targetDays: $0.defaultTargetDays) }
    }

    public struct Day: Equatable, Sendable {
        public var day: String
        public var sleepMin: Double?
        public var strain: Double?
        public var steps: Double?

        public init(day: String, sleepMin: Double? = nil, strain: Double? = nil, steps: Double? = nil) {
            self.day = day
            self.sleepMin = sleepMin
            self.strain = strain
            self.steps = steps
        }
    }

    public struct Progress: Equatable, Sendable {
        public let goal: Goal
        public let daysHit: Int
        public let daysLeft: Int
        public let onTrack: Bool
        public let met: Bool
        /// Monday-first weekday index (0...6) of each day that hit, ascending.
        public let hitWeekdays: [Int]
    }

    public struct Week: Equatable, Sendable {
        /// Days since 1970-01-01 of this week's Monday.
        public let mondayEpochDay: Int
        /// Monday-first weekday index of today (0...6).
        public let todayIndex: Int
        public let progress: [Progress]
    }

    /// Monday-first weekday index (0 = Monday) of an epoch day. 1970-01-01 was a Thursday.
    /// Kotlin twin: `WeeklyPlan.weekdayIndex`.
    public static func weekdayIndex(_ epochDay: Int) -> Int {
        ((epochDay + 3) % 7 + 7) % 7
    }

    /// Kotlin twin: `WeeklyPlan.value`.
    static func value(_ d: Day, _ kind: WeeklyPlanKind) -> Double? {
        switch kind {
        case .sleep: return d.sleepMin
        case .effort: return d.strain
        case .steps: return d.steps
        }
    }

    /// This week's progress per active goal, in input order. nil when `today` does not parse.
    /// Kotlin twin: `WeeklyPlan.week`.
    public static func week(_ days: [Day], today: String, goals: [Goal]) -> Week? {
        guard let t = Baselines.isoEpochDay(today) else { return nil }
        let idx = weekdayIndex(t)
        let monday = t - idx
        var inWeek: [Int: [Day]] = [:]
        for d in days {
            guard let e = Baselines.isoEpochDay(d.day), e >= monday, e <= t else { continue }
            inWeek[e - monday, default: []].append(d)
        }
        let progress = goals.compactMap { raw -> Progress? in
            let goal = Goal(kind: raw.kind, threshold: raw.threshold, targetDays: min(7, max(0, raw.targetDays)))
            guard goal.targetDays > 0 else { return nil }
            let hits = (0...idx).filter { i in
                (inWeek[i] ?? []).contains { d in
                    guard let v = value(d, goal.kind), !v.isNaN, goal.kind.range.contains(v) else { return false }
                    return v >= goal.threshold
                }
            }
            let todayHit = hits.contains(idx)
            let left = (6 - idx) + (todayHit ? 0 : 1)
            return Progress(goal: goal, daysHit: hits.count, daysLeft: left,
                            onTrack: hits.count + left >= goal.targetDays,
                            met: hits.count >= goal.targetDays, hitWeekdays: hits)
        }
        return Week(mondayEpochDay: monday, todayIndex: idx, progress: progress)
    }
}
