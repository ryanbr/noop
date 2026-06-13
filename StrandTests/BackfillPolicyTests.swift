import XCTest
@testable import Strand

/// `BackfillPolicy` rate-limiter, incl. the empty-streak backoff that stops an off-wrist / not-banking
/// strap from being re-offloaded every event floor (#77/#120). Pure value logic, no CoreBluetooth seam.
final class BackfillPolicyTests: XCTestCase {
    private let fe = BackfillPolicy.eventFloorSeconds      // 90
    private let fp = BackfillPolicy.periodicFloorSeconds   // 900

    func testFirstSyncAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: nil))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: nil))
    }

    func testManualAlwaysRunsRegardlessOfFloorOrStreak() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999, emptyStreak: 99))
    }

    func testBaselineFloors() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp))
    }

    func testEmptyStreakBacksOffStrap() {
        // 200s elapsed: passes at baseline (floor 90), blocked once the 4x cap applies (floor 360).
        let last = 1000.0 - 200
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 5))
    }

    func testBackoffIsGraduatedThenCapped() {
        // streak 3 → 2x floor (180s): 100s elapsed passes at baseline, blocked at 2x.
        let last = 1000.0 - 100
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 3))
        // cap holds: a huge streak never stretches beyond 4x (floor 360); 360s elapsed still passes.
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe * 4, emptyStreak: 99))
    }

    func testBackoffNeverDelaysConnectOrForeground() {
        let last = 1000 - fe   // exactly at the baseline event floor
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: last, emptyStreak: 99))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: last, emptyStreak: 99))
    }
}
