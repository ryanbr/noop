import XCTest
import GRDB
@testable import WhoopStore

final class LabMarkerStoreTests: XCTestCase {

    // MARK: - v17 migration (additive: new table + indexes, nothing else dropped)

    func testV17CreatesLabMarkerTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("labMarker"))

        let pk = try await store.primaryKeyColumns("labMarker")
        XCTAssertEqual(pk, ["id"])

        let cols = try await store.columnNamesForTest(table: "labMarker")
        for c in ["id", "deviceId", "markerKey", "category", "day", "takenAt",
                  "value", "valueText", "unit", "source", "note", "referenceText"] {
            XCTAssertTrue(cols.contains(c), "labMarker missing column \(c)")
        }
    }

    func testV17CreatesIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "labMarker")
        XCTAssertTrue(names.contains("idx_labMarker_natural"))
        XCTAssertTrue(names.contains("idx_labMarker_device_marker_takenAt"))
        XCTAssertTrue(names.contains("idx_labMarker_device_category"))
    }

    /// Additive: v17 must not drop any table that existed before it (incl. metricSeries,
    /// the projection sink).
    func testV17IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric", "journal", "workout", "appleDaily",
                  "metricSeries", "pairedDevice", "dayOwnership"] {
            XCTAssertTrue(tables.contains(t), "v17 must not drop \(t)")
        }
    }

    func testSchemaVersionIs17() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 17)
    }

    // MARK: - helpers

    private func mk(
        id: String, key: String, day: String, takenAt: Int,
        value: Double?, valueText: String? = nil, source: String = "manual",
        category: String = "bloodPanel", unit: String = "mmol/L"
    ) -> LabMarkerRow {
        LabMarkerRow(id: id, deviceId: "my-whoop", markerKey: key, category: category,
                     day: day, takenAt: takenAt, value: value, valueText: valueText,
                     unit: unit, source: source, note: nil, referenceText: nil)
    }

    // MARK: - upsert + read by marker / category / keys present

    func testUpsertReadByMarkerAndCategory() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([
            mk(id: "a", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4),
            mk(id: "b", key: "ldl", day: "2026-03-10", takenAt: 1_741_600_000, value: 3.1),
            mk(id: "c", key: "bp_systolic", day: "2026-03-10", takenAt: 1_741_600_500,
               value: 122, category: "bloodPressure", unit: "mmHg"),
        ])

        let ldl = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
        XCTAssertEqual(ldl.map { $0.takenAt }, [1_736_500_000, 1_741_600_000], "oldest first")
        XCTAssertEqual(ldl.map { $0.value }, [3.4, 3.1])

        let bp = try await store.labMarkers(deviceId: "my-whoop", category: "bloodPressure")
        XCTAssertEqual(bp.map { $0.markerKey }, ["bp_systolic"])

        let keys = try await store.markerKeysPresent(deviceId: "my-whoop")
        XCTAssertEqual(keys, ["bp_systolic", "ldl"], "distinct + sorted ascending")
    }

    // MARK: - idempotent by natural key (re-import does not duplicate)

    func testUpsertIdempotentByNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([
            mk(id: "a", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4),
        ])
        // Same (deviceId, markerKey, takenAt, source) but a fresh id + new value → UPDATE, not insert.
        try await store.upsertLabMarkers([
            mk(id: "different-id", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 2.9),
        ])

        let ldl = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
        XCTAssertEqual(ldl.count, 1, "same natural key must not duplicate")
        XCTAssertEqual(ldl[0].value, 2.9, "conflict updates value in place")
    }

    // MARK: - projection into metricSeries under lab-book

    func testWriteProjectsLatestNumericPerDayToMetricSeries() async throws {
        let store = try await WhoopStore.inMemory()
        // Two LDL readings on the SAME day — the later takenAt must win in the projection.
        try await store.upsertLabMarkers([
            mk(id: "a", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4),
            mk(id: "b", key: "ldl", day: "2026-01-10", takenAt: 1_736_590_000, value: 3.0),
            mk(id: "c", key: "ldl", day: "2026-03-10", takenAt: 1_741_600_000, value: 2.8),
        ])

        let proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                                key: "ldl", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.map { $0.day }, ["2026-01-10", "2026-03-10"])
        XCTAssertEqual(proj.map { $0.value }, [3.0, 2.8], "latest-takenAt-per-day wins")
    }

    /// A qualitative (valueText-only) reading must NOT project a row into metricSeries.
    func testQualitativeReadingDoesNotProject() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([
            mk(id: "q", key: "covid_test", day: "2026-02-01", takenAt: 1_738_400_000,
               value: nil, valueText: "negative", source: "manual", category: "appointmentNote", unit: ""),
        ])
        let proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                                key: "covid_test", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.count, 0, "valueText-only readings don't project a REAL cell")
    }

    // MARK: - delete removes the marker row AND its projected day

    func testDeleteRemovesRowAndProjection() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([
            mk(id: "a", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4),
        ])
        // Projection present.
        var proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                                key: "ldl", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.count, 1)

        let deleted = try await store.deleteLabMarker(id: "a")
        XCTAssertTrue(deleted)

        let rows = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
        XCTAssertEqual(rows.count, 0, "marker row removed")
        proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                            key: "ldl", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.count, 0, "orphaned projected day removed")
    }

    /// Deleting ONE of several same-day readings re-projects from the remainder rather
    /// than dropping the day.
    func testDeleteOneOfManyReProjectsRemainder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([
            mk(id: "a", key: "ldl", day: "2026-01-10", takenAt: 1_736_500_000, value: 3.4),
            mk(id: "b", key: "ldl", day: "2026-01-10", takenAt: 1_736_590_000, value: 3.0),
        ])
        // Latest (id b) currently projects 3.0. Delete it → 3.4 should project.
        _ = try await store.deleteLabMarker(id: "b")
        let proj = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId,
                                                key: "ldl", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(proj.map { $0.value }, [3.4], "remaining same-day reading re-projects")
    }
}
