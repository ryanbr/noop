import XCTest
import GRDB
@testable import WhoopStore

final class MetricsCacheTests: XCTestCase {

    func testV4CreatesDerivedTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("sleepSession"))
        XCTAssertTrue(tables.contains("dailyMetric"))
        let sleepPK = try await store.primaryKeyColumns("sleepSession")
        XCTAssertEqual(sleepPK, ["deviceId", "startTs"])
        let dailyPK = try await store.primaryKeyColumns("dailyMetric")
        XCTAssertEqual(dailyPK, ["deviceId", "day"])
    }

    func testSchemaVersionBumped() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 10)
    }

    // MARK: - sleep sessions

    func testSleepSessionUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let s = CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.92,
                                   restingHr: 52, avgHrv: 65.5,
                                   stagesJSON: "[{\"start\":1000,\"end\":2000,\"stage\":\"deep\"}]")
        try await store.upsertSleepSessions([s], deviceId: "devA")

        var rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], s)

        // Re-upsert the same natural key with updated values → no duplicate, value updated.
        let s2 = CachedSleepSession(startTs: 1000, endTs: 6000, efficiency: 0.95,
                                    restingHr: 50, avgHrv: 70.0, stagesJSON: nil)
        try await store.upsertSleepSessions([s2], deviceId: "devA")
        rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "same (deviceId,startTs) must not duplicate")
        XCTAssertEqual(rows[0].endTs, 6000)
        XCTAssertEqual(rows[0].efficiency, 0.95)
        XCTAssertNil(rows[0].stagesJSON)
    }

    func testSleepSessionRangeFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 100, endTs: 200, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: 500, endTs: 600, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "devA")
        let rows = try await store.sleepSessions(deviceId: "devA", from: 400, to: 1000, limit: 100)
        XCTAssertEqual(rows.map { $0.startTs }, [500])
    }

    // MARK: - daily metrics

    func testDailyMetricUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let d = DailyMetric(day: "2026-05-23", totalSleepMin: 420.0, efficiency: 0.9,
                            deepMin: 90, remMin: 110, lightMin: 220, disturbances: 3,
                            restingHr: 53, avgHrv: 60.0, recovery: 0.66, strain: 12.3, exerciseCount: 1)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        var rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], d)

        // Re-upsert same day with new values → no duplicate, value updated.
        let d2 = DailyMetric(day: "2026-05-23", totalSleepMin: 400.0, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 5,
                             restingHr: 55, avgHrv: 58.0, recovery: 0.6, strain: 14.0, exerciseCount: 2)
        try await store.upsertDailyMetrics([d2], deviceId: "devA")
        rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day) must not duplicate")
        XCTAssertEqual(rows[0], d2)
    }

    func testDailyMetricDayRangeFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-05-01", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
            DailyMetric(day: "2026-05-20", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
        ], deviceId: "devA")
        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-10", to: "2026-05-31")
        XCTAssertEqual(rows.map { $0.day }, ["2026-05-20"])
    }

    // MARK: - v7 in-sleep signal columns (spo2Pct / skinTempDevC / respRateBpm)

    func testV7ColumnsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let d = DailyMetric(day: "2026-05-26", totalSleepMin: 420, efficiency: 0.91,
                            deepMin: 90, remMin: 110, lightMin: 220, disturbances: 2,
                            restingHr: 52, avgHrv: 63.0, recovery: 0.70, strain: 11.5,
                            exerciseCount: 1, spo2Pct: 96.4, skinTempDevC: 0.3, respRateBpm: 15.2)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.spo2Pct), 96.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.respRateBpm), 15.2, accuracy: 0.001)
    }

    func testV7ColumnsNilWhenAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        // Omit the three new params — they default to nil.
        let d = DailyMetric(day: "2026-05-25", totalSleepMin: nil, efficiency: nil,
                            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                            restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].spo2Pct)
        XCTAssertNil(rows[0].skinTempDevC)
        XCTAssertNil(rows[0].respRateBpm)
    }

    func testV7UpsertUpdatesNewColumns() async throws {
        let store = try await WhoopStore.inMemory()
        // Insert with nil new columns.
        let d1 = DailyMetric(day: "2026-05-24", totalSleepMin: 400, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 3,
                             restingHr: 54, avgHrv: 60.0, recovery: 0.65, strain: 13.0, exerciseCount: 0)
        try await store.upsertDailyMetrics([d1], deviceId: "devA")

        // Re-upsert same day with new-column values populated.
        let d2 = DailyMetric(day: "2026-05-24", totalSleepMin: 400, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 3,
                             restingHr: 54, avgHrv: 60.0, recovery: 0.65, strain: 13.0, exerciseCount: 0,
                             spo2Pct: 97.1, skinTempDevC: -0.1, respRateBpm: 14.8)
        try await store.upsertDailyMetrics([d2], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "upsert must not duplicate")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.spo2Pct), 97.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), -0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.respRateBpm), 14.8, accuracy: 0.001)
    }

    // MARK: - read highwater cursor (distinct prefix from upload highwater)

    func testReadHighwaterRoundTripsUnderDistinctPrefix() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.readHighwater("hr")
        XCTAssertNil(before)
        try await store.setReadHighwater("hr", 1_716_400_000)
        let after = try await store.readHighwater("hr")
        XCTAssertEqual(after, 1_716_400_000)
        // Distinct from the upload highwater for the same stream.
        try await store.setHighwater("hr", 42)
        let uploadHW = try await store.highwater("hr")
        let readHW = try await store.readHighwater("hr")
        XCTAssertEqual(uploadHW, 42)
        XCTAssertEqual(readHW, 1_716_400_000)
        // Raw rows are stored under the distinct prefix.
        let raw = try await store.cursor("read:hr")
        XCTAssertEqual(raw, 1_716_400_000)
    }
}
