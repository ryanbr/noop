import Foundation

// WeeklyDigest.swift — a deterministic, offline "week in review".
//
// Pure, deterministic, DB-free. Given the daily series for each tracked metric
// (keyed by "yyyy-MM-dd"), this builds a Monday-anchored "this week" summary:
//
//   • per-metric this-week SeriesStat (mean / median / min / max / SD / slope),
//   • week-over-week PeriodComparison (this week vs the immediately preceding
//     Mon–Sun week), reusing ComparisonEngine.compare,
//   • a "vs baseline" delta: this-week mean against a trailing baseline mean
//     (the prior `baselineWeeks` complete weeks before this one),
//   • a sleep-consistency read (SD of the night's values across the week — lower
//     is steadier),
//   • a strain-vs-recovery balance read (is Effort outrunning Charge this week?),
//   • the 1–3 biggest movers ranked by normalised week-over-week change, and
//   • 1–2 plain-English focal points, rendered the way BehaviorInsights.sentence
//     renders an effect.
//
// It deliberately consumes plain [String: Double] day→value maps (not a DB row
// type) so StrandAnalytics stays decoupled from WhoopStore: the UI layer pulls
// recovery/strain/sleep/RHR/HRV out of its own DailyMetric shape and hands them
// in. No AI is required — narration is an optional later layer that can take this
// struct as input.
//
// Week math is timezone/locale-free: weekday is computed from the "yyyy-MM-dd"
// string with a pure Sakamoto/Zeller day-of-week, and week windows are produced
// as inclusive "yyyy-MM-dd" string ranges, so the split matches the day strings
// AnalyticsEngine emits exactly (string comparison is chronological for ISO days).

// MARK: - Tracked metric

/// The five headline metrics a weekly digest reports on.
public enum WeeklyMetric: String, CaseIterable, Sendable {
    case charge   // recovery, 0–100
    case effort   // strain / Effort, 0–100
    case rest     // sleep performance composite, 0–100
    case rhr      // resting heart rate, bpm
    case hrv      // heart-rate variability, ms

    /// Human label for the metric (matches the rest of the app's naming).
    public var label: String {
        switch self {
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest:   return "Rest"
        case .rhr:    return "Resting HR"
        case .hrv:    return "HRV"
        }
    }

    /// Display unit suffix (empty for the unitless 0–100 scores).
    public var unit: String {
        switch self {
        case .charge, .effort, .rest: return ""
        case .rhr: return "bpm"
        case .hrv: return "ms"
        }
    }

    /// True when a HIGHER value is the better outcome. Resting HR is the lone
    /// metric where lower is better, so "up" is framed negatively for it.
    public var higherIsBetter: Bool {
        switch self {
        case .rhr: return false
        default:   return true
        }
    }

    /// A coarse "typical day-to-day range" used to normalise week-over-week deltas
    /// so movers on different scales (a 6 ms HRV swing vs a 4 bpm RHR swing) can be
    /// ranked against each other. Deliberately conservative, deterministic constants
    /// (not personal baselines) so ranking is stable and explainable.
    public var typicalSpread: Double {
        switch self {
        case .charge: return 12.0   // recovery points
        case .effort: return 12.0   // Effort points
        case .rest:   return 12.0   // Rest points
        case .rhr:    return 4.0    // bpm
        case .hrv:    return 8.0    // ms
        }
    }
}

// MARK: - Per-metric line

/// One metric's line in the weekly digest.
public struct WeeklyMetricSummary: Equatable, Sendable {
    public let metric: WeeklyMetric
    /// This-week stats (Mon–Sun). `.empty` when the week has no readings.
    public let thisWeek: SeriesStat
    /// This week vs the immediately preceding Mon–Sun week.
    public let weekOverWeek: PeriodComparison
    /// Mean over the trailing baseline window (the `baselineWeeks` complete weeks
    /// before this one), or nil when there were no baseline readings.
    public let baselineMean: Double?
    /// thisWeek.mean − baselineMean, or nil when baselineMean is nil.
    public let vsBaseline: Double?

    public init(metric: WeeklyMetric, thisWeek: SeriesStat,
                weekOverWeek: PeriodComparison, baselineMean: Double?,
                vsBaseline: Double?) {
        self.metric = metric
        self.thisWeek = thisWeek
        self.weekOverWeek = weekOverWeek
        self.baselineMean = baselineMean
        self.vsBaseline = vsBaseline
    }

