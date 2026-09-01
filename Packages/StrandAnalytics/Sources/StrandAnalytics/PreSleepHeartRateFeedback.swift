import Foundation
import WhoopProtocol
import WhoopStore

/// An opt-in, descriptive pre-sleep heart-rate reading for the following morning.
///
/// The caller supplies a timestamp-coalesced HR timeline: Repository's existing HR reads already
/// coalesce measured and PPG-derived samples, with measured data taking precedence. This type selects
/// the longest supplied sleep session, reads the declared half-open window immediately before it, and
/// compares that observation with a personal rolling baseline. It neither diagnoses nor recommends an
/// action. Journal answers are returned only as facts from the same day; one night cannot establish an
/// association, so they never alter the reading or become an insight.
public enum PreSleepHeartRateFeedback {
    /// Baseline configuration deliberately shares the existing HR plausibility range while keeping a
    /// small floor spread for transparent personal comparison. `rollingMeanSD` is the existing auditable
    /// baseline primitive; this is not a new scoring model.
    public static let baselineCfg = MetricCfg(minVal: SleepHeartRateContrast.validMinBpm,
                                              maxVal: SleepHeartRateContrast.validMaxBpm,
                                              floorSpread: 2,
                                              halfLifeB: 14,
                                              halfLifeS: 21)
    public static let defaultPreSleepWindowSeconds = 30 * 60
    public static let defaultMinimumValidSamples = 10
    public static let minimumBaselineNights = Baselines.minNightsSeed

    /// A prior eligible pre-sleep observation. Callers persist/assemble history; this pure slice does
    /// not write, schedule a prompt, or penalize a missing night.
    public struct HistoricalReading: Equatable, Sendable {
        public let day: String
        public let meanBpm: Double

        public init(day: String, meanBpm: Double) {
            self.day = day
            self.meanBpm = meanBpm
        }
    }

    /// Why a morning reading is or is not available. Every non-eligible state is recoverable on a
    /// later, sufficiently covered night; none creates a streak, goal, or obligation.
    public enum Eligibility: Equatable, Sendable {
        case disabled
        case invalidDay
        case invalidWindow
        case missingPrimarySleep
        case insufficientPreSleepSamples(valid: Int, required: Int)
        case insufficientBaseline(validNights: Int, required: Int)
        case staleBaseline(daysSinceUpdate: Int)
        case eligible
    }

    /// The observed, un-imputed pre-sleep data. Completeness is stated as a sample count because raw
    /// HR cadence can vary; this slice does not pretend a count is a percentage of time covered.
    public struct Observation: Equatable, Sendable {
        public let primarySleepStartTs: Int
        public let primarySleepEndTs: Int
        public let windowStartTs: Int
        public let windowEndTs: Int
        public let meanBpm: Double
        public let validSamples: Int
        public let totalTimestampSamples: Int

        public init(primarySleepStartTs: Int, primarySleepEndTs: Int,
                    windowStartTs: Int, windowEndTs: Int, meanBpm: Double,
                    validSamples: Int, totalTimestampSamples: Int) {
            self.primarySleepStartTs = primarySleepStartTs
            self.primarySleepEndTs = primarySleepEndTs
            self.windowStartTs = windowStartTs
            self.windowEndTs = windowEndTs
            self.meanBpm = meanBpm
            self.validSamples = validSamples
            self.totalTimestampSamples = totalTimestampSamples
        }
    }

    /// A personal comparison only, never a population norm or a health classification.
    public struct Comparison: Equatable, Sendable {
        public let baselineBpm: Double
        public let deltaBpm: Double
        public let baselineNights: Int
        public let baselineStatus: BaselineStatus

        public init(baselineBpm: Double, deltaBpm: Double, baselineNights: Int,
                    baselineStatus: BaselineStatus) {
            self.baselineBpm = baselineBpm
            self.deltaBpm = deltaBpm
            self.baselineNights = baselineNights
            self.baselineStatus = baselineStatus
        }
    }

    /// Explicit limits that a presentation layer must keep visible rather than turning into certainty.
    public enum Uncertainty: Equatable, Sendable {
        /// The first eligible personal baseline is usable but not yet trusted by `Baselines`.
        case provisionalBaseline
        /// There are not yet enough valid historical nights to make any personal comparison.
        case noPersonalComparison
        /// A mature personal baseline has not received a plausible value recently enough to compare.
        case staleBaseline(daysSinceUpdate: Int)
    }

