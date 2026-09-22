import XCTest
import WhoopStore
@testable import Strand

/// The WHOOP export ships absolute skin temperature. It belongs in `skinTempC`, with `skinTempDevC` the
/// deviation from the nights before, never the absolute itself.
final class WhoopImportSkinTempTests: XCTestCase {

    private func row(_ day: String, dev: Double? = nil, abs: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: dev, skinTempC: abs)
    }

    private func nights(_ temps: [Double]) -> [DailyMetric] {
        temps.enumerated().map { row(String(format: "2026-07-%02d", $0.offset + 1), abs: $0.element) }
    }

    func testTheDeviationIsMeasuredAgainstPriorNightsAndNeverTheAbsolute() {
        let out = WhoopImporter.withSkinTempDeviations(nights(Array(repeating: 33.5, count: 10) + [34.3]))
        XCTAssertNil(out[0].skinTempDevC, "no baseline before the first night")
        XCTAssertEqual(out.last?.skinTempC, 34.3)
        XCTAssertEqual(out.last?.skinTempDevC ?? .nan, 0.8, accuracy: 0.01)
        XCTAssertTrue(out.compactMap(\.skinTempDevC).allSatisfy { abs($0) < 2 })
    }

    func testARowWithoutAnAbsoluteKeepsItsDeviation() {
        let out = WhoopImporter.withSkinTempDeviations([row("2026-07-01", dev: 0.2)])
        XCTAssertEqual(out[0].skinTempDevC, 0.2)
        XCTAssertNil(out[0].skinTempC)
    }

    func testTheRepairMovesAnImportedAbsoluteOutOfTheDeviationColumnOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("t.sqlite").path)
        let defaults = UserDefaults(suiteName: "WhoopImportSkinTempTests")!
        defaults.removePersistentDomain(forName: "WhoopImportSkinTempTests")
        let broken = (1...10).map { row(String(format: "2026-07-%02d", $0), dev: 33.5) } + [row("2026-07-11", dev: 34.3)]
        _ = try await store.upsertDailyMetrics(broken, deviceId: "my-whoop")

        let changed = await WhoopImporter.repairAbsoluteSkinTempIfNeeded(store: store, deviceId: "my-whoop",
                                                                         defaults: defaults)
        XCTAssertTrue(changed)
        let rows = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(rows.last?.skinTempC, 34.3)
        XCTAssertEqual(rows.last?.skinTempDevC ?? .nan, 0.8, accuracy: 0.01)
        XCTAssertTrue(rows.allSatisfy { ($0.skinTempDevC.map { abs($0) < 2 }) ?? true })
        let again = await WhoopImporter.repairAbsoluteSkinTempIfNeeded(store: store, deviceId: "my-whoop",
                                                                       defaults: defaults)
        XCTAssertFalse(again)
    }
}
