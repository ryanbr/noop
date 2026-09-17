import XCTest
import WhoopStore
@testable import Strand

/// Current / Archived is a VIEW split, and the sub-minute discard is a save-time gate.
///
/// Why these are tested together: they are the two halves of one request, "keep the last 10 workouts then
/// auto delete". Auto-deleting real training history would be irreversible on a device with no server and
/// no cloud copy, so the split hides rather than removes, and the only thing actually discarded is a
/// session too short to contain training data.
final class WorkoutScopeTests: XCTestCase {

    private func row(_ startTs: Int, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: startTs + 600, sport: sport, source: "manual",
                   durationS: 600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: - The split

    func testFewerThanTheLimitPutsEverythingInCurrentAndNothingInArchived() {
        let rows = (0..<4).map { row(1_700_000_000 + $0 * 3600) }
        XCTAssertEqual(WorkoutsView.scopedRows(rows, scope: .current, currentCount: 10).count, 4)
        XCTAssertTrue(WorkoutsView.scopedRows(rows, scope: .archived, currentCount: 10).isEmpty)
    }

    func testCurrentHoldsTheMostRecentAndArchivedHoldsTheRest() {
        let rows = (0..<25).map { row(1_700_000_000 + $0 * 3600) }   // ascending
        let current = WorkoutsView.scopedRows(rows, scope: .current, currentCount: 10)
        let archived = WorkoutsView.scopedRows(rows, scope: .archived, currentCount: 10)
        XCTAssertEqual(current.count, 10)
        XCTAssertEqual(archived.count, 15)
        let newestCurrent = current.map(\.startTs).min() ?? 0
        let newestArchived = archived.map(\.startTs).max() ?? 0
        XCTAssertGreaterThan(newestCurrent, newestArchived, "every Current row is newer than every Archived one")
    }

    func testTheTwoScopesPartitionTheInputExactly() {
        // Nothing may be lost or duplicated by the split: a row the wearer cannot find in either tab has
        // effectively been deleted by the UI, which is the outcome this design exists to avoid.
        let rows = (0..<23).map { row(1_700_000_000 + $0 * 3600) }
        let combined = WorkoutsView.scopedRows(rows, scope: .current)
            + WorkoutsView.scopedRows(rows, scope: .archived)
        XCTAssertEqual(combined.count, rows.count)
        XCTAssertEqual(Set(combined.map(\.startTs)), Set(rows.map(\.startTs)))
    }

    func testTiedStartTimesCannotOverfillCurrent() {
        // Ranking, not a cutoff timestamp: twelve sessions that all start in the same second must still
        // yield exactly ten in Current. A threshold comparison would hand back all twelve.
        let rows = (0..<12).map { row(1_700_000_000, sport: "Sport\($0)") }
        XCTAssertEqual(WorkoutsView.scopedRows(rows, scope: .current, currentCount: 10).count, 10)
        XCTAssertEqual(WorkoutsView.scopedRows(rows, scope: .archived, currentCount: 10).count, 2)
    }

    func testOrderIsPreserved() {
        // The caller's sort decides what the screen shows; the split only chooses membership.
        let rows = (0..<25).map { row(1_700_000_000 + $0 * 3600) }.sorted { $0.startTs > $1.startTs }
        let current = WorkoutsView.scopedRows(rows, scope: .current)
        XCTAssertEqual(current.map(\.startTs), current.map(\.startTs).sorted(by: >))
    }

    // MARK: - The discard gate

    func testSessionsUnderAMinuteAreDiscarded() {
        XCTAssertTrue(AppModel.isTooShortToSave(elapsedSeconds: 5))
        XCTAssertTrue(AppModel.isTooShortToSave(elapsedSeconds: 30))
        XCTAssertTrue(AppModel.isTooShortToSave(elapsedSeconds: 59.9))
    }

    func testManualEntryHonoursTheSameFloor() {
        // The span-shaped builder is the one the Add/Edit sheet uses, and it had no floor: a start and end
        // thirty seconds apart made a row the live path would have discarded. The duration-shaped builder
        // enforced it only by accident, counting whole minutes.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(86_400)
        func build(_ seconds: TimeInterval) -> WorkoutRow? {
            WorkoutSource.buildManualRowFromSpan(start: start, end: start.addingTimeInterval(seconds),
                                                 sport: "Running", avgHr: nil, energyKcal: nil, now: now)
        }
        XCTAssertNil(build(30), "a 30-second manual entry is refused")
        XCTAssertNil(build(59), "just under the floor is refused")
        XCTAssertNotNil(build(60), "exactly a minute is kept, matching the live-session floor")
        XCTAssertNotNil(build(3600), "an ordinary session is unaffected")
    }

    func testTheTwoFloorsAgree() {
        // One rule, whether a session was tracked or typed in. If these ever diverge, the same workout
        // would be accepted by one door and refused by the other.
        XCTAssertEqual(Double(WorkoutSource.minManualSpanSeconds), AppModel.minimumWorkoutSeconds)
    }

    func testExactlyAMinuteIsKept() {
        // A deliberate one-minute effort is training. The gate is for what falls SHORT of a minute.
        XCTAssertFalse(AppModel.isTooShortToSave(elapsedSeconds: 60))
        XCTAssertFalse(AppModel.isTooShortToSave(elapsedSeconds: 61))
        XCTAssertFalse(AppModel.isTooShortToSave(elapsedSeconds: 3600))
    }
}
