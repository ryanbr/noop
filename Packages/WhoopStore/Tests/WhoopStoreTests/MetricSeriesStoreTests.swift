import XCTest
import GRDB
@testable import WhoopStore

final class MetricSeriesStoreTests: XCTestCase {

    // MARK: - migration (v9 creates the table with the right PK + index)

    func testV9CreatesMetricSeriesTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("metricSeries"))

        let pk = try await store.primaryKeyColumns("metricSeries")
        XCTAssertEqual(pk, ["deviceId", "day", "key"])

        let cols = try await store.columnNamesForTest(table: "metricSeries")
        for c in ["deviceId", "day", "key", "value"] {
            XCTAssertTrue(cols.contains(c), "metricSeries missing column \(c)")
        }
    }

    func testV9CreatesPerMetricIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "metricSeries")
        XCTAssertTrue(names.contains("idx_metricSeries_device_key_day"),
                      "v9 must create the (deviceId, key, day) index for fast per-metric reads")
    }

    func testExistingTablesStillPresentAfterV9() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric", "journal", "workout", "appleDaily"] {
            XCTAssertTrue(tables.contains(t), "v9 must not drop \(t)")
        }
    }

    // MARK: - upsert + read by key + range + ordering

    func testUpsertReadByKeyAndRangeOrdering() async throws {
        let store = try await WhoopStore.inMemory()
        // Insert out of order across two keys.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-20", key: "restingHr", value: 54),
            MetricPoint(day: "2026-05-01", key: "restingHr", value: 58),
            MetricPoint(day: "2026-05-10", key: "restingHr", value: 56),
            MetricPoint(day: "2026-05-10", key: "recovery", value: 72),
        ], deviceId: "devA")

        let hr = try await store.metricSeries(deviceId: "devA", key: "restingHr",
                                              from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(hr.map { $0.day }, ["2026-05-01", "2026-05-10", "2026-05-20"], "day ASC")
        XCTAssertEqual(hr.map { $0.value }, [58, 56, 54])
        XCTAssertEqual(hr.map { $0.key }, ["restingHr", "restingHr", "restingHr"])

        // Range filter (lexicographic compare) + key isolation.
        let ranged = try await store.metricSeries(deviceId: "devA", key: "restingHr",
                                                  from: "2026-05-05", to: "2026-05-15")
        XCTAssertEqual(ranged.map { $0.day }, ["2026-05-10"])

        let rec = try await store.metricSeries(deviceId: "devA", key: "recovery",
                                               from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec[0], MetricPoint(day: "2026-05-10", key: "recovery", value: 72))
    }

    // MARK: - idempotency + conflict-update

    func testIdempotencyAndConflictUpdate() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "recovery", value: 60),
        ], deviceId: "devA")

        // Re-upsert same (deviceId, day, key) with a new value → no duplicate, value updated.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "recovery", value: 88),
        ], deviceId: "devA")

        let rows = try await store.metricSeries(deviceId: "devA", key: "recovery",
                                                from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day,key) must not duplicate")
        XCTAssertEqual(rows[0].value, 88, "conflict must update value in place")
    }

    func testUpsertReturnsChangeCount() async throws {
        let store = try await WhoopStore.inMemory()
        let n = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-01", key: "steps", value: 9000),
            MetricPoint(day: "2026-05-02", key: "steps", value: 11000),
        ], deviceId: "devA")
        XCTAssertEqual(n, 2)
    }

    func testDeviceIsolation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "steps", value: 1),
        ], deviceId: "devA")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "steps", value: 2),
        ], deviceId: "devB")

        let a = try await store.metricSeries(deviceId: "devA", key: "steps",
                                             from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(a.map { $0.value }, [1], "must not bleed devB's row")
        let keys = try await store.metricKeys(deviceId: "devB")
        XCTAssertEqual(keys, ["steps"])
    }

    func testDeletePointUsesFullNaturalKeyAndIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-20", key: "period_start", value: 1),
            MetricPoint(day: "2026-07-21", key: "period_start", value: 1),
        ], deviceId: "noop-cycle")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-20", key: "period_start", value: 1),
        ], deviceId: "other-source")

        let firstDelete = try await store.deleteMetricSeriesPoint(
            deviceId: "noop-cycle", day: "2026-07-20", key: "period_start")
        let secondDelete = try await store.deleteMetricSeriesPoint(
            deviceId: "noop-cycle", day: "2026-07-20", key: "period_start")
        XCTAssertEqual(firstDelete, 1)
        XCTAssertEqual(secondDelete, 0)

        let cycleRows = try await store.metricSeries(
            deviceId: "noop-cycle", key: "period_start", from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(cycleRows.map(\.day), ["2026-07-21"])
        let foreignRows = try await store.metricSeries(
            deviceId: "other-source", key: "period_start", from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(foreignRows.map(\.day), ["2026-07-20"])
    }

    func testDeleteSeriesIsAtomicToSourceAndKey() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-20", key: "period_start", value: 1),
            MetricPoint(day: "2026-07-21", key: "period_start", value: 1),
            MetricPoint(day: "2026-07-21", key: "other", value: 1),
        ], deviceId: "noop-cycle")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-20", key: "period_start", value: 1),
        ], deviceId: "other-source")

        let firstDelete = try await store.deleteMetricSeries(
            deviceId: "noop-cycle", key: "period_start")
        let secondDelete = try await store.deleteMetricSeries(
            deviceId: "noop-cycle", key: "period_start")
        XCTAssertEqual(firstDelete, 2)
        XCTAssertEqual(secondDelete, 0)

        let cyclePeriodRows = try await store.metricSeries(
            deviceId: "noop-cycle", key: "period_start", from: "2026-07-01", to: "2026-07-31")
        let cycleOtherRows = try await store.metricSeries(
            deviceId: "noop-cycle", key: "other", from: "2026-07-01", to: "2026-07-31")
        let foreignRows = try await store.metricSeries(
            deviceId: "other-source", key: "period_start", from: "2026-07-01", to: "2026-07-31")
        XCTAssertTrue(cyclePeriodRows.isEmpty)
        XCTAssertEqual(cycleOtherRows.map(\.day), ["2026-07-21"])
        XCTAssertEqual(foreignRows.map(\.day), ["2026-07-20"])
    }

    // MARK: - distinct metricKeys (sorted)

    func testMetricKeysDistinctAndSorted() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-01", key: "steps", value: 1),
            MetricPoint(day: "2026-05-02", key: "steps", value: 2),     // dup key, different day
            MetricPoint(day: "2026-05-01", key: "recovery", value: 70),
            MetricPoint(day: "2026-05-01", key: "avgHrv", value: 65),
        ], deviceId: "devA")

        let keys = try await store.metricKeys(deviceId: "devA")
        XCTAssertEqual(keys, ["avgHrv", "recovery", "steps"], "distinct + sorted ascending")
    }

    func testMetricKeysEmptyForUnknownDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let keys = try await store.metricKeys(deviceId: "ghost")
        XCTAssertEqual(keys, [])
    }

    // MARK: - metricDays (min/max)

    func testMetricDaysReturnsEarliestAndLatest() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-20", key: "restingHr", value: 54),
            MetricPoint(day: "2026-05-01", key: "restingHr", value: 58),
            MetricPoint(day: "2026-05-10", key: "restingHr", value: 56),
            MetricPoint(day: "2026-06-01", key: "steps", value: 9000),
        ], deviceId: "devA")

        let span = try await store.metricDays(deviceId: "devA", key: "restingHr")
        XCTAssertEqual(span?.earliest, "2026-05-01")
        XCTAssertEqual(span?.latest, "2026-05-20")

        let stepsSpan = try await store.metricDays(deviceId: "devA", key: "steps")
        XCTAssertEqual(stepsSpan?.earliest, "2026-06-01")
        XCTAssertEqual(stepsSpan?.latest, "2026-06-01")
    }

    func testMetricDaysNilWhenAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        let span = try await store.metricDays(deviceId: "devA", key: "missing")
        XCTAssertNil(span)
    }
}