    /// Signed week-over-week change in the metric's own units (this − last).
    public var wowDelta: Double { weekOverWeek.delta }

    /// Direction of the week-over-week change expressed as GOOD / BAD / FLAT,
    /// folding in `higherIsBetter` (so a RHR rise reads as "worse"). 0 when flat
    /// or a period is empty.
    public var wowGoodness: Int {
        guard weekOverWeek.direction != 0 else { return 0 }
        let up = weekOverWeek.direction > 0
        let good = (up == metric.higherIsBetter)
        return good ? 1 : -1
    }

    /// The week-over-week change scaled by the metric's typical spread, so movers
    /// on different units are comparable. 0 when a period is empty.
    public var normalisedMove: Double {
        guard weekOverWeek.current.n > 0, weekOverWeek.previous.n > 0 else { return 0 }
        let s = metric.typicalSpread
        return s > 0 ? wowDelta / s : 0
    }

    /// True when the week-over-week comparison rests on a sparse side: both weeks
    /// carry at least one reading, but either has fewer than
    /// `WeeklyDigestEngine.minDaysForFocus` days. A rough comparison still shows its
    /// raw arrow + %, but the UI shouldn't dress it in a confident good/bad verdict —
    /// a 43% "drop" off 2 days isn't a trend (the #463 chips-vs-summary contradiction).
    public var isRoughComparison: Bool {
        let cur = weekOverWeek.current.n
        let prev = weekOverWeek.previous.n
        guard cur > 0, prev > 0 else { return false }
        return cur < WeeklyDigestEngine.minDaysForFocus
            || prev < WeeklyDigestEngine.minDaysForFocus
    }
}

// MARK: - Digest

/// The complete week-in-review.
public struct WeeklyDigest: Equatable, Sendable {
    /// The Monday that anchors "this week" ("yyyy-MM-dd").
    public let weekStart: String
    /// The Sunday that ends "this week" ("yyyy-MM-dd").
    public let weekEnd: String
    /// Per-metric summaries, in WeeklyMetric.allCases order.
    public let metrics: [WeeklyMetricSummary]
    /// Number of distinct days this week that carried at least one reading.
    public let daysWithData: Int
    /// Sleep-consistency: SD of this week's Rest values (lower = steadier). nil when
    /// fewer than 2 Rest nights this week. In Rest points.
    public let sleepConsistencySD: Double?
    /// Strain-vs-recovery balance read for the week (see `BalanceRead`).
    public let balance: BalanceRead
    /// 1–2 plain-English focal points, most salient first.
    public let focalPoints: [String]
    /// The same focal points as structured values, in the same order, so the app can render them in
    /// the reader's language. `focalPoints` is each line's `englishText`.
    public let focalLines: [DigestFocalLine]

    public init(weekStart: String, weekEnd: String, metrics: [WeeklyMetricSummary],
                daysWithData: Int, sleepConsistencySD: Double?, balance: BalanceRead,
                focalPoints: [String], focalLines: [DigestFocalLine] = []) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.metrics = metrics
        self.daysWithData = daysWithData
        self.sleepConsistencySD = sleepConsistencySD
        self.balance = balance
        self.focalPoints = focalPoints
        self.focalLines = focalLines
    }

    /// Look up one metric's summary.
    public func summary(_ metric: WeeklyMetric) -> WeeklyMetricSummary? {
        metrics.first { $0.metric == metric }
    }

    /// True when no metric carried a single reading this week (caller can show an
    /// empty state instead of a digest).
    public var isEmpty: Bool { daysWithData == 0 }
}

/// How this week's Effort (strain) sat against this week's Charge (recovery).
public enum BalanceRead: String, Equatable, Sendable {
    case overreaching   // Effort high vs Charge — leaning into the red
    case balanced       // Effort and Charge roughly tracking
    case underloaded    // Effort low vs Charge — lots in the tank, little spent
    case insufficient   // not enough of both to call it

    /// Plain-English line for the UI.
    public var sentence: String {
        switch self {
        case .overreaching:
            return "Your Effort outpaced your Charge this week: you leaned into the red. Watch for a recovery dip."
        case .balanced:
            return "Effort and Charge tracked together this week: a sustainable load."
        case .underloaded:
            return "You carried more Charge than you spent this week: there's room to push if you want it."
        case .insufficient:
            return "Not enough Effort and Charge days this week to read your balance."
        }
    }
}

