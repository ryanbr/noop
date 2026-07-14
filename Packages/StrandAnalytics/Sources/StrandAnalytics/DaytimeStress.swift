import Foundation
import WhoopProtocol

// DaytimeStress.swift — an intraday (hour-by-hour) read of the SAME autonomic stress
// proxy the daily Stress monitor shows, computed from the day's banked HR + R-R.
//
// The daily Stress score (StressView / StressScreen) maps "resting HR up + HRV down vs
// a personal baseline" onto a 0–3 logistic. This helper applies that SAME math at the
// per-hour grain so the Stress screen can show *when* in the day stress ran high — not
// a new score. For each waking hour it computes:
//
//   • mean HR over the hour                    (HR up   = stress, like daily RHR)
//   • RMSSD over the hour's clean R-R          (HRV down = stress, like daily avgHRV)
//
// and z-scores each against the day's OWN quiet reference (the calm-hour median + the
// spread across hours), then squashes the z-sum onto 0–3 with the identical logistic
//   stress = 3 / (1 + e^(−raw)). 0 calm · 1.5 baseline · 3 high — same bands as the daily
// score. The day is its own baseline: a desk day with one tense afternoon reads that
// afternoon as elevated *relative to that person's own calm hours*, no cloud, no history
// needed beyond the day itself.
//
// "Sustained high stress" is an honest, conservative flag: the most recent
// `sustainedHours` covered hours must ALL sit in the HIGH band (≥ highBandFloor). It
// drives a passive in-app suggestion to run a Breathe session — never a notification.
//
// APPROXIMATE and non-clinical: an hour with too little data (few HR samples / too few
// clean beats) is reported as `.noData` and never invented.

public enum DaytimeStress {

    // MARK: - Tunables

    /// Minimum HR samples in an hour before its mean HR is trusted (~5 min at 1 Hz).
    public static let minHourHRSamples: Int = 300
    /// Bucket width for the timeline, in seconds (one hour).
    public static let bucketSeconds: Int = 3_600
    /// Band floor for "high" on the shared 0–3 scale (matches StressBand .high).
    public static let highBandFloor: Double = 2.0
    /// Consecutive most-recent covered hours that must all be HIGH to flag sustained stress.
    public static let sustainedHours: Int = 3
    /// First/last local hour-of-day treated as "waking" for the timeline (06:00–22:00).
    public static let wakingStartHour: Int = 6
    public static let wakingEndHour: Int = 22

    // MARK: - Motion gate
    //
    // Cardiac signals alone cannot separate psychological stress from EXERTION: a brisk walk and a
    // tense meeting both raise HR and suppress HRV. Without a motion channel an ambulatory hour is
    // scored as "stress". When the caller supplies the day's gravity (wrist accelerometer), an hour
    // that was substantially ambulatory is MASKED (`level == nil`, `HourPoint.maskedForActivity ==
    // true`) rather than scored, and it is excluded from the calm reference and the coverage totals.
    // No gravity → no masking → byte-identical prior behaviour, so the gate only applies when motion
    // is actually observable. Orthogonal to `ScoringMode` below: masking decides WHICH hours score,
    // the mode decides WHAT reference they score against.

    /// An hour whose gravity-derived activity is ambulatory for at least this fraction of its records
    /// is EXERTION, not stress — masked, not scored. "Ambulatory" = a per-record activity intensity
    /// above `WorkoutDetector.motionThreshold` (0.20 L2-g, the codebase's calibrated walk floor: desk
    /// ≈ 0.05–0.10 g, walking ≈ 0.2–0.4 g). 0.30 means "at least 30 % of the hour was walking or
    /// moving"; below it, a stray reach or one trip to the kitchen does not mask a desk hour. An
    /// hourly grain is coarse — this is the gate that later allows finer epochs, at which point the
    /// fraction can tighten. Range (0, 1].
    public static let activityMaskFraction: Double = 0.30
    /// Post-exercise shadow: HR stays elevated for a while AFTER exertion ends, so the single hour
    /// that immediately FOLLOWS a directly-ambulatory hour is ALSO masked WHILE its mean HR is still
    /// above the calm reference by this margin (bpm). A following hour whose HR has already returned
    /// to the calm reference is scored normally, so the shadow self-limits to genuine cardiac
    /// recovery. Deliberately ONE hour deep (keyed on the directly-active hour, not chained through
    /// prior shadows) so a genuinely tense afternoon that happens to follow a workout is not masked
    /// away. Range ≥ 0.
    public static let postActivityShadowBPM: Double = 8.0

