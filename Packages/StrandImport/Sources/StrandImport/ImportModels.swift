import Foundation

// MARK: - Source provenance

/// Where a normalized row originated. Mirrors the `dataSource.kind` provenance
/// described in the Strand design spec (§5).
public enum DataSourceKind: String, Sendable, Codable, Equatable, CaseIterable {
    case appleHealth
    case whoopExport
    /// Xiaomi Smart Band (Mi Band) — imported from the Mi Fitness iOS app's
    /// on-device SQLite store (`DataBase/<user_id>/de/<user_id>.db`). Account-free,
    /// fully offline: NOOP reads the file the user already owns.
    case xiaomiBand
    /// Oura Ring — the user's own Account data export (JSON), imported from the file
    /// Oura hands them. Sleep periods + daily readiness/activity → daily metrics + sleep
    /// sessions. Fully offline, no Oura cloud/API.
    case ouraImport
    /// Fitbit — the user's own Google Takeout → Fitbit JSON export (per-day sleep /
    /// resting_heart_rate / steps / heart_rate files). Fully offline, no Fitbit/Google API.
    case fitbitImport
    /// Garmin — the user's own Garmin Connect "Export Your Data" (GDPR) wellness JSON/CSV
    /// (sleep / resting HR / stress / steps). The FIT activity files inside the same ZIP are
    /// handled by the wave-1 FIT parser; this path does the WELLNESS daily + sleep only.
    case garminImport
}

// MARK: - Generic health sample (Apple Health Record sink)

/// A single normalized Apple Health `<Record>` reading.
///
/// Timestamps are normalized to UTC `Date`s while the original UTC offset (in
/// minutes) is preserved in `tzOffsetMin`, matching the `hkSample` table shape
/// in the design spec (§5).
public struct HealthSample: Sendable, Equatable, Hashable {
    /// HealthKit type identifier, stripped of the `HKQuantityTypeIdentifier` /
    /// `HKCategoryTypeIdentifier` prefix (e.g. `HeartRate`, `SleepAnalysis`).
    public var type: String
    /// Numeric value, when the record is quantitative. `nil` for pure category
    /// records whose meaning lives in `valueString`.
    public var value: Double?
    /// Raw string value as it appeared in the export (category enum strings,
    /// or the textual numeric value). Always populated when present.
    public var valueString: String?
    /// Unit string from the record (e.g. `count/min`, `%`, `degC`). May be nil.
    public var unit: String?
    /// Start of the sample, normalized to UTC.
    public var start: Date
    /// End of the sample, normalized to UTC.
    public var end: Date
    /// Original UTC offset of the source timestamp, in minutes (e.g. `60` for
    /// `+0100`, `-300` for `-0500`).
    public var tzOffsetMin: Int
    /// `sourceName` attribute (the device/app that produced the record).
    public var sourceName: String?

    public init(
        type: String,
        value: Double?,
        valueString: String?,
        unit: String?,
        start: Date,
        end: Date,
        tzOffsetMin: Int,
        sourceName: String?
    ) {
        self.type = type
        self.value = value
        self.valueString = valueString
        self.unit = unit
        self.start = start
        self.end = end
        self.tzOffsetMin = tzOffsetMin
        self.sourceName = sourceName
    }

    /// Dedupe key per the spec: `type+startDate+endDate+sourceName+value`.
    /// Records nested in a `<Correlation>` also appear at top level; collapsing
    /// on this key removes the duplicates.
    public var dedupeKey: String {
        let v = valueString ?? value.map { String($0) } ?? ""
        return "\(type)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(sourceName ?? "")|\(v)"
    }
}

// MARK: - Apple Health workout

/// A normalized Apple Health `<Workout>` element.
public struct HealthWorkout: Sendable, Equatable {
    /// `workoutActivityType`, stripped of the `HKWorkoutActivityType` prefix
    /// (e.g. `Running`, `FunctionalStrengthTraining`).
    public var activityType: String
    /// Total duration in seconds (from the `duration`/`durationUnit` attrs).
    public var durationS: Double?
    /// Total distance in metres, when present.
    public var distanceM: Double?
    /// Total active energy burned in kilocalories, when present.
    public var energyKcal: Double?
    public var start: Date
    public var end: Date
    public var tzOffsetMin: Int
    public var sourceName: String?

