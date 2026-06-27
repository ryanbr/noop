import Foundation
import WhoopProtocol
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
        /// Recovery / "Charge" score [0,100] or nil (cold-start / no HRV baseline).
        public let recovery: Double?
        /// Day strain / "Effort" [0,100] or nil (insufficient HR samples / invalid HRR).
        public let strain: Double?
        /// Rest composite [0,100] or nil (no in-bed data). This is the value the
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

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?, nightlySkinTempC: Double? = nil,
                    restScore: Double? = nil,
                    chargeConfidence: ScoreConfidence = .calibrating,
                    effortConfidence: ScoreConfidence = .calibrating,
                    restConfidence: ScoreConfidence = .calibrating,
                    sessionMotionByStart: [Int: [Double]] = [:]) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.recovery = recovery; self.strain = strain
            self.nightlySkinTempC = nightlySkinTempC
            self.restScore = restScore
            self.chargeConfidence = chargeConfidence
            self.effortConfidence = effortConfidence
            self.restConfidence = restConfidence
            self.sessionMotionByStart = sessionMotionByStart
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
    public static func analyzeDay(day: String,
                                  hr: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
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
                                  // Opt-in experimental sleep staging (V2). When true, detected nights are
                                  // staged by `SleepStagerV2` instead of V1. Default false keeps V1 the
                                  // byte-identical default for pure-function callers/tests; IntelligenceEngine
                                  // threads `PuffinExperiment.experimentalSleepV2Enabled`. (V7 / #690)
                                  useSleepStagerV2: Bool = false) -> DayResult {

        // ── Sleep detection + staging ─────────────────────────────────────────
        let allSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                  tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                                  bandSleepState: bandSleepState,
                                                  useSleepStagerV2: useSleepStagerV2)
        // Sessions attributed to `day` = those whose end falls on `day` (LOCAL day, #277). `day` is
        // the caller's local-day key; attribute by the same offset so the bucket and the key agree.
        let matched = allSessions.filter { dayString($0.end, offsetSec: tzOffsetSeconds) == day }

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
            inBedS += inBed                       // SUM each fragment's in-bed span
            effWeighted += s.efficiency * inBed   // in-bed-weighted efficiency across the group
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        // (#777) Count the out-of-bed time BETWEEN bridged fragments as awake in-bed: the sleeper was up
        // (e.g. a 20-min walk) but it's one night, so the gap is WASO. Adding it to in-bed (not to asleep)
        // raises awake (= in-bed − asleep) and lowers efficiency, instead of vanishing the time entirely.
        let gapWakeS = Double(SleepStageTotals.interFragmentWakeSeconds(mainGroup.map { (start: $0.start, end: $0.end) }))
        inBedS += gapWakeS
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

        // ── Rest composite (Charge/Effort/Rest) ───────────────────────────────
        // The 0–100 sleep score the `sleep_performance` metric key now carries:
        //   duration-vs-personal-need 0.50 + efficiency 0.20 + restorative share 0.20
        //   + consistency 0.10. nil when there is no in-bed data. The Charge "Rest
        //   quality" term reads it ÷100 (replacing raw efficiency).
        let hasStagedSleep = (deepS + remS) > 0
        let restScore: Double? = matched.isEmpty ? nil : Rest.composite(
            tstSeconds: tstS,
            inBedSeconds: inBedS,
            efficiency: efficiency,
            restorativeSeconds: deepS + remS,
            needHours: sleepNeedHours,
            consistency: sleepConsistency,
            deepSeconds: deepS)

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
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Nightly APPROXIMATE respiratory rate (breaths/min) from the R-R stream via
        // RSA. WHOOP5 v18 carries no raw resp ADC, so this is an on-device estimate,
        // NOT a cloud/clinical respiration value. Per matched in-bed session, estimate
        // over [start, end]; the night's value = median of finite per-session
        // estimates; nil only when no session yields a finite estimate.
        let respRateDaily: Double? = {
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
        let nightlySkinTempC = wornNightlySkinTempC(matched, hr: hr, skinTemp: skinTemp)
        let skinTempDevC: Double? = nightlySkinTempC.flatMap { (v: Double) -> Double? in
            guard let b = baselines.skinTemp, b.usable else { return nil }
            return round2(Baselines.deviation(v, state: b).delta)
        }

        // ── Recovery / "Charge" ───────────────────────────────────────────────
        var recovery: Double? = nil
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
        }

        // ── Strain / "Effort" (cardiovascular load over the full CALENDAR day) ──
        // Integrate dayHr ([localMidnight, localMidnight+24h), clamped to `now` for today) when the
        // caller supplies it, so Effort covers the WHOLE day — an afternoon/evening workout lands in
        // today's Effort same-day instead of being cut off at the night window's ≈ noon bound, and
        // the prior evening's HR (the night window's −30h tail) no longer bleeds in. Falls back to the
        // night `hr` for pure-function callers/tests.
        let effMaxHR: Double? = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restForStrain = restingHRDaily.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = StrainScorer.strain(dayHr ?? hr, maxHR: effMaxHR, restingHR: restForStrain,
                                         sex: profile.sex)

        // ── Workouts ──────────────────────────────────────────────────────────
        // Detect over the full CALENDAR day (dayHr/dayGravity) when the caller supplies it, so a
        // current-day afternoon/evening workout is caught on its own day rather than lagging until
        // a later pass re-reads it through the next night window (which ends at ≈ noon). Falls back
        // to the night window for pure-function callers/tests. restingHR still comes from the night's
        // sleep sessions; nil → WorkoutDetector derives it from the day's own HR floor.
        let workouts = WorkoutDetector.detect(
            hr: dayHr ?? hr, gravity: dayGravity ?? gravity,
            restingHR: restingHRDaily.map(Double.init),
            maxHR: maxHROverride,
            age: profile.age > 0 ? profile.age : nil,
            profile: profile)

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
            // night-window stream when the caller didn't supply one (pure-function callers/tests).
            let sorted = (daySteps ?? steps).filter { dayString($0.ts, offsetSec: tzOffsetSeconds) == day }.sorted { $0.ts < $1.ts }
            if sorted.count < 2 { return nil }
            // A delta this large is a big time-gap / disconnect boundary between sync sessions (or a
            // firmware reboot, byte-indistinguishable from a wrap), NOT real steps — drop it so gaps
            // don't inflate the total. Real 1 Hz motion never ticks this fast between adjacent records.
            let maxStepDelta = 512
            var total = 0
            for i in 1..<sorted.count {
                let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
                if delta >= 1 && delta < maxStepDelta { total += delta }  // ignore a delta >= 512 (gap/reset)
            }
            if total <= 0 { return nil }
            // @57 counts motion ticks, not validated steps — the 5/MG counter overcounts. Divide
            // by the user-calibrated ticks-per-step (default 1.0 = raw pass-through; floor 0.5 so
            // a bad pref can at most double, never explode, the total). (#139)
            let scaled = Int((Double(total) / max(profile.stepTicksPerStep, 0.5)).rounded())
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
        let dayHrFiltered = (dayHr ?? hr).filter { dayString($0.ts, offsetSec: tzOffsetSeconds) == day }
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
            activeKcalEst: activeKcalEst)
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // ── Cache rows ────────────────────────────────────────────────────────
        let cachedSleep = matched.map { s in
            CachedSleepSession(
                startTs: s.start, endTs: s.end,
                efficiency: s.efficiency,
                restingHr: s.restingHR,
                avgHrv: s.avgHRV,
                stagesJSON: encodeStages(s.stages))
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

        // ── Per-score confidence tiers ────────────────────────────────────────
        let chargeConfidence = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines.hrv)
        let effortConfidence = ScoreConfidence.effort(strain: strain, hrSampleCount: hr.count)
        // Rest confidence with H9: downgrade a high-efficiency night whose deep+REM share is implausibly low
        // to low-confidence (likely staging miss) — honest, no faked stages. tstS/efficiency are the
        // main-group totals computed above; restorative = deepS + remS.
        let restConfidence = ScoreConfidence.rest(hasSession: !matched.isEmpty,
                                                  hasStagedSleep: hasStagedSleep,
                                                  asleepSeconds: tstS, restorativeSeconds: deepS + remS,
                                                  efficiency: efficiency)

        return DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                         workouts: workouts, recovery: recovery, strain: strain,
                         nightlySkinTempC: nightlySkinTempC,
                         restScore: restScore,
                         chargeConfidence: chargeConfidence,
                         effortConfidence: effortConfidence,
                         restConfidence: restConfidence,
                         sessionMotionByStart: sessionMotionByStart)
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
    static let minSkinTempSamples = 300

    /// Plausible worn skin-temperature range (°C). Off-wrist/charging samples drift to ambient
    /// and are excluded; the strap's own decode gate is the looser 5–45.
    static let skinTempMinC = 28.0
    static let skinTempMaxC = 42.0

    /// Wear-gated mean in-bed skin temperature (°C) for the night, or nil when too few worn
    /// samples. A sample counts when (a) its timestamp falls inside a detected in-bed `sessions`
    /// span, (b) a concurrent HR sample reads a worn, alive BPM (the strap streams HR only
    /// on-wrist), and (c) the value is in the plausible worn range — so an on-charger interval
    /// drifting to ambient can't poison the nightly mean. °C = raw/100 — the firmware stores
    /// CENTIDEGREES in skin_temp_raw@73, not the AS6221's native 1/128 register units: the real
    /// captures in Whoop5HistoricalTests read worn=3057 / off-wrist=2247, which under /100 are
    /// 30.6 °C skin and 22.5 °C room ambient (physically right on both ends) but under /128 are
    /// 23.9 °C and 17.6 °C — "skin" colder than any live wrist, and below the 28 °C worn gate, so
    /// /128 silently dropped every real night (PR #97 review, tigercraft4; user report #166).
    /// Matches the Android decoder's /100 for the same register. All values APPROXIMATE.
    static func wornNightlySkinTempC(_ sessions: [SleepSession],
                                     hr: [HRSample],
                                     skinTemp: [SkinTempSample],
                                     minSamples: Int = minSkinTempSamples) -> Double? {
        if sessions.isEmpty || skinTemp.isEmpty { return nil }
        var wornSeconds = Set<Int>(minimumCapacity: hr.count)
        for h in hr where (30...220).contains(h.bpm) { wornSeconds.insert(h.ts) }
        var sum = 0.0
        var n = 0
        for t in skinTemp {
            if !wornSeconds.contains(t.ts) { continue }
            if !sessions.contains(where: { t.ts >= $0.start && t.ts <= $0.end }) { continue }
            let c = Double(t.raw) / 100.0
            if c < skinTempMinC || c > skinTempMaxC { continue }
            sum += c
            n += 1
        }
        return n >= minSamples ? sum / Double(n) : nil
    }
}
