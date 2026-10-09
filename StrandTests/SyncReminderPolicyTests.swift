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

    /// Existing notification permission is not consent to a new automation; only a saved ON opts in.
    @MainActor
    func testReminderIsOptInAndPreservesSavedChoices() {
        let defaults = UserDefaults.standard
        let key = "behavior.syncReminder"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        let fresh = BehaviorStore()
        XCTAssertFalse(fresh.syncReminder)
        XCTAssertNil(defaults.object(forKey: key), "Reading the default must not save a user choice")
        fresh.syncReminder = true
        XCTAssertTrue(BehaviorStore().syncReminder, "A user's saved ON survives relaunch/update")
        fresh.syncReminder = false
        XCTAssertFalse(BehaviorStore().syncReminder, "A user's saved OFF survives relaunch/update")
    }
}
