import XCTest
@testable import WhoopStore

final class ScoreInputProvenanceStoreTests: XCTestCase {
    private let stamp = ScoreComputationStamp(
        computedBy: "apple:10.5.0+221", computedAt: 1_724_460_000_000)

    func testMigrationCreatesMetricLevelTableAndIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("scoreInputProvenance")
        let indexes = try await store.indexNamesForTest(table: "scoreInputProvenance")
        let computationPrimaryKey = try await store.primaryKeyColumns("scoreComputationProvenance")
        let computationIndexes = try await store.indexNamesForTest(table: "scoreComputationProvenance")
        XCTAssertTrue(tables.contains("scoreInputProvenance"))
        XCTAssertTrue(tables.contains("scoreComputationProvenance"))
        XCTAssertEqual(primaryKey, ["deviceId", "day", "key"])
        XCTAssertEqual(computationPrimaryKey, ["deviceId", "day", "key"])
        XCTAssertTrue(indexes.contains("idx_scoreInputProvenance_source"))
        XCTAssertTrue(computationIndexes.contains("idx_scoreComputationProvenance_computedBy"))
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
            computation: stamp,
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
        let recoveryBuild = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: daily.day, key: "recovery")
        let restBuild = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: daily.day, key: "sleep_performance")
        XCTAssertEqual(storedDaily.first?.recovery, 71)
        XCTAssertEqual(source, "polar-1")
        XCTAssertEqual(recoveryBuild?.computedBy, stamp.computedBy)
        XCTAssertEqual(recoveryBuild?.computedAt, stamp.computedAt)
        XCTAssertEqual(recoveryBuild?.scope, .scoreWindow)
        XCTAssertEqual(restBuild?.computedBy, stamp.computedBy)
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
            computation: stamp,
            deviceId: "my-whoop-noop",
            from: day,
            to: day
        )
        try await store.persistComputedScores(
            dailyMetrics: [makeDaily(day: day, recovery: 72, strain: nil)],
            metricPoints: [],
            provenance: [.init(day: day, key: "recovery", sourceId: "oura-api")],
            computation: .init(computedBy: "apple:10.5.1+222", computedAt: stamp.computedAt + 1),
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
        let recoveryBuild = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: day, key: "recovery")
        let strainBuild = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: day, key: "strain")
        XCTAssertEqual(recoverySource, "oura-api")
        XCTAssertNil(strainSource)
        XCTAssertEqual(recoveryBuild?.computedBy, "apple:10.5.1+222")
        XCTAssertNil(strainBuild)
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
            computation: stamp,
            deviceId: "my-whoop-noop", from: day, to: day
        )
        // An EMPTY pass over the same window must leave the stored row + provenance untouched.
        try await store.persistComputedScores(
            dailyMetrics: [],
            metricPoints: [],
            provenance: [],
            computation: .init(computedBy: "apple:bad+pass", computedAt: stamp.computedAt + 1),
            deviceId: "my-whoop-noop", from: day, to: day
        )
        let storedDaily = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: day, to: day)
        let source = try await store.scoreInputSource(deviceId: "my-whoop-noop", day: day, key: "recovery")
        let build = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: day, key: "recovery")
        XCTAssertEqual(storedDaily.first?.recovery, 71)   // window not wiped
        XCTAssertEqual(source, "polar-1")                 // provenance not wiped
        XCTAssertEqual(build?.computedBy, stamp.computedBy)
    }

    func testVo2MaxValueAndEstimatorPersistTogetherAndSurviveDailyRescore() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-07-25"
        try await store.persistMetricSeriesWithProvenance(
            points: [MetricPoint(day: day, key: "vo2max_est", value: 48)],
            provenance: [ScoreInputProvenanceRow(day: day, key: "vo2max_est", sourceId: "nes")],
            computation: stamp,
            deviceId: "my-whoop-noop"
        )

        // A normal daily-score replacement spans this Saturday but does not own weekly VO₂max metadata.
        try await store.persistComputedScores(
            dailyMetrics: [makeDaily(day: day, recovery: 71, strain: 42)],
            metricPoints: [],
            provenance: [.init(day: day, key: "recovery", sourceId: "my-whoop")],
            computation: .init(computedBy: "apple:10.5.1+222", computedAt: stamp.computedAt + 1),
            deviceId: "my-whoop-noop",
            from: day,
            to: day
        )

        let points = try await store.metricSeries(
            deviceId: "my-whoop-noop", key: "vo2max_est", from: day, to: day)
        let estimator = try await store.scoreInputSource(
            deviceId: "my-whoop-noop", day: day, key: "vo2max_est")
        let vo2Build = try await store.scoreComputationProvenance(
            deviceId: "my-whoop-noop", day: day, key: "vo2max_est")
        XCTAssertEqual(points.first?.value, 48)
        XCTAssertEqual(estimator, Vo2MaxEstimator.nes.rawValue)
        XCTAssertEqual(vo2Build?.computedBy, stamp.computedBy)
        XCTAssertEqual(vo2Build?.scope, .metricSeries)
    }

    func testBuildIdentityIncludesPlatformVersionAndBuild() {
        XCTAssertEqual(
            ScoreComputationStamp.buildIdentity(
                platform: "android", appVersion: "10.5.0", appBuild: "221"),
            "android:10.5.0+221"
        )
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
