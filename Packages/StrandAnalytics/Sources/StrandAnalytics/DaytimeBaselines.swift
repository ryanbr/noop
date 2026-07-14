import Foundation
import WhoopProtocol

// DaytimeBaselines.swift — the CALLER-side folding path that turns a person's past DAYTIME history
// into the personal rolling baselines `DaytimeStress.analyze(mode: .baselineRelative(hr:rmssd:))`
// scores today's waking hours against.
//
// `.baselineRelative` (see DaytimeStress.ScoringMode) is deliberately caller-fed: the scorer takes a
// finished `BaselineState` and never fetches history itself. This file is that missing caller — it
// computes ONE daytime aggregate per past day and folds the ordered series through the SAME
// Winsorized-EWMA machinery (`Baselines.foldHistory`) the nightly resting-HR / HRV baselines use, with
// the daytime-specific `Baselines.daytimeHRCfg` / `daytimeRMSSDCfg` configs.
//
// The per-day aggregate is defined in terms of EXACTLY the hourly means the scorer references: it reuses
// `DaytimeStress`'s own `floorDiv` / `bucketSeconds` / `isWakingHour` / `minHourHRSamples` /
// `HRVAnalyzer` so "the value we fold into the baseline" and "the value we later z-score against that
// baseline" are the same quantity, never two drifting definitions.

public extension DaytimeStress {

    // MARK: - Per-day daytime aggregate

    /// Percentile of a day's waking-hour mean HRs used as that day's daytime-HR aggregate: the 10th,
    /// i.e. the CALM FLOOR ("how low does my HR run when I'm calm and awake"). VALIDATED — this is the
    /// ~65 bpm pooled figure from the 26-day Oura-reference correlation behind
    /// `baselineRelativeHighMarginBPM`. It is intentionally the floor (not the median) because the HR
    /// term pairs it with a FIXED bpm margin (a large effective spread via `marginToSigma`), so anchoring
    /// at the floor makes "floor + margin" the exact HIGH cutoff.
    static let daytimeHRAggregatePercentile: Double = 0.10

    /// Percentile of a day's waking-hour RMSSDs used as that day's daytime-RMSSD aggregate: the 50th
    /// (MEDIAN / typical), NOT the symmetric calm-ceiling percentile. The asymmetry with HR above is
    /// deliberate and load-bearing: the RMSSD term is scaled by the person's OWN spread
    /// (`Baselines.sigma`), not a fixed margin, so `(baseline − hourRMSSD) / σ` is only meaningful when
    /// `baseline` is the TYPICAL daytime RMSSD — then a typical hour reads neutral and only genuine HRV
    /// suppression reads stressed. Anchoring at a calm-ceiling percentile (the direct mirror of HR's
    /// floor) would make an ordinary median hour sit ~1–2σ "below baseline" and stack a large false
    /// stress term on top of the HR term. TUNING SEAM: like every RMSSD figure in this mode, the median
    /// choice is a first pass pending an HR+HRV validation pass (the validated study was HR-only).
    static let daytimeRMSSDAggregatePercentile: Double = 0.50

    /// One local day's waking HR + R-R streams, the input to the daytime-baseline fold. `hr`/`rr` carry
    /// wall-clock `ts`; `tzOffsetSeconds` (seconds east of UTC for THAT day) places them on the local
    /// clock exactly as `analyze`'s `tzOffsetSeconds` does, so DST-varying days can each carry their own
    /// offset.
    ///
    /// Not `Sendable`: `HRSample` / `RRInterval` (WhoopProtocol) aren't `Sendable`, and this is a plain
    /// pure-function input built and consumed within one context — it is never sent across actors.
    struct DaytimeDayStreams: Equatable {
        public let hr: [HRSample]
        public let rr: [RRInterval]
        public let tzOffsetSeconds: Int
        public init(hr: [HRSample], rr: [RRInterval], tzOffsetSeconds: Int) {
            self.hr = hr; self.rr = rr; self.tzOffsetSeconds = tzOffsetSeconds
        }
    }

