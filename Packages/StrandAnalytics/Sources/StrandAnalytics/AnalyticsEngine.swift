import Foundation
import WhoopProtocol
import WhoopStore   // OuraRespScale: the one place a ring's milli-bpm respiration row is read
@preconcurrency import WhoopStore

// AnalyticsEngine.swift — orchestrator producing DailyMetric + sleep-session results.
//
// Mirrors the role of server/ingest/app/analysis/daily.py + sleep.daily_sleep_summary:
// given a day's raw streams + a user profile + personal baselines, it runs the
// individual analyzers and assembles a `DailyMetric` (WhoopStore shape) plus the
// detected `SleepSession`s (and their `CachedSleepSession` cache shapes).
//
// This is a PURE function over its inputs — it does NOT touch the database
// (persistence is wired elsewhere). All derived values are APPROXIMATE.

public enum AnalyticsEngine {

    /// Pair the strap's WRIST_OFF/WRIST_ON events into off-wrist `[start, end)` intervals for the sleep
    /// detector's fractional wear filter (#500; design credited to j0b-dev's #504). Each WRIST_OFF opens
    /// an interval that closes at the next WRIST_ON, or at `windowEnd` if the strap is still off at the
    /// end of the read window. Events need not be pre-sorted; kinds are formatted "NAME(n)" (e.g.
    /// "WRIST_OFF(10)"), matched by prefix. Repeated OFFs/ONs without a partner are coalesced.
    public static func offWristIntervals(events: [WhoopEvent], windowEnd: Int) -> [(start: Int, end: Int)] {
        let wear = events
            .filter { $0.kind.hasPrefix("WRIST_OFF") || $0.kind.hasPrefix("WRIST_ON") }
            .sorted { $0.ts < $1.ts }
        var intervals: [(start: Int, end: Int)] = []
        var offStart: Int? = nil
        for e in wear {
            if e.kind.hasPrefix("WRIST_OFF") {
                if offStart == nil { offStart = e.ts }            // ignore repeated OFFs
            } else {                                              // WRIST_ON closes an open off-wrist span
                if let s = offStart, e.ts > s { intervals.append((start: s, end: e.ts)) }
                offStart = nil
            }
        }
        if let s = offStart, windowEnd > s { intervals.append((start: s, end: windowEnd)) }
        return intervals
    }

