import Foundation
import WhoopStore
import StrandImport

/// Maps a parsed Oura / Fitbit / Garmin own-data export into the on-device WhoopStore tables the UI
/// reads — `dailyMetric`, `sleepSession`, and the generic `metricSeries` — under a per-brand Data
/// Source id ("oura-import" / "fitbit-import" / "garmin-import"), so importing lights up the history
/// immediately as its own source distinct from WHOOP.
///
/// HONEST DATA: only fields the export carried are written. The brand's OWN scores (Oura readiness,
/// any sleep score) are stored under REFERENCE metric keys only — never as NOOP's Charge/Effort/Rest.
/// NOOP recomputes its own scores downstream from the imported raw RHR / HRV / sleep, exactly as it
/// does for every other imported source. Fully offline — the parse never touches the network.
enum WearableImporter {

    /// The Oura/Fitbit/Garmin export mapping revision, stamped into the Import test-mode parser line.
    static let importerVersion = 1

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> WearableImportResult {
        let result = try ImportCoordinator().importWearableExport(from: url)
        let deviceId = result.brand.sourceId

        // Day rollups → DailyMetric. HRV/recovery/respiration that the export lacks stay nil; NOOP
        // derives what it can locally. A brand's reference scores never populate `recovery`/`strain`.
        var metrics: [DailyMetric] = []
        for d in result.days {
            metrics.append(DailyMetric(
                day: d.day,
                totalSleepMin: d.totalSleepMin,
                efficiency: d.efficiencyPct ?? sleepEfficiency(total: d.totalSleepMin, awake: d.awakeMin),
                deepMin: d.deepMin,
                remMin: d.remMin,
                lightMin: d.lightMin,
                disturbances: nil,
                restingHr: d.restingHr,
                avgHrv: d.avgHrvMs,
                recovery: nil,                 // NEVER the brand's readiness score
                strain: nil,
                exerciseCount: nil,
                spo2Pct: d.spo2Pct,
                skinTempDevC: d.skinTempDevC,
                respRateBpm: d.respRateBpm))   // imported night resp now reaches the day rollup (#17)
        }
        // Capture the rows the store actually wrote (summed SQLite changes) for the Import test mode.
        let metricsWritten = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        // Sleep sessions → CachedSleepSession. Oura/Garmin give duration breakdowns without a per-segment
        // hypnogram, so those sessions carry no stage JSON (we never synthesize a fake one); Fitbit's
        // optional `levels.data` hypnogram is mapped when present.
        var sessions: [CachedSleepSession] = []
        for s in result.sleeps {
            let startTs = Int(s.start.timeIntervalSince1970)
            let endTs = Int(s.end.timeIntervalSince1970)
            let segs: [[String: Any]] = s.stages.map {
                ["start": Int($0.start.timeIntervalSince1970),
                 "end": Int($0.end.timeIntervalSince1970),
                 "stage": $0.stage]
            }
            let json = segs.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: segs))
                .flatMap { String(data: $0, encoding: .utf8) }
            sessions.append(CachedSleepSession(
                startTs: startTs,
                endTs: endTs,
                efficiency: s.efficiencyPct ?? efficiency(segs: segs, start: startTs, end: endTs),
                restingHr: s.lowestHr ?? s.avgHr,   // sleeping-min HR ≈ resting; falls back to avg
                avgHrv: s.avgHrvMs,
                stagesJSON: json))
        }
        let sessionsWritten = try await store.upsertSleepSessions(sessions, deviceId: deviceId)

        // Generic metric series — every scalar keyed for the Metric Explorer + correlations. The brand's
        // own scores go under clearly-labelled reference keys (e.g. "ref_readiness_score"), so they're
        // browseable but never mistaken for a NOOP score.
        var points: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?) {
            if let v { points.append(MetricPoint(day: day, key: key, value: v)) }
        }
        for d in result.days {
            add(d.day, "steps", d.steps.map(Double.init))
            add(d.day, "distance_m", d.distanceM)
            add(d.day, "energy_kcal", d.activeKcal)
            add(d.day, "total_kcal", d.totalKcal)
            add(d.day, "rhr", d.restingHr.map(Double.init))
            add(d.day, "hrv", d.avgHrvMs)
            add(d.day, "skin_temp_dev_c", d.skinTempDevC)
            add(d.day, "spo2", d.spo2Pct)
            add(d.day, "vo2max", d.vo2max)
            add(d.day, "stress", d.avgStress.map(Double.init))
            add(d.day, "sleep_total_min", d.totalSleepMin)
            add(d.day, "sleep_deep_min", d.deepMin)
            add(d.day, "sleep_light_min", d.lightMin)
            add(d.day, "sleep_rem_min", d.remMin)
            // Reference-only: the brand's own scores, never a NOOP Charge/Effort/Rest input.
            add(d.day, "ref_readiness_score", d.readinessScore.map(Double.init))
            add(d.day, "ref_sleep_score", d.sleepScore.map(Double.init))
        }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        // Import & Data Ingest test mode: emit the per-stage / reject / day-delta trace iff the mode is on.
        // The numbers are the import's own parsed + persisted counts, so emission changes nothing saved.
        if let trace {
            let daysMapped = Set(result.days.map { $0.day }).count
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: result.brand.dataSourceKind, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "days", rowsIn: result.days.count, rowsOut: metricsWritten),
                ImportTrace.stageLine(category: "sleeps", rowsIn: sessions.count, rowsOut: sessionsWritten),
                // The Oura/Fitbit/Garmin parser drops unusable rows upstream in StrandImport; the app map
                // keeps every day/sleep, so the reject signal at this seam is the day-delta below.
                ImportTrace.rejectLine(droppedRows: 0, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "days", daysMapped: daysMapped, daysPersisted: metricsWritten),
            ]
            trace(lines)
        }

        return result
    }

    /// Asleep fraction of in-bed time, from the daily stage minutes (when the export gave no efficiency).
    private static func sleepEfficiency(total: Double?, awake: Double?) -> Double? {
        guard let total, total > 0 else { return nil }
        let awake = awake ?? 0
        let inBed = total + awake
        return inBed > 0 ? min(100, total / inBed * 100) : nil
    }

    /// Asleep fraction from the hypnogram segments (non-wake ÷ in-bed span).
    private static func efficiency(segs: [[String: Any]], start: Int, end: Int) -> Double? {
        guard end > start, !segs.isEmpty else { return nil }
        var asleep = 0
        for seg in segs {
            guard let s = seg["start"] as? Int, let e = seg["end"] as? Int,
                  let stage = seg["stage"] as? String, stage != "wake" else { continue }
            asleep += max(0, e - s)
        }
        return min(100, Double(asleep) / Double(end - start) * 100)
    }
}