    /// VALIDATED (26-day Oura-reference correlation, HR-only): a personal daytime-HR elevation
    /// of ~15 bpm over a POOLED/ROLLING baseline — the 10th-percentile daytime HR pooled across
    /// days, ~65 bpm in the reference set — is where elevated HR starts reading as
    /// Oura-comparable "high" stress (r≈0.6 against Oura's own stress signal). A PER-DAY
    /// (day-relative) baseline scored WORSE in the same comparison (r 0.43–0.53): an all-day
    /// elevated day pulls its own floor up and masks the stress, which is exactly why
    /// `.baselineRelative` leans on `Baselines`' cross-day rolling EWMA instead of a day-local
    /// reference. TUNING SEAM: this is HR-only; HR+HRV (WHOOP-era, RMSSD included) is expected
    /// to beat this r≈0.6 ceiling — re-validate this margin once that comparison exists. See
    /// `marginToSigma` for how it's translated onto the shared 0–3 squash curve.
    public static let baselineRelativeHighMarginBPM: Double = 15.0

    /// Gate for whether the personal daytime-RMSSD baseline feeds the live 0–3 score. `false`:
    /// `.baselineRelative` scores HR-only, exactly the channel the r≈0.6 margin above was validated
    /// on. The RMSSD half of the pipeline — `dayDaytimeAggregate`, `foldDaytimeBaselines`, the
    /// `daytime_rmssd` config, and `rawScore`'s HRV term — is built and unit-tested, but stays OUT
    /// of the live score until it has its OWN Oura-reference validation pass.
    ///
    /// WHY OFF (validated against real WHOOP data, 2026-07): daytime RMSSD off the wrist is
    /// artifact-dominated — hourly values swing ~40→430 ms as posture / motion / talking break the
    /// R-R stream, an order of magnitude noisier than the overnight recumbent HRV the nightly
    /// baselines use. `rawScore` sums the HRV z EQUAL-WEIGHT with the HR z, so an artifact hour can
    /// swing the combined score by ±3 (the full band) on noise alone. Enabling it before it is shown
    /// to IMPROVE the correlation risks pushing the combined score BELOW the HR-only r≈0.6 ceiling —
    /// the exact regression `baselineRelativeHighMarginBPM`'s comment warns against. Flip to `true`
    /// only once daytime HR+RMSSD is validated to beat HR-only on an Oura-style stress reference.
    public static let daytimeRMSSDScoringEnabled: Bool = false

    // MARK: - Scoring mode

    /// WHERE each hour's "calm" reference point + spread come from. Every other step —
    /// bucketing, the waking-hour filter, the squash curve, sustained-high, high-stress-minutes
    /// — is identical between modes; only the reference differs.
    ///
    /// Relationship to the rest of the Stress screen (StressView.swift): the DAILY 0–3 score
    /// (`StressModel`) already compares last night's NIGHTLY resting-HR/HRV to a plain trailing
    /// 30-day mean/SD, computed locally in StressView (not via `Baselines`) — that's a
    /// once-a-day number from SLEEP vitals. The Advanced HRV card (`StressIndex`,
    /// `HRVFreqDomain`) is a today-only descriptive lens with no baseline at all. `.baselineRelative`
    /// is neither: it's an HOURLY breakdown of TODAY from DAYTIME/waking-hours HR+RMSSD against a
    /// PERSONAL cross-day rolling baseline. Daytime HR runs warmer than nocturnal resting HR
    /// (posture, thermic effect), so it needs its OWN baseline (`daytime_hr`/`daytime_rmssd`,
    /// below) rather than reusing the nightly `resting_hr`/`hrv` configs — reusing the nightly
    /// ones would systematically over-read stress. The three surfaces are complementary lenses
    /// on the same underlying autonomic signal, not competing implementations of one baseline.
    public enum ScoringMode: Equatable, Sendable {
        /// DEFAULT — unchanged from before this mode existed. Each hour is z-scored against
        /// THIS DAY's own calm-hour reference (`calmReference`): the lower quartile of the
        /// day's own waking-hour mean HR, the upper quartile of its own waking-hour RMSSD. No
        /// personal history needed — the day is its own baseline. Byte-identical output to the
        /// pre-existing single-mode `analyze` for the same hr/rr/tzOffsetSeconds.
        case dayRelative

