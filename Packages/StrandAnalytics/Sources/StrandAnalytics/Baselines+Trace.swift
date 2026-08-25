import Foundation

// Baselines+Trace.swift - the per-night BASELINE FOLD diagnostic (Recovery test mode).
//
// Every other core analytics component has a trace file; the fold did not, so a strap log could show
// what a baseline IS (RecoveryScorer+Trace prints mean / spread / nValid / status) but never how it got
// there. That gap costs real triage time, because the fold's decisions are exactly the ones that go
// wrong quietly: a night rejected as a hard outlier is "seen, but not folded" and leaves no trace at
// all, and a spread pinned on its floor looks identical to a spread that has genuinely settled.
//
// Returns the state from `Baselines.update(...)` VERBATIM and recomputes only the intermediate
// decisions for the lines, so the trace can never disagree with the baseline the scorer reads. Pure and
// side-effect-free: no clock, no I/O, so a fixture night pins the exact lines. Gated at the call site
// behind the Recovery test mode; when it is off this is never called, so there is zero cost. No
// em-dashes. Values, counts and thresholds only, no PII.

extension Baselines {

    /// Side-effect-free diagnostic twin of `update(...)`: returns the SAME state `update(...)` would,
    /// plus a line naming which branch the night took and why.
    ///
    /// The branches, in the order `update` tests them:
    ///  - `seed` / `seed-empty` - the first ever night; it FIXES the centre and starts spread at the floor.
    ///  - `missing`     - no value for the night; skip-and-hold, `nightsSinceUpdate` climbs.
    ///  - `implausible` - outside the metric's physiological bounds; skip-and-hold.
    ///  - `rejected`    - a hard outlier once seeded and no longer young; seen, but not folded.
    ///  - `folded`      - the normal Winsorized-EWMA path.
    ///
    /// The `folded` line reports `young`, the effective spread and half-life actually used, the Winsor
    /// band and whether the value was clamped, and spread before/after WITH whether it landed on
    /// `cfg.floorSpread`. That last flag is the point of the whole file: `atFloor=yes` many nights in
    /// means the z-scores the score divides by are still being computed against the floor.
    ///
    /// - Parameter metric: the metric key ("hrv", "resting_hr", ...) so one log can carry several folds.
    public static func updateTrace(_ state: BaselineState?,
                                   value: Double?,
                                   cfg: MetricCfg,
                                   metric: String,
                                   rejectHardOutliers: Bool = true) -> (state: BaselineState, lines: [String]) {
        // The returned state is the REAL fold's, always. Nothing below recomputes it.
        let next = update(state, value: value, cfg: cfg, rejectHardOutliers: rejectHardOutliers)

        func r2(_ x: Double) -> Double { (x * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0 }
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        let head = "baseline \(metric)"
        let stateSuffix = "-> mean=\(r2(next.baseline)) spread=\(r2(next.spread)) "
            + "nValid=\(next.nValid) status=\(next.status.rawValue)"

        // Branch order MIRRORS `update` exactly: it tests `state == nil` FIRST and that branch decides
        // the value's validity itself, so a first night with a missing or out-of-range value is a seed
        // case and not a skip. Testing value-ness first here would label those two lines wrongly while
        // still returning the right state, which is the worst kind of diagnostic.
        guard let state = state else {
            guard let v = value, cfg.minVal <= v && v <= cfg.maxVal else {
                return (next, ["\(head) night=seed-empty no usable first value "
                               + "(bounds=\(r2(cfg.minVal))..\(r2(cfg.maxVal))) "
                               + "seeded at midpoint, nValid stays 0 \(stateSuffix)"])
            }
            return (next, ["\(head) night=seed value=\(r2(v)) "
                           + "spread starts at floor=\(r2(cfg.floorSpread)) "
                           + "(this ONE night fixes the centre) \(stateSuffix)"])
        }

        guard let value = value else {
            return (next, ["\(head) night=missing skip-and-hold "
                           + "nightsSinceUpdate=\(next.nightsSinceUpdate) \(stateSuffix)"])
        }

        guard cfg.minVal <= value && value <= cfg.maxVal else {
            return (next, ["\(head) night=implausible value=\(r2(value)) "
                           + "bounds=\(r2(cfg.minVal))..\(r2(cfg.maxVal)) skip-and-hold "
                           + "nightsSinceUpdate=\(next.nightsSinceUpdate) \(stateSuffix)"])
        }

        // Same predicate `update` uses: tied to the valid-night count, not to spread.
        let isYoung = state.nValid < earlyAdaptNights

        if rejectHardOutliers && state.nValid >= minNightsSeed && !isYoung {
            let dev = abs(value - state.baseline)
            if dev > hardOutlierK * state.spread {
                return (next, ["\(head) night=rejected value=\(r2(value)) "
                               + "dev=\(r2(dev)) > k=\(r2(hardOutlierK))*spread=\(r2(state.spread)) "
                               + "(seen, NOT folded) \(stateSuffix)"])
            }
        }

        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effHalfLifeB = isYoung ? earlyHalfLifeB : cfg.halfLifeB
        let lo = state.baseline - winsorK * effSpread
        let hi = state.baseline + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let wasClamped = clamped != value
        // `update` floors the spread with max(cfg.floorSpread, ...); report when that floor is what won,
        // since a spread sitting on its floor is indistinguishable from a settled one in every other log.
        let atFloor = next.spread <= cfg.floorSpread

        return (next, ["\(head) night=folded value=\(r2(value)) young=\(yn(isYoung)) "
                       + "effSpread=\(r2(effSpread)) halfLifeB=\(r2(effHalfLifeB)) "
                       + "winsor=\(r2(lo))..\(r2(hi)) clamped=\(yn(wasClamped))"
                       + (wasClamped ? " to=\(r2(clamped))" : "")
                       + " spread \(r2(state.spread))->\(r2(next.spread)) atFloor=\(yn(atFloor)) \(stateSuffix)"])
    }

    /// Replay an ordered history (oldest first) through `updateTrace`, returning the final state and one
    /// line per night. The state threaded between nights is the real fold's, so this is
    /// `foldHistory(...)` with commentary rather than a reimplementation of it.
    ///
    /// This is the shape that answers "how many nights until the spread lifted", which is unanswerable
    /// from a single night's line.
    /// - Parameter tail: keep only the last N lines. The WHOLE history is still folded, so the state is
    ///   unchanged; this bounds the log, because an established user's history is hundreds of nights and
    ///   a diagnostic nobody can read is not a diagnostic. nil keeps every line.
    public static func foldHistoryTrace(_ values: [Double?],
                                        cfg: MetricCfg,
                                        metric: String,
                                        rejectHardOutliers: Bool = true,
                                        tail: Int? = nil) -> (state: BaselineState, lines: [String]) {
        var state: BaselineState? = nil
        var lines: [String] = []
        for v in values {
            let step = updateTrace(state, value: v, cfg: cfg, metric: metric,
                                   rejectHardOutliers: rejectHardOutliers)
            state = step.state
            lines.append(contentsOf: step.lines)
        }
        if let tail = tail, tail >= 0, lines.count > tail {
            let dropped = lines.count - tail
            lines = ["baseline \(metric) (earlier \(dropped) night(s) omitted)"] + lines.suffix(tail)
        }
        guard let final = state else {
            // Empty history: mirror foldHistory's midpoint seed rather than inventing a different one.
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return (BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                  nightsSinceUpdate: 0,
                                  status: computeStatus(nValid: 0, nightsSinceUpdate: 0)),
                    ["baseline \(metric) history=empty"])
        }
        return (final, lines)
    }

