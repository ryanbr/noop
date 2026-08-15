import Foundation
import WhoopStore
import StrandImport

/// Maps a parsed + aggregated Apple Health export into the on-device store under its own
/// source id ("apple-health"), so it sits BESIDE Whoop for the per-source pages and cross-source
/// consensus. Populates appleDaily, dailyMetric, the generic metricSeries, and workouts.
enum AppleHealthImport {

    /// The Apple Health mapping revision, stamped into the Import test-mode parser line. Bump when this
    /// importer's aggregate->store mapping changes.
    static let importerVersion = 1

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore, deviceId: String,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> ImportSummary {
        // retainRawSamples:false — a multi-year export is millions of HealthSample
        // structs (hundreds of MB to >1 GB); iOS jetsam-kills the app if we hold
        // them all (issue #355). The importer folds them into per-day aggregates
        // incrementally and drops the raw array; `aggregate` consumes the
        // pre-folded `sampleDailies`.
        let result = try ImportCoordinator().importAppleHealth(from: url, retainRawSamples: false)
        let daily = AppleHealthAggregator.aggregate(result)

        // Apple-specific daily aggregates (steps/energy/vo2/hr/weight).
        let appleRows = daily.map { d in
            AppleDaily(day: d.day,
                       steps: d.steps.map { Int($0) },
                       activeKcal: d.activeKcal, basalKcal: d.basalKcal, vo2max: d.vo2max,
                       avgHr: d.avgHr.map { Int($0.rounded()) },
                       maxHr: d.maxHr.map { Int($0.rounded()) },
                       walkingHr: d.walkingHr.map { Int($0.rounded()) },
                       weightKg: d.weightKg)
        }
        // Capture the rows the store actually wrote (summed SQLite changes) for the Import test mode; the
        // return value already exists, so capturing it changes nothing about what is saved.
        let appleWritten = try await store.upsertAppleDaily(appleRows, deviceId: deviceId)

        // Recovery-relevant subset into dailyMetric (recovery/strain are nil — Apple doesn't compute them).
        let dm = daily.map { d in
            DailyMetric(day: d.day,
                        totalSleepMin: d.asleepMin, efficiency: nil,
                        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.coreMin,
                        disturbances: nil,
                        restingHr: d.restingHr.map { Int($0.rounded()) },
                        avgHrv: d.hrvSDNN, recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: d.spo2Pct, skinTempDevC: nil, respRateBpm: d.respRate,
                        // #89: Apple Health steps must land in DailyMetric.steps too — the sourced-daily
                        // arbitration resolves "steps" via metricValue(d) = d.steps, so leaving it nil (the
                        // pre-fix state) meant imported Apple steps never surfaced there.
                        steps: d.steps.map { Int($0) },
                        avgSdnn: d.hrvSDNN)   // Apple HRV is SDNN — mirror into the SDNN field
        }
        let dmWritten = try await store.upsertDailyMetrics(dm, deviceId: deviceId)

        // Everything, generically, for the metric explorer.
        let points = AppleHealthAggregator.metricPoints(daily)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        // Workouts.
        let workouts = result.workouts.map { w in
            WorkoutRow(startTs: Int(w.start.timeIntervalSince1970),
                       endTs: Int(w.end.timeIntervalSince1970),
                       sport: w.activityType, source: WorkoutSource.appleHealthSource,
                       durationS: w.durationS, energyKcal: w.energyKcal,
                       avgHr: w.avgHr.map { Int($0.rounded()) },
                       maxHr: w.maxHr.map { Int($0.rounded()) }, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil)
        }
        let workoutsWritten = try await store.upsertWorkouts(workouts, deviceId: deviceId)

        // Import & Data Ingest test mode: emit the per-stage / reject / day-delta trace iff the mode is on
        // (the caller passes a non-nil `trace` only when TestCentre.active(.dataImport)). The numbers are
        // exactly the import's own parsed + persisted counts, so emission changes nothing about what saved.
        if let trace {
            let daysMapped = Set(daily.map { $0.day }).count
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: .appleHealth, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "appleDaily", rowsIn: appleRows.count, rowsOut: appleWritten),
                ImportTrace.stageLine(category: "dailyMetric", rowsIn: dm.count, rowsOut: dmWritten),
                ImportTrace.stageLine(category: "workouts", rowsIn: workouts.count, rowsOut: workoutsWritten),
                // Apple Health is tolerant: skippedSpans counts XML spans the sanitizer scrubbed / a partial
                // parse. The aggregator drops nothing further, so droppedRows is 0 here.
                ImportTrace.rejectLine(droppedRows: 0, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "appleDaily", daysMapped: daysMapped, daysPersisted: appleWritten),
            ]
            trace(lines)
        }

        return result.summary
    }
}