        /// Oura-style — each hour is z-scored against the PERSONAL rolling baseline for daytime
        /// HR (and, when available, daytime RMSSD): the SAME Winsorized-EWMA machinery
        /// (`Baselines.update` / `Baselines.foldHistory`) that backs the nightly HRV /
        /// resting-HR baselines elsewhere in the app, using `Baselines.metricCfg["daytime_hr"]`
        /// / `["daytime_rmssd"]` (see `Baselines.daytimeHRCfg` / `daytimeRMSSDCfg`). A caller
        /// builds `hr` (and, when it has the history, `rmssd`) by folding this person's past
        /// daytime aggregates — VALIDATED as each day's 10th-percentile daytime HR (a pooled
        /// "how low does my HR run when I'm calm and awake" floor), the same way the nightly
        /// baselines are folded from past nights.
        ///
        /// The HR reference point is `hr.baseline`, but the HIGH-band threshold does NOT scale
        /// with this person's own day-to-day `hr.spread` — see `baselineRelativeHighMarginBPM`:
        /// the validated model is a roughly FIXED bpm margin over the personal floor, not a
        /// variability-scaled one. `hr.spread` still rides along on the passed-in state for
        /// other consumers; this mode simply doesn't read it for the HR term.
        ///
        /// `rmssd` is `nil` when no personal RMSSD baseline exists yet — e.g. an imported,
        /// Oura-era day with no R-R stream, so there is no history to fold one from. The
        /// stressor then honestly falls back to HR-only scoring for the whole read and flags
        /// `Result.hrOnlyFallback`; this mirrors the per-hour graceful-nil already in
        /// `rawScore`, just at the whole-baseline grain instead of the single-hour grain. The
        /// RMSSD term (when present) DOES still scale by `rmssd.spread` via `Baselines.sigma` —
        /// only the HR term has a validated fixed-margin figure so far.
        case baselineRelative(hr: BaselineState, rmssd: BaselineState?)
    }

    // MARK: - Output

    /// One hour of the daytime timeline. `level` is the shared 0–3 stress proxy, or nil
    /// when the hour had too little signal to score honestly.
    public struct HourPoint: Equatable, Sendable {
        /// Hour-of-day on the LOCAL clock (0–23), the bucket this point covers.
        public let hour: Int
        /// Unix seconds at the start of the bucket (wall-clock).
        public let startTs: Int
        /// Shared 0–3 stress proxy for the hour, or nil when `.noData`.
        public let level: Double?
        /// Mean HR over the hour (bpm), or nil.
        public let meanHR: Double?
        /// RMSSD over the hour's clean R-R (ms), or nil (too few clean beats).
        public let rmssd: Double?
        /// True when this hour was left unscored because it was AMBULATORY (exertion), not because it
        /// lacked HR — so `level == nil` here means "masked as activity", not "no data". Lets the UI
        /// separate "you were moving" from "no reading" and keeps active hours out of the calm
        /// reference and the coverage totals. See the motion-gate constants above.
        public let maskedForActivity: Bool

        /// True when the hour was scored (had enough HR to place on the curve).
        public var hasData: Bool { level != nil }

        public init(hour: Int, startTs: Int, level: Double?, meanHR: Double?, rmssd: Double?,
                    maskedForActivity: Bool = false) {
            self.hour = hour
            self.startTs = startTs
            self.level = level
            self.meanHR = meanHR
            self.rmssd = rmssd
            self.maskedForActivity = maskedForActivity
        }
    }

