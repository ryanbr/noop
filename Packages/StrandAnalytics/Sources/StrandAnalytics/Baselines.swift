import Foundation

// Baselines.swift — personal rolling baselines per nightly metric.
//
// Ported from server/ingest/app/analysis/baselines.py.
//
// Two paths are provided:
//   1. Winsorized EWMA (the production model): robust, recency-weighted center
//      with an EWMA-of-absolute-deviation spread tracker, cold-start gating, hard
//      outlier rejection, and Winsor clamping. This is `update`/`foldHistory`.
//   2. Trailing-window mean/SD (the task's "trailing 30-day mean/SD"): a simple,
//      auditable rolling mean and sample SD over the trailing N valid nights.
//      This is `rollingMeanSD`. Useful for explainability and cross-checking.
//
// Both produce a `BaselineState` so RecoveryScorer can consume either uniformly.

/// Per-metric configuration for the baseline model.
public struct MetricCfg: Equatable, Sendable {
    public let minVal: Double       // physiological lower bound (hard reject below)
    public let maxVal: Double       // physiological upper bound (hard reject above)
    public let floorSpread: Double  // σ_floor: minimum dispersion
    public let halfLifeB: Double    // baseline-center half-life (nights)
    public let halfLifeS: Double    // spread half-life (nights, slower than center)

    public init(minVal: Double, maxVal: Double, floorSpread: Double,
                halfLifeB: Double, halfLifeS: Double) {
        self.minVal = minVal
        self.maxVal = maxVal
        self.floorSpread = floorSpread
        self.halfLifeB = halfLifeB
        self.halfLifeS = halfLifeS
    }
}

/// Baseline status flags (cold-start → trusted → stale).
public enum BaselineStatus: String, Equatable, Sendable {
    case calibrating  // fewer than MIN_NIGHTS_SEED valid nights; no score yet
    case provisional  // between seed and trust thresholds; usable, higher uncertainty
    case trusted      // at least MIN_NIGHTS_TRUST valid nights
    case stale        // usable but no update for > STALE_DAYS nights
}

/// Immutable snapshot of a personal baseline for one metric after N nights.
public struct BaselineState: Equatable, Sendable {
    /// Robust EWMA center (the personal "mean").
    public let baseline: Double
    /// EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253
    /// to approximate Gaussian σ.
    public let spread: Double
    /// Count of valid nights contributing to the state.
    public let nValid: Int
    /// Consecutive nights with no valid value (staleness tracking).
    public let nightsSinceUpdate: Int
    /// Cold-start / staleness status.
    public let status: BaselineStatus

    public init(baseline: Double, spread: Double, nValid: Int,
                nightsSinceUpdate: Int, status: BaselineStatus) {
        self.baseline = baseline
        self.spread = spread
        self.nValid = nValid
        self.nightsSinceUpdate = nightsSinceUpdate
        self.status = status
    }

    /// True iff fully trusted (not calibrating or stale).
    public var trusted: Bool { status == .trusted }
    /// True iff at least provisionally usable (nValid ≥ MIN_NIGHTS_SEED).
    public var usable: Bool { status == .provisional || status == .trusted }
}

/// Three forms of deviation from a personal baseline.
public struct Deviation: Equatable, Sendable {
    /// Robust z-score: (value − baseline) / (1.253 × spread).
    public let z: Double
    /// Signed physical-units delta: value − baseline.
    public let delta: Double
    /// Fractional deviation: value / baseline − 1.
    public let ratio: Double
    /// True iff |z| ≤ 1.0.
    public let inNormalRange: Bool

    public init(z: Double, delta: Double, ratio: Double, inNormalRange: Bool) {
        self.z = z; self.delta = delta; self.ratio = ratio
        self.inNormalRange = inNormalRange
    }
}

public enum Baselines {

    // MARK: - Constants (baselines.py)

