import XCTest
import WhoopStore
@testable import Strand

/// Pins the Workouts HR-zone card's parsing/aggregation to the real stored shapes:
/// the macOS importer/backfill write {"z1".."z5"}, the Android importer writes
/// {"zone1".."zone5"} for the same data — both must parse so a cache moved between
/// platforms still renders. Mirrors the Android WorkoutZonesTest case-for-case.
final class WorkoutZonesTests: XCTestCase {

    func testParsesMacKeyShape() {
        XCTAssertEqual(WorkoutZones.percents(#"{"z1":12.5,"z5":4.5}"#), [12.5, 0, 0, 0, 4.5])
    }

    func testParsesAndroidKeyShape() {
        XCTAssertEqual(WorkoutZones.percents(#"{"zone1":10,"zone2":20,"zone3":30,"zone4":25,"zone5":15}"#),
                       [10, 20, 30, 25, 15])
    }

    func testRejectsNilEmptyAndAllZero() {
        XCTAssertNil(WorkoutZones.percents(nil))
        XCTAssertNil(WorkoutZones.percents("{}"))
        XCTAssertNil(WorkoutZones.percents(#"{"z1":0}"#))
        XCTAssertNil(WorkoutZones.percents("not json"))
    }

    func testSummaryIsDurationWeighted() {
        func row(_ start: Int, _ durS: Double, _ zones: String?) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: start + Int(durS), sport: "Running", source: "whoop",
                       durationS: durS, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: zones, notes: nil, steps: nil)
        }
        let s = WorkoutZones.summary(from: [
            row(0, 3600, #"{"z1":100}"#),          // 60 min all Z1
            row(10_000, 1800, #"{"zone5":100}"#),  // 30 min all Z5 (Android key shape)
            row(20_000, 1800, nil),                // no zones — excluded from the count
        ])
        XCTAssertEqual(s?.sessionsWithZones, 2)
        XCTAssertEqual(s?.minutes[0] ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(s?.minutes[4] ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(s?.totalMinutes ?? 0, 90, accuracy: 1e-9)
    }
}