    /// The full daytime read: the hourly timeline plus the sustained-high summary.
    public struct Result: Equatable, Sendable {
        /// Waking-hour timeline, earliest → latest. Hours with no signal carry `level == nil`.
        public let hours: [HourPoint]
        /// True when the most recent `sustainedHours` SCORED hours all sit in the HIGH band.
        public let sustainedHigh: Bool
        /// Count of trailing high hours backing `sustainedHigh` (0 when not sustained).
        public let sustainedRun: Int
        /// Mean stress across the SCORED hours, or nil when none were scorable.
        public let dayMean: Double?
        /// Peak scored hour (highest `level`), or nil.
        public let peak: HourPoint?
        /// Count of waking hours left unscored because they were AMBULATORY (the motion gate fired),
        /// i.e. `hours.filter { $0.maskedForActivity }.count`. Lets a caller report honest coverage
        /// ("N hours excluded — you were moving") instead of a silently short timeline. 0 when no
        /// gravity was supplied or nothing was masked; 0 for `.empty`.
        public let activityMaskedHours: Int
        /// ADDITIVE — total minutes across SCORED waking hours at/above `highBandFloor`, the
        /// Oura-comparable "time in high stress" figure. Each scored hour is one `bucketSeconds`
        /// bucket, so this is `(# high-band scored hours) * bucketSeconds / 60`. Compare against
        /// Oura's `stress_high_s / 60` — NOOP's timeline is hourly-grain vs Oura's ~5-minute
        /// grain, so treat this as a coarse approximation, not a precise match. 0 for `.empty`
        /// and for any day with no scored hours.
        public let highStressMinutes: Int
        /// ADDITIVE — true when `.baselineRelative` mode was requested but had no personal RMSSD
        /// baseline to score against (e.g. an imported Oura-era day with no R-R history), so the
        /// whole read honestly fell back to HR-only scoring. Always false in `.dayRelative` mode
        /// (there, a missing RMSSD is already handled per-hour by `rawScore`, not flagged
        /// day-wide) and false for `.empty`.
        public let hrOnlyFallback: Bool

        public init(hours: [HourPoint], sustainedHigh: Bool, sustainedRun: Int,
                    dayMean: Double?, peak: HourPoint?, activityMaskedHours: Int = 0,
                    highStressMinutes: Int = 0, hrOnlyFallback: Bool = false) {
            self.hours = hours
            self.sustainedHigh = sustainedHigh
            self.sustainedRun = sustainedRun
            self.dayMean = dayMean
            self.peak = peak
            self.activityMaskedHours = activityMaskedHours
            self.highStressMinutes = highStressMinutes
            self.hrOnlyFallback = hrOnlyFallback
        }

        /// The scored hours only (level non-nil), in time order.
        public var scored: [HourPoint] { hours.filter { $0.level != nil } }

        /// Empty read — used when the day had no usable intraday HR at all.
        public static let empty = Result(hours: [], sustainedHigh: false, sustainedRun: 0,
                                         dayMean: nil, peak: nil, activityMaskedHours: 0,
                                         highStressMinutes: 0, hrOnlyFallback: false)
    }