    /// Winsorization clamp: fold only within ±WINSOR_K × spread.
    public static let winsorK: Double = 3.0
    /// Hard-reject gate: drop the night if > HARD_OUTLIER_K × spread away.
    public static let hardOutlierK: Double = 5.0
    /// Minimum valid nights before "provisionally" trusted.
    public static let minNightsSeed: Int = 4
    /// Minimum valid nights before fully trusted.
    public static let minNightsTrust: Int = 14
    /// Missing-night count after which a baseline is marked stale.
    public static let staleDays: Int = 14
    /// How many days a nightly VITAL may be carried forward and still be presented as the "latest"
    /// reading. A carry exists so one missed night doesn't blank a tile — not so a months-old value
    /// reads as tonight's measurement. Past this age the tile must show "—": a silent stale number is
    /// worse than no number, because the reader takes it for a current measurement (which is exactly
    /// what a 14-day-old imported respiratory rate did, surfacing as "Respiratory 15.6" on the Sleep
    /// tab's Night detail with no date beside it). A week comfortably covers a missed night or a
    /// weekend off-strap while staying decisively short of `staleDays`, past which the personal
    /// baseline that judges the value is itself stale. Byte-twin of the Android `vitalCarryDays`.
    public static let vitalCarryDays: Int = 7

    /// The freshest `(day, value)` pair that is still fresh enough to present as "latest", or nil when
    /// the newest one is older than `vitalCarryDays` relative to `todayKey`. Both keys are `yyyy-MM-dd`,
    /// which compares chronologically as a string, so no calendar math (or time zone) is involved —
    /// `points` need only be sorted oldest→newest. Shared by every "latest vital" resolver so the Sleep
    /// tab's Night detail, the Health tab's Vital Signs and the Android twin cannot disagree about when
    /// a carried value has gone stale.
    public static func freshestCarried<T>(_ points: [(day: String, value: T)],
                                          todayKey: String,
                                          carryDays: Int = vitalCarryDays) -> (day: String, value: T)? {
        guard let newest = points.last else { return nil }
        return newest.day >= cutoffKey(todayKey: todayKey, carryDays: carryDays) ? newest : nil
    }