    public init(
        activityType: String,
        durationS: Double?,
        distanceM: Double?,
        energyKcal: Double?,
        start: Date,
        end: Date,
        tzOffsetMin: Int,
        sourceName: String?
    ) {
        self.activityType = activityType
        self.durationS = durationS
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.start = start
        self.end = end
        self.tzOffsetMin = tzOffsetMin
        self.sourceName = sourceName
    }
}

// MARK: - Sleep stage interval

/// The canonical sleep stages Strand recognises from Apple Health
/// `HKCategoryValueSleepAnalysis*` values.
public enum SleepStage: String, Sendable, Equatable, CaseIterable {
    case inBed
    case asleepUnspecified   // legacy "Asleep"
    case asleepCore
    case asleepDeep
    case asleepREM
    case awake
    case unknown

    /// Map a raw HealthKit `SleepAnalysis` category value string to a stage.
    /// Accepts both the modern `HKCategoryValueSleepAnalysis…` form and the
    /// legacy numeric/short forms.
    public static func from(rawValue raw: String) -> SleepStage {
        switch raw {
        case "HKCategoryValueSleepAnalysisInBed", "InBed", "0":
            return .inBed
        case "HKCategoryValueSleepAnalysisAsleep", "HKCategoryValueSleepAnalysisAsleepUnspecified", "Asleep", "1":
            return .asleepUnspecified
        case "HKCategoryValueSleepAnalysisAsleepCore", "AsleepCore", "3":
            return .asleepCore
        case "HKCategoryValueSleepAnalysisAsleepDeep", "AsleepDeep", "4":
            return .asleepDeep
        case "HKCategoryValueSleepAnalysisAsleepREM", "AsleepREM", "5":
            return .asleepREM
        case "HKCategoryValueSleepAnalysisAwake", "Awake", "2":
            return .awake
        default:
            return .unknown
        }
    }
}

/// A single contiguous sleep-stage interval from Apple Health.
public struct SleepStageInterval: Sendable, Equatable {
    public var stage: SleepStage
    public var start: Date
    public var end: Date
    public var tzOffsetMin: Int
    public var sourceName: String?

    public init(
        stage: SleepStage,
        start: Date,
        end: Date,
        tzOffsetMin: Int,
        sourceName: String?
    ) {
        self.stage = stage
        self.start = start
        self.end = end
        self.tzOffsetMin = tzOffsetMin
        self.sourceName = sourceName
    }
}

// MARK: - Whoop daily cycle (physiological_cycles.csv)

/// One row of `physiological_cycles.csv` — Whoop's master daily summary.
///
/// All durations are stored in **minutes** as they appear in the CSV. Energy is
/// stored in **kcal** (Whoop's CSV `(cal)` is actually kcal). Timestamps are the
/// raw `YYYY-MM-DD HH:MM:SS` strings parsed against `cycleTimezone` into UTC
/// `Date`s, with the offset preserved in `tzOffsetMin`.
public struct WhoopCycleRow: Sendable, Equatable {
    /// Cycle start (UTC). The primary key for a Whoop day.
    public var cycleStart: Date?
    public var cycleEnd: Date?
    /// Original `Cycle timezone` offset in minutes (e.g. `+01:00` → 60).
    public var tzOffsetMin: Int

    public var recoveryScore: Double?
    public var restingHeartRate: Double?
    public var hrvMs: Double?
    public var skinTempCelsius: Double?
    public var bloodOxygenPct: Double?
    public var dayStrain: Double?
    public var energyKcal: Double?
    public var avgHeartRate: Double?
    public var maxHeartRate: Double?

    public var sleepOnset: Date?
    public var wakeOnset: Date?
    public var sleepPerformancePct: Double?
    public var respiratoryRate: Double?
    public var asleepDurationMin: Double?
    public var inBedDurationMin: Double?
    public var lightSleepDurationMin: Double?
    public var deepSleepDurationMin: Double?
    public var remDurationMin: Double?
    public var awakeDurationMin: Double?
    public var sleepEfficiencyPct: Double?
    public var sleepConsistencyPct: Double?
    public var sleepNeedMin: Double?
    public var sleepDebtMin: Double?