/// One weekly-digest focal point as data rather than prose, so the app layer can localize it.
/// `englishText` is the sentence `WeeklyDigest.focalPoints` carries, byte for byte.
public enum DigestFocalLine: Equatable, Sendable {
    /// How far a mover moved: a whole percentage, or (when the percentage is under 1 or undefined) an
    /// absolute amount already rounded to one decimal, in the metric's unit (empty = Charge/Effort/Rest points).
    public enum Magnitude: Equatable, Sendable {
        case percent(Int)
        case amount(Double, unit: String)
    }

    /// The biggest week-over-week movers. `direction` is the sign of the move (1, -1 or 0); `goodness` is
    /// `WeeklyMetricSummary.wowGoodness` (1 good, -1 worth a look, 0 neutral).
    case mover(metric: WeeklyMetric, direction: Int, magnitude: Magnitude, goodness: Int,
               thisAverage: Int, lastAverage: Int)
    /// A non-trivial strain-vs-recovery read (`BalanceRead.sentence`).
    case balance(BalanceRead)
    /// This week has fewer than `minDaysForFocus` days so far.
    case currentWeekSparse(days: Int)
    /// Last week had fewer than `minDaysForFocus` days.
    case previousWeekSparse(days: Int)
    /// Nothing moved and Rest held within the steadiness band (SD rounded to one decimal).
    case steadyRest(sd: Double)
    /// Nothing moved meaningfully.
    case steady

    public var englishText: String {
        switch self {
        case let .mover(metric, direction, magnitude, goodness, thisAverage, lastAverage):
            let directionWord = direction > 0 ? "up" : (direction < 0 ? "down" : "flat")
            let magnitudeText: String
            switch magnitude {
            case .percent(let p): magnitudeText = "\(p)%"
            case let .amount(v, unit): magnitudeText = "\(v)\(unit.isEmpty ? " pts" : " " + unit)"
            }
            let frame: String
            switch goodness {
            case 1:  frame = ", a good sign"
            case -1: frame = ", worth a look"
            default: frame = ""
            }
            return "\(metric.label) is \(directionWord) \(magnitudeText) week over week"
                + " (avg \(thisAverage) vs \(lastAverage))\(frame)."
        case .balance(let b):
            return b.sentence
        case .currentWeekSparse(let days):
            let dayWord = days == 1 ? "day" : "days"
            return "Only \(days) \(dayWord) into this week so far, too early to "
                + "call a week-over-week trend yet."
        case .previousWeekSparse(let days):
            let dayWord = days == 1 ? "day" : "days"
            return "Last week only had \(days) \(dayWord) of data, so week-over-week "
                + "changes are rough, not a trend."
        case .steadyRest(let sd):
            return "A steady week: Rest held even (±\(sd) pts) and nothing moved much."
        case .steady:
            return "A steady week: no metric moved meaningfully from last week."
        }
    }
}

public enum WeeklyDigestEngine {

    /// How many complete weeks before "this week" form the vs-baseline comparison.
    public static let baselineWeeks: Int = 4
    /// Minimum days each side needs before a week-over-week move is "real" enough
    /// to surface as a focal point (guards against a 1-day week swinging wildly).
    public static let minDaysForFocus: Int = 3

    // MARK: - Entry point

