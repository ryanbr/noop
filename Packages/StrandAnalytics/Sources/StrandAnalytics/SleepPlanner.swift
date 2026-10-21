import Foundation

// SleepPlanner.swift — tonight's sleep target, time in bed and bedtime for a wake time.
//
// Pure, deterministic, DB-free. Given the night's personal sleep need, the current
// sleep-debt estimate (SleepDebt), today's nap minutes and the user's typical sleep
// efficiency, it returns one plan per sleep goal: how much sleep the goal asks for,
// how long to be in bed to get it, and the bedtime that implies for a wake time.
//
// The goal ladder (70 / 85 / 100 % of tonight's need) and the three-consecutive-night
// eligibility gate follow the shape of the WHOOP app's sleep planner as observed in
// its shipped resources (facts only, no WHOOP code). Everything else here is NOOP's
// own arithmetic and is documented below.
//
// HONEST by construction:
//   - PRESENTATION ONLY. Nothing here feeds Rest, recovery, debt or any stored value.
//   - Tonight's need = base need + current debt − today's naps, where naps only repay
//     debt: a nap never lowers tonight's need below the base need.
//   - Time in bed = sleep target ÷ typical efficiency (median of recent nights,
//     clamped to 50…100 %). With no efficiency history it equals the sleep target,
//     so the plan never invents an awake allowance it has no evidence for.
//   - Fewer than three consecutive recent nights with sleep → no plan (nil).
//
// Constant-explicit + dependency-free so the Kotlin mirror (android … SleepPlanner.kt)
// is byte-identical.

/// One sleep goal on the planner ladder.
public enum SleepPlannerGoal: String, CaseIterable, Sendable {
    case minimum
    case solid
    case full

    /// Fraction of tonight's need this goal asks for.
    public var fraction: Double {
        switch self {
        case .minimum: return 0.70
        case .solid: return 0.85
        case .full: return 1.00
        }
    }
}

/// The planner's read for one goal.
public struct SleepPlanTier: Equatable, Sendable {
    public let goal: SleepPlannerGoal
    /// Asleep minutes the goal asks for.
    public let sleepTargetMin: Int
    /// Minutes in bed needed to reach the target at the typical efficiency.
    public let timeInBedMin: Int
    /// Bedtime as a local minute of day in [0, 1440).
    public let bedtimeMinuteOfDay: Int
}

/// Tonight's plan: the need breakdown plus one tier per goal.
public struct SleepPlan: Equatable, Sendable {
    /// Personal base need (minutes).
    public let baseNeedMin: Int
    /// Current debt carried into tonight (minutes, ≥ 0).
    public let debtMin: Int
    /// Nap minutes credited against the debt today (≥ 0, ≤ debtMin).
    public let napCreditMin: Int
    /// base + debt − nap credit.
    public let tonightNeedMin: Int
    /// Efficiency used for time in bed, 0.5…1.0 (1.0 when there was no history).
    public let efficiencyUsed: Double
    /// One tier per goal, in `SleepPlannerGoal.allCases` order.
    public let tiers: [SleepPlanTier]
}

public enum SleepPlanner {

    /// Consecutive nights with sleep the plan needs before it says anything.
    public static let requiredConsecutiveNights = 3

    /// How many recent nights the typical efficiency is taken over.
    public static let efficiencyWindowNights = 14

    public static let minEfficiency = 0.5
    public static let maxEfficiency = 1.0