    public init() {
        self.cycleStart = nil
        self.cycleEnd = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Whoop sleep (sleeps.csv)

/// One row of `sleeps.csv` — per sleep or nap. Adds the `Nap` boolean over the
/// daily cycle summary.
public struct WhoopSleepRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var sleepOnset: Date?
    public var wakeOnset: Date?
    public var tzOffsetMin: Int
    public var isNap: Bool

    public var sleepPerformancePct: Double?
    public var respiratoryRate: Double?
    public var asleepDurationMin: Double?
    public var inBedDurationMin: Double?
    public var lightSleepDurationMin: Double?
    public var deepSleepDurationMin: Double?
    public var remDurationMin: Double?
    public var awakeDurationMin: Double?
    public var sleepEfficiencyPct: Double?
    public var sleepConsistencyPct: Double?
    public var sleepNeedMin: Double?
    public var sleepDebtMin: Double?

    public init() {
        self.cycleStart = nil
        self.sleepOnset = nil
        self.wakeOnset = nil
        self.tzOffsetMin = 0
        self.isNap = false
    }
}

// MARK: - Whoop workout (workouts.csv)

/// One row of `workouts.csv`. GPS / distance / altitude columns are optional.
public struct WhoopWorkoutRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var workoutStart: Date?
    public var workoutEnd: Date?
    public var tzOffsetMin: Int

    public var activityName: String?
    public var activityStrain: Double?
    public var energyKcal: Double?
    public var avgHeartRate: Double?
    public var maxHeartRate: Double?

    public var hrZone1Pct: Double?
    public var hrZone2Pct: Double?
    public var hrZone3Pct: Double?
    public var hrZone4Pct: Double?
    public var hrZone5Pct: Double?

    // Optional GPS / distance / altitude columns (may be absent entirely).
    public var distanceMeters: Double?
    public var altitudeGainMeters: Double?
    public var altitudeChangeMeters: Double?

