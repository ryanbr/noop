import XCTest
@testable import Strand

/// The silent "strap not synced" reminder shows three hours after NOOP was last seen running, and never while it
/// keeps syncing: every sync moves it.
final class SyncReminderPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let synced: TimeInterval = 1_789_999_000

    func testItShowsThreeHoursAfterTheMomentThatArmedIt() {
        XCTAssertEqual(SyncReminderPolicy.fireDate(enabled: true, lastSyncedAt: synced, now: now),
                       now.addingTimeInterval(3 * 60 * 60))
    }

    /// Each completed sync re-arms it from its own moment, so a strap that keeps syncing never lets it show.
    func testEverySyncMovesItAhead() {
        let later = now.addingTimeInterval(10 * 60)
        let first = SyncReminderPolicy.fireDate(enabled: true, lastSyncedAt: synced, now: now) ?? .distantPast
        let second = SyncReminderPolicy.fireDate(enabled: true, lastSyncedAt: synced, now: later) ?? .distantPast
        XCTAssertEqual(second.timeIntervalSince(first), 10 * 60)
    }

    /// Its switch off withdraws it; a phone that never synced a strap has nothing to remind about.
    func testWithdrawnWhenOffOrWhenNoStrapEverSynced() {
        XCTAssertNil(SyncReminderPolicy.fireDate(enabled: false, lastSyncedAt: synced, now: now))
        XCTAssertNil(SyncReminderPolicy.fireDate(enabled: true, lastSyncedAt: nil, now: now))
    }
}