    /// Build the weekly digest anchored on the Monday of the week containing
    /// `anchorDay` ("yyyy-MM-dd", typically today).
    ///
    /// - Parameters:
    ///   - byMetric: per-metric day→value maps. Missing metrics / days are simply
    ///     absent; this is robust to sparse data.
    ///   - anchorDay: any "yyyy-MM-dd" in the target week (we snap to its Monday).
    ///     A non-parseable string yields an all-empty digest.
    ///   - effortDisplayFactor: multiplier applied to EFFORT averages (and the pts
    ///     fallback magnitude) in the rendered focal-point sentences ONLY, so a user
    ///     on the 0–21 Effort scale (#268) never reads a stored 0–100 mean in prose.
    ///     Percent changes are scale-invariant and stay untouched. Defaults to 1.0
    ///     (stored scale) so existing callers are byte-identical. Display-only: no
    ///     stat, delta or threshold changes.
    public static func build(byMetric: [WeeklyMetric: [String: Double]],
                             anchorDay: String,
                             effortDisplayFactor: Double = 1.0) -> WeeklyDigest {
        guard let monday = mondayOfWeek(containing: anchorDay) else {
            return emptyDigest(weekStart: anchorDay, weekEnd: anchorDay)
        }
        let sunday = addDays(monday, 6)
        let lastMonday = addDays(monday, -7)
        let lastSunday = addDays(monday, -1)

        // Baseline window: the `baselineWeeks` complete weeks ending the day before
        // last week starts (so it never overlaps this week or last week).
        let baselineEnd = addDays(lastMonday, -1)               // Sunday before last week
        let baselineStart = addDays(lastMonday, -7 * baselineWeeks)

        var summaries: [WeeklyMetricSummary] = []
        var daysSeen: Set<String>? = []

        for metric in WeeklyMetric.allCases {
            let series = byMetric[metric] ?? [:]

            var noAccum: Set<String>? = nil
            let thisVals = valuesInRange(series, start: monday, end: sunday, daysSeen: &daysSeen)
            let lastVals = valuesInRange(series, start: lastMonday, end: lastSunday, daysSeen: &noAccum)
            let baseVals = valuesInRange(series, start: baselineStart, end: baselineEnd, daysSeen: &noAccum)

            let thisStat = ComparisonEngine.stat(thisVals)
            let wow = ComparisonEngine.compare(current: thisVals, previous: lastVals)
            let baseMean: Double? = baseVals.isEmpty ? nil
                : baseVals.reduce(0, +) / Double(baseVals.count)
            let vsBase: Double? = baseMean.map { thisStat.mean - $0 }

            summaries.append(WeeklyMetricSummary(
                metric: metric, thisWeek: thisStat, weekOverWeek: wow,
                baselineMean: baseMean, vsBaseline: vsBase))
        }

        // Sleep consistency: SD of this week's Rest series (lower = steadier).
        let restStat = summaries.first { $0.metric == .rest }?.thisWeek
        let restConsistency: Double? = (restStat?.n ?? 0) >= 2 ? restStat?.stdev : nil

        let balance = balanceRead(summaries)
        let focal = focalLines(summaries: summaries, balance: balance,
                               consistencySD: restConsistency,
                               effortDisplayFactor: effortDisplayFactor)

        return WeeklyDigest(
            weekStart: monday, weekEnd: sunday, metrics: summaries,
            daysWithData: (daysSeen ?? []).count, sleepConsistencySD: restConsistency,
            balance: balance, focalPoints: focal.map(\.englishText), focalLines: focal)
    }

    // MARK: - Balance read

    /// Read this week's Effort against this week's Charge. Both are 0–100; a clearly
    /// higher Effort mean than Charge mean is "overreaching", clearly lower is
    /// "underloaded", within `balanceBand` is "balanced". Needs ≥ minDaysForFocus
    /// of each, else `.insufficient`.
    static let balanceBand: Double = 10.0

    static func balanceRead(_ summaries: [WeeklyMetricSummary]) -> BalanceRead {
        guard
            let effort = summaries.first(where: { $0.metric == .effort })?.thisWeek,
            let charge = summaries.first(where: { $0.metric == .charge })?.thisWeek,
            effort.n >= minDaysForFocus, charge.n >= minDaysForFocus
        else { return .insufficient }

        let gap = effort.mean - charge.mean
        if gap > balanceBand { return .overreaching }
        if gap < -balanceBand { return .underloaded }
        return .balanced
    }

    // MARK: - Focal points

    /// Pick 1–2 plain-English focal points, most salient first.
    ///
    /// Priority order:
    ///   1. The single biggest *meaningful* week-over-week mover (both weeks have
    ///      ≥ minDaysForFocus days, and the normalised move clears `focusThreshold`),
    ///      rendered with its good/bad framing.
    ///   2. Either the balance read (when not balanced/insufficient) OR the second
    ///      biggest mover — whichever is more salient — as a supporting line.
    ///
    /// If nothing clears the bar, a single steady-week line is returned.
    static let focusThreshold: Double = 0.5   // half a "typical spread" of movement

    static func focalPoints(summaries: [WeeklyMetricSummary],
                            balance: BalanceRead,
                            consistencySD: Double?,
                            effortDisplayFactor: Double = 1.0) -> [String] {
        focalLines(summaries: summaries, balance: balance, consistencySD: consistencySD,
                   effortDisplayFactor: effortDisplayFactor).map(\.englishText)
    }

