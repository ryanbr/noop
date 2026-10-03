import Foundation

/// The silent "strap not synced" reminder (iOS).
///
/// Swiping NOOP away ends it, and iOS does not start a force-quit app again for Bluetooth: syncing stops until
/// NOOP is opened, and nothing says so. A tester swipes it away now and then, and the strap's history then waits
/// for the next open (Sep–Oct 2026). Android needs none of this: its foreground service survives a swipe.
///
/// So NOOP keeps ONE pending local notification and pushes it `quietInterval` ahead at every completed sync and
/// whenever it comes on screen or leaves it. While NOOP syncs, the reminder keeps moving and never shows. Once
/// syncing stops — NOOP swiped away, or the strap out of reach — it shows, `quietInterval` after the last of
/// those moments. It is delivered passively: no sound, no screen wake, only a line on the Lock Screen.
///
/// Pure and platform-free so `StrandTests` covers it; `SyncReminder` (iOS) schedules what this decides.
enum SyncReminderPolicy {

    /// The one request's identifier: each re-arm replaces it rather than adding another.
    static let identifier = "noop.syncReminder"

    /// How long without a sync before the reminder shows. The copy names it ("in the last 3 hours").
    static let quietInterval: TimeInterval = 3 * 60 * 60

    /// When the reminder shows unless something moves it first, or nil to withdraw it. `enabled`: the Settings
    /// switch. `lastSyncedAt`: the last completed sync, nil on a phone that has never synced a strap, where there
    /// is nothing to remind about. `now`: the sync, or the move on or off screen, that re-arms it — every moment
    /// NOOP was demonstrably running, so the reminder never fires sooner than `quietInterval` after one.
    static func fireDate(enabled: Bool, lastSyncedAt: TimeInterval?, now: Date) -> Date? {
        guard enabled, lastSyncedAt != nil else { return nil }
        return now.addingTimeInterval(quietInterval)
    }
}