    // MARK: - Shared stress math (identical formula to the daily StressModel)

    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread. (Matches StressMath.std.)
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. HR-up and HRV-down both push it positive — the SAME
    /// directionality as the daily score (RHR up = stress, HRV down = stress).
    static func rawScore(hr: Double?, meanHR: Double?, sdHR: Double,
                         rmssd: Double?, meanRMSSD: Double?, sdRMSSD: Double) -> Double {
        var sum = 0.0
        if let h = hr, let m = meanHR, sdHR > 0.0001 {
            sum += (h - m) / sdHR              // HR up = stress
        }
        if let r = rmssd, let m = meanRMSSD, sdRMSSD > 0.0001 {
            sum += (m - r) / sdRMSSD           // HRV (RMSSD) down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). Identical to
    /// StressMath.squash, so an hourly point shares the daily score's scale and bands.
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    /// Solve for the z-score spread `sd` such that a raw elevation of exactly `marginBPM` (or any
    /// unit — this is unit-agnostic) squashes to exactly `band` on the shared 0–3 curve:
    /// `band = 3 / (1 + e^(−marginBPM/sd))`. Used to translate `baselineRelativeHighMarginBPM`'s
    /// validated bpm figure into the `sd` the shared `squash` curve expects, so "baseline +
    /// margin" lands exactly on `band` by construction rather than by a second, separate
    /// threshold check. Defensive fallback (never divides by zero/negative-log) if `band` is
    /// ever configured at or outside the curve's open range (0, 3).
    static func marginToSigma(marginBPM: Double, atBand band: Double) -> Double {
        let ratio = 3.0 / band - 1.0
        guard ratio > 0, marginBPM > 0 else { return max(marginBPM, 1e-9) }
        return marginBPM / (-log(ratio))
    }

    // MARK: - Public API

    /// Build the daytime stress timeline from a day's banked HR + R-R.
    ///
    /// - Parameters:
    ///   - hr: the day's `[HRSample]` (any order; bucketed by ts here).
    ///   - rr: the day's `[RRInterval]`.
    ///   - gravity: the day's `[GravitySample]` (wrist accelerometer), for the motion gate. Defaults
    ///     empty: with no gravity NOTHING is masked and the read is byte-identical to before. When
    ///     present, ambulatory hours are masked out of the score (see the motion-gate constants).
    ///   - tzOffsetSeconds: seconds east of UTC, for placing each bucket on the LOCAL
    ///     clock (so "waking hours" and the hour labels are local). Defaults to UTC.
    ///   - mode: `.dayRelative` (DEFAULT — unchanged existing behaviour) or
    ///     `.baselineRelative` (Oura-style, vs a personal rolling baseline). ADDITIVE and
    ///     opt-in: existing callers that don't pass `mode` keep the exact prior behaviour.
    ///
    /// Returns `.empty` when there isn't a single hour with enough HR to score.
    public static func analyze(hr: [HRSample], rr: [RRInterval],
                               gravity: [GravitySample] = [],
                               tzOffsetSeconds: Int = 0,
                               mode: ScoringMode = .dayRelative) -> Result {
        // v7.0.2 perf (#707): buckets the day's full HR + R-R streams into per-hour aggregates and runs an
        // RMSSD per hour — invoked from the Stress view, so a `body` re-evaluation re-buckets the whole day.
        // Memoize on the streams' fingerprint + tz offset + scoring mode; result is a small `Result`, raw
        // arrays not held. The mode key folds in only (baseline, spread) for baseline-relative — the two
        // fields that can change the score — not the whole BaselineState (nValid/status/etc. never do).
        let modeKey: ModeKey
        switch mode {
        case .dayRelative:
            modeKey = .dayRelative
        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            modeKey = .baselineRelative(hrBaseline: hrBaseline.baseline, hrSpread: hrBaseline.spread,
                                        rmssdBaseline: rmssdBaseline?.baseline, rmssdSpread: rmssdBaseline?.spread)
        }
        let key = StressKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            // Fold all three axes into one quant so two different gravity streams cannot share a key
            // (same hr/rr with different motion must NOT reuse a cached result).
            gravity: StreamFingerprint.of(gravity, ts: { $0.ts }, quant: {
                Int(($0.x * 128).rounded()) &+ Int(($0.y * 128).rounded()) &* 257
                    &+ Int(($0.z * 128).rounded()) &* 66_049
            }),
            tz: tzOffsetSeconds, mode: modeKey)
        return analyzeCache.value(key) {
            analyzeUncached(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tzOffsetSeconds, mode: mode)
        }
    }

    private struct StressKey: Hashable {
        let hr: StreamFingerprint; let rr: StreamFingerprint; let gravity: StreamFingerprint
        let tz: Int; let mode: ModeKey
    }

    /// Hashable fingerprint of `ScoringMode` for the memo cache — `BaselineState` itself isn't
    /// `Hashable`, and only its `baseline`/`spread` can change the score, so those are what get
    /// folded in (see the `analyze` doc above).
    private enum ModeKey: Hashable {
        case dayRelative
        case baselineRelative(hrBaseline: Double, hrSpread: Double, rmssdBaseline: Double?, rmssdSpread: Double?)
    }

    private static let analyzeCache = AnalyticsMemoCache<StressKey, Result>(capacity: 8)

    private static func analyzeUncached(hr: [HRSample], rr: [RRInterval],
                                        gravity: [GravitySample],
                                        tzOffsetSeconds: Int, mode: ScoringMode) -> Result {
        guard !hr.isEmpty else { return .empty }

        // 1) Bucket HR + R-R into LOCAL hour-of-day buckets, keyed by the bucket start
        //    (floored to the hour on the local clock).
        var hrByBucket: [Int: [Double]] = [:]
        for s in hr {
            let local = s.ts + tzOffsetSeconds
            let bucket = floorDiv(local, bucketSeconds) * bucketSeconds
            hrByBucket[bucket, default: []].append(Double(s.bpm))
        }
        var rrByBucket: [Int: [Double]] = [:]
        for s in rr {
            let local = s.ts + tzOffsetSeconds
            let bucket = floorDiv(local, bucketSeconds) * bucketSeconds
            rrByBucket[bucket, default: []].append(Double(s.rrMs))
        }

        // 2) Per-hour mean HR + RMSSD (RMSSD via the shared HRV cleaner, so ectopic
        //    beats can't fabricate variability). An hour with < minHourHRSamples HR is
        //    left unscored (noData) — never invented.
        struct HourAgg { let bucket: Int; let meanHR: Double?; let rmssd: Double?; let nHR: Int }
        let orderedBuckets = hrByBucket.keys.sorted()
        var aggs: [HourAgg] = []
        aggs.reserveCapacity(orderedBuckets.count)
        for b in orderedBuckets {
            let hrs = hrByBucket[b] ?? []
            let mHR = hrs.count >= minHourHRSamples ? mean(hrs) : nil
            let rrRes = HRVAnalyzer.analyze(rawRR: rrByBucket[b] ?? [])
            aggs.append(HourAgg(bucket: b, meanHR: mHR, rmssd: rrRes.rmssd, nHR: hrs.count))
        }

        // 2b) Motion gate: bucket the day's gravity-derived activity by the SAME local hour and mark
        //     each hour AMBULATORY when at least `activityMaskFraction` of its records clear the
        //     calibrated walk floor (`WorkoutDetector.motionThreshold`) — reusing the exact activity
        //     series `SedentaryDetector` / `WorkoutDetector` already trust. Empty gravity → no active
        //     buckets → nothing masked below (byte-identical to the pre-motion behaviour).
        var activeFracByBucket: [Int: Double] = [:]
        if !gravity.isEmpty {
            var counts: [Int: (active: Int, total: Int)] = [:]
            for p in WorkoutDetector.activitySeries(gravity) {
                let local = p.ts + tzOffsetSeconds
                let bucket = floorDiv(local, bucketSeconds) * bucketSeconds
                var e = counts[bucket] ?? (0, 0)
                e.total += 1
                if p.intensity > WorkoutDetector.motionThreshold { e.active += 1 }
                counts[bucket] = e
            }
            for (b, e) in counts where e.total > 0 {
                activeFracByBucket[b] = Double(e.active) / Double(e.total)
            }
        }
        func isAmbulatory(_ bucket: Int) -> Bool {
            (activeFracByBucket[bucket] ?? 0) >= activityMaskFraction
        }

        // 3) The reference point + spread for each signal — WHERE they come from depends on
        //    `mode`. Every other step (bucketing above incl. the motion gate, the waking-hour
        //    filter, the squash curve, sustained-high, high-stress-minutes below) is identical
        //    between modes; only the reference differs.
        let refHR: Double?
        let sdHR: Double
        let refRMSSD: Double?
        let sdRMSSD: Double
        let hrOnlyFallback: Bool
        switch mode {
        case .dayRelative:
            // The day's OWN quiet reference: centre on the CALM end (the lower quartile of
            // hourly mean HR, the upper quartile of hourly RMSSD), and spread from the
            // across-hour SD. This makes a flat day read ~baseline and a spiky day surface
            // its tense hours — without any cross-day history. Falls back to the plain mean
            // when there are too few scored hours for a quartile.
            //
            // Built from the WAKING hours only — the same hours scored in step 4. Sleep is the
            // calmest, lowest-HR / highest-HRV stretch of the day, and the analysis window
            // always begins at local midnight, so the current day routinely carries several
            // hours of it. Letting those night hours into the reference drags the "calm" anchor
            // far beneath every waking hour, inflating an ordinary calm day toward HIGH and
            // falsely tripping the sustained-high Breathe nudge.
            // Ambulatory hours are excluded from the day's OWN calm reference too (the motion
            // gate): an exertion hour's elevated HR / suppressed HRV must not pull the calm
            // anchor up or inflate the across-hour spread the z-scores divide by.
            let referenceAggs = aggs.filter { isWakingHour($0.bucket) && !isAmbulatory($0.bucket) }
            let hrMeans = referenceAggs.compactMap { $0.meanHR }
            let rmssdVals = referenceAggs.compactMap { $0.rmssd }
            refHR = calmReference(hrMeans, calmIsLow: true)         // calm HR is LOW
            refRMSSD = calmReference(rmssdVals, calmIsLow: false)   // calm HRV is HIGH
            sdHR = std(hrMeans, mean: mean(hrMeans))
            sdRMSSD = std(rmssdVals, mean: mean(rmssdVals))
            hrOnlyFallback = false

        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            // The PERSONAL cross-day baseline, folded by the caller from past daytime
            // aggregates via `Baselines.update`/`foldHistory` (see the `ScoringMode` doc).
            // Ambulatory hours are still masked out of the SCORE in step 4 (the motion gate),
            // but the reference itself is external, so it needs no ambulatory exclusion here.
            refHR = hrBaseline.baseline
            // VALIDATED tuning, not `Baselines.sigma(hrBaseline)`: the correlation study behind
            // `baselineRelativeHighMarginBPM` found a roughly FIXED bpm margin over the personal
            // floor — not one scaled by this person's own day-to-day spread — best matched
            // Oura's stress signal. `marginToSigma` solves for the sd that makes exactly
            // `refHR + baselineRelativeHighMarginBPM` land on `highBandFloor` on the shared
            // squash curve, so the validated margin IS the "high" cutoff by construction.
            sdHR = Self.marginToSigma(marginBPM: baselineRelativeHighMarginBPM, atBand: highBandFloor)
            if let rmssdBaseline {
                refRMSSD = rmssdBaseline.baseline
                // No independently validated RMSSD margin yet (see the constant's doc) — this
                // term still scales by the person's own spread via the shared σ conversion.
                sdRMSSD = Baselines.sigma(rmssdBaseline)
                hrOnlyFallback = false
            } else {
                // No personal RMSSD baseline exists (e.g. an Oura-era day with no R-R history to
                // fold one from). `rawScore` already treats a nil meanRMSSD as "skip this term",
                // so passing nil here gracefully degrades to HR-only scoring — flagged honestly
                // in the output rather than silently.
                refRMSSD = nil
                sdRMSSD = 0
                hrOnlyFallback = true
            }
        }

        // 4) Score each waking-hour bucket on the shared 0–3 curve.
        var points: [HourPoint] = []
        points.reserveCapacity(aggs.count)
        for a in aggs {
            guard isWakingHour(a.bucket) else { continue }
            let hourOfDay = floorDiv(a.bucket, bucketSeconds) % 24
            // The wall-clock bucket start (undo the local shift applied above).
            let wallStart = a.bucket - tzOffsetSeconds
            // Motion gate: an AMBULATORY hour — or the post-exercise shadow hour whose HR has not yet
            // recovered to the calm reference — is EXERTION, so its elevated HR is masked out of the
            // score instead of read as stress. The shadow is gated on `refHR` so it self-limits to
            // genuine cardiac recovery (a following hour already back at baseline scores normally).
            // Only meaningful when the hour actually HAD a reading to withhold — a no-HR hour is plain
            // `.noData`, not "masked".
            let shadow = isAmbulatory(a.bucket - bucketSeconds)
                && a.meanHR != nil && refHR != nil && a.meanHR! > refHR! + postActivityShadowBPM
            let masked = a.meanHR != nil && (isAmbulatory(a.bucket) || shadow)
            // Score only when at least one signal is present AND HR cleared the count gate AND the
            // hour was not motion-masked (HR is the always-available anchor; RMSSD enriches it).
            let level: Double? = (a.meanHR != nil && !masked)
                ? squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: sdHR,
                                  rmssd: a.rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD))
                : nil
            points.append(HourPoint(hour: hourOfDay, startTs: wallStart,
                                    level: level, meanHR: a.meanHR, rmssd: a.rmssd,
                                    maskedForActivity: masked))
        }
        let activityMaskedHours = points.reduce(0) { $0 + ($1.maskedForActivity ? 1 : 0) }