    /// `focalPoints` as structured lines (see `DigestFocalLine`).
    static func focalLines(summaries: [WeeklyMetricSummary],
                           balance: BalanceRead,
                           consistencySD: Double?,
                           effortDisplayFactor: Double = 1.0) -> [DigestFocalLine] {
        // Rank movers by |normalised move|, significant (enough days) first.
        let movers = summaries
            .filter { $0.weekOverWeek.current.n >= minDaysForFocus
                   && $0.weekOverWeek.previous.n >= minDaysForFocus
                   && abs($0.normalisedMove) >= focusThreshold }
            .sorted { abs($0.normalisedMove) > abs($1.normalisedMove) }

        var lines: [DigestFocalLine] = []

        if let top = movers.first {
            lines.append(moverLine(top, effortDisplayFactor: effortDisplayFactor))
        }

        // Supporting line: prefer a non-trivial balance read, else the 2nd mover.
        if balance == .overreaching || balance == .underloaded {
            lines.append(.balance(balance))
        } else if movers.count >= 2 {
            lines.append(moverLine(movers[1], effortDisplayFactor: effortDisplayFactor))
        }

        // Nothing cleared the mover bar. Distinguish three very different reasons:
        //   • the CURRENT week is SPARSE (fewer than minDaysForFocus days in) — we simply
        //     can't call a week-over-week trend yet, even though the per-metric chips may
        //     show a big raw swing off 1–2 days. Saying "a steady week — nothing moved"
        //     there flatly contradicts those chips (the #463 report). Be honest instead.
        //   • the PREVIOUS week is SPARSE (typical new user in week 2): movers are gated
        //     on previous.n ≥ minDaysForFocus, so nothing can surface even when the chips
        //     show big raw %s off last week's 1–2 days — the same #463 contradiction,
        //     mirrored. Same honesty, aimed at last week.
        //   • the week has enough days and genuinely held even — the calm "steady" read.
        if lines.isEmpty {
            let currentDays = summaries.map { $0.weekOverWeek.current.n }.max() ?? 0
            let prevDays = summaries.map { $0.weekOverWeek.previous.n }.max() ?? 0
            if currentDays >= 1 && currentDays < minDaysForFocus {
                lines.append(.currentWeekSparse(days: currentDays))
            } else if currentDays >= minDaysForFocus, prevDays >= 1, prevDays < minDaysForFocus {
                lines.append(.previousWeekSparse(days: prevDays))
            } else if let sd = consistencySD, sd <= 6.0 {
                lines.append(.steadyRest(sd: round1(sd)))
            } else {
                lines.append(.steady)
            }
        }

        return Array(lines.prefix(2))
    }

    /// Render one mover as a plain-English sentence, the way BehaviorInsights.sentence
    /// renders an effect. Folds in good/bad framing (a Charge rise is "up — good", a
    /// Resting HR rise is "up — worth a look"). `effortDisplayFactor` rescales the
    /// EFFORT averages (and its pts fallback) for display only — % is scale-invariant.
    static func moverSentence(_ s: WeeklyMetricSummary,
                              effortDisplayFactor: Double = 1.0) -> String {
        moverLine(s, effortDisplayFactor: effortDisplayFactor).englishText
    }

    /// `moverSentence` as a structured line (see `DigestFocalLine.mover`).
    static func moverLine(_ s: WeeklyMetricSummary,
                          effortDisplayFactor: Double = 1.0) -> DigestFocalLine {
        let f = s.metric == .effort ? effortDisplayFactor : 1.0
        let direction = s.wowDelta > 0 ? 1 : (s.wowDelta < 0 ? -1 : 0)
        let magnitude: DigestFocalLine.Magnitude
        if let pct = s.weekOverWeek.pctChange, abs(pct) >= 1 {
            magnitude = .percent(roundedInt(abs(pct)))
        } else {
            magnitude = .amount(round1(abs(s.wowDelta) * f), unit: s.metric.unit)
        }
        return .mover(metric: s.metric, direction: direction, magnitude: magnitude,
                      goodness: s.wowGoodness,
                      thisAverage: roundedInt(s.thisWeek.mean * f),
                      lastAverage: roundedInt(s.weekOverWeek.previous.mean * f))
    }

    // MARK: - Range extraction