    /// Build tonight's plan, or nil when there are fewer than
    /// `requiredConsecutiveNights` consecutive nights ending at the newest night.
    ///
    /// - Parameters:
    ///   - nights: chronological `(day "yyyy-MM-dd", asleepMin?, efficiency?)` rows.
    ///     Efficiency may be a fraction (0…1) or a percentage (>1, divided by 100).
    ///   - baseNeedMin: personal base sleep need (minutes).
    ///   - debtMin: current sleep-debt estimate (minutes; negatives read as 0).
    ///   - napMinToday: asleep minutes outside the main night today.
    ///   - wakeMinuteOfDay: intended wake time, local minute of day.
    /// Kotlin twin: `SleepPlanner.plan`.
    public static func plan(
        nights: [(day: String, asleepMin: Double?, efficiency: Double?)],
        baseNeedMin: Double,
        debtMin: Double,
        napMinToday: Double,
        wakeMinuteOfDay: Int
    ) -> SleepPlan? {
        guard consecutiveNights(nights.map { ($0.day, $0.asleepMin) }) >= requiredConsecutiveNights else {
            return nil
        }
        let base = max(0.0, baseNeedMin)
        let debt = max(0.0, debtMin)
        let napCredit = min(max(0.0, napMinToday), debt)
        let tonight = base + debt - napCredit
        let eff = typicalEfficiency(nights.map { $0.efficiency }) ?? 1.0

        let tiers = SleepPlannerGoal.allCases.map { goal -> SleepPlanTier in
            let target = tonight * goal.fraction
            let inBed = roundHalfAway(target / eff)
            return SleepPlanTier(
                goal: goal,
                sleepTargetMin: roundHalfAway(target),
                timeInBedMin: inBed,
                bedtimeMinuteOfDay: wrapMinute(wakeMinuteOfDay - inBed)
            )
        }
        return SleepPlan(
            baseNeedMin: roundHalfAway(base),
            debtMin: roundHalfAway(debt),
            napCreditMin: roundHalfAway(napCredit),
            tonightNeedMin: roundHalfAway(tonight),
            efficiencyUsed: eff,
            tiers: tiers
        )
    }

    /// Length of the run of calendar-consecutive nights with sleep (> 0 min) that ends
    /// at the newest night carrying sleep. Rows without sleep are ignored; a gap of a
    /// day or more ends the run. Malformed day keys end the run too.
    /// Kotlin twin: `SleepPlanner.consecutiveNights`.
    public static func consecutiveNights(_ rows: [(day: String, asleepMin: Double?)]) -> Int {
        let slept: [Int?] = rows.compactMap { row -> Int?? in
            guard let m = row.asleepMin, m > 0 else { return nil }
            return .some(epochDay(row.day))
        }
        guard let newest = slept.last, var previous = newest else { return 0 }
        var run = 1
        for maybeDay in slept.dropLast().reversed() {
            guard let day = maybeDay else { break }
            if day == previous { continue }
            if day != previous - 1 { break }
            run += 1
            previous = day
        }
        return run
    }

    /// Median efficiency (fraction) over the newest `efficiencyWindowNights` usable
    /// values, clamped to [minEfficiency, maxEfficiency]; nil when none are usable.
    /// Kotlin twin: `SleepPlanner.typicalEfficiency`.
    public static func typicalEfficiency(_ values: [Double?]) -> Double? {
        let usable = values.compactMap { v -> Double? in
            guard let v = v, v > 0 else { return nil }
            return v > 1.0 ? v / 100.0 : v
        }
        let window = Array(usable.suffix(efficiencyWindowNights)).sorted()
        guard !window.isEmpty else { return nil }
        let mid = window.count / 2
        let median = window.count % 2 == 1 ? window[mid] : (window[mid - 1] + window[mid]) / 2.0
        return min(maxEfficiency, max(minEfficiency, median))
    }

    /// Days since 1970-01-01 for a "yyyy-MM-dd" key (proleptic Gregorian), nil if malformed.
    /// Pure integer arithmetic so both platforms agree without a calendar API.
    /// Kotlin twin: `SleepPlanner.epochDay`.
    public static func epochDay(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y0 = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Kotlin twin: `SleepPlanner.wrapMinute`.
    static func wrapMinute(_ m: Int) -> Int {
        let day = 24 * 60
        return ((m % day) + day) % day
    }

    /// Half-away-from-zero, matching Swift `Double.rounded()`.
    /// Kotlin twin: `SleepPlanner.roundHalfAway`.
    static func roundHalfAway(_ v: Double) -> Int {
        Int(v.rounded())
    }
}
