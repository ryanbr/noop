import Foundation

/// One day's inputs for the retrospective expenditure estimate. Both fields are optional because the two
/// series are independently sparse — a day with a weigh-in and no food log is common, and inventing a
/// value for the missing one is exactly what this engine must not do.
public struct AdaptiveExpenditureDay: Equatable, Sendable {
    public let day: String          // "yyyy-MM-dd", the app's day key
    public let caloriesIn: Double?
    public let weightKg: Double?

    public init(day: String, caloriesIn: Double? = nil, weightKg: Double? = nil) {
        self.day = day; self.caloriesIn = caloriesIn; self.weightKg = weightKg
    }
}

/// How much the estimate below deserves to be trusted. Deliberately coarse — the inputs do not support
/// a percentage, and a number would imply a precision this method does not have.
public enum AdaptiveExpenditureConfidence: String, Equatable, Sendable {
    case building, moderate, high
}

/// A retrospective estimate of average daily energy expenditure, with an interval.
///
/// Never a single number: the method's error is dominated by things this engine cannot see (hydration
/// swings, an under-logged weekend), so a bare figure would be the fabrication the rest of NOOP refuses
/// to make. The interval is the honest output and the caller should render it as one.
public struct AdaptiveExpenditureEstimate: Equatable, Sendable {
    public let estimatedDailyKcal: Double
    public let lowerKcal: Double
    public let upperKcal: Double
    public let meanIntakeKcal: Double
    public let weightSlopeKgPerDay: Double
    public let intakeDays: Int
    public let weightReadings: Int
    public let windowDays: Int
    public let confidence: AdaptiveExpenditureConfidence

    public init(estimatedDailyKcal: Double, lowerKcal: Double, upperKcal: Double, meanIntakeKcal: Double,
                weightSlopeKgPerDay: Double, intakeDays: Int, weightReadings: Int, windowDays: Int,
                confidence: AdaptiveExpenditureConfidence) {
        self.estimatedDailyKcal = estimatedDailyKcal; self.lowerKcal = lowerKcal; self.upperKcal = upperKcal
        self.meanIntakeKcal = meanIntakeKcal; self.weightSlopeKgPerDay = weightSlopeKgPerDay
        self.intakeDays = intakeDays; self.weightReadings = weightReadings; self.windowDays = windowDays
        self.confidence = confidence
    }
}

/// Average daily expenditure inferred from logged intake and the weight trend (TDEE by energy balance).
///
/// `expenditure = intake − change in stored energy`, with the conventional 7,700 kcal per kg of body mass.
/// The identity is exact; the inputs are not. Day-to-day weight is mostly water, and food logs are
/// under-reported by a wide and person-specific margin, so this is meaningful only over weeks and only as
/// a range.
///
/// DELIBERATELY NOT AN INPUT TO ANYTHING. It never feeds Charge, the calorie card, or the workout
/// calorie estimate: those come from measured heart rate through Keytel, and quietly overwriting a
/// measurement with an inference from a food diary would be a strictly worse number wearing the same
/// label. This answers a question the user asks explicitly, and returns nil rather than guess.
///
/// Kotlin twin: `AdaptiveExpenditureEngine`.
public enum AdaptiveExpenditureEngine {
    /// Energy density of body-mass change. The textbook 7,700 kcal/kg (≈3,500 kcal/lb) figure, which
    /// assumes the change is adipose; it over-states early loss, when a real share of it is glycogen and
    /// its bound water. That bias is one reason the output is an interval.
    public static let kcalPerKg = 7_700.0

    /// Windows. Three weeks is the floor because a week of water retention can hide a 500 kcal/day gap,
    /// and six weeks is the ceiling because beyond that the body's own expenditure has adapted and the
    /// average stops describing today.
    public static let minWindowDays = 21
    public static let maxWindowDays = 42

    /// Coverage floors. Intake is the weak input, so it carries the strictest gate: a fortnight of logs
    /// AND 70% of the window, which together reject the common "logged hard for five days" pattern that
    /// would otherwise read as a huge deficit.
    public static let minIntakeDays = 14
    public static let minIntakeCoverage = 0.70
    public static let minWeightReadings = 6