    /// Collect the values of `series` whose day is within [start, end] inclusive
    /// (ISO string comparison is chronological), ordered chronologically so the
    /// resulting SeriesStat slope is meaningful. When `daysSeen` is non-nil, the days
    /// that carried a value are recorded into it (pass `&someNilOptional` to skip).
    static func valuesInRange(_ series: [String: Double], start: String, end: String,
                              daysSeen: inout Set<String>?) -> [Double] {
        let inRange = series.filter { $0.key >= start && $0.key <= end }
        if daysSeen != nil {
            for k in inRange.keys { daysSeen?.insert(k) }
        }
        // Sort by day string so the slope is chronological regardless of dict order.
        return inRange.sorted { $0.key < $1.key }.map { $0.value }
    }

    // MARK: - Pure week math (timezone/locale-free)

    /// The Monday (ISO "yyyy-MM-dd") of the week containing `day`. nil if `day`
    /// can't be parsed as a valid yyyy-MM-dd.
    public static func mondayOfWeek(containing day: String) -> String? {
        guard let (y, m, d) = parseYMD(day), let w = weekday(y, m, d) else { return nil }
        // weekday: 0=Sunday … 6=Saturday. Days since Monday: Mon=0 … Sun=6.
        let sinceMonday = (w + 6) % 7
        return addDays(day, -sinceMonday)
    }

    /// Add `n` days (may be negative) to a "yyyy-MM-dd" day, returning "yyyy-MM-dd".
    /// Falls back to the input string if it can't be parsed.
    public static func addDays(_ day: String, _ n: Int) -> String {
        guard let (y, m, d) = parseYMD(day) else { return day }
        let jdn = julianDayNumber(y, m, d) + n
        let (ny, nm, nd) = fromJulianDayNumber(jdn)
        return formatYMD(ny, nm, nd)
    }

    /// Sakamoto's day-of-week: 0=Sunday, 1=Monday … 6=Saturday. nil for an invalid
    /// calendar date.
    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        guard (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        var yy = y
        if m < 3 { yy -= 1 }
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
    }

    /// Days in a month, leap-year aware.
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2: return isLeap(y) ? 29 : 28
        default: return 0
        }
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) }

    /// Parse "yyyy-MM-dd" into integer components, validating the date is real.
    /// Public so UI layers can format week-range labels without re-implementing the
    /// (timezone-free) date parse.
    public static func parseYMD(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        return (y, m, d)
    }

    /// Zero-padded "yyyy-MM-dd".
    static func formatYMD(_ y: Int, _ m: Int, _ d: Int) -> String {
        let yy = y < 1000 ? String(format: "%04d", y) : "\(y)"
        let mm = m < 10 ? "0\(m)" : "\(m)"
        let dd = d < 10 ? "0\(d)" : "\(d)"
        return "\(yy)-\(mm)-\(dd)"
    }

    /// Convert a proleptic-Gregorian date to a Julian Day Number (integer-only,
    /// timezone-free). Used purely for date arithmetic.
    static func julianDayNumber(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    /// Inverse of `julianDayNumber`.
    static func fromJulianDayNumber(_ jdn: Int) -> (Int, Int, Int) {
        let a = jdn + 32044
        let b = (4 * a + 3) / 146097
        let c = a - (146097 * b) / 4
        let dd = (4 * c + 3) / 1461
        let e = c - (1461 * dd) / 4
        let mm = (5 * e + 2) / 153
        let day = e - (153 * mm + 2) / 5 + 1
        let month = mm + 3 - 12 * (mm / 10)
        let year = 100 * b + dd - 4800 + mm / 10
        return (year, month, day)
    }

    // MARK: - Empty digest

    static func emptyDigest(weekStart: String, weekEnd: String) -> WeeklyDigest {
        let summaries = WeeklyMetric.allCases.map { m in
            WeeklyMetricSummary(metric: m, thisWeek: .empty,
                                weekOverWeek: ComparisonEngine.compare(current: [], previous: []),
                                baselineMean: nil, vsBaseline: nil)
        }
        return WeeklyDigest(weekStart: weekStart, weekEnd: weekEnd, metrics: summaries,
                            daysWithData: 0, sleepConsistencySD: nil,
                            balance: .insufficient, focalPoints: [])
    }

    // MARK: - Formatting helpers (mirror BehaviorInsights)

    static func roundedInt(_ x: Double) -> Int { Int(x.rounded()) }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
