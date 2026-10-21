import Foundation

// Achievements.swift - milestones unlocked from the user's own daily history.
//
// The WHOOP app has a server-driven achievements surface with celebration screens (observed in the shipped
// app's model shapes, facts only, no WHOOP code). NOOP has no server, so this is the local equivalent: a
// fixed list of milestones, each unlocked on the first day the user's own stored metrics reach it.
//
// Rules (Kotlin twin: com.noop.analytics.Achievements, held aligned by mirrored fixtures):
//   - a "scored day" is a day with a Charge (recovery) value in 0...100;
//   - streaks are consecutive civil days with a score (TZ-free epoch arithmetic); a streak milestone
//     unlocks on the day the run first reaches its length;
//   - single-day milestones unlock on the earliest day the value reaches the threshold inside the
//     metric's plausible range, so an artefact never unlocks one;
//   - `isNew` = unlocked within the last `newWindowDays` days ending at today.
//
// Pure: no clock, no I/O, no storage. PRESENTATION ONLY.

/// One milestone. The raw value matches the Kotlin `Achievements.Id.raw`.
public enum AchievementId: String, CaseIterable, Sendable {
    case firstScore, streak7, streak30, scored100, charge90, sleep8h, effort18, steps10k
}

public enum Achievements {

    public static let newWindowDays = 7

    public struct Day: Equatable, Sendable {
        public var day: String
        public var recovery: Double?
        public var strain: Double?
        public var sleepMin: Double?
        public var steps: Double?

        public init(day: String, recovery: Double? = nil, strain: Double? = nil, sleepMin: Double? = nil,
                    steps: Double? = nil) {
            self.day = day
            self.recovery = recovery
            self.strain = strain
            self.sleepMin = sleepMin
            self.steps = steps
        }
    }

    public struct Achievement: Equatable, Sendable {
        public let id: AchievementId
        /// The day it unlocked, nil while locked.
        public let unlockedDay: String?
        public let isNew: Bool
    }

    /// Kotlin twin: `Achievements.inRange`.
    static func inRange(_ v: Double?, _ lo: Double, _ hi: Double) -> Double? {
        guard let v, !v.isNaN, v >= lo, v <= hi else { return nil }
        return v
    }

    /// Every milestone in `AchievementId.allCases` order, locked or not. Rows may arrive in any order;
    /// unparseable day keys are ignored. When `today` does not parse, nothing is new.
    /// Kotlin twin: `Achievements.evaluate`.
    public static func evaluate(_ days: [Day], today: String) -> [Achievement] {
        let dated = days.compactMap { d in Baselines.isoEpochDay(d.day).map { (epoch: $0, day: d) } }
            .sorted { $0.epoch < $1.epoch }
        var unlocked: [AchievementId: (day: String, epoch: Int)] = [:]
        var run = 0
        var lastScored: Int?
        var scored = 0
        for row in dated {
            let d = row.day
            var hits: [AchievementId] = []
            if inRange(d.recovery, 0, 100) != nil {
                if lastScored != row.epoch {   // same-day duplicates count once
                    run = (lastScored == row.epoch - 1) ? run + 1 : 1
                    scored += 1
                    lastScored = row.epoch
                }
                hits.append(.firstScore)
                if run >= 7 { hits.append(.streak7) }
                if run >= 30 { hits.append(.streak30) }
                if scored >= 100 { hits.append(.scored100) }
            }
            if let r = inRange(d.recovery, 0, 100), r >= 90 { hits.append(.charge90) }
            if let s = inRange(d.sleepMin, 60, 960), s >= 480 { hits.append(.sleep8h) }
            if let e = inRange(d.strain, 0, 21), e >= 18 { hits.append(.effort18) }
            if let st = inRange(d.steps, 1, 100_000), st >= 10_000 { hits.append(.steps10k) }
            for id in hits where unlocked[id] == nil { unlocked[id] = (d.day, row.epoch) }
        }
        let t = Baselines.isoEpochDay(today)
        return AchievementId.allCases.map { id in
            let u = unlocked[id]
            var isNew = false
            if let u, let t { isNew = u.epoch <= t && u.epoch > t - newWindowDays }
            return Achievement(id: id, unlockedDay: u?.day, isNew: isNew)
        }
    }
}
