import XCTest
import GRDB
@testable import WhoopStore

/// v40 (#1636): the nightly ABSOLUTE skin temperature, kept beside the deviation derived from it.
///
/// The engine computed this mean on every pass and discarded it once `skinTempDevC` was taken, so a
/// wearer saw "+0.5 Δ°C" with no way to learn what it moved from. Twin of the Kotlin
/// `DailySkinTempAbsoluteMigrationTest` (v33 → v34).
final class DailySkinTempAbsoluteTests: XCTestCase {

    func testV40SkinTempAbsoluteColumnPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "dailyMetric")
        XCTAssertTrue(cols.contains("skinTempC"), "dailyMetric missing v40 skinTempC column")
        // The deviation column is untouched: every existing gate (illness, Charge) still reads it.
        XCTAssertTrue(cols.contains("skinTempDevC"), "v40 must not disturb skinTempDevC")
    }

    func testV40RoundTripKeepsAbsoluteAndDeviationDistinct() async throws {
        let store = try await WhoopStore.inMemory()
        // A febrile night from the report: 34.6 °C absolute, a deviation that reads as barely anything.
        let d = DailyMetric(day: "2026-08-14", totalSleepMin: 415, efficiency: 0.9,
                            deepMin: 88, remMin: 108, lightMin: 219, disturbances: 2,
                            restingHr: 50, avgHrv: 62.0, recovery: 0.06, strain: 10.5,
                            exerciseCount: 1, spo2Pct: 96.2, skinTempDevC: 0.52, respRateBpm: 14.7,
                            steps: 7_900, activeKcalEst: 2_180.0, avgSdnn: 88.4, skinTempC: 34.6)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.skinTempC), 34.6, accuracy: 0.001,
                       "the absolute must survive the round trip")
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), 0.52, accuracy: 0.001,
                       "the deviation must persist independently of the absolute")
    }

    func testOmittingTheAbsoluteKeepsItNil() async throws {
        let store = try await WhoopStore.inMemory()
        // Every pre-#1636 call site omits it (defaulted init), and a night scored before v40 has no
        // absolute to report. Nil, never a fabricated 0.0 — which would read as a real temperature.
        let bare = DailyMetric(day: "2026-08-15", totalSleepMin: nil, efficiency: nil,
                               deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                               restingHr: nil, avgHrv: 55.0, recovery: nil, strain: nil,
                               exerciseCount: nil, skinTempDevC: 0.1)
        try await store.upsertDailyMetrics([bare], deviceId: "devA")
        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-08-15", to: "2026-08-15")
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.skinTempC, "an unscored night must not claim a temperature")
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), 0.1, accuracy: 0.001)
    }

    /// An upsert over an existing day must not blank a previously-stored absolute by omission — the
    /// DO UPDATE list has to carry the column or a later cache write silently erases it.
    func testUpsertOverAnExistingDayUpdatesTheAbsolute() async throws {
        let store = try await WhoopStore.inMemory()
        let first = DailyMetric(day: "2026-08-20", totalSleepMin: 400, efficiency: 0.9,
                                deepMin: 80, remMin: 100, lightMin: 220, disturbances: 1,
                                restingHr: 51, avgHrv: 60.0, recovery: 0.7, strain: 9.0,
                                exerciseCount: 0, skinTempC: 33.9)
        try await store.upsertDailyMetrics([first], deviceId: "devA")
        let second = DailyMetric(day: "2026-08-20", totalSleepMin: 400, efficiency: 0.9,
                                 deepMin: 80, remMin: 100, lightMin: 220, disturbances: 1,
                                 restingHr: 51, avgHrv: 60.0, recovery: 0.7, strain: 9.0,
                                 exerciseCount: 0, skinTempC: 34.4)
        try await store.upsertDailyMetrics([second], deviceId: "devA")
        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-08-20", to: "2026-08-20")
        XCTAssertEqual(rows.count, 1, "same (deviceId, day) must not duplicate")
        XCTAssertEqual(try XCTUnwrap(rows.first?.skinTempC), 34.4, accuracy: 0.001,
                       "a re-score must be able to correct the stored absolute")
    }
}
