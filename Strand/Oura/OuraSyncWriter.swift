// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import WhoopStore
import WhoopProtocol
import StrandImport

/// Maps an assembled `OuraSyncResult` into the on-device WhoopStore under `deviceId = "oura-api"` — the
/// cloud sibling of `Strand/Data/WearableImporter.swift`. HONEST DATA: Oura's own scores go only to
/// ref_*/oura_* metricSeries keys; `DailyMetric.recovery`/`.strain` stay nil. The source registers as
/// `.cloudImport`, which is structurally priority-2 in DayOwnerResolver, so it never seizes a WHOOP day.
enum OuraSyncWriter {

    @discardableResult
    static func persist(_ result: OuraSyncResult, into store: WhoopStore,
                        deviceId: String = "oura-api") async throws -> OuraSyncSummary {
        var summary = OuraSyncSummary()

        // 0. Register the cloud source (the one thing WearableImporter skips). Idempotent by id.
        let now = Int(Date().timeIntervalSince1970)
        let device = PairedDevice(
            id: deviceId, brand: "Oura", model: result.ringModel ?? "Oura (cloud)",
            sourceKind: .cloudImport, capabilities: [], status: .paired,
            addedAt: now, lastSeenAt: now)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(device)

        // 1. Raw archive — verbatim, every page, lossless.
        if !result.rawPages.isEmpty {
            summary.rawPages = try await store.upsertOuraRaw(result.rawPages, deviceId: deviceId)
        }

        // 2. Days → DailyMetric. recovery/strain ALWAYS nil (never Oura's readiness). Mirrors WearableImporter.
        let metrics = result.days.map { d in
            DailyMetric(day: d.day, totalSleepMin: d.totalSleepMin, efficiency: d.efficiencyPct,
                        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.lightMin, disturbances: nil,
                        restingHr: d.restingHr, avgHrv: d.avgHrvMs, recovery: nil, strain: nil,
                        exerciseCount: nil, spo2Pct: d.spo2Pct, skinTempDevC: d.skinTempDevC,
                        respRateBpm: d.respRateBpm, steps: d.steps, activeKcalEst: d.activeKcal)
        }
        summary.days = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        // 3. Sleep sessions → CachedSleepSession (+ stagesJSON), then per-session motion via the dedicated setter.
        var sessions: [CachedSleepSession] = []
        for p in result.sleepPeriods {
            let startTs = Int(p.session.start.timeIntervalSince1970)
            let endTs = Int(p.session.end.timeIntervalSince1970)
            sessions.append(CachedSleepSession(
                startTs: startTs, endTs: endTs, efficiency: p.session.efficiencyPct,
                restingHr: p.session.lowestHr ?? p.session.avgHr, avgHrv: p.session.avgHrvMs,
                stagesJSON: stagesJSON(p.session.stages)))
        }
        summary.sleeps = try await store.upsertSleepSessions(sessions, deviceId: deviceId)
        for p in result.sleepPeriods where !p.movement30s.isEmpty {   // motionJSON is NOT on the sleep upsert
            _ = try await store.persistSessionMotion(
                deviceId: deviceId, sessionStart: Int(p.session.start.timeIntervalSince1970),
                motionEpochs: p.movement30s.map(Double.init))
        }

        // 4. HR → hrSample via the Streams insert path (in-sleep HR + the whole-day /heartrate series).
        var hr: [HRSample] = result.heartRate.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        for p in result.sleepPeriods { hr.append(contentsOf: p.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) }) }
        if !hr.isEmpty {
            let counts = try await store.insert(Streams(hr: hr), deviceId: deviceId)
            summary.hrSamples = counts.hr
        }

        // 5. Workouts → WorkoutRow.
        let workouts = result.workouts.map { w in
            WorkoutRow(startTs: Int(w.start.timeIntervalSince1970), endTs: Int(w.end.timeIntervalSince1970),
                       sport: w.activity, source: w.source, durationS: w.end.timeIntervalSince(w.start),
                       energyKcal: w.energyKcal, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil, steps: nil)
        }
        summary.workouts = try await store.upsertWorkouts(workouts, deviceId: deviceId)

        // 6. Extras → metricSeries (ref_*/oura_*/vo2max — parity with the file-import lane, sourced from
        //    the extras array so vo2max/ref_sleep_score are never lost even though DailyMetric lacks them).
        let points = result.extras.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        summary.metricPoints = try await store.upsertMetricSeries(points, deviceId: deviceId)

        return summary
    }

    /// Serialize decoded stages to the `[{start,end,stage}]` JSON the cache stores (same shape as WearableImporter).
    private static func stagesJSON(_ stages: [WearableSleepStageInterval]) -> String? {
        guard !stages.isEmpty else { return nil }
        let segs = stages.map { ["start": Int($0.start.timeIntervalSince1970),
                                 "end": Int($0.end.timeIntervalSince1970), "stage": $0.stage] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: segs)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
#endif // OURA_CLOUD_IMPORT
