#if os(iOS)
import Foundation
import UserNotifications

/// Keeps the one pending "strap not synced" notification where `SyncReminderPolicy` says: moved ahead at every
/// completed sync and every move on or off screen, withdrawn when the switch is off. Each call replaces the same
/// request (`SyncReminderPolicy.identifier`), so there is never more than one. Without notification permission
/// iOS simply never shows it; NOOP does not ask for permission here (the Settings switch does, when turned on).
@MainActor
enum SyncReminder {

    /// Said once per run: the first arm is the evidence a tester's log needs, and the re-arms after every sync
    /// would only repeat it.
    private static var armLogged = false

    static func rearm(enabled: Bool, lastSyncedAt: TimeInterval?, log: (String) -> Void) {
        let center = UNUserNotificationCenter.current()
        guard let fire = SyncReminderPolicy.fireDate(enabled: enabled, lastSyncedAt: lastSyncedAt, now: Date()) else {
            center.removePendingNotificationRequests(withIdentifiers: [SyncReminderPolicy.identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Strap not synced")
        content.body = String(localized: "NOOP hasn't synced your strap in the last 3 hours. Open NOOP to resume syncing.")
        content.interruptionLevel = .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: SyncReminderPolicy.identifier, content: content, trigger: trigger))
        if !armLogged {
            armLogged = true
            let time = fire.formatted(date: .omitted, time: .shortened)
            log("Sync reminder: armed for \(time); every sync moves it 3 h ahead, so it shows only if syncing stops")
        }
    }

    /// Asked when the switch is turned on, the way every other notification switch asks.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// NOOP is on screen: a reminder already delivered describes a gap that is over.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [SyncReminderPolicy.identifier])
    }
}
#endif