        let scored = points.compactMap { p -> (HourPoint, Double)? in p.level.map { (p, $0) } }
        guard !scored.isEmpty else {
            // No scorable waking hour — still return the (unscored) timeline so the UI can
            // show "not enough data" rather than nothing. `hrOnlyFallback` is a MODE property
            // (whether a personal RMSSD baseline existed to score against), so it's still worth
            // reporting even though nothing ended up scored.
            return points.isEmpty ? .empty
                : Result(hours: points, sustainedHigh: false, sustainedRun: 0,
                         dayMean: nil, peak: nil, activityMaskedHours: activityMaskedHours,
                         highStressMinutes: 0, hrOnlyFallback: hrOnlyFallback)
        }

        // 5) Sustained-high flag: walk back from the latest SCORED hour while each is HIGH.
        var run = 0
        for (_, lvl) in scored.reversed() {
            if lvl >= highBandFloor { run += 1 } else { break }
        }
        let sustained = run >= sustainedHours

        let dayMean = mean(scored.map { $0.1 })
        let peak = scored.max { $0.1 < $1.1 }?.0

        // 6) Oura-comparable "time in high stress": each scored hour at/above `highBandFloor`
        //    is one full `bucketSeconds` bucket, converted to minutes. Uses the SAME threshold
        //    `StressBand.high` (StressView) and the sustained-high check above already use, so
        //    all three stay in lockstep by construction.
        let highStressMinutes = scored.filter { $0.1 >= highBandFloor }.count * (bucketSeconds / 60)

