import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// `sleep_efficiency` is a percentage everywhere it is read: an imported metricSeries point is WHOOP's
/// 0–100 figure and the catalog labels the key "%". `DailyMetric.efficiency` is the 0–1 fraction, and it
/// was passed through unscaled, so a history mixing imported and strap-only days charted ~0.9 beside ~90.
/// Twin of the Kotlin `SleepEfficiencyUnitTest`.
final class SleepEfficiencyUnitTests: XCTestCase {

    private let strapId = "my-whoop"
    private let key = "sleep_efficiency"

    private func daily(_ day: String, efficiency: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: efficiency, deepMin: 90, remMin: 100,
                    lightMin: 230, disturbances: 2, restingHr: 52, avgHrv: 70, recovery: 60, strain: 8,
                    exerciseCount: 0)
    }

    /// The literals are the expected values of the Kotlin test too. Exact equality on purpose: the two
    /// platforms must produce the same bits, FP dust included.
    func testDailyColumnReturnsPercent() {
        let cases: [(stored: Double, percent: Double)] = [
            (0.0, 0.0),
            (0.005, 0.5),
            (0.29, 28.999999999999996),
            (0.57, 56.99999999999999),
            (0.58, 57.99999999999999),
            (0.7, 70.0),
            (0.785, 78.5),
            (0.875, 87.5),
            (0.923, 92.30000000000001),
            (0.95, 95.0),
            (0.9876543210987654, 98.76543210987654),
            (1.0, 100.0),
            (1.0000000000000002, 100.00000000000003),   // FP noise above a whole night is still a fraction
            (1.5, 150.0),                               // the split itself, matching the v26 heal's `> 1.5`
            (1.5000000000000002, 1.5000000000000002),
            (62.0, 62.0),                               // Fitbit / Oura-export / Mi Band rows are percentages
            (88.5, 88.5),
            (92.3, 92.3),
            (100.0, 100.0),
        ]
        for c in cases {
            XCTAssertEqual(Repository.dailyColumn(key: key, day: daily("2026-06-12", efficiency: c.stored)),
                           c.percent, "stored \(c.stored)")
        }
        XCTAssertNil(Repository.dailyColumn(key: key, day: daily("2026-06-12", efficiency: nil)))
    }

    /// The reported shape, through both read paths the screens use (Explore reads `exploreSeries`, Compare
    /// and Lab Book read `resolvedSeries`): an import covering the older days, strap-only nights after it.
    @MainActor
    func testMixedImportedAndStrapOnlyDaysShareOneScale() async throws {
        let importedDay = Repository.localDayKey(Date().addingTimeInterval(-4 * 86_400))
        let importedNoSeriesDay = Repository.localDayKey(Date().addingTimeInterval(-3 * 86_400))
        let strapDay = Repository.localDayKey(Date().addingTimeInterval(-2 * 86_400))

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: strapId, mac: nil, name: "WHOOP")
        // An imported day carries the fraction in its row AND the percentage in its series point; the
        // series point must still win, and must not be scaled a second time.
        _ = try await store.upsertDailyMetrics([daily(importedDay, efficiency: 0.5),
                                                daily(importedNoSeriesDay, efficiency: 0.75)],
                                               deviceId: strapId)
        try await store.upsertMetricSeries([MetricPoint(day: importedDay, key: key, value: 92.3)],
                                           deviceId: strapId)
        _ = try await store.upsertDailyMetrics([daily(strapDay, efficiency: 0.875)],
                                               deviceId: strapId + "-noop")

        let repo = Repository(deviceId: strapId)
        repo.setStoreForTesting(store)
        await repo.refresh()

        let expectedDays = [importedDay, importedNoSeriesDay, strapDay]
        let expectedValues = [92.3, 75.0, 87.5]

        let explored = await repo.exploreSeries(key: key, source: strapId)
        XCTAssertEqual(explored.map(\.day), expectedDays)
        XCTAssertEqual(explored.map(\.value), expectedValues)

        let resolved = await repo.resolvedSeries(key: key, source: strapId).values
        XCTAssertEqual(resolved.map(\.day), expectedDays)
        XCTAssertEqual(resolved.map(\.value), expectedValues)
    }

    /// A row whose column already holds a percentage (the demo seeder writes one under the strap id) sits
    /// beside fraction rows without being scaled twice.
    @MainActor
    func testPercentScaleRowIsNotScaledTwice() async throws {
        let percentDay = Repository.localDayKey(Date().addingTimeInterval(-3 * 86_400))
        let fractionDay = Repository.localDayKey(Date().addingTimeInterval(-2 * 86_400))

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: strapId, mac: nil, name: "WHOOP")
        _ = try await store.upsertDailyMetrics([daily(percentDay, efficiency: 88.5),
                                                daily(fractionDay, efficiency: 0.875)],
                                               deviceId: strapId)

        let repo = Repository(deviceId: strapId)
        repo.setStoreForTesting(store)
        await repo.refresh()

        let explored = await repo.exploreSeries(key: key, source: strapId)
        XCTAssertEqual(explored.map(\.day), [percentDay, fractionDay])
        XCTAssertEqual(explored.map(\.value), [88.5, 87.5])
    }
}