    /// This slice intentionally makes no causal inference from a single observation or its journal facts.
    public enum Inference: Equatable, Sendable { case notEstablished }
    /// This slice intentionally cannot support a behavior, treatment, or other recommendation.
    public enum Recommendation: Equatable, Sendable { case unsupported }

    /// A projection of a same-day `JournalEntry`. It preserves what was logged without exposing notes or
    /// claiming that the entry explains this reading.
    public struct JournalFact: Equatable, Sendable {
        public let day: String
        public let question: String
        public let answeredYes: Bool
        public let numericValue: Double?

        public init(day: String, question: String, answeredYes: Bool, numericValue: Double?) {
            self.day = day
            self.question = question
            self.answeredYes = answeredYes
            self.numericValue = numericValue
        }
    }

    public struct Feedback: Equatable, Sendable {
        public let eligibility: Eligibility
        public let observation: Observation?
        public let comparison: Comparison?
        public let uncertainty: [Uncertainty]
        public let inference: Inference
        public let recommendation: Recommendation
        /// Same-day journal facts only. They are deliberately not treated as a causal insight.
        public let journalContext: [JournalFact]

        public init(eligibility: Eligibility, observation: Observation?, comparison: Comparison?,
                    uncertainty: [Uncertainty], inference: Inference,
                    recommendation: Recommendation, journalContext: [JournalFact]) {
            self.eligibility = eligibility
            self.observation = observation
            self.comparison = comparison
            self.uncertainty = uncertainty
            self.inference = inference
            self.recommendation = recommendation
            self.journalContext = journalContext
        }
    }