    /// nil when the history cannot support an estimate — the normal answer for most installs, and the
    /// point of the gates. `days` need not be sorted or contiguous.
    public static func estimate(days: [AdaptiveExpenditureDay]) -> AdaptiveExpenditureEstimate? {
        let ordered = days.sorted { $0.day < $1.day }
        guard let first = ordered.first?.day, let last = ordered.last?.day,
              let span = dayCount(from: first, to: last), span >= minWindowDays else { return nil }
        let window = min(span, maxWindowDays)
        // Keep the most RECENT `window` days: an adapted metabolism makes the tail the honest part.
        let recent = ordered.filter { d in
            guard let back = dayCount(from: d.day, to: last) else { return false }
            // `dayCount` is INCLUSIVE — `dayCount(last, last)` is 1 — so the last `window` days are
            // `back <= window`. A strict `<` silently drops the oldest day while still reporting the
            // full `window`, which both loses data and understates coverage.
            return back <= window
        }

        let intake = recent.compactMap { $0.caloriesIn }.filter { $0 > 0 }
        let weights = recent.compactMap { d -> (Int, Double)? in
            guard let w = d.weightKg, w > 0, let i = dayCount(from: first, to: d.day) else { return nil }
            return (i, w)
        }
        guard intake.count >= minIntakeDays,
              min(1.0, Double(intake.count) / Double(window)) >= minIntakeCoverage,
              Set(weights.map { $0.0 }).count >= minWeightReadings,
              let slope = leastSquaresSlope(weights) else { return nil }

        let meanIntake = intake.reduce(0, +) / Double(intake.count)
        // The identity. A RISING weight means intake exceeded expenditure, so the stored-energy term is
        // subtracted — getting this sign backwards is the classic error and it is why the test pins both
        // directions rather than only a deficit.
        let estimate = meanIntake - slope * kcalPerKg

        // Interval. Half a kilo of water across the window is an everyday swing and translates directly
        // into an apparent daily gap; the intake half widens as coverage falls, because the days someone
        // fails to log are not a random sample of their eating.
        let waterKcalPerDay = (0.5 * kcalPerKg) / Double(window)
        // Clamped: `coverage` is "share of the window that was logged", so it cannot exceed 1. A caller
        // that merged its two sparse series badly and passed a day twice would otherwise push it above 1,
        // which SHRINKS the margin and RAISES the confidence — making the answer look more certain than
        // its data, the one direction this engine must never err in. Clamping rather than de-duplicating
        // on purpose: silently picking one of two conflicting values for a day would hide the caller's bug.
        let coverage = min(1.0, Double(intake.count) / Double(window))
        let intakeUncertainty = meanIntake * 0.10 * (1.0 - coverage) + meanIntake * 0.05
        let margin = waterKcalPerDay + intakeUncertainty

        // DISTINCT days, not readings. Two weigh-ins on one morning are one day of evidence about the
        // trend, and counting both would let a chatty scale — or a caller that passed a day twice — buy
        // the same confidence as a fortnight of extra data.
        let weightDays = Set(weights.map { $0.0 }).count
        let confidence: AdaptiveExpenditureConfidence
        if window >= 28 && coverage >= 0.90 && weightDays >= 12 { confidence = .high }
        else if window >= 21 && coverage >= 0.80 { confidence = .moderate }
        else { confidence = .building }

        return AdaptiveExpenditureEstimate(
            estimatedDailyKcal: estimate,
            lowerKcal: estimate - margin, upperKcal: estimate + margin,
            meanIntakeKcal: meanIntake, weightSlopeKgPerDay: slope,
            intakeDays: min(intake.count, window), weightReadings: weightDays, windowDays: window,
            confidence: confidence)
    }

    /// Ordinary least-squares slope in kg per DAY. nil when every reading shares one day, which would
    /// divide by zero — a real case when a scale syncs several readings with one timestamp.
    static func leastSquaresSlope(_ points: [(Int, Double)]) -> Double? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let meanX = points.reduce(0.0) { $0 + Double($1.0) } / n
        let meanY = points.reduce(0.0) { $0 + $1.1 } / n
        var num = 0.0, den = 0.0
        for (x, y) in points {
            let dx = Double(x) - meanX
            num += dx * (y - meanY); den += dx * dx
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Whole days between two "yyyy-MM-dd" keys, inclusive of the first.
    ///
    /// nil on an unparseable key. `AnalyticsEngine.dayStartUtcSeconds` is deliberately nil-tolerant and
    /// returns 0 for one (so a bad key cannot take down a scoring pass), which is indistinguishable from
    /// 1970 here — and a stray 0 would silently stretch the window by twenty thousand days. Treating a
    /// zero as unparseable is the difference between refusing to answer and answering nonsense.
    static func dayCount(from: String, to: String) -> Int? {
        let a = AnalyticsEngine.dayStartUtcSeconds(from)
        let b = AnalyticsEngine.dayStartUtcSeconds(to)
        guard a > 0, b > 0 else { return nil }
        return (b - a) / 86_400 + 1
    }
}
