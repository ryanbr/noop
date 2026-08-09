import XCTest
@testable import WhoopStore

final class ScoreInputProvenanceStoreTests: XCTestCase {
    func testMigrationCreatesMetricLevelTableAndIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("scoreInputProvenance")
        let indexes = try await store.indexNamesForTest(table: "scoreInputProvenance")
        XCTAssertTrue(tables.contains("scoreInputProvenance"))
        XCTAssertEqual(primaryKey, ["deviceId", "day", "key"])
        XCTAssertTrue(indexes.contains("idx_scoreInputProvenance_source"))
    }

    func testComputedScoresAndProvenancePersistTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let daily = makeDaily(day: "2026-07-24", recovery: 71, strain: 42)
        let rest = MetricPoint(day: daily.day, key: "sleep_performance", value: 83)
        let provenance = [
            ScoreInputProvenanceRow(day: daily.day, key: "recovery", sourceId: "polar-1"),
            ScoreInputProvenanceRow(day: daily.day, key: "strain", sourceId: "polar-1"),
            ScoreInputProvenanceRow(day: daily.day, key: "sleep_performance", sourceId: "polar-1"),
        ]

        try await store.persistComputedScores(
            dailyMetrics: [daily],
            metricPoints: [rest],
            provenance: provenance,
            deviceId: "my-whoop-noop",
            from: daily.day,
            to: daily.day
        )

        let storedDaily = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: daily.day, to: daily.day
        )
        let source = try await store.scoreInputSource(
            deviceId: "my-whoop-noop", day: daily.day, key: "recovery"
        )
        XCTAssertEqual(storedDaily.first?.recovery, 71)
        XCTAssertEqual(source, "polar-1")
    }

    func testReplacingWindowRemovesProvenanceForMissingMetric() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-07-24"
        try await store.persistComputedScores(
            dailyMetrics: [makeDaily(day: day, recovery: 71, strain: 42)],
            metricPoints: [],
            provenance: [
                .init(day: day, key: "recovery", sourceId: "polar-1"),
                .init(day: day, key: "strain", sourceId: "polar-1"),
            ],
            deviceId: "my-whoop-noop",
            from: day,
            to: day
        )
        try await store.persistComputedScores(
            dailyMetrics: [makeDaily(day: day, recovery: 72, strain: nil)],
            metricPoints: [],
            provenance: [.init(day: day, key: "recovery", sourceId: "oura-api")],
            deviceId: "my-whoop-noop",
            from: day,
            to: day
        )

        let recoverySource = try await store.scoreInputSource(
            deviceId: "my-whoop-noop", day: day, key: "recovery"
        )
        let strainSource = try await store.scoreInputSource(
            deviceId: "my-whoop-noop", day: day, key: "strain"
        )
        XCTAssertEqual(recoverySource, "oura-api")
        XCTAssertNil(strainSource)
    }

    func testEmptyPassDoesNotWipeExistingWindow() async throws {
        // #1196: a scoring pass that produced NO daily rows must not destructively rewrite the window.
        // Before the guard, an empty pass still ran the provenance wide-delete and blanked the window's
        // attribution; the guard makes an empty pass a no-op so recovery/strain/streak history survives a
        // transient/degenerate empty pass (the "0 days / lost streak" flicker during an offload storm).
        let store = try await WhoopStore.inMemory()
        let day = "2026-07-24"
        try await store.persistComputedScores(
            dailyMetrics: [makeDaily(day: day, recovery: 71, strain: 42)],
            metricPoints: [],
            provenance: [.init(day: day, key: "recovery", sourceId: "polar-1")],
            deviceId: "my-whoop-noop", from: day, to: day
        )
        // An EMPTY pass over the same window must leave the stored row + provenance untouched.
        try await store.persistComputedScores(
            dailyMetrics: [],
            metricPoints: [],
            provenance: [],
            deviceId: "my-whoop-noop", from: day, to: day
        )
        let storedDaily = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: day, to: day)
        let source = try await store.scoreInputSource(deviceId: "my-whoop-noop", day: day, key: "recovery")
        XCTAssertEqual(storedDaily.first?.recovery, 71)   // window not wiped
        XCTAssertEqual(source, "polar-1")                 // provenance not wiped
    }

    private func makeDaily(day: String, recovery: Double?, strain: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: recovery,
            strain: strain,
            exerciseCount: nil
        )
    }
}