    /// One day's daytime aggregates, computed with the SCORER's own hourly bucketing so the folded value
    /// matches what `.baselineRelative` later references:
    ///   - `hr`: the `daytimeHRAggregatePercentile` (P10) of the day's WAKING-hour mean HRs, where each
    ///     hour's mean HR is gated at `minHourHRSamples` exactly like the scorer (a sparse/imported day
    ///     whose hours never clear the gate yields `nil` — it contributes no daytime-HR floor, honestly).
    ///   - `rmssd`: the `daytimeRMSSDAggregatePercentile` (P50) of the day's WAKING-hour RMSSDs, each run
    ///     through the same `HRVAnalyzer.analyze(rawRR:)` cleaner the scorer uses (so ectopic beats can't
    ///     fabricate variability); `nil` when no waking hour had enough clean R-R (e.g. an HR-only day).
    /// Either field is `nil` independently. Bucketing keys off the HR buckets (like the scorer), so an
    /// hour with R-R but no HR contributes neither.
    static func dayDaytimeAggregate(hr: [HRSample], rr: [RRInterval],
                                    tzOffsetSeconds: Int) -> (hr: Double?, rmssd: Double?) {
        guard !hr.isEmpty else { return (nil, nil) }

        // Bucket HR + R-R into LOCAL hour-of-day buckets, byte-for-byte the scorer's step 1.
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

        // Per WAKING hour: the gated mean HR + the cleaned RMSSD, mirroring the scorer's step 2 + waking
        // filter. Keyed off HR buckets so an R-R-only hour is ignored exactly as the scorer ignores it.
        var wakingMeanHRs: [Double] = []
        var wakingRMSSDs: [Double] = []
        for (bucket, hrs) in hrByBucket where isWakingHour(bucket) {
            if hrs.count >= minHourHRSamples, let m = mean(hrs) { wakingMeanHRs.append(m) }
            if let rmssd = HRVAnalyzer.analyze(rawRR: rrByBucket[bucket] ?? []).rmssd {
                wakingRMSSDs.append(rmssd)
            }
        }

        let hrAgg = wakingMeanHRs.isEmpty
            ? nil : quantile(wakingMeanHRs.sorted(), daytimeHRAggregatePercentile)
        let rmssdAgg = wakingRMSSDs.isEmpty
            ? nil : quantile(wakingRMSSDs.sorted(), daytimeRMSSDAggregatePercentile)
        return (hrAgg, rmssdAgg)
    }

    // MARK: - Fold the trailing history into personal baselines

    /// Fold a person's trailing per-day daytime streams (OLDEST → NEWEST, TODAY EXCLUDED — today is the
    /// day being scored, not part of its own baseline) into the personal baselines `.baselineRelative`
    /// consumes.
    ///
    /// Each day contributes one `dayDaytimeAggregate`; the ordered series is replayed through
    /// `Baselines.foldHistory` (the identical Winsorized-EWMA path as the nightly baselines) with
    /// `daytimeHRCfg` / `daytimeRMSSDCfg`. `nil` aggregates (sparse/HR-only days) become skip-and-hold
    /// nights, exactly like a missing nightly value.
    ///
    /// The HR baseline is always returned (it may be `.calibrating`; the caller checks `.usable` to
    /// decide whether to use `.baselineRelative` at all). The RMSSD baseline is returned ONLY when it is
    /// `.usable` (≥ `Baselines.minNightsSeed` days actually carried a daytime RMSSD); otherwise `nil`, so
    /// the scorer honestly runs HR-only rather than z-scoring against a 1–2-day, untrustworthy HRV
    /// baseline — the whole-baseline grain of the per-hour graceful-nil already in `rawScore`.
    static func foldDaytimeBaselines(days: [DaytimeDayStreams]) -> (hr: BaselineState, rmssd: BaselineState?) {
        var hrAggs: [Double?] = []
        var rmssdAggs: [Double?] = []
        hrAggs.reserveCapacity(days.count)
        rmssdAggs.reserveCapacity(days.count)
        for d in days {
            let agg = dayDaytimeAggregate(hr: d.hr, rr: d.rr, tzOffsetSeconds: d.tzOffsetSeconds)
            hrAggs.append(agg.hr)
            rmssdAggs.append(agg.rmssd)
        }
        let hrState = Baselines.foldHistory(hrAggs, cfg: Baselines.daytimeHRCfg)
        let rmssdState = Baselines.foldHistory(rmssdAggs, cfg: Baselines.daytimeRMSSDCfg)
        return (hrState, rmssdState.usable ? rmssdState : nil)
    }

    /// The scoring mode to hand `analyze` for TODAY, decided from the trailing daytime `history`:
    /// `.baselineRelative` once the personal HR baseline is `.usable` (≥ `Baselines.minNightsSeed` days
    /// of real daytime HR aggregates — the Oura-style, validated-r≈0.6 path), else `.dayRelative` (the
    /// unchanged default). This is the single graceful-degradation gate: a cold start, or a trailing
    /// window that is all sparse/imported days, keeps EXACTLY today's pre-existing day-relative behaviour.
    static func scoringMode(history days: [DaytimeDayStreams]) -> ScoringMode {
        let baselines = foldDaytimeBaselines(days: days)
        guard baselines.hr.usable else { return .dayRelative }
        return .baselineRelative(hr: baselines.hr, rmssd: baselines.rmssd)
    }
}