    /// The recalibration-aware fold, traced. Twin of `foldHistory(_:dayKeys:cfg:baselineEpoch:)`, which
    /// DROPS (rather than skip-and-holds) every night dated before the recalibration epoch.
    ///
    /// The drop is the point. A manual "Recalibrate baseline" discards the user's earlier nights and
    /// restarts the count, and nothing in a log has ever said so - a reporter sat at "Calibrating, 3 of
    /// 4 nights" holding 15 valid nights, because each tap threw them away. The `dropped=` line names
    /// that directly instead of leaving it to be inferred from a suspiciously low nValid.
    ///
    /// `baselineEpoch` is REQUIRED here, unlike the production overload which defaults to reading it
    /// from UserDefaults: this file stays pure, so the caller reads the pref and passes it in.
    public static func foldHistoryTrace(_ values: [Double?],
                                        dayKeys: [String],
                                        cfg: MetricCfg,
                                        metric: String,
                                        baselineEpoch: Double,
                                        tail: Int? = nil) -> (state: BaselineState, lines: [String]) {
        guard baselineEpoch > 0 else {
            return foldHistoryTrace(values, cfg: cfg, metric: metric, tail: tail)
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        // Filter THEN fold, which is what the production loop does night by night; folding the kept
        // nights in order gives the identical state, and a test pins that against the real function.
        var kept: [Double?] = []
        var dropped = 0
        for (i, v) in values.enumerated() {
            if i < dayKeys.count, let d = fmt.date(from: dayKeys[i]),
               d.timeIntervalSince1970 < baselineEpoch {
                dropped += 1
                continue
            }
            kept.append(v)
        }
        let day = fmt.string(from: Date(timeIntervalSince1970: baselineEpoch))
        let head = "baseline \(metric) recalibrated=\(day) dropped=\(dropped) night(s) before it"
        let out = foldHistoryTrace(kept, cfg: cfg, metric: metric, tail: tail)
        return (out.state, [head] + out.lines)
    }
}