        return Result(hours: points, sustainedHigh: sustained, sustainedRun: run,
                      dayMean: dayMean, peak: peak, activityMaskedHours: activityMaskedHours,
                      highStressMinutes: highStressMinutes, hrOnlyFallback: hrOnlyFallback)
    }

    // MARK: - Helpers

    /// Floor-division that is correct for negative numerators (so a local time just before
    /// the UTC epoch still buckets to the hour below, not toward zero).
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// Whether a local hour-bucket start falls inside the waking window the timeline scores
    /// (06:00–22:00). The single source of truth for "waking" — used both to build the calm
    /// reference and to pick the hours to score, so the two can never drift apart.
    static func isWakingHour(_ bucket: Int) -> Bool {
        let hourOfDay = floorDiv(bucket, bucketSeconds) % 24
        return hourOfDay >= wakingStartHour && hourOfDay < wakingEndHour
    }

    /// The day's "calm" reference for a signal: the quartile toward the calm end (lower
    /// quartile when calm is LOW, e.g. HR; upper quartile when calm is HIGH, e.g. RMSSD).
    /// Falls back to the plain mean below 4 values, and to nil when empty.
    static func calmReference(_ xs: [Double], calmIsLow: Bool) -> Double? {
        guard !xs.isEmpty else { return nil }
        guard xs.count >= 4 else { return mean(xs) }
        let s = xs.sorted()
        return calmIsLow ? quantile(s, 0.25) : quantile(s, 0.75)
    }

    /// Linear-interpolated quantile of an already-sorted, non-empty array.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }   // defensive: callers guard emptiness; never trap on []
        if n == 1 { return sorted[0] }
        let pos = q * Double(n - 1)
        let lo = Int(pos), hi = min(lo + 1, n - 1)
        let frac = pos - Double(lo)
        return sorted[lo] + frac * (sorted[hi] - sorted[lo])
    }
}
