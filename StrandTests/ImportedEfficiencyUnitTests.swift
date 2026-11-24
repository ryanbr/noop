import XCTest
import Foundation
import WhoopStore
import StrandAnalytics
@testable import Strand

/// `dailyMetric.efficiency` and `sleepSession.efficiency` hold the 0–1 fraction the native pipeline writes.
/// The Oura-export / Fitbit / Garmin and Mi Band importers wrote a percentage into them, and `Rest` clamps
/// efficiency to 0–1, so every such night scored a perfect efficiency component. Twin of the Kotlin
/// `ImportedEfficiencyUnitTest`: same exports, same literals.
final class ImportedEfficiencyUnitTests: XCTestCase {

    private func importExport(_ json: String, named name: String) async throws -> WhoopStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        let store = try await WhoopStore.inMemory()
        _ = try await WearableImporter.importExport(url: url, into: store)
        return store
    }

    private func day(_ store: WhoopStore, _ source: String) async throws -> DailyMetric {
        let rows = try await store.dailyMetrics(deviceId: source, from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    private func session(_ store: WhoopStore, _ source: String) async throws -> CachedSleepSession {
        let rows = try await store.sleepSessions(deviceId: source, from: 0, to: 4_102_444_800, limit: 10)
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    private let oura = """
        { "sleep": [
            { "day": "2026-06-01", "bedtime_start": "2026-05-31T23:15:00+00:00",
              "bedtime_end": "2026-06-01T06:30:00+00:00", "total_sleep_duration": 25200,
              "deep_sleep_duration": 5400, "light_sleep_duration": 13800, "rem_sleep_duration": 6000,
              "awake_time": 900, "efficiency": 92, "lowest_heart_rate": 48, "average_hrv": 65 } ] }
        """

    private func fitbit(efficiency: String) -> String {
        """
        [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
            "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20, \(efficiency)
            "levels": { "summary": { "deep": { "minutes": 80 }, "light": { "minutes": 220 },
              "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
    }

    func testOuraExportStoresTheFraction() async throws {
        let store = try await importExport(oura, named: "oura_2026.json")
        let d = try await day(store, "oura-import"), s = try await session(store, "oura-import")
        XCTAssertEqual(d.efficiency, 0.92)
        XCTAssertEqual(s.efficiency, 0.92)
    }

    func testFitbitExportStoresTheFraction() async throws {
        let store = try await importExport(fitbit(efficiency: "\"efficiency\": 94,"), named: "sleep-2026-06-01.json")
        let d = try await day(store, "fitbit-import"), s = try await session(store, "fitbit-import")
        XCTAssertEqual(d.efficiency, 0.94)
        XCTAssertEqual(s.efficiency, 0.94)
    }

    /// The export that names no efficiency falls back to asleep ÷ in-bed, on the same scale.
    func testFallbackFromDailyMinutesIsAFraction() async throws {
        let store = try await importExport(fitbit(efficiency: ""), named: "sleep-2026-06-01.json")
        let d = try await day(store, "fitbit-import"), s = try await session(store, "fitbit-import")
        XCTAssertEqual(d.efficiency, 0.9523809523809523)
        XCTAssertNil(s.efficiency, "no hypnogram and no stated efficiency: nothing to derive it from")
    }

    /// Rest is the figure the scale reached: 92% and 100% efficiency must not score the same night alike.
    func testRestNoLongerSaturatesOnAnImportedNight() async throws {
        let store = try await importExport(oura, named: "oura_2026.json")
        let stored = try await day(store, "oura-import")
        let rest = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: stored))
        let asPercent = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: stored.withEfficiency(92)))
        // 50% x 0.875 of need + 20% x 0.92 + 20% x restorative + 10% x neutral consistency.
        XCTAssertEqual(rest, 85.25)
        XCTAssertEqual(asPercent - rest, 1.6, accuracy: 0.011, "20% of the missing 8 points of efficiency")
    }

    func testMiBandEfficiencyIsAFraction() {
        XCTAssertEqual(XiaomiImporter.sleepEfficiency(total: 400, awake: 20), 0.9523809523809523)
        XCTAssertEqual(XiaomiImporter.sleepEfficiency(total: 400, awake: nil), 1.0)
        XCTAssertNil(XiaomiImporter.sleepEfficiency(total: 0, awake: 20))
        let segs: [[String: Any]] = [["start": 0, "end": 24_000, "stage": "light"],
                                     ["start": 24_000, "end": 25_200, "stage": "wake"]]
        XCTAssertEqual(XiaomiImporter.efficiency(segs: segs, start: 0, end: 25_200), 0.9523809523809523)
    }

    /// The Mi Band card reads the session's value directly, so it must read the fraction it now gets and a
    /// percentage from a night imported before this change.
    func testMiBandCardReadsBothScales() {
        XCTAssertEqual(XiaomiBandView.efficiencyPercent(0.9523809523809523), 95)
        XCTAssertEqual(XiaomiBandView.efficiencyPercent(95.23809523809523), 95)
        XCTAssertEqual(XiaomiBandView.efficiencyPercent(1.0), 100)
        XCTAssertEqual(XiaomiBandView.efficiencyPercent(100), 100)
    }
}

private extension DailyMetric {
    func withEfficiency(_ value: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: value, deepMin: deepMin, remMin: remMin,
                    lightMin: lightMin, disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv,
                    recovery: recovery, strain: strain, exerciseCount: exerciseCount)
    }
}