    public init() {
        self.cycleStart = nil
        self.workoutStart = nil
        self.workoutEnd = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Whoop journal (journal_entries.csv)

/// One row of `journal_entries.csv` — tall format: a question and its answer
/// (with optional notes) per cycle.
public struct WhoopJournalRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var tzOffsetMin: Int
    public var question: String?
    public var answer: String?
    public var notes: String?

    public init() {
        self.cycleStart = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Xiaomi Smart Band (Mi Fitness export)

/// The canonical sleep stages NOOP recognises from the Mi Fitness `sleep` table's
/// per-segment `state` codes. Verified against a real Mi Band 10 export:
/// `1 = awake, 2 = light, 3 = deep, 4 = REM, 5 = awake-in-bed`.
public enum XiaomiSleepStage: String, Sendable, Equatable, CaseIterable {
    case awake
    case light
    case deep
    case rem
    case awakeInBed
    case unknown

    public static func from(state: Int) -> XiaomiSleepStage {
        switch state {
        case 1: return .awake
        case 2: return .light
        case 3: return .deep
        case 4: return .rem
        case 5: return .awakeInBed
        default: return .unknown
        }
    }
}

/// One contiguous sleep-stage interval (`items[]` entry) from a Mi Fitness `sleep` row.
public struct XiaomiSleepStageInterval: Sendable, Equatable {
    public var stage: XiaomiSleepStage
    public var start: Date
    public var end: Date

    public init(stage: XiaomiSleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }
}

/// One sleep session reconstructed from a Mi Fitness `sleep` interval row, including
/// its full hypnogram (`stages`). Durations are minutes, as the band reports them.
public struct XiaomiSleepSession: Sendable, Equatable {
    public var bedtime: Date
    public var wakeTime: Date
    public var deepMin: Double?
    public var lightMin: Double?
    public var remMin: Double?
    public var awakeMin: Double?
    public var avgHr: Int?
    public var minHr: Int?
    public var maxHr: Int?
    public var awakeCount: Int?
    public var sleepScore: Int?
    public var stages: [XiaomiSleepStageInterval]

    public init(
        bedtime: Date,
        wakeTime: Date,
        deepMin: Double? = nil,
        lightMin: Double? = nil,
        remMin: Double? = nil,
        awakeMin: Double? = nil,
        avgHr: Int? = nil,
        minHr: Int? = nil,
        maxHr: Int? = nil,
        awakeCount: Int? = nil,
        sleepScore: Int? = nil,
        stages: [XiaomiSleepStageInterval] = []
    ) {
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.deepMin = deepMin
        self.lightMin = lightMin
        self.remMin = remMin
        self.awakeMin = awakeMin
        self.avgHr = avgHr
        self.minHr = minHr
        self.maxHr = maxHr
        self.awakeCount = awakeCount
        self.sleepScore = sleepScore
        self.stages = stages
    }
}

/// One calendar day rolled up from the Mi Fitness `*_day` tables. `day` is the
/// band's local calendar day (`YYYY-MM-DD`, derived from the row's `zone_offset`).
/// All metric fields are optional — a given day only carries what the band recorded.
public struct XiaomiDailyRow: Sendable, Equatable {
    public var day: String
    public var dayStart: Date

    // Activity (steps_day / calories_day / intensity_day / valid_stand_day)
    public var steps: Int?
    public var distanceM: Double?
    public var activeKcal: Double?
    public var intensityMin: Double?
    public var standCount: Int?

    // Heart rate (heart_rate_day)
    public var restingHr: Int?
    public var avgHr: Int?
    public var minHr: Int?
    public var maxHr: Int?

    // Sleep rollup (sleep_day)
    public var totalSleepMin: Double?
    public var deepMin: Double?
    public var lightMin: Double?
    public var remMin: Double?
    public var awakeMin: Double?
    public var sleepScore: Int?

    // Wellbeing (stress_day / spo2_day / vitality)
    public var avgStress: Int?
    public var avgSpo2: Double?
    public var vitality: Int?

    public init(day: String, dayStart: Date) {
        self.day = day
        self.dayStart = dayStart
    }
}

/// Normalized output of parsing a Mi Fitness export (the iOS app sandbox folder,
/// a zip of it, or the bare `<user_id>.db`).
public struct XiaomiImportResult: Sendable, Equatable {
    public var days: [XiaomiDailyRow]
    public var sleeps: [XiaomiSleepSession]
    public var summary: ImportSummary

    public init(days: [XiaomiDailyRow], sleeps: [XiaomiSleepSession], summary: ImportSummary) {
        self.days = days
        self.sleeps = sleeps
        self.summary = summary
    }
}

// MARK: - Wearable file-export import (Oura / Fitbit / Garmin own-data exports)

/// Which third-party wearable an export came from. Used to pick the right parser and to
/// tag every imported row with an honest per-source label (`oura-import` / `fitbit-import` /
/// `garmin-import`), so the UI never confuses Oura/Fitbit/Garmin data with WHOOP's.
public enum WearableBrand: String, Sendable, Equatable, CaseIterable {
    case oura
    case fitbit
    case garmin

    /// The per-source partition / provenance id written as the Data Source device id (mirrors
    /// `"my-whoop"` / `"apple-health"` / `"xiaomi-band"`). Honest: imported, not live.
    public var sourceId: String {
        switch self {
        case .oura:   return "oura-import"
        case .fitbit: return "fitbit-import"
        case .garmin: return "garmin-import"
        }
    }

    /// Human label for the import summary / Data Source card.
    public var displayName: String {
        switch self {
        case .oura:   return "Oura"
        case .fitbit: return "Fitbit"
        case .garmin: return "Garmin"
        }
    }

    public var dataSourceKind: DataSourceKind {
        switch self {
        case .oura:   return .ouraImport
        case .fitbit: return .fitbitImport
        case .garmin: return .garminImport
        }
    }
}

/// One contiguous sleep-stage interval reconstructed from a wearable export's hypnogram, when
/// the export carried per-segment staging (Fitbit `levels.data`, Garmin `sleepLevels`). Oura's
/// account export gives stage DURATIONS but not a per-segment timeline, so its sessions carry the
/// duration breakdown without a stage list — honest: we never synthesize a fake hypnogram.
public struct WearableSleepStageInterval: Sendable, Equatable {
    /// Normalized stage name written into the stage JSON: "deep" / "light" / "rem" / "wake".
    public var stage: String
    public var start: Date
    public var end: Date

    public init(stage: String, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }
}

/// One sleep session imported from a wearable export. Durations are MINUTES (as NOOP's
/// `DailyMetric` / sleep model use). A field is nil when the export didn't carry it — never
/// fabricated. `stages` is empty when the export gave only a duration breakdown (Oura).
public struct WearableSleepSession: Sendable, Equatable {
    public var start: Date          // bedtime / sleep onset (UTC)
    public var end: Date            // wake (UTC)
    public var deepMin: Double?
    public var lightMin: Double?
    public var remMin: Double?
    public var awakeMin: Double?
    public var totalSleepMin: Double?
    public var efficiencyPct: Double?
    public var avgHr: Int?
    public var lowestHr: Int?       // Oura/Garmin lowest sleeping HR ≈ resting
    public var avgHrvMs: Double?    // Oura "average_hrv" (rMSSD ms); others nil
    public var respRateBpm: Double? // Oura "average_breath"; others nil
    public var sleepScore: Int?     // the brand's OWN score — stored as reference only, never Charge
    public var stages: [WearableSleepStageInterval]

    public init(
        start: Date,
        end: Date,
        deepMin: Double? = nil,
        lightMin: Double? = nil,
        remMin: Double? = nil,
        awakeMin: Double? = nil,
        totalSleepMin: Double? = nil,
        efficiencyPct: Double? = nil,
        avgHr: Int? = nil,
        lowestHr: Int? = nil,
        avgHrvMs: Double? = nil,
        respRateBpm: Double? = nil,
        sleepScore: Int? = nil,
        stages: [WearableSleepStageInterval] = []
    ) {
        self.start = start
        self.end = end
        self.deepMin = deepMin
        self.lightMin = lightMin
        self.remMin = remMin
        self.awakeMin = awakeMin
        self.totalSleepMin = totalSleepMin
        self.efficiencyPct = efficiencyPct
        self.avgHr = avgHr
        self.lowestHr = lowestHr
        self.avgHrvMs = avgHrvMs
        self.respRateBpm = respRateBpm
        self.sleepScore = sleepScore
        self.stages = stages
    }
}

/// One calendar day rolled up from a wearable export. `day` is the export's own calendar day
/// string (`YYYY-MM-DD`). Every metric is optional — a day only carries what the export recorded.
///
/// HONEST DATA: `readinessScore` (Oura) is THEIR score, kept for reference only — it is NEVER shown
/// as NOOP's Charge. NOOP recomputes its own scores downstream from the raw inputs (RHR / HRV /
/// sleep) that are present, exactly as it does for any imported source.
public struct WearableDailyRow: Sendable, Equatable {
    public var day: String

    // Activity
    public var steps: Int?
    public var distanceM: Double?
    public var activeKcal: Double?
    public var totalKcal: Double?

    // Heart / recovery inputs
    public var restingHr: Int?
    public var avgHrvMs: Double?
    public var respRateBpm: Double?   // night respiration (breaths/min) folded from the session, so it reaches the day rollup (#17)
    public var skinTempDevC: Double?  // Oura "temperature_deviation" (°C from baseline)
    public var spo2Pct: Double?
    public var avgStress: Int?        // Garmin daily average stress (0..100), reference
    public var vo2max: Double?        // Oura "vo2_max" (mL/kg/min); feeds Fitness Age, same as Apple Health VO2max

    // Sleep rollup (mirrors the night's session, for the daily metric)
    public var totalSleepMin: Double?
    public var deepMin: Double?
    public var lightMin: Double?
    public var remMin: Double?
    public var awakeMin: Double?
    public var efficiencyPct: Double?

    // The brand's OWN reference scores — stored under reference keys, never NOOP Charge/Effort/Rest.
    public var readinessScore: Int?   // Oura daily readiness (reference)
    public var sleepScore: Int?       // brand sleep score (reference)

    public init(day: String) {
        self.day = day
    }
}

/// Normalized output of parsing a wearable export (Oura / Fitbit / Garmin own-data export).
public struct WearableImportResult: Sendable, Equatable {
    public var brand: WearableBrand
    public var days: [WearableDailyRow]
    public var sleeps: [WearableSleepSession]
    public var summary: ImportSummary

    public init(brand: WearableBrand, days: [WearableDailyRow], sleeps: [WearableSleepSession], summary: ImportSummary) {
        self.brand = brand
        self.days = days
        self.sleeps = sleeps
        self.summary = summary
    }
}

// MARK: - Import results & summary

/// Lightweight summary of an import: how many normalized rows were produced and
/// the overall date span they cover.
public struct ImportSummary: Sendable, Equatable {
    public var sourceKind: DataSourceKind
    public var recordCount: Int
    public var earliest: Date?
    public var latest: Date?
    /// Per-category counts (e.g. `["HeartRate": 1200, "SleepAnalysis": 88]` for
    /// Apple Health, or `["cycles": 30, "workouts": 12]` for Whoop).
    public var countsByCategory: [String: Int]
    /// Number of XML spans dropped during a tolerant import: either a single
    /// hard parse error after which we kept the partial result (counts as 1), or
    /// the number of illegal-byte runs the pre-parse sanitizer scrubbed. Surfaced
    /// honestly in the UI so a partial import never silently looks complete.
    /// `0` for a fully clean import. Defaulted so other sources (Whoop) and older
    /// call sites stay source-compatible.
    public var skippedSpans: Int

    public init(
        sourceKind: DataSourceKind,
        recordCount: Int,
        earliest: Date?,
        latest: Date?,
        countsByCategory: [String: Int],
        skippedSpans: Int = 0
    ) {
        self.sourceKind = sourceKind
        self.recordCount = recordCount
        self.earliest = earliest
        self.latest = latest
        self.countsByCategory = countsByCategory
        self.skippedSpans = skippedSpans
    }
}

/// Normalized output of parsing an Apple Health export.
public struct AppleHealthImportResult: Sendable, Equatable {
    public var samples: [HealthSample]
    public var workouts: [HealthWorkout]
    public var sleepIntervals: [SleepStageInterval]
    public var summary: ImportSummary
    /// Pre-aggregated per-day sample rows, folded incrementally by the importer
    /// so a multi-year export never has to retain the raw `samples` array in RAM
    /// (issue #355). When the importer kept raw samples (`retainRawSamples:true`,
    /// the default) this is empty and `AppleHealthAggregator.aggregate` re-folds
    /// `samples`; when it dropped them (the app path) this carries the folded
    /// result and `samples` is empty. Defaulted to `[]` for source-compatibility
    /// with existing call sites that build a result from raw `samples`.
    public var sampleDailies: [AppleDailyAggregate]

    public init(
        samples: [HealthSample],
        workouts: [HealthWorkout],
        sleepIntervals: [SleepStageInterval],
        summary: ImportSummary,
        sampleDailies: [AppleDailyAggregate] = []
    ) {
        self.samples = samples
        self.workouts = workouts
        self.sleepIntervals = sleepIntervals
        self.summary = summary
        self.sampleDailies = sampleDailies
    }
}

/// Normalized output of parsing a Whoop CSV export bundle.
public struct WhoopImportResult: Sendable, Equatable {
    public var cycles: [WhoopCycleRow]
    public var sleeps: [WhoopSleepRow]
    public var workouts: [WhoopWorkoutRow]
    public var journal: [WhoopJournalRow]
    public var summary: ImportSummary

    public init(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow],
        summary: ImportSummary
    ) {
        self.cycles = cycles
        self.sleeps = sleeps
        self.workouts = workouts
        self.journal = journal
        self.summary = summary
    }
}

// MARK: - Errors

public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case fileNotFound(String)
    case notAZipOrFolder(String)
    case missingEntry(String)
    case xmlParseFailed(String)
    case emptyExport(String)

    public var description: String {
        switch self {
        case .fileNotFound(let p):    return "File not found: \(p)"
        case .notAZipOrFolder(let p): return "Expected a folder or .zip: \(p)"
        case .missingEntry(let e):    return "Required entry not found: \(e)"
        case .xmlParseFailed(let m):  return "XML parse failed: \(m)"
        case .emptyExport(let m):     return "Export contained no usable data: \(m)"
        }
    }

    /// Honest, human-readable failure text surfaced in the import UI. Without this the enum bridges to
    /// NSError positionally and the user sees an opaque "…ImportError erreur 4" with no clue what went
    /// wrong (#857). `LocalizedError.errorDescription` is what `Error.localizedDescription` returns, so
    /// the Data Sources screen now shows the same plain sentence `description` carries.
    public var errorDescription: String? { description }
}