    /// The oldest `yyyy-MM-dd` a carried vital may bear: `todayKey − carryDays` days. The parse, the
    /// calendar and the format all pin UTC, so the arithmetic is pure key math and never shifts a day
    /// under a local time zone or a DST edge. An unparseable key yields `todayKey`, which admits only
    /// today — fail closed, never carry.
    public static func cutoffKey(todayKey: String, carryDays: Int = vitalCarryDays) -> String {
        guard let today = dayKeyFormatter.date(from: todayKey),
              let cutoff = utcCalendar.date(byAdding: .day, value: -carryDays, to: today)
        else { return todayKey }
        return dayKeyFormatter.string(from: cutoff)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Early-life anti-anchoring (Reddit HRV report)
    //
    // The original model seeds the center on the first valid night with spread pinned at the
    // floor, then becomes "usable" at minNightsSeed. If those first few nights read artificially
    // HIGH (a common cold-start artefact), three things compounded to lock the baseline high for
    // ~2-3 weeks: (a) the seed fixed the mean high while spread sat at the floor; (b) the hard
    // outlier gate then REJECTED the user's genuine LOWER nights (a true 54ms vs an anchored ~85ms
    // baseline is >5× the floor spread → "seen but not folded"); (c) the still-tight spread made
    // the z-score hypersensitive, crushing Charge to 1-2.
    //
    // The fix is conservative and principled: during the baseline's EARLY life let reality pull
    // the center down quickly, THEN settle to the normal long-term smoothing.
    //   - Skip the hard-outlier rejection while the baseline is young (nValid below the threshold)
    //     OR while spread is still at the floor — so legitimate lower nights are never discarded
    //     before the spread has had a chance to widen to reflect them.
    //   - Use a faster effective center half-life for the first few nights so it tracks reality in
    //     days, not weeks, before relaxing back to halfLifeB.
    //   - Widen the effective spread used for Winsor clamping during early life so an honest lower
    //     night isn't clamped flat against a floor-tight band.
    // Long-term behaviour (after earlyAdaptNights, once spread has lifted) is byte-identical to
    // before, so the baseline stays smooth and non-jittery once it has settled.

    /// Valid-night count below which the baseline is treated as "young": fast center adaptation
    /// and a suspended hard-outlier gate. Chosen so convergence happens in days, not weeks.
    public static let earlyAdaptNights: Int = 8
    /// Center half-life (nights) used while the baseline is young — much faster than halfLifeB so a
    /// high seed is pulled toward reality within days.
    public static let earlyHalfLifeB: Double = 3.0
    /// Multiplier on spread for the Winsor clamp while young, so an honest lower night isn't clamped
    /// flat against a floor-tight band before the spread has had a chance to widen.
    public static let earlySpreadInflate: Double = 2.5

    /// UserDefaults key for the manual HRV-baseline recalibration epoch (epoch SECONDS).
    /// 0 / absent = no recalibration. Written by the Settings "Recalibrate HRV baseline" button.
    public static let hrvBaselineEpochKey: String = "noop.hrvBaselineEpoch"

    /// UserDefaults key for the manual RECOVERY-baseline recalibration epoch (epoch SECONDS).
    /// 0 / absent = no recalibration. This is the Charge-wide sibling of `hrvBaselineEpochKey`: HRV is
    /// the dominant Charge driver and re-anchors on its own epoch today, while the resting-HR /
    /// respiration / skin-temp baselines that also feed Charge re-anchor on THIS epoch. The Settings
    /// "Recalibrate Charge baseline" button writes BOTH keys to now (see `recalibrateRecoveryBaselines`)
    /// so the whole Charge build-up restarts cleanly. Same string on iOS UserDefaults + Android prefs.
    public static let recoveryBaselineEpochKey: String = "noop.recoveryBaselineEpoch"

    /// Default per-metric configurations (HRV, resting HR, respiration, skin temp, daily
    /// Effort/strain).
    ///
    /// "strain" backs the RecoveryScorer Activity-Balance / previous-day-Effort term: bounds
    /// match `StrainScorer.maxStrain`'s 0-100 output scale (the Charge/Effort/Rest redesign's
    /// rescale of the historical 0-21 axis). floorSpread is wider than the physiological
    /// metrics above (5.0 vs ~1-2% of range elsewhere) because day-to-day training load is
    /// EXPECTED to swing hard (a rest day vs a hard day is a normal, large delta) — a tight
    /// floor would make the z-score hypersensitive to routine training variation. Same
    /// half-lives as the other metrics for consistency.
    public static let metricCfg: [String: MetricCfg] = [
        "hrv": MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0,
                         halfLifeB: 14.0, halfLifeS: 21.0),
        "resting_hr": MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0,
                                halfLifeB: 14.0, halfLifeS: 21.0),
        "resp": MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5,
                          halfLifeB: 14.0, halfLifeS: 21.0),
        "skin_temp": MetricCfg(minVal: 20.0, maxVal: 42.0, floorSpread: 0.3,
                               halfLifeB: 14.0, halfLifeS: 21.0),
        "strain": MetricCfg(minVal: 0.0, maxVal: 100.0, floorSpread: 5.0,
                            halfLifeB: 14.0, halfLifeS: 21.0),
    ]

    /// Convenience accessors for the standard configs.
    public static var hrvCfg: MetricCfg { metricCfg["hrv"]! }
    public static var restingHRCfg: MetricCfg { metricCfg["resting_hr"]! }
    public static var respCfg: MetricCfg { metricCfg["resp"]! }
    /// Baseline config for the RecoveryScorer Activity-Balance / previous-day-Effort term.
    public static var strainCfg: MetricCfg { metricCfg["strain"]! }

    /// Convert a half-life in nights to an EWMA smoothing factor.
    static func lambda(halfLife: Double) -> Double {
        1.0 - pow(0.5, 1.0 / halfLife)
    }

    static func computeStatus(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && nValid >= minNightsSeed { return .stale }
        if nValid < minNightsSeed { return .calibrating }
        if nValid < minNightsTrust { return .provisional }
        return .trusted
    }

    /// #612: calendar days since the newest night that carried a usable HRV reading (the baseline's input),
    /// or nil when there is none / a key can't be parsed. This is DISTINCT from `calibrationNights` (which
    /// counts progress TOWARD a usable baseline) — it measures staleness, so a surface can say "no new nights
    /// from your strap for N days" when the baseline aged out silently instead of only "building your
    /// baseline". Pure and TZ-free (civil-day arithmetic); mirror EXACTLY in the Kotlin twin.
    /// `dayKeys`/`nightlyHrv` are parallel (same night per index); `today` is an ISO `yyyy-MM-dd` key.
    public static func nightsSinceNewestValidNight(dayKeys: [String], nightlyHrv: [Double?], today: String) -> Int? {
        var newest: String? = nil
        for i in 0..<Swift.min(dayKeys.count, nightlyHrv.count) where nightlyHrv[i] != nil {
            let k = dayKeys[i]
            if newest == nil || k > newest! { newest = k }
        }
        guard let n = newest, let a = isoEpochDay(n), let b = isoEpochDay(today) else { return nil }
        let d = b - a
        return d >= 0 ? d : nil
    }

    /// Days from civil epoch (proleptic Gregorian) for an ISO `yyyy-MM-dd`, or nil if unparseable. TZ-free
    /// (Howard Hinnant's algorithm), so Swift and Kotlin agree bit-for-bit on the day difference.
    static func isoEpochDay(_ iso: String) -> Int? {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), m >= 1, m <= 12 else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: - Winsorized EWMA update (production model)

    /// Incorporate one new nightly value into the baseline state.
    ///
    /// - `state == nil`: seed the first night.
    /// - `value == nil` or out-of-range: skip-and-hold (carry forward).
    /// - hard outlier (> HARD_OUTLIER_K × spread): seen but not folded.
    /// - otherwise: Winsorized EWMA center + EWMA-abs-dev spread update.
    public static func update(_ state: BaselineState?, value: Double?, cfg: MetricCfg) -> BaselineState {
        let lb = lambda(halfLife: cfg.halfLifeB)
        let ls = lambda(halfLife: cfg.halfLifeS)

        // First night ever.
        guard let state = state else {
            if let v = value, cfg.minVal <= v && v <= cfg.maxVal {
                return BaselineState(baseline: v, spread: cfg.floorSpread, nValid: 1,
                                     nightsSinceUpdate: 0, status: .calibrating)
            }
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 1, status: .calibrating)
        }

        // Missing night: skip-and-hold.
        guard let value = value else {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Step 0: sanity gate — physiologically implausible → skip-and-hold.
        if !(cfg.minVal <= value && value <= cfg.maxVal) {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Is the baseline still "young"? While young we adapt faster and suspend the hard-outlier
        // gate so genuine lower nights are never discarded before the spread reflects them. Tied to
        // the valid-night count (NOT spread): a long flat history is settled even though its spread
        // never lifted off the floor, and must still reject a wild one-off outlier.
        let isYoung = state.nValid < earlyAdaptNights

        // Hard outlier rejection (only once seeded AND no longer young): seen, but not folded.
        // Suspending this during early life is the core anti-anchoring fix — a high seed with a
        // floor-tight spread would otherwise reject the user's real, lower readings as "outliers"
        // (a true 54ms vs an anchored ~90ms baseline is >5× the floor spread).
        if state.nValid >= minNightsSeed && !isYoung {
            let dev = abs(value - state.baseline)
            if dev > hardOutlierK * state.spread {
                return BaselineState(baseline: state.baseline, spread: state.spread,
                                     nValid: state.nValid, nightsSinceUpdate: 0,
                                     status: computeStatus(nValid: state.nValid, nightsSinceUpdate: 0))
            }
        }

        // First real value after a None-placeholder seed: treat as clean first night.
        if state.nValid == 0 {
            return BaselineState(baseline: value, spread: cfg.floorSpread, nValid: 1,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }

        // Step 1: Winsorized EWMA update.
        // While young, widen the clamp band (inflate the effective spread) so an honest lower night
        // isn't clamped flat against a floor-tight band, and use the faster early center half-life so
        // the center tracks reality in days. Both relax to the normal values once settled.
        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effLb = isYoung ? lambda(halfLife: earlyHalfLifeB) : lb
        let lo = state.baseline - winsorK * effSpread
        let hi = state.baseline + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let newBaseline = effLb * clamped + (1.0 - effLb) * state.baseline

        // Spread uses the UNCLAMPED value so true deviations are tracked.
        let absDev = abs(value - newBaseline)
        let newSpread = max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread)
        let newN = state.nValid + 1

        return BaselineState(baseline: newBaseline, spread: newSpread, nValid: newN,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: newN, nightsSinceUpdate: 0))
    }

    /// Replay an ordered sequence of nightly values (oldest first) to build state.
    /// `nil` entries are treated as missing nights (skip-and-hold).
    public static func foldHistory(_ values: [Double?], cfg: MetricCfg) -> BaselineState {
        var state: BaselineState? = nil
        for v in values { state = update(state, value: v, cfg: cfg) }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    /// Read the persisted manual-recalibration epoch (epoch SECONDS) for the HRV baseline.
    /// 0 = no recalibration. The Settings "Recalibrate HRV baseline" button writes now-seconds here.
    public static func hrvBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: hrvBaselineEpochKey)
    }

    /// Read the persisted manual-recalibration epoch (epoch SECONDS) for the wider RECOVERY baseline
    /// (resting HR / respiration / skin temp). 0 = no recalibration. Written alongside the HRV epoch by
    /// `recalibrateRecoveryBaselines`. A fold that wants to honour this passes it through the day-keyed
    /// `foldHistory(_:dayKeys:cfg:baselineEpoch:)` overload exactly like the HRV path.
    public static func recoveryBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: recoveryBaselineEpochKey)
    }

    /// Recalibrate every baseline that feeds Charge: drop the anchor so the ~4-night build-up restarts
    /// from `now`. This is the single source of truth behind the Settings "Recalibrate Charge baseline"
    /// button on all platforms — it writes `now` (epoch SECONDS) to BOTH the HRV epoch and the recovery
    /// epoch, so HRV (the dominant driver, already wired) and the resting-HR / respiration / skin-temp
    /// baselines re-anchor together. It does NOT delete any stored day: only the day from which the
    /// baselines re-learn moves. After this the next baseline computation re-seeds from the first
    /// on-or-after-`now` night, so Today honestly shows the calibrating/building state again.
    /// - Parameters:
    ///   - now: the anchor instant (epoch SECONDS). Defaults to the current time.
    ///   - defaults: the store to write to (overridable for tests).
    public static func recalibrateRecoveryBaselines(now: Double = Date().timeIntervalSince1970,
                                                    defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: hrvBaselineEpochKey)
        defaults.set(now, forKey: recoveryBaselineEpochKey)
    }

    /// Replay an ordered sequence of nightly values (oldest first) to build state, honouring a
    /// manual recalibration `baselineEpoch` (epoch SECONDS; 0 = no recalibration).
    ///
    /// `dayKeys` runs parallel to `values` ("yyyy-MM-dd", same order/length). Any night whose day
    /// STARTS before `baselineEpoch` is ignored entirely (NOT a skip-and-hold — it is dropped, so the
    /// baseline re-seeds from the first on-or-after-epoch night). This lets the user reset a baseline
    /// that anchored too high: tap Recalibrate, and the Charge baseline re-learns from tonight onward.
    ///
    /// When `baselineEpoch <= 0` (the default / no recalibration) this is byte-identical to the plain
    /// `foldHistory(_:cfg:)`. When `baselineEpoch` is nil it is read from UserDefaults via
    /// `hrvBaselineEpoch()` so callers that already use the HRV config get recalibration for free.
    /// Diagnostic companion to the epoch-aware `foldHistory` (#731): how many nights that fold DROPS
    /// because they predate the recalibration epoch, plus the epoch itself as a `yyyy-MM-dd` day key
    /// (nil when no recalibration is set).
    ///
    /// Exists because a "Charge is stuck" report is otherwise unexplainable from a strap log. A user who
    /// taps "Recalibrate baseline" discards every earlier night and must re-earn `minNightsSeed` nights;
    /// tapping it again resets that progress to zero. A reporter did exactly that for two weeks — 15 valid
    /// HRV nights on file, but `nValid=3` and no Charge — and nothing in the log said the epoch was why.
    /// Mirrors the fold's drop rule EXACTLY (same UTC day-start parse, same strict `<` comparison), so the
    /// number reported is the number actually dropped.
    public static func epochDropDiagnostic(dayKeys: [String],
                                           baselineEpoch: Double? = nil) -> (dropped: Int, epochDay: String?) {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return (0, nil) }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let dropped = dayKeys.reduce(into: 0) { acc, key in
            if let d = fmt.date(from: key), d.timeIntervalSince1970 < epoch { acc += 1 }
        }
        return (dropped, fmt.string(from: Date(timeIntervalSince1970: epoch)))
    }

    public static func foldHistory(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                   baselineEpoch: Double? = nil) -> BaselineState {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return foldHistory(values, cfg: cfg) }

        // Pre-build the day-start epoch (UTC) for each "yyyy-MM-dd" key once.
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        var state: BaselineState? = nil
        for (i, v) in values.enumerated() {
            // Drop (not skip-and-hold) any night dated before the recalibration epoch.
            if i < dayKeys.count, let d = fmt.date(from: dayKeys[i]),
               d.timeIntervalSince1970 < epoch {
                continue
            }
            state = update(state, value: v, cfg: cfg)
        }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    // MARK: - Device-era boundary (#459)

    /// The recalibration epoch (seconds, UTC start-of-day) at the LATEST device-era boundary in a
    /// source-tagged nightly history, for feeding `foldHistory`'s `baselineEpoch` so a baseline can't
    /// mix two brands' incompatible HRV scales (#459: an Oura→WHOOP switch has Oura RMSSD ~120–155 ms
    /// vs WHOOP ~72–112 ms with no overlap nights, so a straddling 30-night window reads the first
    /// WHOOP nights as "suppressed" against an Oura-inflated mean — a device artifact, not physiology).
    ///
    /// CONTRACT: `sourceDays` is exactly ONE `(dayKey "yyyy-MM-dd", sourceId)` per night — the day's
    /// WINNING source (the same per-day merge winner whose value the fold uses), NOT one row per source.
    /// The "current era" is read off the NEWEST day's brand, so an overlap day carrying two brands would,
    /// under the deterministic (day, sourceId) sort, let the lexically-later source (e.g. "oura-import" >
    /// "my-whoop") masquerade as the current brand. Passing one-per-day-winner makes that impossible; the
    /// same-day-tie handling below is only a determinism backstop, not a licence to pass raw multi-source
    /// rows. Any order is fine (it is sorted here).
    ///
    /// The epoch is the start of the first day of the LATEST contiguous single-brand era: walk
    /// newest→oldest while the brand matches the newest night's brand, and return that run's first day's
    /// start (a lone off-brand day inside the current era truncates it — fail-safe: it drops MORE history,
    /// never mixes scales). Returns 0.0 (no recalibration → `foldHistory` is byte-identical) when the
    /// whole history is ONE brand — so a single-device user, and a WHOOP user whose imported + computed +
    /// strap ids all bucket to "whoop", is completely unaffected.
    ///
    /// The brand bucket is intentionally coarse and NOT `DeviceFamily` (that only splits WHOOP 4 vs 5,
    /// both the same HRV scale): every WHOOP-origin id (the canonical import, the active strap, the
    /// "-noop" computed sibling, Health-Connect/Apple rows that ride the strap source) is ONE brand;
    /// each wearable-export brand (oura/fitbit/garmin) is its own. Pure + unit-pinned; the caller
    /// assembles `sourceDays` from the ORIGINAL per-source reads (brand is lost once a wearable day is
    /// re-homed under the computed WHOOP id, so detection must precede the merge). Mirrors the Kotlin twin.
    public static func deviceEraEpoch(_ sourceDays: [(day: String, sourceId: String)]) -> Double {
        if sourceDays.isEmpty { return 0.0 }
        // Total order by (day, sourceId) — a same-day mixed-brand row (an overlap night) must break the
        // tie IDENTICALLY to the Kotlin twin, so a plain by-day sort (Swift's is not stable) can't
        // diverge the computed epoch across platforms.
        let sorted = sourceDays.sorted { $0.day != $1.day ? $0.day < $1.day : $0.sourceId < $1.sourceId }
        let currentBrand = brandBucket(sorted.last!.sourceId)
        // No brand change anywhere → no epoch (byte-identical fold for every single-brand user).
        if !sorted.contains(where: { brandBucket($0.sourceId) != currentBrand }) { return 0.0 }
        // Walk back over the contiguous current-brand suffix; its first day opens the current era.
        var eraStartDay = sorted.last!.day
        for entry in sorted.reversed() {
            if brandBucket(entry.sourceId) != currentBrand { break }
            eraStartDay = entry.day
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: eraStartDay)?.timeIntervalSince1970 ?? 0.0
    }

    /// Coarse HRV-scale brand for a source id (#459). Every WHOOP-origin id shares ONE scale; each
    /// wearable-export brand is its own. Unknown ids bucket to "whoop" (the strap source and its Apple/
    /// Health-Connect riders), so only a positively-identified wearable export changes the era. Mirrors
    /// the Kotlin twin.
    static func brandBucket(_ sourceId: String) -> String {
        // `hasPrefix` deliberately catches BOTH the export id ("oura-import") and the cloud id
        // ("oura-api"), so an Oura-cloud era and an Oura-export era read as the same brand.
        if sourceId.hasPrefix("oura") { return "oura" }
        if sourceId.hasPrefix("fitbit") { return "fitbit" }
        if sourceId.hasPrefix("garmin") { return "garmin" }
        // "apple-health" / "health-connect" fall through to "whoop" ON PURPOSE: NOOP's Apple/HC daily
        // rows ride the strap source's scale, and HC is a pass-through whose true origin is unknowable,
        // so they must NOT open a false era boundary against WHOOP nights.
        return "whoop"
    }

    // MARK: - Deviation

    /// Compute z / delta / ratio / in-normal-range for a value vs a baseline.
    /// z uses (value − baseline) / (1.253 × spread); 1.253 converts EWMA-abs-dev
    /// to an approximate Gaussian σ (E[|X−μ|] = σ·√(2/π) ≈ σ/1.253).
    public static func deviation(_ value: Double, state: BaselineState) -> Deviation {
        let sigma = max(1.253 * state.spread, 1e-9)
        let z = (value - state.baseline) / sigma
        let delta = value - state.baseline
        let ratio = state.baseline != 0 ? (value / state.baseline - 1.0) : 0.0
        return Deviation(z: z, delta: delta, ratio: ratio, inNormalRange: abs(z) <= 1.0)
    }

    // MARK: - Trailing-window mean/SD (simple, auditable)

    /// Rolling personal baseline from the trailing `window` valid nights, as a
    /// plain mean and sample SD (ddof=1). This is the task's "trailing 30-day
    /// mean/SD" path: no recency weighting, maximally explainable.
    ///
    /// Physiologically implausible values (outside cfg bounds) and nils are
    /// dropped. The spread returned is stored in the SAME internal units the
    /// Winsor EWMA uses (abs-dev space), i.e. SD / 1.253, so that
    /// `deviation()` recovers the intended Gaussian σ unchanged.
    ///
    /// - Parameters:
    ///   - values: ordered nightly values (oldest → newest); nils allowed.
    ///   - cfg: metric config (bounds + floor spread).
    ///   - window: number of trailing valid nights to use (default 30).
    public static func rollingMeanSD(_ values: [Double?], cfg: MetricCfg, window: Int = 30) -> BaselineState {
        let valid = values.compactMap { v -> Double? in
            guard let v = v, cfg.minVal <= v && v <= cfg.maxVal else { return nil }
            return v
        }
        guard !valid.isEmpty else {
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }
        let trailing = valid.suffix(window)
        let n = trailing.count
        let mean = trailing.reduce(0, +) / Double(n)

        let sd: Double
        if n >= 2 {
            var ss = 0.0
            for v in trailing { let d = v - mean; ss += d * d }
            sd = (ss / Double(n - 1)).squareRoot()
        } else {
            // Single sample: no dispersion estimate; fall back to the σ floor.
            sd = cfg.floorSpread * 1.253
        }

        // Apply the σ floor in σ-space, then convert to internal abs-dev space.
        let sigmaFloored = max(cfg.floorSpread, sd)
        let spreadInternal = sigmaFloored / 1.253

        return BaselineState(baseline: mean, spread: spreadInternal, nValid: n,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: n, nightsSinceUpdate: 0))
    }
}
