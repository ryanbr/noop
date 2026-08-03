import Foundation
import StrandAnalytics
import WhoopStore
import StrandImport

/// Maps a parsed Xiaomi / Mi Band export (Mi Fitness iOS sandbox) into the on-device
/// WhoopStore tables the UI reads — `dailyMetric`, `sleepSession` (with a real
/// per-epoch hypnogram), and the generic `metricSeries` — so importing lights up the
/// full history immediately as its own `xiaomi-band` Data Source.
enum XiaomiImporter {

    /// Per-source partition key (mirrors `"my-whoop"` / `"apple-health"`).
    static let deviceId = "xiaomi-band"

    /// The Mi Fitness mapping revision, stamped into the Import test-mode parser line.
    static let importerVersion = 1

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore, deviceId: String = deviceId,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> ImportSummary {
        let result = try ImportCoordinator().importXiaomiBand(from: url)

        // Day rollups → DailyMetric. The Mi Fitness export has no HRV / recovery /
        // respiration, so those stay nil and NOOP derives what it can locally.
        var metrics: [DailyMetric] = []
        for d in result.days {
            metrics.append(DailyMetric(
                day: d.day,
                totalSleepMin: d.totalSleepMin,
                efficiency: sleepEfficiency(total: d.totalSleepMin, awake: d.awakeMin),
                deepMin: d.deepMin,
                remMin: d.remMin,
                lightMin: d.lightMin,
                disturbances: nil,
                restingHr: d.restingHr,
                avgHrv: nil,
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                spo2Pct: d.avgSpo2,
                skinTempDevC: nil,
                respRateBpm: nil))
        }
        // Capture the rows the store actually wrote (summed SQLite changes) for the Import test mode.
        let metricsWritten = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        // Sleep sessions → CachedSleepSession with the band's actual hypnogram.
        var sessions: [CachedSleepSession] = []
        for s in result.sleeps {
            let startTs = Int(s.bedtime.timeIntervalSince1970)
            let endTs = Int(s.wakeTime.timeIntervalSince1970)
            let segs: [[String: Any]] = s.stages.map {
                ["start": Int($0.start.timeIntervalSince1970),
                 "end": Int($0.end.timeIntervalSince1970),
                 "stage": stageName($0.stage)]
            }
            let json = segs.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: segs))
                .flatMap { String(data: $0, encoding: .utf8) }
            sessions.append(CachedSleepSession(
                startTs: startTs,
                endTs: endTs,
                efficiency: efficiency(segs: segs, start: startTs, end: endTs),
                restingHr: s.minHr,            // band's sleeping-min HR ≈ resting
                avgHrv: nil,
                stagesJSON: json))
        }
        let sessionsWritten = try await store.upsertSleepSessions(sessions, deviceId: deviceId)

        // Generic metric series — every scalar keyed, for the Metric Explorer + correlations.
        var points: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?) {
            if let v { points.append(MetricPoint(day: day, key: key, value: v)) }
        }
        for d in result.days {
            add(d.day, "steps", d.steps.map(Double.init))
            add(d.day, "distance_m", d.distanceM)
            add(d.day, "energy_kcal", d.activeKcal)
            add(d.day, "rhr", d.restingHr.map(Double.init))
            add(d.day, "avg_hr", d.avgHr.map(Double.init))
            add(d.day, "max_hr", d.maxHr.map(Double.init))
            add(d.day, "min_hr", d.minHr.map(Double.init))
            add(d.day, "spo2", d.avgSpo2)
            add(d.day, "stress", d.avgStress.map(Double.init))
            add(d.day, "vitality", d.vitality.map(Double.init))
            add(d.day, "intensity_min", d.intensityMin)
            add(d.day, "stand_count", d.standCount.map(Double.init))
            add(d.day, "sleep_total_min", d.totalSleepMin)
            add(d.day, "sleep_deep_min", d.deepMin)
            add(d.day, "sleep_light_min", d.lightMin)
            add(d.day, "sleep_rem_min", d.remMin)
            add(d.day, "sleep_score", d.sleepScore.map(Double.init))
        }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        // Import & Data Ingest test mode: emit the per-stage / reject / day-delta trace iff the mode is on.
        // The numbers are the import's own parsed + persisted counts, so emission changes nothing saved.
        if let trace {
            let daysMapped = Set(metrics.map { $0.day }).count
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: .xiaomiBand, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "days", rowsIn: metrics.count, rowsOut: metricsWritten),
                ImportTrace.stageLine(category: "sleeps", rowsIn: sessions.count, rowsOut: sessionsWritten),
                // The Mi Fitness rollups already drop unusable rows upstream in StrandImport; the app map
                // keeps every day/sleep, so the only reject signal at this seam is the day-delta below.
                ImportTrace.rejectLine(droppedRows: 0, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "days", daysMapped: daysMapped, daysPersisted: metricsWritten),
            ]
            trace(lines)
        }

        return result.summary
    }

    private static func stageName(_ s: XiaomiSleepStage) -> String {
        switch s {
        case .deep: return "deep"
        case .rem: return "rem"
        case .light: return "light"
        case .awake, .awakeInBed, .unknown: return "wake"
        }
    }

    /// Asleep fraction of in-bed time, from the daily stage minutes.
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
                  let stage = seg["stage"] as? String, !SleepStageVocabulary.isWake(stage) else { continue }
            asleep += max(0, e - s)
        }
        return min(100, Double(asleep) / Double(end - start) * 100)
    }
}