    /// Produce the next-morning reading from existing timestamped HR and sleep primitives.
    ///
    /// `hr` is expected to be the repository's measured/PPG-coalesced timeline. To remain safe for other
    /// callers, duplicate timestamps are also ignored after the first element, preserving the caller's
    /// precedence order. Both window bounds are transparent and half-open: `[sleep.start - window, sleep.start)`.
    public static func evaluate(enabled: Bool, sessions: [SleepSession], hr: [HRSample],
                                history: [HistoricalReading], journalEntries: [JournalEntry], day: String,
                                minimumValidSamples: Int = defaultMinimumValidSamples,
                                preSleepWindowSeconds: Int = defaultPreSleepWindowSeconds) -> Feedback {
        let unsupported = Recommendation.unsupported
        let noInference = Inference.notEstablished
        guard enabled else {
            return Feedback(eligibility: .disabled, observation: nil, comparison: nil, uncertainty: [],
                            inference: noInference, recommendation: unsupported, journalContext: [])
        }
        guard let evaluationDate = canonicalDay(day) else {
            return Feedback(eligibility: .invalidDay, observation: nil, comparison: nil, uncertainty: [],
                            inference: noInference, recommendation: unsupported, journalContext: [])
        }
        guard minimumValidSamples > 0, preSleepWindowSeconds > 0 else {
            return Feedback(eligibility: .invalidWindow, observation: nil, comparison: nil, uncertainty: [],
                            inference: noInference, recommendation: unsupported, journalContext: [])
        }
        let sessionsWithDuration = sessions.compactMap { session -> (session: SleepSession, duration: Int)? in
            let (duration, overflow) = session.end.subtractingReportingOverflow(session.start)
            return !overflow && duration > 0 ? (session, duration) : nil
        }
        guard let primary = sessionsWithDuration.max(by: { $0.duration < $1.duration })?.session else {
            return Feedback(eligibility: .missingPrimarySleep, observation: nil, comparison: nil, uncertainty: [],
                            inference: noInference, recommendation: unsupported, journalContext: [])
        }

        let (start, windowOverflow) = primary.start.subtractingReportingOverflow(preSleepWindowSeconds)
        guard !windowOverflow else {
            return Feedback(eligibility: .invalidWindow, observation: nil, comparison: nil, uncertainty: [],
                            inference: noInference, recommendation: unsupported, journalContext: [])
        }
        let inWindow = deduplicated(hr).filter { $0.ts >= start && $0.ts < primary.start }
        let valid = inWindow.filter { baselineCfg.minVal <= Double($0.bpm) && Double($0.bpm) <= baselineCfg.maxVal }
        guard valid.count >= minimumValidSamples else {
            return Feedback(eligibility: .insufficientPreSleepSamples(valid: valid.count, required: minimumValidSamples),
                            observation: nil, comparison: nil, uncertainty: [], inference: noInference,
                            recommendation: unsupported, journalContext: [])
        }
        let mean = Double(valid.reduce(0) { $0 + $1.bpm }) / Double(valid.count)
        let observation = Observation(primarySleepStartTs: primary.start, primarySleepEndTs: primary.end,
                                      windowStartTs: start, windowEndTs: primary.start, meanBpm: mean,
                                      validSamples: valid.count, totalTimestampSamples: inWindow.count)
        // Baselines use prior nights only and
        // `rollingMeanSD` requires oldest-to-newest input. Retain the first caller-supplied reading
        // for a repeated canonical day; one day contributes at most one night and no synthetic average
        // is invented.
        var seenDays = Set<String>()
        let priorHistory = history
            .compactMap { reading -> (reading: HistoricalReading, date: Date)? in
                guard let date = canonicalDay(reading.day), date < evaluationDate,
                      seenDays.insert(reading.day).inserted else { return nil }
                return (reading, date)
            }
            .sorted { $0.date < $1.date }
        let rollingBaseline = Baselines.rollingMeanSD(priorHistory.map(\.reading.meanBpm), cfg: baselineCfg)
        let latestContributingDate = priorHistory.last {
            baselineCfg.minVal <= $0.reading.meanBpm && $0.reading.meanBpm <= baselineCfg.maxVal
        }?.date
        let nightsSinceUpdate = latestContributingDate.flatMap {
            gregorianUTC.dateComponents([.day], from: $0, to: evaluationDate).day
        }.map { max(0, $0) } ?? 0
        let baseline = BaselineState(
            baseline: rollingBaseline.baseline,
            spread: rollingBaseline.spread,
            nValid: rollingBaseline.nValid,
            nightsSinceUpdate: nightsSinceUpdate,
            status: Baselines.computeStatus(nValid: rollingBaseline.nValid,
                                            nightsSinceUpdate: nightsSinceUpdate)
        )
        let context = journalEntries.filter { $0.day == day }.map {
            JournalFact(day: $0.day, question: $0.question, answeredYes: $0.answeredYes,
                        numericValue: $0.numericValue)
        }
        guard baseline.nValid >= minimumBaselineNights else {
            return Feedback(eligibility: .insufficientBaseline(validNights: baseline.nValid,
                                                                 required: minimumBaselineNights),
                            observation: observation, comparison: nil, uncertainty: [.noPersonalComparison],
                            inference: noInference, recommendation: unsupported, journalContext: context)
        }
        guard baseline.usable else {
            return Feedback(eligibility: .staleBaseline(daysSinceUpdate: baseline.nightsSinceUpdate),
                            observation: observation, comparison: nil,
                            uncertainty: [.staleBaseline(daysSinceUpdate: baseline.nightsSinceUpdate)],
                            inference: noInference, recommendation: unsupported, journalContext: context)
        }

        let comparison = Comparison(baselineBpm: baseline.baseline, deltaBpm: mean - baseline.baseline,
                                    baselineNights: baseline.nValid, baselineStatus: baseline.status)
        let uncertainty: [Uncertainty] = baseline.status == .trusted ? [] : [.provisionalBaseline]
        return Feedback(eligibility: .eligible, observation: observation, comparison: comparison,
                        uncertainty: uncertainty, inference: noInference, recommendation: unsupported,
                        journalContext: context)
    }

    /// Stored, not computed (#1784). `canonicalDay` reads this once per history row, so a computed
    /// property built a fresh `Calendar` for every prior night. `Calendar` is a `Sendable` value type,
    /// so one shared instance is safe and the construction happens once.
    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func canonicalDay(_ day: String) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digitPositions.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }

        let year = Int(bytes[0] - 48) * 1_000 + Int(bytes[1] - 48) * 100
            + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let dayOfMonth = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        let calendar = gregorianUTC
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard roundTrip.era == 1 && roundTrip.year == year && roundTrip.month == month
            && roundTrip.day == dayOfMonth else { return nil }
        return date
    }

    /// One sample per timestamp, FIRST occurrence wins.
    ///
    /// First-wins is the caller's precedence order, not an arbitrary pick: `evaluate`'s contract is an
    /// already-coalesced timeline where measured data outranks PPG-derived, so the first element for a
    /// timestamp is the one the repository chose. Stated here as well as on `evaluate` because the rule
    /// is invisible at this call site, and a later reader changing it to last-wins would silently invert
    /// that precedence (#1784).
    private static func deduplicated(_ hr: [HRSample]) -> [HRSample] {
        var seen = Set<Int>()
        return hr.filter { seen.insert($0.ts).inserted }
    }
}
