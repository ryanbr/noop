import XCTest
@testable import WhoopStore

final class WeightHistoryTests: XCTestCase {
    // Expected strings captured from `swiftc -O WeightHistory.swift main.swift` and copied verbatim
    // into WeightHistoryTest.kt. Both directions pin the source/date/value contract.
    func testValidationOracle() {
        let days = ["2024-02-29", "2026-02-29", "2000-02-29", "1900-02-29", "2100-02-29", "2026-04-31", "2026-04-30", "0001-01-01", "0000-01-01", "9999-12-31", "2026-13-01", "2026-00-10", "2026-09-00", "2026-09-31", "2026-9-25", " 2026-09-25", "２０２６-09-25", "2026-09-25"]
        XCTAssertEqual(days.map { WeightHistory.validDay($0) ? "1" : "0" }.joined(), "101000110100000001")
        XCTAssertEqual([-1, 0, Double.nan, Double.infinity, 1000.1, 0.1, 80.5, 1000].map {
            WeightHistory.validKilograms($0) ? "1" : "0"
        }.joined(), "00000111")
    }

    func testResolutionOracle() {
        let entries = [WeightEntry(day: "2026-09-25", kilograms: 80, source: "health-connect"),
                       WeightEntry(day: "2026-09-24", kilograms: 82, source: "health-connect"),
                       WeightEntry(day: "2026-09-25", kilograms: 81, source: "apple-health"),
                       WeightEntry(day: "2026-09-25", kilograms: 79.5, source: "noop-weight"),
                       WeightEntry(day: "2026-09-26", kilograms: 78, source: "noop-weight"),
                       WeightEntry(day: "2026-09-23", kilograms: 0, source: "noop-weight"),
                       WeightEntry(day: "2026-09-22", kilograms: 90, source: "unknown")]
        let result = WeightHistory.resolve(entries, through: "2026-09-25")
        XCTAssertEqual(result.map { "\($0.day)|\($0.kilograms)|\($0.source)" }.joined(separator: "\n"),
                       "2026-09-24|82.0|health-connect\n2026-09-25|79.5|noop-weight")
        XCTAssertEqual(WeightHistory.resolve(entries.reversed(), through: "2026-09-25"), result)
    }

    func testEditAndDeletePreserveImportedReadingsAndOtherKeys() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-09-25", key: "weight", value: 81)], deviceId: "health-connect")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-09-25", key: "mood", value: 4)], deviceId: "noop-mood")
        try await store.saveWeight(day: "2026-09-25", kilograms: 80)
        try await store.saveWeight(day: "2026-09-25", kilograms: 79.5)
        let edited = try await store.weightHistory(through: "2026-09-25")
        XCTAssertEqual(edited, [WeightEntry(day: "2026-09-25", kilograms: 79.5, source: "noop-weight")])
        // Re-import must not overwrite a manual entry.
        try await store.upsertMetricSeries([MetricPoint(day: "2026-09-25", key: "weight", value: 82)], deviceId: "health-connect")
        let afterImport = try await store.weightHistory(through: "2026-09-25")
        XCTAssertEqual(afterImport, edited)
        try await store.deleteWeight(day: "2026-09-25")
        try await store.deleteWeight(day: "2026-09-25")
        let afterDelete = try await store.weightHistory(through: "2026-09-25")
        XCTAssertEqual(afterDelete, [WeightEntry(day: "2026-09-25", kilograms: 82, source: "health-connect")])
        let moods = try await store.metricSeries(deviceId: "noop-mood", key: "mood", from: "2026-09-25", to: "2026-09-25")
        XCTAssertEqual(moods.first?.value, 4)
    }

    func testInvalidWriteDoesNotReplaceGoodData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveWeight(day: "2026-09-25", kilograms: 80)
        for (day, value) in [("2026-09-25", Double.nan), ("2026-02-29", 80), ("2026-09-25", 0)] {
            do { try await store.saveWeight(day: day, kilograms: value); XCTFail("Invalid weight was accepted") }
            catch WeightHistoryError.invalidEntry { }
        }
        let history = try await store.weightHistory(through: "2026-09-25")
        XCTAssertEqual(history.first?.kilograms, 80)
    }

    func testCheckpointedDatabaseBackupRetainsDatesValuesAndSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.sqlite")
        let backup = directory.appendingPathComponent("noop-backup.sqlite")
        let store = try await WhoopStore(path: original.path)
        try await store.saveWeight(day: "2026-09-23", kilograms: 85.25)
        try await store.saveWeight(day: "2026-09-25", kilograms: 84.75)
        try await store.upsertMetricSeries([MetricPoint(day: "2026-09-24", key: "weight", value: 85)], deviceId: "health-connect")
        try await store.checkpointWAL()
        try FileManager.default.copyItem(at: original, to: backup)
        let restored = try await WhoopStore(path: backup.path)
        let expected = try await store.weightHistory(through: "2026-09-25")
        let actual = try await restored.weightHistory(through: "2026-09-25")
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 3)
    }
    func testLegacyDailyWeightsSurviveOverridesAndOldDates() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-01-10"
        func daily(_ day: String, _ kg: Double) -> AppleDaily {
            AppleDaily(day: day, steps: nil, activeKcal: nil, basalKcal: nil, vo2max: nil,
                       avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: kg)
        }
        try await store.upsertAppleDaily([daily(day, 84.2), daily("2026-09-27", 70)], deviceId: "health-connect")
        var history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history, [WeightEntry(day: day, kilograms: 84.2, source: "health-connect")])
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "weight", value: 83)], deviceId: "health-connect")
        history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history.first?.kilograms, 83)
        try await store.saveWeight(day: day, kilograms: 82)
        history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history.first?.kilograms, 82)
        try await store.deleteWeight(day: day)
        history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history.first?.kilograms, 83)
        // SQLite rejects NaN in a NOT NULL REAL column; zero exercises the same invalid-series fallback.
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "weight", value: 0)], deviceId: "health-connect")
        history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history.first?.kilograms, 84.2)
        try await store.upsertAppleDaily([daily(day, 85)], deviceId: "apple-health")
        history = try await store.weightHistory(through: "2026-09-26")
        XCTAssertEqual(history, [WeightEntry(day: day, kilograms: 85, source: "apple-health")])
    }

}