    /// Baselines passed in by the caller (built from prior nights via Baselines).
    public struct ProfileBaselines: Sendable {
        public let hrv: BaselineState?
        public let restingHR: BaselineState?
        public let resp: BaselineState?
        public let skinTemp: BaselineState?
        public init(hrv: BaselineState? = nil, restingHR: BaselineState? = nil,
                    resp: BaselineState? = nil, skinTemp: BaselineState? = nil) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp
            self.skinTemp = skinTemp
        }
    }

    /// The full analysis result for one day.
    ///
    /// NOTE: not `Sendable` — it embeds `DailyMetric` / `CachedSleepSession` from
    /// WhoopStore, which are not `Sendable` (and that package is out of scope to
    /// modify here). The individual analyzer result types in this package ARE
    /// `Sendable`.
    public struct DayResult {
        /// DailyMetric in the WhoopStore cache shape (recovery/strain/sleep rolled up).
        public let daily: DailyMetric
        /// Detected sleep sessions (rich, with stage segments).
        public let sleepSessions: [SleepSession]
        /// CachedSleepSession cache rows (one per detected session).
        public let cachedSleep: [CachedSleepSession]
        /// Detected workout/exercise sessions.
        public let workouts: [ExerciseSession]
        /// #1545: where the detector lost every candidate workout on this day. nil only when detection did
        /// not run. Always populated otherwise — including (especially) when `workouts` is empty, which is
        /// the case the counts exist to explain.
        public let detectionFunnel: WorkoutDetector.DetectionFunnel?
        /// Recovery / "Charge" score [0,100] or nil (cold-start / no HRV baseline).
        public let recovery: Double?
        /// Ordered Charge driver breakdown (one row per real term that fed the score, biggest
        /// mover first). Empty when there is no score (cold-start) or no driver computed. The UI
        /// renders one row per driver under the Charge ring; it never recomputes the score.
        public let chargeDrivers: [ChargeDriver]
        /// A5: skin temperature as a RELATIVE deviation-from-baseline marker (a trend, never a
        /// clinical absolute), or nil when no deviation is available. Carries the signed °C
        /// deviation + the relative tier (cooler / typical / warmer) for the UI to present.
        public let skinTempRelative: SkinTempRelative?
        /// Day strain / "Effort" [0,100] or nil (insufficient HR samples / invalid HRR).
        public let strain: Double?
        /// Rest composite [0,100] or nil (no asleep time). This is the value the
        /// `sleep_performance` metric key carries (duration-vs-need 0.50 + efficiency
        /// 0.20 + restorative share 0.20 + consistency 0.10). The downstream metric-series
        /// builder reads it from here; the Charge "Rest quality" term reads it ÷100.
        public let restScore: Double?
        /// Per-score confidence tiers (Charge / Effort / Rest) for the small label under
        /// each score. Always present (worst case `.calibrating`).
        public let chargeConfidence: ScoreConfidence
        public let effortConfidence: ScoreConfidence
        public let restConfidence: ScoreConfidence
        /// Wear-gated mean in-bed skin temperature (°C) for this night, or nil when no worn
        /// in-bed samples were available. Baseline-INDEPENDENT (like avgHrv): the caller seeds
        /// a personal skin-temp baseline from these nightly means and re-derives
        /// `DailyMetric.skinTempDevC` in a second pass. APPROXIMATE.
        public let nightlySkinTempC: Double?
        /// Per-session per-epoch MOTION magnitudes (H8), keyed by each matched session's detected start
        /// (`SleepSession.start`), on the same 30 s epoch grid as that session's `stagesJSON`. The caller
        /// persists these via `WhoopStore.persistSessionMotion` after upserting the sleep-session rows. A
        /// session with too little gravity to grid is OMITTED (no key), so the caller never persists a
        /// fabricated zero series. (H8)
        public let sessionMotionByStart: [Int: [Double]]
        /// Per-session per-epoch BAND sleep_state (#175), keyed by each matched session's detected start,
        /// on the same 30 s grid as `stagesJSON` / `sessionMotionByStart`. The strap's OWN @81 code
        /// (0 wake/1 still/2 asleep/3 up) gridded per session, for the caller to persist via
        /// `WhoopStore.persistSessionSleepState`. A session with no band-state samples is OMITTED (no key),
        /// so the caller persists NULL there rather than a fabricated array. Feeds the H7 re-onset CONFIRM
        /// guard on the NEXT pass; never overrides the derived hypnogram. Empty on a WHOOP 4.0. (#175)
        public let sessionSleepStateByStart: [Int: [Int]]

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?, nightlySkinTempC: Double? = nil,
                    restScore: Double? = nil,
                    chargeConfidence: ScoreConfidence = .calibrating,
                    effortConfidence: ScoreConfidence = .calibrating,
                    restConfidence: ScoreConfidence = .calibrating,
                    sessionMotionByStart: [Int: [Double]] = [:],
                    sessionSleepStateByStart: [Int: [Int]] = [:],
                    chargeDrivers: [ChargeDriver] = [],
                    skinTempRelative: SkinTempRelative? = nil,
                    detectionFunnel: WorkoutDetector.DetectionFunnel? = nil) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.detectionFunnel = detectionFunnel
            self.recovery = recovery; self.strain = strain
            self.chargeDrivers = chargeDrivers
            self.skinTempRelative = skinTempRelative
            self.nightlySkinTempC = nightlySkinTempC
            self.restScore = restScore
            self.chargeConfidence = chargeConfidence
            self.effortConfidence = effortConfidence
            self.restConfidence = restConfidence
            self.sessionMotionByStart = sessionMotionByStart
            self.sessionSleepStateByStart = sessionSleepStateByStart
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Format a unix-seconds timestamp as a UTC YYYY-MM-DD day string.
    public static func dayString(_ ts: Int) -> String {
        isoDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Format a unix-seconds timestamp as the device's LOCAL YYYY-MM-DD day string (#277).
    ///
    /// The day key is the core aggregation key for daily metrics; the dashboard reads "today" by
    /// the device's LOCAL calendar day, so the bucket must be the LOCAL day too. A west-of-UTC
    /// user's evening (which crosses midnight UTC) would otherwise flow into the next UTC bucket
    /// and the local "today" read would never find it — freezing the dashboard (Toronto/UTC-4
    /// report). `offsetSec` is seconds EAST of UTC (TimeZone.current.secondsFromGMT()). The local
    /// date is the UTC date of `(ts + offsetSec)`: shifting the instant by the offset turns the
    /// fixed-UTC formatter into a local-calendar formatter. `offsetSec == 0` is byte-identical to
    /// the UTC `dayString(_:)` above, so pure-function callers/tests on UTC are unchanged.
    public static func dayString(_ ts: Int, offsetSec: Int) -> String {
        dayString(ts + offsetSec)
    }

    /// UTC-midnight epoch seconds of an ISO `day` key (yyyy-MM-dd). `isoDay` is a FIXED-UTC formatter,
    /// so `dayString(ts, offsetSec:) == day` ⇔ `(ts + offsetSec) ∈ [dayStartUtcSeconds(day), +86400)` —
    /// an integer range check that replaces the per-sample DateFormatter the full-day stream filters in
    /// `analyzeDay` used to run (~170k formatter invocations per scored day, ×maxDays, every pass; #996,
    /// found by ryanbr's Kotlin↔Swift diff review). A malformed `day` falls back to 0 — an empty 1970
    /// window no real sample matches — rather than trapping. Unreachable in practice (`day` always comes
    /// from `dayString`), and the Kotlin mirror degrades the SAME way (`runCatching { … }.getOrDefault(0)`)
    /// instead of throwing, so a single bad day key can never take down a whole scoring pass on either
    /// platform (nil-tolerant over fail-fast, per the #996 review).
    static func dayStartUtcSeconds(_ day: String) -> Int {
        Int(isoDay.date(from: day)?.timeIntervalSince1970 ?? 0)
    }

    /// Skip the redundant calendar-day re-read in analyzeRecent's per-day scan (#997, ryanbr). For a
    /// PAST day the night window `[nightLo, nightHi]` reads through to the NEXT local midnight, so the
    /// calendar day `[dayLo, dayHi]` is a strict SUBSET of the hr/steps/gravity streams already in
    /// memory — the dayHr/daySteps/dayGravity re-reads (~60 per pass, including the big ~86k-row HR
    /// ones) re-query rows the caller already holds. When the day span is a NON-truncated subset of the
    /// night window, return the day's samples by filtering the night list in memory; return nil when
    /// the shortcut is unsafe and the caller must read the store directly:
    ///   - TODAY: its calendar day runs past the 18 h night cap (`dayHi > nightHi`).
    ///   - a night read that came back at `limit` rows may be truncated INSIDE the day span
    ///     (`ORDER BY ts ASC LIMIT` drops the LATE rows — exactly where the day sits).
    /// Byte-identical to the direct read: same owner (the caller reads both windows from one device),
    /// same INCLUSIVE `[dayLo, dayHi]` bounds (matching the store's `ts >= from AND ts <= to` range),
    /// same order (the night list came from the SAME ts-ASC store method, and filtering preserves
    /// order), and the store's HR coalesce (measured ∪ v26 PPG, #156) dedups on a range-INDEPENDENT
    /// `h.ts = p.ts` anti-join, so coalescing-then-filtering equals coalescing over the day range. The
    /// guards are self-protecting — a DST-shifted `dayLo`/`dayHi` simply falls outside the window and
    /// declines — so the shortcut can only ever DECLINE to a direct read, never return wrong data.
    /// Mirrors Kotlin `AnalyticsEngine.daySliceFromNight`; lives here (like `offWristIntervals`)
    /// so the pure logic is package-testable. (#997)
    public static func daySliceFromNight<T>(_ night: [T],
                                            nightLo: Int, nightHi: Int,
                                            dayLo: Int, dayHi: Int,
                                            limit: Int = 200_000,
                                            ts: (T) -> Int) -> [T]? {
        guard dayLo >= nightLo, dayHi <= nightHi, night.count < limit else { return nil }
        return night.filter { ts($0) >= dayLo && ts($0) <= dayHi }
    }

    /// JSON-encode stage segments to the verbatim array shape CachedSleepSession stores.
    /// `.sortedKeys` makes the output deterministic — JSONEncoder otherwise emits object keys in an
    /// unstable order (it can vary call to call), which would make stored stage JSON non-reproducible
    /// and defeat the post-sync self-heal's "skip the write when the re-derived JSON is unchanged" check.
    /// Decoders are key-order-independent, so this is purely a stabilization.
    public static func encodeStages(_ stages: [StageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stages) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Inverse of `encodeStages`: decode a stored `stagesJSON` back to `[StageSegment]`. Only the on-device
    /// SEGMENT-ARRAY shape (`[{start,end,stage}]`) decodes; the imported minute-dict shape
    /// (`{light,deep,rem,awake}`) is not a segment timeline and yields `[]` (key-order-independent). (#804)
    public static func decodeStages(_ json: String?) -> [StageSegment] {
        guard let json, let data = json.data(using: .utf8),
              let stages = try? JSONDecoder().decode([StageSegment].self, from: data) else { return [] }
        return stages
    }

    /// Reconstruct the pure `SleepSession` the analyzer stages from a persisted, device-PROVIDED
    /// `CachedSleepSession` — e.g. an Oura ring's own SleepNet hypnogram (#773), whose `stagesJSON` uses the
    /// same `deep/light/rem/wake` vocabulary `hypnogramMetrics` reads. Uses the effective (edit-aware) onset,
    /// preserves the stored efficiency (deriving it from the decoded stage minutes only when the row stored
    /// none), and passes `restingHR`/`avgHRV` through as stored — nil for a ring night, which `analyzeDay`
    /// then re-derives from that day's hr/rr over this window. Returns nil when the row has no decodable
    /// stage timeline, so a non-hypnogram (minute-dict) row is never injected. (#804 Fix A)
    public static func sleepSession(fromProvided c: CachedSleepSession) -> SleepSession? {
        let stages = decodeStages(c.stagesJSON)
        guard !stages.isEmpty else { return nil }
        let efficiency: Double
        if let e = c.efficiency {
            efficiency = e
        } else if let m = SleepStageTotals.minutes(fromStagesJSON: c.stagesJSON), m.inBed > 0 {
            efficiency = m.asleep / m.inBed
        } else {
            efficiency = 0
        }
        return SleepSession(start: c.effectiveStartTs, end: c.endTs, efficiency: efficiency,
                            stages: stages, restingHR: c.restingHr, avgHRV: c.avgHrv)
    }

    /// Analyze one day's streams into a `DayResult`.
    ///
    /// - Parameters:
    ///   - day: the calendar day (UTC) this metric is for; a sleep session is
    ///     attributed to the day its `end` falls on (a night ending that morning).
    ///   - hr/rr/resp/gravity: the day's raw streams (the wider window around the
    ///     night may be passed; sleep detection finds the in-bed span itself).
    ///   - profile: user profile (age/sex/weight/height) for HRmax + calories.
    ///   - baselines: personal baselines for recovery normalization.
    ///   - maxHROverride: explicit HRmax (bpm) to use for strain/zones; nil →
    ///     Tanaka from profile.age.
    /// The night's respiratory rate (breaths/min) from a strap's OWN per-window rate rows, or nil when
    /// the night has too little of it to summarise. Pure → unit-testable, and byte-twinned in Kotlin.
    ///
    /// This is NOT the RSA estimate `SleepStager.respRateFromRR` computes: these rows are a measurement
    /// the device made and NOOP decoded (the Oura ring's 0x6A `breath`, stored in milli-bpm), so the
    /// question is coverage, not method. The night's value is the MEDIAN of the rows that fall inside a
    /// matched in-bed session — the same statistic the ledger this decode was validated with used, and
    /// robust to the odd out-of-band record.
    ///
    /// Two guards, both about representativeness rather than trust:
    ///   * the in-session rows must SPAN at least `vendorRespMinSpanS`. A record cadence is not a
    ///     reliable proxy for coverage (real nights hold both ~30 s and ~296 s spacing), so the gate is on
    ///     the time the rows actually cover: a 36-minute tail of a night is not that night's respiration,
    ///     and it would enter the personal baseline as though it were.
    ///   * the median must land inside `SleepStager.respPlausibleRangeBpm` (8–25), the SAME band the RSA
    ///     path is clamped to, so one corrupt record can never publish an impossible rate.
    public static func vendorRespRateBpm(_ rows: [RespSample],
                                         sessions: [(start: Int, end: Int)]) -> Double? {
        guard !rows.isEmpty, !sessions.isEmpty else { return nil }
        let inSession = rows.filter { r in sessions.contains { r.ts >= $0.start && r.ts <= $0.end } }
        guard let first = inSession.map(\.ts).min(), let last = inSession.map(\.ts).max(),
              last - first >= vendorRespMinSpanS else { return nil }
        let median = HRVAnalyzer.median(inSession.map { OuraRespScale.breathsPerMin(raw: $0.raw) })
        return SleepStager.respPlausibleRangeBpm.contains(median) ? median : nil
    }

    /// Minimum span (seconds) a night's vendor respiration rows must cover before their median is taken
    /// as the night's rate. One hour: enough that the value describes the night rather than a fragment,
    /// and low enough to keep a partially-drained night. Twin of the Kotlin constant.
    public static let vendorRespMinSpanS = 3_600

    public static func analyzeDay(day: String,
                                  hr: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  // The strap's OWN per-window respiratory RATE rows, when it measures one
                                  // (the Oura ring's 0x6A `breath`, stored in milli-bpm — see
                                  // `OuraRespScale`). Kept separate from `resp` on purpose: `resp` is the
                                  // WHOOP raw respiration ADC WAVEFORM the stager peak-detects, a different
                                  // quantity that must never be pooled with a rate. Empty for every WHOOP
                                  // night, which therefore scores exactly as before.
                                  vendorResp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  steps: [StepSample] = [],
                                  // Calendar-day-scoped overrides for the ADDITIVE daily totals
                                  // (steps + activeKcalEst) AND workout detection. When nil, each
                                  // falls back to the same night window the rest of the analysis uses
                                  // (preserving the pure-function contract). The caller
                                  // (IntelligenceEngine) supplies a full
                                  // [localMidnight(day), localMidnight(day)+86400) read here so a
                                  // day's late hours — which fall outside the ~42h night-detection
                                  // window (it ends at dayStart+12h ≈ noon) — are still seen.
                                  //
                                  // dayHr/daySteps drive the additive step + calorie totals.
                                  // dayHr/dayGravity ALSO feed WorkoutDetector so an afternoon /
                                  // evening workout is detected on its OWN calendar day instead of
                                  // lagging to the next pass (the old night window only reached noon,
                                  // so a 5 pm run was invisible until tomorrow's run re-read it). A
                                  // workout straddling local midnight is split at the day boundary —
                                  // the same accepted tradeoff the step/calorie totals already make.
                                  // dayHr ALSO drives Strain / "Effort" so the day's load reflects the
                                  // WHOLE calendar day (afternoon workouts included), not midnight→noon.
                                  //
                                  // Sleep / recovery keep using hr/rr/resp/gravity — staging needs the
                                  // pre-midnight night span the calendar day omits.
                                  dayHr: [HRSample]? = nil,
                                  daySteps: [StepSample]? = nil,
                                  dayGravity: [GravitySample]? = nil,
                                  // Wear-gated nightly skin-temp mean is harvested here
                                  // (baseline-independent); IntelligenceEngine seeds a personal
                                  // baseline from these means across nights and re-derives
                                  // skinTempDevC in pass 2 (same two-pass shape as avgHrv→recovery).
                                  skinTemp: [SkinTempSample] = [],
                                  // Device family that wrote `skinTemp`, so the raw→°C conversion picks
                                  // the right scale (#938): 5/MG banks CENTIDEGREES (raw/100), the WHOOP
                                  // 4.0 v24 field is a RAW ADC on a different scale. Default `.whoop5`
                                  // keeps every 5/MG + pure-function caller byte-identical;
                                  // IntelligenceEngine passes the day owner's real family.
                                  skinTempFamily: DeviceFamily = .whoop5,
                                  // Per-device WHOOP 4.0 worn anchor raw (#938 second capture): the raw that
                                  // maps to 33.0 °C for THIS device. The @72 skin-temp ADC's register offset is
                                  // per-device — a second real 4.0 strap shares the floor (~509) + saturation
                                  // (2047) but has a worn band ~1100–1600, which the global 826 anchor maps to
                                  // 47–72 °C, failing 100% of the worn gate. IntelligenceEngine learns it once
                                  // per run from the owner's own worn median. nil → the family-aware conversion
                                  // uses the global `Whoop4SkinTemp.anchorRaw`, so every 5/MG + pure-function
                                  // caller stays byte-identical (`.whoop5` ignores the anchor entirely).
                                  skinTempAnchorRaw: Double? = nil,
                                  // #1467: 0 (default) keeps every existing caller's skin-temp "worn" gate
                                  // exact-timestamp, byte-identical. IntelligenceEngine passes a non-zero
                                  // value for an owner whose HR and skin-temp streams aren't co-sampled at
                                  // 1 Hz (an Oura ring) — see `AnalyticsEngine.defaultOuraWornToleranceSec`.
                                  skinTempWornToleranceSec: Int = 0,
                                  // WHOOP 4.0 raw SpO2 PPG ADC samples (red/IR) for the night window
                                  // (#93). The nightly red/IR means over detected sleep are banked on the
                                  // DailyMetric as RAW ADC — honest "the sensor decoded" data, NOT a
                                  // calibrated blood-oxygen % (that needs WHOOP's proprietary curve).
                                  // Default empty keeps pure-function callers/tests + non-4.0 nights nil.
                                  spo2: [SpO2Sample] = [],
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  // Wall-clock UTC offset (seconds) for the sleep detector's daytime
                                  // false-sleep guard (#90). Default 0 keeps pure-function callers/tests
                                  // on UTC; IntelligenceEngine passes the device's real offset.
                                  tzOffsetSeconds: Int = 0,
                                  // Off-wrist `[start, end)` intervals (unix seconds) for the off-wrist
                                  // sleep backstop (#500), paired from WRIST_OFF/WRIST_ON events by
                                  // `offWristIntervals`. The HR-gap proxy in detectSleep is the always-on
                                  // guard; these explicit intervals sharpen it under the FRACTIONAL rule
                                  // (#504) — a session is dropped only when its off-wrist coverage reaches
                                  // maxOffWristSleepFraction. Default empty keeps pure-function callers/
                                  // tests event-free; IntelligenceEngine passes the night window's intervals.
                                  wristOff: [(start: Int, end: Int)] = [],
                                  // Rest composite (Charge/Effort/Rest) personalization. Both default to
                                  // their neutral form so pure-function callers/tests get a well-defined
                                  // Rest from a single night; IntelligenceEngine refines them from history.
                                  //   sleepNeedHours: personal sleep need (h). Default 8 h; the caller
                                  //     refines it toward the recent average. Drives the 0.50 duration term.
                                  //   sleepConsistency: sleep/wake regularity in [0,1] (1 = perfectly
                                  //     regular). nil → the consistency term is neutral (0.5) since a single
                                  //     day carries no regularity signal — the caller supplies it from history.
                                  sleepNeedHours: Double = Rest.defaultNeedHours,
                                  sleepConsistency: Double? = nil,
                                  // The user's learned habitual midsleep (local time-of-day seconds in
                                  // [0, 86400)) for the main-night scored pick, so a late/shift sleeper's
                                  // real night out-scores a daytime nap. nil = cold-start: the selector
                                  // falls back to the broad overnight-band bonus. IntelligenceEngine
                                  // computes this once per run from the trailing sleep history and threads
                                  // it down; pure-function callers/tests leave it nil and stay on the
                                  // cold-start band. (#547)
                                  habitualMidsleepSec: Int? = nil,
                                  // The strap's OWN persisted v18 BAND sleep_state per timestamp (Interpreter's
                                  // `(sb>>4)&3`: 0 wake/1 still/2 asleep/3 up). Consumed ONLY to confirm a
                                  // borderline H7 morning re-onset — a daytime block the strap itself scored
                                  // "asleep" is kept even on a borderline HR dip (#531). Default empty keeps
                                  // pure-function callers/tests free of it; IntelligenceEngine threads the
                                  // night window's persisted band state. (#531 / H8 consume)
                                  bandSleepState: [(ts: Int, state: Int)] = [],
                                  // Which sleep-staging recipe runs (V2 vs V1). When true, detected nights
                                  // are staged by `SleepStagerV2` instead of V1. This PARAMETER defaults
                                  // false to keep pure-function callers/tests byte-identical — it is NOT
                                  // the product default. IntelligenceEngine threads
                                  // `PuffinExperiment.experimentalSleepV2Enabled`, which is default ON
                                  // (#277/#351), so the shipped app stages with V2. (7.0.0)
                                  useSleepStagerV2: Bool = false,
                                  // Opt-in motion-aware wake refinement (#364 "Proposal 2" follow-up; density
                                  // gate precedent #345). When true, `WakeMotionRefinement` re-derives each
                                  // detected session's stages, reclassifying a hot-but-still WAKE segment to
                                  // `light` when it shows no locomotion and a stable posture outside isolated
                                  // burst minutes; it only ever runs AFTER V1/V2 staging and self-gates on the
                                  // observed gravity + step density, so it is a no-op on a sparse (e.g. WHOOP
                                  // 4.0) night regardless of this flag. Default false keeps every pure-function
                                  // caller/test byte-identical; IntelligenceEngine threads
                                  // `PuffinExperiment.motionAwareWakeEnabled`.
                                  useMotionAwareWake: Bool = false,
                                  // Caller-supplied, already-staged sleep sessions to fold in ALONGSIDE the
                                  // motion detector's — the day owner's OWN device-provided hypnogram (an
                                  // Oura ring's SleepNet night, #773), reconstructed from its persisted
                                  // `CachedSleepSession` via `sleepSession(fromProvided:)`. This is the fix
                                  // for #804: a ring sends no gravity vector, so `detectSleep` stages nothing
                                  // and the night scored blank (totalSleepMin/eff/avgHrv nil) even though the
                                  // ring's hypnogram was persisted and shown on the timeline. Provided
                                  // sessions are PRE-staged: they bypass detectSleep AND wake refinement.
                                  // Where a provided session overlaps a detected one the PROVIDED session
                                  // wins (authoritative device staging over motion inference); non-overlapping
                                  // detected sessions (a nap the ring didn't report) are kept. Each provided
                                  // session's nightly restingHR/avgHRV is (re)derived HERE from this day's
                                  // hr/rr over its window when the stored row carried none, so the daily
                                  // RHR/HRV light up. Default `[]` (every WHOOP / pure-function caller) keeps
                                  // the byte-identical motion-only path.
                                  providedSleep: [SleepSession] = [],
                                  // Sleep PROVENANCE for the per-day sleep trace (CAPTURE-C / #799). The
                                  // measured BLE path is `.measured` (the default); the caller passes
                                  // `.imported(...)` when a previously-imported sleep row WON the daily merge,
                                  // so the trace shows the import winning instead of silently substituting the
                                  // measured night. Trace-only: never alters the DayResult. nil/default keeps
                                  // pure-function callers/tests byte-identical (still emits `measured`).
                                  sleepProvenance: SleepProvenance = .measured,
                                  // Sleep & Rest test-mode trace sink (zero-cost default nil = byte-identical).
                                  // When non-nil, the gate trace from detectSleep and the Rest sub-score line
                                  // are forwarded line-by-line. Side-effect-only; never alters the DayResult.
                                  traceSink: ((String) -> Void)? = nil,
                                  // HRV & Autonomic test-mode sink (#141). nil = byte-identical default. When
                                  // non-nil, the nightly per-5-min-window RMSSDs (tagged by sleep stage) + a
                                  // whole-night vs deep-only vs last-SWS summary are forwarded so an "HRV reads
                                  // ~2x higher than WHOOP" report shows WHICH stages lift it.
                                  hrvTraceSink: ((String) -> Void)? = nil,
                                  // Whether to emit the ~90 per-window `hrv window …` lines (vs just the 1-line
                                  // summary). The caller sets it TRUE only for the most-recent night so the
                                  // 5000-line ring buffer isn't flooded (21 nights × ~90 windows would evict the
                                  // always-on diagnostics); the 1-line `hrv nightSummary` is kept for EVERY night.
                                  hrvWindowDetail: Bool = false,
                                  // #141: when true, the nightly HRV is RMSSD over DEEP-sleep windows only
                                  // (WHOOP-style), instead of the whole-night mean. Threaded from the caller
                                  // (UnitPrefs.hrvWindowKey). Default false = byte-identical whole-night value.
                                  deepHrvWindow: Bool = false,
                                  // #1545: which TRIMP recipe scores Effort. Edwards (the default) is
                                  // time-in-zone and pays NOTHING below 50% HRR, so intermittent work —
                                  // a lifting session, once the sets are averaged against the rests —
                                  // can score near zero however long it lasts. Banister is exponential in
                                  // %HRR with no floor. Threaded rather than read from a global so this
                                  // stays a pure function, and defaulted so every existing caller and
                                  // test is byte-identical.
                                  effortMethod: StrainScorer.Method = .edwards) -> DayResult {

        // Precompute the day's UTC bounds ONCE (#996). `dayString(ts, offsetSec:)` formats the UTC
        // calendar day of (ts + offset) with a FIXED offset, so "== day" is exactly membership in
        // [dayStartUtc, +86400). That turns the day-bucketing filters below — otherwise a per-sample
        // DateFormatter over the full-day dayHr/daySteps streams (~86k 1 Hz samples each) once per
        // analyzeDay, ×maxDays every pass — into an integer range check. Byte-identical to the
        // formatter compare (locked by AnalyticsEngineDayBoundsTests, incl. fractional offsets).
        let dayStartUtc = dayStartUtcSeconds(day)
        let dayEndUtc = dayStartUtc + 86_400
        func tsInDay(_ ts: Int) -> Bool { (ts + tzOffsetSeconds) >= dayStartUtc && (ts + tzOffsetSeconds) < dayEndUtc }

        // ── Sleep detection + staging ─────────────────────────────────────────
        let detectedSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                  tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                                  bandSleepState: bandSleepState,
                                                  useSleepStagerV2: useSleepStagerV2,
                                                  traceSink: traceSink)
        // Motion-aware wake refinement (#364 follow-up) runs AFTER V1/V2 staging, over every detected
        // session (naps included — the same eligibility gates apply). `steps` is the SAME calendar-day/
        // night-window stream the caller passed for the rest of this analysis; the pass self-gates on its
        // observed density, so an empty/sparse `steps` (e.g. a WHOOP 4.0, which never emits StepSample at
        // all) is a no-op regardless of `useMotionAwareWake`.
        let refinedSessions = useMotionAwareWake
            ? detectedSessions.map { WakeMotionRefinement.refine($0, grav: gravity, steps: steps) }
            : detectedSessions
        // #804 Fix A: fold in the caller's device-provided hypnogram (see `providedSleep`). Empty = the
        // byte-identical motion-only path. Otherwise enrich each provided session's nightly restingHR/avgHRV
        // from THIS day's hr/rr over its window (the stored ring row carries neither), using the SAME helpers
        // detectSleep populates a session with, then keep only the detected sessions that DON'T overlap a
        // provided one (provided is authoritative where they collide; a separate nap survives).
        let allSessions: [SleepSession]
        if providedSleep.isEmpty {
            allSessions = refinedSessions
        } else {
            let rrSorted = rr.sortedByTsStable()
            let enrichedProvided: [SleepSession] = providedSleep.map { s in
                guard s.restingHR == nil || s.avgHRV == nil else { return s }
                let rhr = s.restingHR ?? SleepStager.sessionRestingHR(start: s.start, end: s.end, hr: hr)
                let hrv = s.avgHRV ?? SleepStager.sessionAvgHRV(start: s.start, end: s.end, rr: rrSorted)
                return SleepSession(start: s.start, end: s.end, efficiency: s.efficiency,
                                    stages: s.stages, restingHR: rhr, avgHRV: hrv)
            }
            let keptDetected = refinedSessions.filter { d in
                !enrichedProvided.contains { $0.start < d.end && d.start < $0.end }
            }
            allSessions = keptDetected + enrichedProvided
        }
        // Sessions attributed to `day` = those whose end falls on `day` (LOCAL day, #277). `day` is
        // the caller's local-day key; attribute by the same offset so the bucket and the key agree.
        let matched = allSessions.filter { tsInDay($0.end) }

        // ── The day's MAIN night (#525) ───────────────────────────────────────
        // A day can hold an overnight AND a daytime nap (both end on `day`, so both are in `matched`).
        // The sleep-DURATION figures (total sleep / stage minutes / efficiency / disturbances, hence the
        // Rest composite, the debt ledger, and the dashboard card) describe the MAIN night — the SAME
        // block the Sleep tab's hero shows (longest, preferring an overnight-anchored onset). They must
        // NOT silently sum the nap in, or the "your night" number disagrees across screens (the #525
        // report). Naps stay their OWN session rows in `sleepSessions` / `cachedSleep`, where the Sleep
        // tab lists and labels them separately. `SleepStageTotals.mainNightIndex` is the single shared
        // selector so the analytics rollup and the Sleep tab resolve to the identical block.
        // Pick by the LEARNED-TIMING score, threading the user's learned habitual midsleep so a
        // late/shift sleeper's real night out-scores a daytime nap (nil = cold-start overnight band).
        // BIPHASIC GAP-BRIDGE (#561): a main sleep briefly interrupted by a short wake (a fragment the
        // detector left split because the wake gap was longer than its sparse-gravity bridge, or a true
        // biphasic night) is scored as ONE night via `mainNightGroupIndices`: it bridges adjacent blocks
        // whose gap is < `gapBridgeMaxMin`, scores the bridged span, and returns ALL the fragments in the
        // winning group. The AASM aggregate below then SUMS the group's stages — in-bed is the SUM of each
        // fragment's own in-bed span (the inter-fragment wake gap is NOT part of any fragment, so it is
        // excluded and we do NOT invent WASO for it). A day with no bridgeable gap collapses to the single
        // block the bare `mainNightIndex` would pick. Intelligence / the Ledger / the Sleep tab all read
        // this SAME group (the seam below passes the same `gapBridgeMaxMin`), so #525 does not regress.
        let mainGroupIdx = SleepStageTotals.mainNightGroupIndices(
            matched.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: tzOffsetSeconds, habitualMidsleepSec: habitualMidsleepSec) ?? []
        let mainGroup: [SleepSession] = mainGroupIdx.map { matched[$0] }

        // ── Daily sleep aggregates (AASM) SUMMED over the main-night GROUP (#525 / #561) ──
        var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0
        var inBedS = 0.0, effWeighted = 0.0
        var disturbances = 0
        for s in mainGroup {
            let m = SleepStager.hypnogramMetrics(s)
            let inBed = Double(s.end - s.start)
            inBedS += inBed                       // each fragment's own in-bed span (the gap is added below)
            effWeighted += s.efficiency * inBed   // in-bed-weighted efficiency across the group
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        // OUT-OF-BED time BETWEEN bridged fragments is AWAKE (#777/#705): a main night bridged from two
        // fragments split by a 20-min wake gap was reporting that gap as nowhere (it is in no fragment's
        // [start,end) span), so 20+ min of real awake read as ~4 min - a v7.1 regression, multi-reporter.
        // Fold the gap into AWAKE by extending the in-bed denominator (in-bed = asleep + awake; tstS is
        // unchanged), so efficiency and the Rest composite both reflect it. ONE shared definition with the
        // edit/recompute seam (`SleepStageTotals.interFragmentAwakeSeconds`), so the two paths agree and the
        // denominator is never double-counted. A bridged gap also counts as one disturbance.
        let gapAwakeS = SleepStageTotals.interFragmentAwakeSeconds(mainGroup.map { (start: $0.start, end: $0.end) })
        if gapAwakeS > 0 {
            inBedS += gapAwakeS              // the gap is fully awake: extends in-bed, adds 0 to effWeighted
            disturbances += 1
        }
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

        // ── Rest composite (Charge/Effort/Rest) ───────────────────────────────
        // The 0–100 sleep score the `sleep_performance` metric key now carries:
        //   duration-vs-personal-need 0.50 + efficiency 0.20 + restorative share 0.20
        //   + consistency 0.10. nil when there is no asleep time. The Charge "Rest
        //   quality" term reads it ÷100 (replacing raw efficiency).
        let hasStagedSleep = (deepS + remS) > 0
        let restScore: Double? = tstS <= 0 ? nil : Rest.composite(
            tstSeconds: tstS,
            inBedSeconds: inBedS,
            efficiency: efficiency,
            restorativeSeconds: deepS + remS,
            needHours: sleepNeedHours,
            consistency: sleepConsistency,
            deepSeconds: deepS)
        // #345: gravity-sparse computed ONCE — reused by the sleep-motion trace below AND the Rest
        // confidence guard, so the two can never diverge and isGravitySparse runs only once per day.
        let gravitySparse = SleepStager.isGravitySparse(gravity, hr: hr)
        // Sleep & Rest test mode (E5): emit the Rest sub-score breakdown for this night, reusing the
        // IDENTICAL inputs `restScore` consumed above so the trace can never disagree with the score.
        // `subScoreLine` itself reuses `Rest.composite` for the final value. Side-effect-only; emitted
        // only when a trace is requested and this day actually scored a night.
        if let traceSink, !matched.isEmpty {
            if restScore != nil {
                traceSink(Rest.subScoreLine(
                    tstSeconds: tstS, inBedSeconds: inBedS, efficiency: efficiency,
                    restorativeSeconds: deepS + remS, needHours: sleepNeedHours,
                    consistency: sleepConsistency, deepSeconds: deepS,
                    groupFragments: mainGroup.count, groupInBedSeconds: inBedS))
            }
            // #319: the motion-coverage + staging context behind the Rest number, so a high score on a poor
            // night can be explained from an export (WHOOP 4.0 banks motion coarsely → sparse=true → most
            // epochs default to sleep → over-counted duration → high Rest). `stager` says whether V1/V2 ran.
            traceSink(AnalyticsEngine.sleepMotionLine(
                day: day, grav: gravity.count, hr: hr.count,
                sparse: gravitySparse,
                useSleepStagerV2: useSleepStagerV2, family: skinTempFamily))
            // CAPTURE-C (#799): append the sleep PROVENANCE so an imported row winning the merge is visible
            // (not silently swapped for the measured night). hoursAsleep = the scored night's tst in minutes;
            // sourceRowId = the main-night's start ts for the measured path (stable per night), else the
            // caller-supplied winning-row id. Trace-only; the DayResult is unchanged.
            let mainStart = mainGroup.map { $0.start }.min() ?? matched.map { $0.start }.min() ?? 0
            traceSink(sleepProvenanceLine(provenance: sleepProvenance,
                                          hoursAsleepMin: tstS / 60.0,
                                          sourceRowId: String(mainStart)))
            // #271: the ONSET decision — did HR actually dip when the window opened, or did it open on a
            // still-but-awake stretch (HR still ~baseline)? Both the day-median baseline AND the at-onset
            // window read from the SAME HR that DETECTION ran over (`dayHr ?? hr` — the full calendar day
            // when the caller supplies it, else the night window), so the onset instant is guaranteed to be
            // inside it and the baseline reads as a real DAY median (a real onset sits BELOW it, matching the
            // daytime/re-onset guards). Emitted only when both have HR, so a motion-only night stays silent.
            let onsetHr = dayHr ?? hr
            if mainStart > 0,
               let baselineHr = AnalyticsEngine.medianBpm(onsetHr.map { $0.bpm }),
               let hrAtOnset = AnalyticsEngine.medianBpm(
                   onsetHr.filter { $0.ts >= mainStart && $0.ts < mainStart + AnalyticsEngine.onsetTraceWindowSec }
                     .map { $0.bpm }) {
                traceSink(AnalyticsEngine.sleepOnsetLine(onsetTs: mainStart,
                                                         hrAtOnsetBpm: hrAtOnset,
                                                         baselineHrBpm: baselineHr))
            }
        }

        // #525 NOTE: the sleep-DURATION figures above are main-night-only (the headline "your night"),
        // but the physiological aggregates below (resting HR, HRV, respiration) intentionally stay over
        // ALL matched sessions. This is deliberate, not an oversight: recovery should reflect the body's
        // best resting physiology for the day, the main overnight dominates these anyway (it is far longer
        // than any nap and HRV is in-bed-weighted by duration), and narrowing them to the main night would
        // widen the change's blast radius into the recovery score right at a release boundary for a
        // negligible shift. The Rest/sleep-quality term is main-night; the recovery physiology is
        // day-best-resting, night-dominated. Keep these two definitions distinct on purpose.
        // Daily resting HR = lowest per-session resting HR across matched sessions.
        let restingHRDaily = matched.compactMap { $0.restingHR }.min()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        let avgHRVDaily: Double? = {
            if deepHrvWindow {
                // #141: WHOOP-style HRV — pool RMSSD over DEEP-stage 5-min windows only (slow-wave sleep),
                // instead of the whole-night mean. Reuses the SAME sessionHrvWindows the HRV trace is built
                // from, so the displayed value equals the `deepOnly` figure the trace logs. rr sorted (RMSSD
                // = successive diffs). nil when no deep sleep is detected (WHOOP-4.0 staging can be sparse) —
                // the caller shows calibrating, never a fabricated number.
                let rrSorted = rr.sortedByTsStable()
                let deep = matched.flatMap { s in
                    SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rrSorted, stages: s.stages)
                        .filter { $0.stage == "deep" }.compactMap { $0.rmssd }
                }
                return deep.isEmpty ? nil : deep.reduce(0, +) / Double(deep.count)
            }
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Daily SDNN (ms) = the 5-min SDNN INDEX (Task Force) over the in-bed R-R across matched sessions —
        // the mean of per-5-min-segment SDNN, the BROAD autonomic-variability metric (both branches) and the
        // slow twin of the vagal RMSSD `avgHRVDaily` above. The index (not a single whole-night SD) is used
        // deliberately: whole-night SD is dominated by the slow HR drift across sleep stages and reads 2-3×
        // high, which would mislabel Apple Health (its SDNN samples are short-window) and make any cross-check
        // against a watch meaningless. The 5-min index is window-comparable to those. nil when no segment has
        // enough clean beats (HRVAnalyzer's own gate). Keeps the R-R timestamps (segmentation needs them).
        let avgSDNNDaily: Double? = {
            let inBed = rr.filter { r in matched.contains { r.ts >= $0.start && r.ts < $0.end } }
            return inBed.isEmpty ? nil : HRVAnalyzer.sdnnIndex(inBed, segmentSec: 300)
        }()

        // ── HRV & Autonomic nightly trace (#141) ──────────────────────────────
        // Per-5-min-window RMSSD tagged by the sleep stage at its center, then a night summary comparing
        // NOOP's whole-night mean (what it reports) against a deep-only mean and a WHOOP-style
        // last-slow-wave-sleep value — so an "HRV reads ~2x higher than WHOOP" report shows WHICH stages
        // lift it, and lets a deep-sleep-windowed fix be validated before it ships. Reuses the SAME
        // sessionHrvWindows the value is built from (can't diverge). Zero cost when the sink is nil.
        if let hrvTraceSink {
            func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
            // sessionHrvWindows requires ts-sorted rr (RMSSD = successive diffs); the value path passes the
            // stager's pre-sorted rrS, so sort our own copy of the day's raw rr once here for the re-window.
            let rrSorted = rr.sortedByTsStable()
            var allWin: [SleepStager.HrvWindow] = []
            for s in matched {
                let wins = SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rrSorted, stages: s.stages)
                if hrvWindowDetail {
                    for w in wins {
                        let rm = w.rmssd.map { "\(r2($0))ms" } ?? "nil"
                        hrvTraceSink("hrv window t=\((w.startTs - s.start) / 60)min stage=\(w.stage) beats=\(w.cleanBeats) rmssd=\(rm)")
                    }
                }
                allWin.append(contentsOf: wins)
            }
            func meanMs(_ ws: [SleepStager.HrvWindow]) -> String {
                let v = ws.compactMap { $0.rmssd }
                return v.isEmpty ? "nil" : "\(r2(v.reduce(0, +) / Double(v.count)))ms"
            }
            let withR = allWin.filter { $0.rmssd != nil }
            let deepW = withR.filter { $0.stage == "deep" }
            let lastSws = SleepStager.lastDeepRun(allWin).filter { $0.rmssd != nil }
            // `reported` is the value NOOP actually displays (duration-weighted session-mean-of-means);
            // `wholeNight` is the pooled-window mean it equals on single-session nights and the apples-to-
            // apples baseline for the deepOnly/lastSWS comparison (all three are pooled window means).
            let reported = avgHRVDaily.map { "\(r2($0))ms" } ?? "nil"
            hrvTraceSink("hrv nightSummary reported=\(reported) wholeNight=\(meanMs(withR)) deepOnly=\(meanMs(deepW)) lastSWS=\(meanMs(lastSws)) nWin=\(withR.count) nDeep=\(deepW.count)")
        }

        // Nightly APPROXIMATE respiratory rate (breaths/min) from the R-R stream via
        // RSA. WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate,
        // NOT a cloud/clinical respiration value. Per matched in-bed session, estimate
        // over [start, end]; the night's value = median of finite per-session
        // estimates; nil only when no session yields a finite estimate.
        //
        // A DEVICE-MEASURED rate wins over that estimate when the night has one. `vendorResp` carries a
        // strap's own respiratory-rate rows — today the Oura ring's 0x6A `breath`, one value per sleep
        // window, computed by the ring's firmware rather than derived here (see `vendorRespRateBpm`).
        // Preferring it is not a close call: on a ring night the RSA estimate is built from BANKED R-R,
        // where shuffling or reversing the night returns the same 13.3333 bpm — it carries no breathing
        // information at all. A WHOOP night passes no `vendorResp`, so it keeps the RSA path verbatim.
        let respRateDaily: Double? = {
            if let vendor = Self.vendorRespRateBpm(vendorResp,
                                                   sessions: matched.map { (start: $0.start, end: $0.end) }) {
                return vendor
            }
            let perSession = matched
                .map { SleepStager.respRateFromRR(rr, start: $0.start, end: $0.end) }
                .filter { $0.isFinite }
            return perSession.isEmpty ? nil : HRVAnalyzer.median(perSession)
        }()

        let sleepStart = matched.map { $0.start }.min()
        let sleepEnd = matched.map { $0.end }.max()

        // ── Skin-temperature deviation (offline) ──────────────────────────────
        // Computed BEFORE recovery so Charge can fold it in. Wear-gated in-bed mean
        // (baseline-independent, harvested every pass) + the deviation against the
        // personal baseline. In pass 1 baselines.skinTemp is nil so the deviation is nil
        // and the mean is harvested; IntelligenceEngine seeds the baseline from those means
        // and re-derives the deviation in pass 2 (mirrors avgHrv→recovery). APPROXIMATE.
        let nightlySkinTempC = wornNightlySkinTempC(matched, hr: hr, skinTemp: skinTemp,
                                                    family: skinTempFamily, anchorRaw: skinTempAnchorRaw,
                                                    wornToleranceSec: skinTempWornToleranceSec)
        let skinTempDevC: Double? = nightlySkinTempC.flatMap { (v: Double) -> Double? in
            guard let b = baselines.skinTemp, b.usable else { return nil }
            return round2(Baselines.deviation(v, state: b).delta)
        }

        // ── Raw SpO2 (WHOOP 4.0 v24 PPG ADC) ──────────────────────────────────
        // Nightly red/IR ADC means over the detected in-bed spans, or nil when the night carried no raw
        // SpO2 samples in any span. Baseline-independent (unlike skin temp): a RAW device reading, banked
        // as-is for the Health "Raw SpO₂" tile — NOT a calibrated blood-oxygen %. (#93)
        let nightlySpo2Raw = nightlySpo2RawMeans(matched, spo2: spo2)

        // ── Recovery / "Charge" ───────────────────────────────────────────────
        var recovery: Double? = nil
        // Ordered "why is Charge what it is" rows, built from the SAME inputs as the score
        // (empty when there is no score / cold-start). Surfaced on DayResult for the UI.
        var chargeDrivers: [ChargeDriver] = []
        if let hrvVal = avgHRVDaily, let rhrVal = restingHRDaily, let hrvBase = baselines.hrv {
            // Rest-quality term = the Rest composite ÷100 (replaces raw efficiency).
            let sleepPerf = restScore.map { $0 / 100.0 }
            recovery = RecoveryScorer.recovery(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: respRateDaily,       // term drops + renormalizes when nil / no baseline
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf,
                skinTempDev: skinTempDevC)  // symmetric penalty; drops + renormalizes when nil
            // Driver breakdown from the identical inputs; omits any missing term, never faked.
            chargeDrivers = RecoveryScorer.chargeDrivers(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: respRateDaily,
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf,
                skinTempDev: skinTempDevC)
        }
        // A5: skin temp as a RELATIVE deviation marker (trend, not a clinical absolute). nil
        // when no deviation is available (no baseline yet / not worn) so the UI shows nothing.
        let skinTempRelative = RecoveryScorer.skinTempRelative(deviationC: skinTempDevC)

        // ── Strain / "Effort" (cardiovascular load over the full CALENDAR day) ──
        // Integrate dayHr ([localMidnight, localMidnight+24h), clamped to `now` for today) when the
        // caller supplies it, so Effort covers the WHOLE day — an afternoon/evening workout lands in
        // today's Effort same-day instead of being cut off at the night window's ≈ noon bound, and
        // the prior evening's HR (the night window's −30h tail) no longer bleeds in. Falls back to the
        // night `hr` for pure-function callers/tests.
        let effMaxHR: Double? = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restForStrain = restingHRDaily.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = StrainScorer.strain(dayHr ?? hr, maxHR: effMaxHR, restingHR: restForStrain,
                                         method: effortMethod, sex: profile.sex)

        // ── Workouts ──────────────────────────────────────────────────────────
        // Detect over the full CALENDAR day (dayHr/dayGravity) when the caller supplies it, so a
        // current-day afternoon/evening workout is caught on its own day rather than lagging until
        // a later pass re-reads it through the next night window (which ends at ≈ noon). Falls back
        // to the night window for pure-function callers/tests. restingHR still comes from the night's
        // sleep sessions; nil → WorkoutDetector derives it from the day's own HR floor.
        var detectionFunnel: WorkoutDetector.DetectionFunnel? = nil
        let workouts = WorkoutDetector.detect(
            hr: dayHr ?? hr, gravity: dayGravity ?? gravity,
            restingHR: restingHRDaily.map(Double.init),
            // #1545: the DAY's effective HRmax, not just the override. Passing `maxHROverride` meant an
            // install with no override left the detector to fall back to `StrainScorer.estimateHRmax`,
            // which returns max(observed p99.5, Tanaka) -- so every bout was measured against a HRmax at
            // least as high as, and usually higher than, the one its own day used. A higher HRmax is a
            // bigger reserve and therefore a SMALLER %HRR, so bouts were held to a stricter yardstick
            // than the day containing them: for age 30 / RHR 60 with an observed 195, a 125 bpm minute is
            // zone 1 for the day and zone 0 for the bout. That is the same
            // day-disagrees-with-its-own-workouts failure #1562 fixed for the TRIMP method.
            //
            // This also feeds the z2+ qualification gate below, so it changes which bouts are DETECTED,
            // not only how they score -- in the direction of no longer dropping a workout by a standard
            // its own day never applied. Still nil for an age-less profile, where the detector's own
            // estimate remains the only available fallback.
            maxHR: effMaxHR,
            age: profile.age > 0 ? profile.age : nil,
            profile: profile,
            // #1545: the bouts inside a day MUST be scored by the same recipe as the day itself.
            // A day on Banister whose workouts were still on Edwards would show a session scoring
            // less than the day it sits inside, which is a worse inconsistency than either method.
            effortMethod: effortMethod,
            funnel: { detectionFunnel = $0 })

        // ── Steps (APPROXIMATE) ───────────────────────────────────────────────
        // step_motion_counter@57 is a CUMULATIVE u16 running counter (it climbs while you move, holds
        // flat when still, and wraps at 65536). The daily total is the SUM of WRAP-AWARE increments of
        // that counter across the time-ordered 1 Hz records: delta = (cur - prev) & 0xFFFF. The first
        // record has no predecessor (contributes 0). The day's read window may include adjacent-day
        // samples, so filter to the LOCAL-day key dayString(ts, tzOffset)==day first (#277).
        //
        // Reading byte @57 ALONE and summing it (the old bug, #132/#276/#316: exzanimo saw ~24× too
        // many steps) both ignored the high byte and summed a running total — exploding the count to
        // ~10M/day. Decoding the full u16 and summing wrap-aware DELTAS yields a sane ~14k. ESTIMATE
        // only — not cloud/clinical parity.
        let stepsTotal: Int? = {
            // Prefer the full-calendar-day stream for the additive total; fall back to the
            // night-window stream when the caller didn't supply one (pure-function callers/tests). The
            // day's read window may include adjacent-day samples, so filter to the LOCAL-day key first
            // (#277); the wrap-aware tick math itself lives in the shared StepsCounter kernel so the daily
            // and per-workout (#398) totals can never disagree.
            let inDay = (daySteps ?? steps).filter { tsInDay($0.ts) }
            guard let ticks = StepsCounter.stepsInWindow(inDay) else { return nil }
            // @57 counts motion ticks, not validated steps — the 5/MG counter overcounts. Divide
            // by the user-calibrated ticks-per-step (default 1.0 = raw pass-through; floor 0.5 so
            // a bad pref can at most double, never explode, the total). (#139)
            let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
            return scaled > 0 ? scaled : nil
        }()

        // ── Daily calories (APPROXIMATE, HR-only whole-day estimate) ──────────
        // Whole-day active+resting energy from the full HR window, using the same resting/active
        // per-second model the per-workout estimate uses (resting BMR below activeThreshold, Keytel
        // active above). effMaxHR + restingHRDaily are the same effective HRmax / resting baseline
        // strain uses. Nil when there is no HR. A heart-rate ESTIMATE — not cloud/clinical parity.
        // Whole-day additive totals (steps above, calories here) are summed over the full LOCAL
        // calendar day supplied by the caller (dayHr / daySteps), NOT the ~42h sleep-detection
        // window — which, anchored to the current time-of-day, would drop a past day's late hours
        // and double-count seconds shared with adjacent days. The filter uses the LOCAL-day key
        // (dayString(ts, tzOffset)) so it agrees with the bucket (#277). Fall back to the
        // night-window hr for pure-function callers that don't supply dayHr. Strain keeps the full
        // window (bounded log).
        let dayHrFiltered = (dayHr ?? hr).filter { tsInDay($0.ts) }
        let activeKcalEst: Double? = dayHrFiltered.isEmpty ? nil : Calories.estimateDayCalories(
            dayHrFiltered, profile: profile, hrmax: effMaxHR,
            restingHR: restingHRDaily.map(Double.init))

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        let daily = DailyMetric(
            day: day,
            totalSleepMin: matched.isEmpty ? nil : tstS / 60.0,
            efficiency: matched.isEmpty ? nil : efficiency,
            deepMin: matched.isEmpty ? nil : deepS / 60.0,
            remMin: matched.isEmpty ? nil : remS / 60.0,
            lightMin: matched.isEmpty ? nil : lightS / 60.0,
            disturbances: matched.isEmpty ? nil : disturbances,
            restingHr: restingHRDaily,
            avgHrv: avgHRVDaily,
            recovery: recovery,
            strain: strain,
            exerciseCount: workouts.count,
            spo2Pct: nil,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateDaily,
            steps: stepsTotal,
            activeKcalEst: activeKcalEst,
            spo2Red: nightlySpo2Raw?.red,
            spo2Ir: nightlySpo2Raw?.ir,
            avgSdnn: avgSDNNDaily)
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // ── Cache rows ────────────────────────────────────────────────────────
        let cachedSleep = matched.map { s in
            CachedSleepSession(
                startTs: s.start, endTs: s.end,
                efficiency: s.efficiency,
                restingHr: s.restingHR,
                avgHrv: s.avgHRV,
                stagesJSON: encodeStages(s.stages),
                // #345 follow-up: stamp the DAY's motion-coverage verdict on every session so the Sleep
                // tab can caption a sparse (likely under-detected) night. A NOOP-computed night is always
                // true/false here; imported nights never reach this path and keep nil (unknown).
                stagingSparse: gravitySparse)
        }

        // ── Per-session per-epoch motion (H8) ─────────────────────────────────
        // The strap's per-epoch movement on the SAME 30 s grid as each session's stages, for the caller to
        // persist beside `stagesJSON`. A session that can't grid (too little gravity) is omitted, so the
        // caller persists NULL there rather than a fabricated zero series.
        var sessionMotionByStart: [Int: [Double]] = [:]
        for s in matched {
            let motion = SleepStager.sessionEpochMotion(start: s.start, end: s.end, grav: gravity)
            if !motion.isEmpty { sessionMotionByStart[s.start] = motion }
        }

        // ── Per-session per-epoch BAND sleep_state (#175) ─────────────────────
        // Grid the strap's OWN band sleep_state (the SAME `bandSleepState` samples the H7 guard consumes)
        // onto each matched session's 30 s epochs, for the caller to persist beside `stagesJSON`. This is
        // the source the band-state chain lacked (persist → next pass's H7 re-onset CONFIRM). A session
        // whose window carries no band samples is omitted (no key) → the caller persists NULL, an absent
        // signal stays absent. Empty on a WHOOP 4.0 (no band_sleep_state stream). The band code is carried
        // verbatim; it NEVER overrides the derived hypnogram, only confirms a borderline morning re-onset.
        var sessionSleepStateByStart: [Int: [Int]] = [:]
        if !bandSleepState.isEmpty {
            for s in matched {
                let states = SleepStager.sessionEpochSleepState(start: s.start, end: s.end,
                                                                sleepState: bandSleepState)
                if !states.isEmpty { sessionSleepStateByStart[s.start] = states }
            }
        }

        // ── Per-score confidence tiers ────────────────────────────────────────
        let chargeConfidence = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines.hrv)
        let effortConfidence = ScoreConfidence.effort(strain: strain, hrSampleCount: hr.count)
        // Rest confidence with H9: downgrade a high-efficiency night whose deep+REM share is implausibly low
        // to low-confidence (likely staging miss) — honest, no faked stages. tstS/efficiency are the
        // main-group totals computed above; restorative = deepS + remS.
        let restConfidence = ScoreConfidence.rest(hasSession: !matched.isEmpty,
                                                  hasStagedSleep: hasStagedSleep,
                                                  asleepSeconds: tstS, restorativeSeconds: deepS + remS,
                                                  efficiency: efficiency, gravitySparse: gravitySparse)

        return DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                         workouts: workouts, recovery: recovery, strain: strain,
                         nightlySkinTempC: nightlySkinTempC,
                         restScore: restScore,
                         chargeConfidence: chargeConfidence,
                         effortConfidence: effortConfidence,
                         restConfidence: restConfidence,
                         sessionMotionByStart: sessionMotionByStart,
                         sessionSleepStateByStart: sessionSleepStateByStart,
                         chargeDrivers: chargeDrivers,
                         skinTempRelative: skinTempRelative,
                         detectionFunnel: detectionFunnel)
    }

    // MARK: - Rest composite (Charge/Effort/Rest)

    /// The 0–100 Rest score. Composite of four published-sleep-quality components:
    ///   - duration vs personal need (0.50): hours asleep ÷ need, clamped to 1.0.
    ///   - efficiency (0.20): asleep / in-bed, already in [0,1].
    ///   - restorative share (0.20): (deep + REM) ÷ asleep, clamped to a 0.50 target
    ///     (≈50% deep+REM is "full marks"; healthy adults sit ~40–50%).
    ///   - consistency (0.10): sleep/wake regularity in [0,1]; a single day carries no
    ///     regularity signal, so the caller supplies it from history — nil → neutral 0.5.
    /// All sub-scores clamp to [0,1]; the weighted sum scales to [0,100]. Kept
    /// dependency-free + constant-explicit so the Kotlin mirror is byte-identical.
    ///
    /// DEEP-sleep honesty (Reddit HRV/sleep report): pooling deep+REM let a night with normal REM
    /// but almost no DEEP still earn near-full restorative credit (so Rest read 95+ with little deep).
    /// When the caller supplies the DEEP split (`deepSeconds`), the restorative sub-score is scaled by
    /// a gentle deep-adequacy factor: full credit once deep ≥ `deepShareTarget` (~13% of asleep is the
    /// healthy floor), ramping to `deepFloorFactor` (0.5 — never zeroed) as deep → 0. So a near-zero-deep
    /// night loses up to half the 0.20 restorative term (~10 pts) — honest, not tanking, no fabricated
    /// stages. Deep unknown (`deepSeconds == nil`, e.g. an imported night with only a pooled total) →
    /// factor 1.0, identical to the prior pooled behaviour.
    public enum Rest {
        /// Default personal sleep need (hours) before the caller refines it.
        public static let defaultNeedHours: Double = 8.0
        /// "Full marks" restorative (deep+REM) share of asleep time.
        public static let restorativeTarget: Double = 0.50
        /// Deep-sleep share of asleep time that earns FULL restorative credit (~13% is the healthy
        /// floor for adults; below it the restorative term is scaled down toward `deepFloorFactor`).
        public static let deepShareTarget: Double = 0.13
        /// The most the restorative term is scaled down by when deep is ~absent — half, never zero,
        /// so a low-deep night reads honestly without the whole night tanking.
        public static let deepFloorFactor: Double = 0.5
        /// Neutral consistency when the caller supplies no regularity signal.
        public static let neutralConsistency: Double = 0.5

        public static let wDuration: Double = 0.50
        public static let wEfficiency: Double = 0.20
        public static let wRestorative: Double = 0.20
        public static let wConsistency: Double = 0.10

        /// Minimum trailing nights before a personal sleep-need estimate is trusted; below this the
        /// population default is used (cold-start honesty — never learn a need from a few nights).
        public static let minNeedNights: Int = 7
        /// Hard cap on personalized need (h): beyond typical adult need even for genuine long sleepers.
        public static let maxNeedHours: Double = 9.5

        /// Population TARGET nightly sleep need (hours) for an age (NSF/AASM recommended-range
        /// midpoint). Used as a FLOOR: the personal estimate can only adjust it UP for genuine long
        /// sleepers, NEVER below the population target — so a chronic under-sleeper's need can't drift
        /// toward their own deficit (which would falsely erase their sleep debt and read a short night
        /// as "Strong"). Deliberately the target, not the minimum: flooring at the low end of the
        /// range would understate a sleep-deprived (vs genuinely short-sleeping) user's deficit.
        public static func populationNeedFloorHours(age: Int?) -> Double {
            guard let age, age > 0 else { return 8.0 }   // unknown → adult target
            switch age {
            case ..<18: return 9.0     // children/teens need more (NSF 8–12; target ~9)
            default: return 8.0        // adults (18–64) & older (65+): NSF 7–9, target ~8 (the app default)
            }
        }

        /// Personalized nightly sleep need (hours), population-ANCHORED and age-floored (T1). The
        /// personal component is the user's UPPER-QUARTILE nightly duration over the trailing window —
        /// what they sleep on their less-restricted nights, NOT their average (which a chronic deficit
        /// drags down) — floored at the age-appropriate population TARGET and capped at `maxNeedHours`.
        /// So it only ever ADJUSTS UP for genuine long sleepers, never below the target. Fewer
        /// than `minNeedNights` scorable nights → the population default (cold-start). Zero/negative
        /// entries (no-data days) are dropped and do not count toward the minimum.
        public static func personalizedNeedHours(nightlyHours: [Double], age: Int?) -> Double {
            let floor = populationNeedFloorHours(age: age)
            let xs = nightlyHours.filter { $0 > 0 }.sorted()
            guard xs.count >= minNeedNights else {
                return min(max(defaultNeedHours, floor), maxNeedHours)
            }
            // Linear-interpolated 75th percentile — the "unrestricted" nights.
            let pos = 0.75 * Double(xs.count - 1)
            let lo = Int(pos), hi = min(lo + 1, xs.count - 1)
            let q = xs[lo] + (pos - Double(lo)) * (xs[hi] - xs[lo])
            return min(max(q, floor), maxNeedHours)
        }

        /// Build the composite. `tstSeconds` = total sleep time, `restorativeSeconds` = deep+REM
        /// seconds, `deepSeconds` = deep-stage seconds (nil → no deep-adequacy adjustment, pooled
        /// behaviour). Returns a value in [0,100].
        public static func composite(tstSeconds: Double,
                                     inBedSeconds: Double,
                                     efficiency: Double,
                                     restorativeSeconds: Double,
                                     needHours: Double,
                                     consistency: Double?,
                                     deepSeconds: Double? = nil) -> Double {
            func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }

            let needSeconds = max(needHours, 0.1) * 3600.0
            let durationScore = clamp01(tstSeconds / needSeconds)
            let efficiencyScore = clamp01(efficiency)
            // Deep-adequacy factor in [deepFloorFactor, 1]: 1.0 once deep ≥ target share, ramping
            // down to the floor as deep → 0. nil deep (unknown split) ⇒ 1.0 (no adjustment).
            let deepFactor: Double = {
                guard let deep = deepSeconds, tstSeconds > 0, deepShareTarget > 0 else { return 1.0 }
                let adequacy = clamp01((deep / tstSeconds) / deepShareTarget)
                return deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
            }()
            let restorativeScore = tstSeconds > 0
                ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget) * deepFactor
                : 0.0
            let consistencyScore = clamp01(consistency ?? neutralConsistency)

            let weighted = wDuration * durationScore
                + wEfficiency * efficiencyScore
                + wRestorative * restorativeScore
                + wConsistency * consistencyScore
            // weighted is in [0,1] (weights sum to 1). Scale to [0,100] and round to 2dp.
            return (weighted * 10000.0).rounded() / 100.0
        }

        /// Rest composite [0,100] derived from a persisted `DailyMetric` (the pass-2 / display path —
        /// the raw streams are gone, but the night's totals remain). nil when there's no sleep.
        /// Single source of truth so the persisted `sleep_performance` series and the Charge
        /// "Rest quality" term agree. `consistency` is the caller's regularity signal (nil → neutral).
        public static func composite(daily d: DailyMetric, needHours: Double = defaultNeedHours,
                                     consistency: Double? = nil) -> Double? {
            guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
            let tstSec = tstMin * 60.0
            let deepSec = (d.deepMin ?? 0) * 60.0
            let restorativeSec = (d.deepMin ?? 0) * 60.0 + (d.remMin ?? 0) * 60.0
            return composite(tstSeconds: tstSec, inBedSeconds: tstSec / max(eff, 0.01),
                             efficiency: eff, restorativeSeconds: restorativeSec,
                             needHours: needHours, consistency: consistency,
                             deepSeconds: deepSec)
        }
    }

    /// Round to 2 decimal places (matches the imported/demo skin-temp deviation precision).
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }

    /// Min worn, in-bed skin-temp samples (1 Hz ⇒ seconds) before a nightly mean is trusted.
    /// ~5 min guards against a few stray samples fabricating a baseline value.
    public static let minSkinTempSamples = 300

    /// Plausible worn skin-temperature range (°C). Off-wrist/charging samples drift to ambient
    /// and are excluded; the strap's own decode gate is the looser 5–45.
    static let skinTempMinC = 28.0
    static let skinTempMaxC = 42.0

    /// Wear-gated mean in-bed skin temperature (°C) for the night, or nil when too few worn
    /// samples. A sample counts when (a) its timestamp falls inside a detected in-bed `sessions`
    /// span, (b) a concurrent HR sample reads a worn, alive BPM (the strap streams HR only
    /// on-wrist), and (c) the value is in the plausible worn range — so an on-charger interval
    /// drifting to ambient can't poison the nightly mean.
    ///
    /// The raw→°C conversion is DEVICE-FAMILY-AWARE (#938): 5/MG stores CENTIDEGREES in
    /// skin_temp_raw@73 (°C = raw/100 — the Whoop5HistoricalTests captures read worn 3057 = 30.6 °C /
    /// off-wrist 2247 = 22.5 °C, physically right on both ends), but the WHOOP 4.0 v24 field@72 is a
    /// RAW ADC on a different scale — running it through /100 read every worn 4.0 night ~8 °C, below
    /// the 28 °C worn gate, so kept=0 and skin temp + the illness signal vanished (issue #938). The
    /// shared `skinTempCelsius(raw:family:)` (WhoopProtocol) picks the right scale; `family` defaults
    /// to `.whoop5` so every existing 5/MG + pure-function caller is byte-identical. All values
    /// APPROXIMATE.
    static func wornNightlySkinTempC(_ sessions: [SleepSession],
                                     hr: [HRSample],
                                     skinTemp: [SkinTempSample],
                                     family: DeviceFamily = .whoop5,
                                     // Per-device WHOOP 4.0 worn anchor raw (#938); nil → the global
                                     // `Whoop4SkinTemp.anchorRaw`, keeping 5/MG + pure-function callers
                                     // byte-identical. Threaded straight to the funnel's conversion.
                                     anchorRaw: Double? = nil,
                                     minSamples: Int = minSkinTempSamples,
                                     // #1467: how many seconds apart a "worn" HR sample may sit from a
                                     // skin-temp sample and still count it as concurrent. Default 0 =
                                     // today's exact-timestamp match, byte-identical for every existing
                                     // caller. See `skinTempFunnel`'s doc for why a ring needs this > 0.
                                     wornToleranceSec: Int = 0) -> Double? {
        skinTempFunnel(sessions, hr: hr, skinTemp: skinTemp, family: family,
                       anchorRaw: anchorRaw, minSamples: minSamples,
                       wornToleranceSec: wornToleranceSec).mean
    }

    /// Nightly means of the WHOOP 4.0 raw SpO2 PPG channels (red/IR ADC) over the detected in-bed
    /// `sessions`, or nil when no raw SpO2 sample fell inside any span. A sample counts when its
    /// timestamp lies within a session's [start, end]. RAW device output — the red/IR optical means are
    /// banked as-is (unit "raw_adc"); this is NOT a calibrated blood-oxygen %, which needs WHOOP's
    /// proprietary curve. Unlike skin temp there is deliberately no worn-HR / plausible-range gate: the
    /// value is surfaced honestly as raw ADC, never scored, so there's nothing to poison into a fake %.
    /// No wear gate (unlike skin temp): the strap streams SpO2 only on-wrist, so there's nothing to
    /// exclude, and this name — matching the Kotlin `nightlySpo2RawMeans` twin — avoids the "worn"
    /// prefix's false implication of a gate. (#93)
    static func nightlySpo2RawMeans(_ sessions: [SleepSession], spo2: [SpO2Sample]) -> (red: Int, ir: Int)? {
        guard !sessions.isEmpty, !spo2.isEmpty else { return nil }
        var redSum = 0, irSum = 0, kept = 0
        for s in spo2 where sessions.contains(where: { $0.start <= s.ts && s.ts <= $0.end }) {
            redSum += s.red; irSum += s.ir; kept += 1
        }
        guard kept > 0 else { return nil }
        return (red: redSum / kept, ir: irSum / kept)
    }

    /// Nightly gated mean of the 5/MG SpO2 **candidate** byte (`@82`) over the detected in-bed
    /// `sessions`, with the sample count it rests on — or nil when no in-band reading fell inside any
    /// span. (#112, tracking #103.)
    ///
    /// WHY THIS EXISTS. The candidate is decoded and stored but deliberately never scored: `@82` looks
    /// like a strap-computed SpO2 %, and on one independent 8-night check it tracked the WHOOP app almost
    /// exactly, but on the two nights from the strap it was found on it moved the OPPOSITE way. Two
    /// devices, contradictory answers, so it cannot be promoted. Breaking that tie needs a third strap —
    /// and until now the only way to read the candidate was to scroll the Deep Timeline chart and eyeball
    /// it, which is a poor instrument to ask a volunteer to use and produces a number nobody can check.
    ///
    /// This makes the comparison one number against one number: the wearer reads this and the figure the
    /// WHOOP app reports for the same night. `samples` travels with the mean on purpose — a mean over 11
    /// readings and a mean over 1100 are not the same evidence, and a correlation built from the first
    /// would be worthless.
    ///
    /// Gated to `70...100`, the SAME in-band window the decoder applies when it emits
    /// `spo2_candidate_82`: sub-70 nonzero values are diagnostic codes and bit-7 values are saturation
    /// sentinels, so averaging them in would produce a number that is not a percentage of anything.
    ///
    /// DIAGNOSTIC ONLY. Nothing scores this, it never writes `spo2Pct`, and it is not a blood-oxygen
    /// reading — it is the raw candidate averaged, surfaced so it can be checked against a real one.
    ///
    /// The mean is ROUNDED (`.rounded()`), not floored — `sum / kept` on two `Int`s truncates toward
    /// zero, silently biasing every candidate down by up to 0.99 (e.g. a true 97.97 shipped as 97,
    /// missing an app-displayed 98 the transform's own precise value would have round-matched). Every
    /// value in range is positive (70...100), so round-half-up and round-half-away-from-zero agree —
    /// no platform-divergence risk from the rounding rule itself. Byte-parity twin of the Kotlin
    /// `nightlySpo2CandidateMean`.
    public static func nightlySpo2CandidateMean(_ sessions: [SleepSession],
                                         aux: [V18AuxSample]) -> (mean: Int, samples: Int)? {
        guard !sessions.isEmpty, !aux.isEmpty else { return nil }
        var sum = 0, kept = 0
        for a in aux {
            guard let v = a.auxByte82, (70...100).contains(v) else { continue }
            guard sessions.contains(where: { $0.start <= a.ts && a.ts <= $0.end }) else { continue }
            sum += v; kept += 1
        }
        guard kept > 0 else { return nil }
        return (mean: Int((Double(sum) / Double(kept)).rounded()), samples: kept)
    }

    /// The plausible range for a raw Oura `0x6F` SpO2 sample before the ceiling transform below.
    /// Excludes the mis-scaled `dc_raw`/perfusion-channel contamination (-1016 … 11,709,098,
    /// OURA_PROTOCOL.md §6.5.0.1) by three orders of magnitude, same bounds as
    /// `Repository.spo2SingleChannelPlausible` (kept in sync manually — the app layer cannot be
    /// imported here, so that display gate should read from this one instead of redefining it).
    public static let spo2SingleChannelPlausible = 50...110

    /// Nightly **ceiling@100** mean of the Oura ring's own decoded SpO2 (`spo2Sample.red`, `0x6F`)
    /// over the detected in-bed `sessions`, with the sample count it rests on — or nil when no
    /// plausible sample fell inside any span. Oura twin of `nightlySpo2CandidateMean` above; queue
    /// 11a's starting transform.
    ///
    /// WHY CEILING@100, NOT RAW OR THE OFFSET+CLAMP FIT. `0x6F`'s raw wire mean carries a
    /// consistent positive bias — 20-48% of samples on a contamination-clean night read above the
    /// physical 100% ceiling (OURA_PROTOCOL.md §6.5.0.1) — so the raw mean is the ONE transform
    /// that has missed the Oura app's own displayed value on every full-tier paired night measured
    /// so far (1/3 as of 2026-08-22, see §6.5.0). `min(sample, 100)` applied PER-SAMPLE before
    /// averaging (a clamp on the aggregate mean is a different, wrong number) has round-matched
    /// the app's displayed value on all 3 of those nights — the best track record of the
    /// candidates tried, edging out the offset−0.32+clamp[85,100] fit (2/3) on this same bar. Not a
    /// validated calibration (n=3, only the rounded integer, not the app's internal precision) —
    /// per the derived-biosignal rule (CLAUDE.md), it ships the same way `spo2_candidate_82` ships:
    /// diagnostic-only, gated behind the display toggle, never written to `spo2Pct`, never scored.
    ///
    /// Gated to `spo2SingleChannelPlausible` (50...110) BEFORE the ceiling is applied, so a
    /// contaminated row (down to -1016) cannot drag the mean down — the ceiling alone only guards
    /// the top of the range.
    ///
    /// The mean is ROUNDED (`.rounded()`), not floored — same fix, same reasoning, as
    /// `nightlySpo2CandidateMean` just above (found 2026-08-24 comparing a live-persisted 08-23/24
    /// row against the Oura app: the transform's precise mean, 97.97, round-matched the app's 98%,
    /// but the shipped `sum / kept` Int division floored it to 97, a spurious miss). All values here
    /// are positive too, so the rounding-rule choice is again inert. Byte-parity twin of the Kotlin
    /// `nightlySpo2CeilingMean`.
    public static func nightlySpo2CeilingMean(_ sessions: [SleepSession],
                                        spo2: [SpO2Sample]) -> (mean: Int, samples: Int)? {
        guard !sessions.isEmpty, !spo2.isEmpty else { return nil }
        var sum = 0, kept = 0
        for s in spo2 {
            guard spo2SingleChannelPlausible.contains(s.red) else { continue }
            guard sessions.contains(where: { $0.start <= s.ts && s.ts <= $0.end }) else { continue }
            sum += min(s.red, 100); kept += 1
        }
        guard kept > 0 else { return nil }
        return (mean: Int((Double(sum) / Double(kept)).rounded()), samples: kept)
    }

    /// #1169 SHADOW METRIC: the primary-session MEAN resting HR — window each detected sleep session's HR
    /// samples to `[start, end)` and delegate to the #1174-defined `PrimarySessionRestingHR.meanHR` (that
    /// definition is UNCHANGED). `IntelligenceEngine` stores the result beside the shipped nightly HR FLOOR
    /// (`daily.restingHr`) as "rhr_primary_session" — instrumentation only, never shown, never scored — so
    /// the mean-vs-floor comparison #1169 asks for can be evaluated from exports without a headline switch.
    /// Byte-parity twin of the Kotlin `primarySessionRestingHR`.
    public static func primarySessionRestingHR(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples) -> Double? {
        PrimarySessionRestingHR.meanHR(sessions: primarySessions(sessions: sessions, hr: hr),
                                       validBpm: validBpm, minValidSamples: minValidSamples)
    }

    /// #1169 coverage inputs for the shadow `rhr_primary_session` mean (valid-sample count + primary-session
    /// duration). Builds the SAME per-session inputs as `primarySessionRestingHR` and delegates to
    /// `PrimarySessionRestingHR.coverage`, so it is `nil` in lockstep with the mean. Byte-parity twin of the
    /// Kotlin `primarySessionRestingHRCoverage`.
    public static func primarySessionRestingHRCoverage(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples) -> PrimarySessionRestingHR.Coverage? {
        PrimarySessionRestingHR.coverage(sessions: primarySessions(sessions: sessions, hr: hr),
                                         validBpm: validBpm, minValidSamples: minValidSamples)
    }

    /// Window `hr` to each session's `[start, end)` once — the shared input BOTH the #1169 mean and its coverage
    /// average over. Extracted so a caller that needs both windows the samples a SINGLE time (this is O(sessions
    /// × hr); doing it once per metric is pure duplicate work). Twin of the Kotlin `primarySessions`.
    private static func primarySessions(sessions: [SleepSession], hr: [HRSample]) -> [PrimarySessionRestingHR.Session] {
        sessions.map { s in
            PrimarySessionRestingHR.Session(
                durationSec: Double(s.end - s.start),
                bpm: hr.filter { $0.ts >= s.start && $0.ts < s.end }.map { $0.bpm })
        }
    }

    /// The #1169 mean AND its coverage from ONE windowing of `hr` (both read the same longest primary session).
    /// Byte-identical to calling `primarySessionRestingHR` + `primarySessionRestingHRCoverage` separately, but
    /// windows the per-session samples once instead of twice — the only caller (IntelligenceEngine) needs both.
    /// Twin of the Kotlin `primarySessionRestingHRWithCoverage`.
    public static func primarySessionRestingHRWithCoverage(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples)
        -> (mean: Double?, coverage: PrimarySessionRestingHR.Coverage?) {
        let built = primarySessions(sessions: sessions, hr: hr)
        return (PrimarySessionRestingHR.meanHR(sessions: built, validBpm: validBpm, minValidSamples: minValidSamples),
                PrimarySessionRestingHR.coverage(sessions: built, validBpm: validBpm, minValidSamples: minValidSamples))
    }

    // MARK: - Skin-temp funnel diagnostic (#752)

    // Skin temp coming out 0/absent on a WHOOP 4.0 (or any) night is opaque: the user can't tell whether
    // there were no samples at all, every sample fell outside a detected in-bed span, none were worn (no
    // concurrent live HR), every value was outside the plausible worn range, or there simply weren't enough
    // survivors to trust a mean. This pure, READ-ONLY funnel re-runs the SAME gates `wornNightlySkinTempC`
    // applies and counts where samples dropped - WITHOUT changing the mean or any score - so an absent
    // skin-temp can be triaged ("0 raw samples in window" vs "1842 samples but none worn" vs "all out of the
    // 28–42 °C range - likely off-wrist/charging"). It is a triage surface, logged by the caller, never a
    // scoring change. Mirrors the REM-funnel diagnostic shape (#688). (#752)

    /// Why nightly skin temp funneled toward absent for one night. Counts are over the night's raw skin-temp
    /// samples; each sample is attributed to the FIRST gate that dropped it, in the SAME order
    /// `wornNightlySkinTempC` applies (not-worn → out-of-window → out-of-range → kept), so the four drop
    /// buckets plus `kept` sum to `totalSamples`. Pure + deterministic; shares the exact gate logic with the
    /// real computation, so it explains the SAME mean the app uses. (#752)
    public struct SkinTempFunnelDiagnostic: Equatable, Sendable {
        /// Raw skin-temp samples seen for the night (the funnel's mouth).
        public let totalSamples: Int
        /// Dropped because no concurrent worn-HR second (the strap streams HR only on-wrist).
        public let droppedNotWorn: Int
        /// Worn, but the sample's timestamp fell in no detected in-bed session span.
        public let droppedOutOfWindow: Int
        /// Worn + in-window, but the value was outside the plausible worn range (28–42 °C) - likely
        /// off-wrist/charging drift to ambient.
        public let droppedOutOfRange: Int
        /// Samples that passed every gate and fed the nightly mean.
        public let kept: Int
        /// Minimum kept samples required before a nightly mean is trusted (the last gate).
        public let minSamples: Int
        /// The nightly mean (°C) the gates produced, or nil when `kept < minSamples` (or no input).
        public let mean: Double?
        // #skin-diag: raw-ADC visibility so an absent WHOOP 4.0 skin temp explains WHY (anchor mis-map
        // vs genuinely no worn data). Pure observations of the input — they do NOT affect `mean`/gates.
        /// Min / median / max of the night's RAW skin-temp ADC values (nil when no samples). The WHOOP
        /// 4.0 worn band is ~550–2040; this tells whether the strap streamed a plausible worn band at all.
        public let rawMin: Int?
        public let rawMedian: Int?
        public let rawMax: Int?
        /// Raw samples inside the worn ADC band (`Whoop4SkinTemp.wornMin…wornMaxRaw`). ≥100 lets the
        /// per-device anchor (#938/#404) learn; below that it falls back to the global 826 anchor.
        public let inBandCount: Int
        /// The anchor raw actually used for the °C map — the caller's per-device anchor if supplied, else
        /// the global 826. nil on 5/MG (centidegree path, no anchor).
        public let resolvedAnchorRaw: Double?
        /// What °C the median raw maps to under `resolvedAnchorRaw`. If this sits outside 28–42 °C, EVERY
        /// worn sample is gated out — the #404 anchor-mismap signature. nil on 5/MG or when no samples.
        public let medianMappedC: Double?

        public init(totalSamples: Int, droppedNotWorn: Int, droppedOutOfWindow: Int,
                    droppedOutOfRange: Int, kept: Int, minSamples: Int, mean: Double?,
                    rawMin: Int? = nil, rawMedian: Int? = nil, rawMax: Int? = nil,
                    inBandCount: Int = 0, resolvedAnchorRaw: Double? = nil, medianMappedC: Double? = nil) {
            self.totalSamples = totalSamples; self.droppedNotWorn = droppedNotWorn
            self.droppedOutOfWindow = droppedOutOfWindow; self.droppedOutOfRange = droppedOutOfRange
            self.kept = kept; self.minSamples = minSamples; self.mean = mean
            self.rawMin = rawMin; self.rawMedian = rawMedian; self.rawMax = rawMax
            self.inBandCount = inBandCount; self.resolvedAnchorRaw = resolvedAnchorRaw
            self.medianMappedC = medianMappedC
        }

        /// True when the night produced no usable mean - the case this diagnostic exists to triage.
        public var isAbsent: Bool { mean == nil }

        /// Human-readable line(s) for the caller to LOG. No I/O here - the engine stays pure. When raw
        /// samples exist, a second `skin-temp-raw:` line surfaces the ADC band + resolved anchor mapping.
        public var summary: String {
            var s = "skin-temp-funnel: \(totalSamples) samples → kept \(kept)/\(minSamples) "
                + "(mean=\(mean.map { String(format: "%.2f°C", $0) } ?? "absent")); "
                + "dropped[notWorn=\(droppedNotWorn), outOfWindow=\(droppedOutOfWindow), "
                + "outOfRange=\(droppedOutOfRange)]"
            if let lo = rawMin, let mid = rawMedian, let hi = rawMax {
                s += "\nskin-temp-raw: raw[min=\(lo) p50=\(mid) max=\(hi)] inBand=\(inBandCount)/\(totalSamples)"
                if let a = resolvedAnchorRaw, let mapped = medianMappedC {
                    s += String(format: "; anchor=%.0f → p50 maps %.1f°C (worn gate 28–42°C, ADC band 550–2040)",
                                a, mapped)
                }
            }
            return s
        }
    }

    /// #1467: how far apart (seconds) a valid HR sample may sit from a skin-temp sample and still mark it
    /// "worn", when the caller opts in via `wornToleranceSec` > 0. Ground-truthed against a 7-night Oura
    /// gap: exact-timestamp co-occurrence (tolerance 0) landed every one of those nights just under
    /// `minSkinTempSamples` (155-296 kept, minSamples=300) despite 269-675 raw skin-temp samples and
    /// 3,900-14,600 valid HR samples each night — the ring's HR and skin-temp channels are independently
    /// clocked, unlike a WHOOP strap's single co-sampled per-second stream, so only ~40-55% of timestamps
    /// coincide exactly by chance. A ±2 s window alone recovered every real (non-fragment) night comfortably
    /// past the floor (622-635 kept); this default carries margin. See `worklog/BOARD.md` queue 11b and
    /// `worklog/analysis/2026-08-19-1745-oura-app-skintemp-groundtruth-check.txt`.
    public static let defaultOuraWornToleranceSec = 5

    /// Read-only skin-temp funnel for one night (#752). Re-runs the SAME wear/window/range gates
    /// `wornNightlySkinTempC` uses (and produces the IDENTICAL mean), additionally counting where each
    /// sample dropped, so an absent skin temp is self-explaining. The public `wornNightlySkinTempC` is a
    /// thin wrapper over this, so the two can never disagree. Pure + deterministic. (#752)
    public static func skinTempFunnel(_ sessions: [SleepSession],
                                      hr: [HRSample],
                                      skinTemp: [SkinTempSample],
                                      family: DeviceFamily = .whoop5,
                                      // Per-device WHOOP 4.0 worn anchor raw (#938 second capture); nil → the
                                      // global `Whoop4SkinTemp.anchorRaw`, so 5/MG + pure-function callers are
                                      // byte-identical.
                                      anchorRaw: Double? = nil,
                                      minSamples: Int = minSkinTempSamples,
                                      // #1467: 0 (default) = exact-timestamp "worn" match, byte-identical to
                                      // every caller before this change. A device whose HR and skin-temp
                                      // streams aren't co-sampled at 1 Hz (an Oura ring) needs > 0 — see
                                      // `defaultOuraWornToleranceSec`'s doc for the ground truth behind the
                                      // value. IntelligenceEngine threads it per the OWNER device, never
                                      // globally, so WHOOP behavior is untouched by construction.
                                      wornToleranceSec: Int = 0) -> SkinTempFunnelDiagnostic {
        let total = skinTemp.count
        // #skin-diag: raw-ADC band + resolved anchor — PURE observation of the input, computed once and
        // reported on both return paths. Never touches the mean/gate logic below (byte-parity preserved).
        let sortedRaws = skinTemp.map { $0.raw }.sorted()
        let rawMin = sortedRaws.first
        let rawMax = sortedRaws.last
        let rawMedian = sortedRaws.isEmpty ? nil : sortedRaws[sortedRaws.count / 2]
        let inBandCount = family == .whoop4
            ? sortedRaws.filter { $0 >= Whoop4SkinTemp.wornMinRaw && $0 <= Whoop4SkinTemp.wornMaxRaw }.count
            : total
        let usedAnchor: Double? = family == .whoop4 ? (anchorRaw ?? Whoop4SkinTemp.anchorRaw) : nil
        let medianMappedC: Double? = (usedAnchor != nil && rawMedian != nil)
            ? skinTempCelsius(raw: rawMedian!, family: family, anchorRaw: usedAnchor!) : nil
        // No sessions ⇒ every sample is out of window; no samples ⇒ an empty funnel. Either way the mean is
        // nil, exactly as `wornNightlySkinTempC`'s early return produced before.
        if sessions.isEmpty || skinTemp.isEmpty {
            return SkinTempFunnelDiagnostic(totalSamples: total, droppedNotWorn: 0,
                                            droppedOutOfWindow: sessions.isEmpty ? total : 0,
                                            droppedOutOfRange: 0, kept: 0, minSamples: minSamples, mean: nil,
                                            rawMin: rawMin, rawMedian: rawMedian, rawMax: rawMax,
                                            inBandCount: inBandCount, resolvedAnchorRaw: usedAnchor,
                                            medianMappedC: medianMappedC)
        }
        // #1467: tolerance 0 keeps the ORIGINAL O(1) exact-second Set lookup, untouched — every caller
        // before this change, and every WHOOP night today, takes this branch and is byte-identical.
        // tolerance > 0 (an Oura owner) instead sorts the valid HR timestamps once and binary-searches
        // each skin-temp sample for the nearest one, so the check stays O(hr log hr + skinTemp log hr)
        // rather than an O(hr × skinTemp) scan.
        let wornSeconds: Set<Int>?
        let sortedValidHrTs: [Int]?
        if wornToleranceSec <= 0 {
            var s = Set<Int>(minimumCapacity: hr.count)
            for h in hr where (30...220).contains(h.bpm) { s.insert(h.ts) }
            wornSeconds = s
            sortedValidHrTs = nil
        } else {
            wornSeconds = nil
            sortedValidHrTs = hr.filter { (30...220).contains($0.bpm) }.map { $0.ts }.sorted()
        }
        // True when some valid HR reading sits within `wornToleranceSec` of `ts` (inclusive both sides).
        func isWorn(_ ts: Int) -> Bool {
            if let wornSeconds { return wornSeconds.contains(ts) }
            guard let sortedValidHrTs, !sortedValidHrTs.isEmpty else { return false }
            var lo = 0, hi = sortedValidHrTs.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let d = sortedValidHrTs[mid] - ts
                if abs(d) <= wornToleranceSec { return true }
                if d < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return false
        }
        var sum = 0.0
        var kept = 0
        var notWorn = 0, outOfWindow = 0, outOfRange = 0
        for t in skinTemp {
            if !isWorn(t.ts) { notWorn += 1; continue }
            if !sessions.contains(where: { t.ts >= $0.start && t.ts <= $0.end }) { outOfWindow += 1; continue }
            // WHOOP 4.0 ONLY (#938 second capture): drop raws outside the plausible worn ADC band BEFORE the
            // anchor map. The no-contact floor (~509) and the 11-bit saturation ceiling (2047) are doff /
            // charging transients, not worn skin — with a per-device anchor a floor or pegged raw could
            // otherwise map into the 28–42 °C window and poison the mean. Attributed to the SAME `outOfRange`
            // bucket the °C gate uses ("out of plausible range"), so the four drop buckets + kept still sum to
            // totalSamples. `.whoop5` is untouched here → its centidegree path stays byte-identical.
            if family == .whoop4,
               t.raw < Whoop4SkinTemp.wornMinRaw || t.raw > Whoop4SkinTemp.wornMaxRaw {
                outOfRange += 1; continue
            }
            // Per-device anchor (#938): nil anchorRaw → the global `Whoop4SkinTemp.anchorRaw` (826), byte-
            // identical to the pre-change conversion; `.whoop5` ignores the anchor.
            let c = skinTempCelsius(raw: t.raw, family: family, anchorRaw: anchorRaw ?? Whoop4SkinTemp.anchorRaw)
            if c < skinTempMinC || c > skinTempMaxC { outOfRange += 1; continue }
            sum += c
            kept += 1
        }
        let mean = kept >= minSamples ? sum / Double(kept) : nil
        return SkinTempFunnelDiagnostic(totalSamples: total, droppedNotWorn: notWorn,
                                        droppedOutOfWindow: outOfWindow, droppedOutOfRange: outOfRange,
                                        kept: kept, minSamples: minSamples, mean: mean,
                                        rawMin: rawMin, rawMedian: rawMedian, rawMax: rawMax,
                                        inBandCount: inBandCount, resolvedAnchorRaw: usedAnchor,
                                        medianMappedC: medianMappedC)
    }
}
