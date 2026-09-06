import Foundation
import UserNotifications

/// The wind-down nudge (#207) — a gentle, NON-critical evening local notification suggesting it's
/// time to start winding down so the user can reach their usual wake time well-rested.
///
/// Cross-platform (macOS + iOS): a sideloaded backgrounded app can't fire a dependable LOUD wake
/// alarm (no critical-alert entitlement), but it CAN post a calm daily reminder. The nudge fires on a
/// repeating calendar trigger at a time DERIVED from the user's earliest wake time minus their usual
/// sleep need minus a short lead. State is its own UserDefaults-backed store so it doesn't couple to
/// the shared BehaviorStore. On-device only; nothing is sent anywhere.
@MainActor
enum WindDownNudge {

    private static let requestId = "wind-down-nudge"

    // MARK: - Persisted settings (own keys; default OFF, opt-in like every automation)

    private enum K {
        static let enabled = "windDown.enabled"
        static let sleepNeed = "windDown.sleepNeedMinutes"   // default 8h
        static let lead = "windDown.leadMinutes"             // default 30m
        static let wake = "windDown.wakeMinutes"             // earliest wake, minutes since midnight
        // PR#554 (MumiZed) — per-day wake overrides. A JSON map of {weekday(1=Sun…7=Sat): wakeMinutes}.
        // Empty / no entry for a day = that day uses the default `wakeMinutes`, so the feature is purely
        // additive (no override → exactly the old single-time behaviour).
        static let perDayWake = "windDown.perDayWakeMinutes"
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    static var sleepNeedMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.sleepNeed) as? Int ?? 8 * 60
        return min(max(v, 5 * 60), 11 * 60)
    }

    static var leadMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.lead) as? Int ?? 30
        return min(max(v, 0), 120)
    }

    static var wakeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.wake) as? Int ?? 7 * 60   // 07:00
        return min(max(v, 0), 24 * 60 - 1)
    }

    // MARK: - Per-day wake overrides (PR#554)

    /// The stored per-weekday wake overrides — {weekday(1=Sun…7=Sat): wakeMinutes}. Empty when the user
    /// hasn't set any (the common case), so every day falls back to the single `wakeMinutes`. Values are
    /// clamped to a valid minute-of-day on read so a corrupt blob can't schedule at a nonsense time.
    static var perDayWakeOverrides: [Int: Int] {
        guard let data = UserDefaults.standard.data(forKey: K.perDayWake),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw {
            guard let day = Int(k), (1...7).contains(day) else { continue }
            out[day] = min(max(v, 0), 24 * 60 - 1)
        }
        return out
    }

    /// The wake time used for a given Calendar weekday (1=Sun…7=Sat) — the per-day override if set, else the
    /// default `wakeMinutes`. The single source of truth both the schedule and the UI read, so they agree.
    static func wakeMinutes(forWeekday weekday: Int) -> Int {
        perDayWakeOverrides[weekday] ?? wakeMinutes
    }

    /// Whether ANY per-day override is set — drives whether scheduling fans out to 7 per-weekday triggers
    /// (overrides present) or keeps the single daily trigger (none).
    static var hasPerDayOverrides: Bool { !perDayWakeOverrides.isEmpty }

    /// Set or clear a single weekday's wake override (pass nil to clear → that day reverts to the default),
    /// rescheduling if enabled. Clamps the minute-of-day so a bad value can't be stored.
    static func setWakeOverride(weekday: Int, minutes: Int?) {
        guard (1...7).contains(weekday) else { return }
        var map = perDayWakeOverrides
        if let m = minutes {
            map[weekday] = min(max(m, 0), 24 * 60 - 1)
        } else {
            map.removeValue(forKey: weekday)
        }
        let encodable = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: K.perDayWake)
        }
        if isEnabled { schedule() }
    }

    /// The nudge minute-of-day for a given weekday — that day's wake (override or default) minus sleep need
    /// minus lead, wrapped into [0, 1440). Pure; mirrors `nudgeMinuteOfDay()` per-day. (PR#554)
    static func nudgeMinuteOfDay(forWeekday weekday: Int) -> Int {
        let raw = wakeMinutes(forWeekday: weekday) - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    /// The day shift for a given weekday's nudge — 0 if the nudge lands on the same day as the wake,
    /// -1 if it wraps to the previous evening. The minute-of-day wrap in `nudgeMinuteOfDay` silently
    /// loses which day the nudge belongs to; this companion carries that information so the scheduler
    /// can pin the trigger to the nudge's day, not the wake's. (#1863)
    ///
    /// `raw` is always in [-780, 1139] given the clamped inputs (wake ≤ 1439, sleepNeed ≥ 300, lead ≤ 120),
    /// so the shift is always 0 or -1 — but the formula is general floor-division for safety.
    static func nudgeDayShift(forWeekday weekday: Int) -> Int {
        let raw = wakeMinutes(forWeekday: weekday) - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        // Floor division (Swift's `/` truncates toward zero, so adjust for negatives).
        return raw < 0 ? -(((-raw - 1) / day) + 1) : raw / day
    }

    /// Shift a Calendar weekday (1=Sun…7=Sat) by a day count, wrapping through the week end. (#1863)
    /// `shiftedWeekday(weekday: 1, by: -1)` → 7 (Sunday's evening-before nudge fires on Saturday).
    static func shiftedWeekday(weekday: Int, by shift: Int) -> Int {
        let zeroBased = weekday - 1 + shift
        return ((zeroBased % 7) + 7) % 7 + 1
    }

    // MARK: - Public API

    /// The result of enabling the nudge — lets the UI react instead of silently persisting an "on" toggle
    /// that can never fire. `.denied` means the OS won't deliver (permission off), so the caller should
    /// revert the switch and point the user at Settings.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization FIRST — mirroring the
    /// smart-alarm backup path in `AppModel.scheduleSmartAlarmBackupNotification`: if undetermined it asks
    /// once and schedules on grant; if already denied it reports back rather than persisting a dead toggle.
    ///
    /// Why this matters: the old version called `requestAuthorization` with an empty completion and then
    /// scheduled unconditionally. `requestAuthorization` only shows the system dialog when the status is
    /// `.notDetermined`; once a user (or a prior sideload install with the same bundle id) has denied, the
    /// dialog never returns and the app silently scheduled reminders the OS would never deliver — with
    /// nothing in the UI to explain it. Now denial surfaces.
    ///
    /// `completion` always runs on the main actor (the settings/authorization callbacks fire off-main).
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            // Clear the single trigger AND any per-day triggers (PR#554) so disabling leaves nothing behind.
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId] + perDayRequestIds)
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    // First ask — the system dialog appears now (a predictable moment), then we schedule on
                    // grant so the FIRST night is covered rather than only after some later re-arm.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: K.enabled)
                                schedule()
                                completion?(.scheduled)
                            } else {
                                UserDefaults.standard.set(false, forKey: K.enabled)
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    // .denied (or any future non-authorized case) — don't fake an enabled toggle. The caller
                    // surfaces a "notifications are off" prompt with a jump to Settings.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Update the earliest wake time the nudge is derived from, rescheduling if enabled.
    static func setWakeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.wake)
        if isEnabled { schedule() }
    }

    /// The minute-of-day the nudge fires: wake − sleepNeed − lead, wrapped into [0, 1440).
    static func nudgeMinuteOfDay() -> Int {
        let raw = wakeMinutes - sleepNeedMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    // MARK: - Scheduling

    /// Per-weekday request ids — cleared alongside the single id so toggling overrides on/off never leaves
    /// a stale trigger behind.
    private static var perDayRequestIds: [String] { (1...7).map { "\(requestId)-wd\($0)" } }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        // Clear BOTH the single trigger and any per-day triggers so switching between the two modes (or
        // editing an override) never double-fires or leaves an orphaned reminder.
        center.removePendingNotificationRequests(withIdentifiers: [requestId] + perDayRequestIds)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to wind down")
        content.body = String(localized: "A calm hour now helps you hit your wake time well-rested.")
        content.sound = .default

        // PR#554 — with per-day overrides set, fan out to seven weekday-pinned triggers each at that day's
        // own nudge time; with none, keep the single daily trigger (identical to the pre-#554 behaviour).
        if hasPerDayOverrides {
            for weekday in 1...7 {
                let minute = nudgeMinuteOfDay(forWeekday: weekday)
                // #1863 — an early wake (e.g. 03:30) wraps the nudge minute to the previous evening
                // (19:00). The minute wrap alone loses which DAY that evening belongs to, so the trigger
                // was pinned to the wake's own weekday — firing 8+ hours AFTER the wake it precedes.
                // Derive the day shift and pin the trigger to the nudge's day, not the wake's.
                let shift = nudgeDayShift(forWeekday: weekday)
                var comps = DateComponents()
                comps.weekday = shiftedWeekday(weekday: weekday, by: shift)   // the nudge's day
                comps.hour = minute / 60
                comps.minute = minute % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                // The request id stays keyed to the wake's weekday so toggling/clearing overrides
                // always matches the ids `perDayRequestIds` enumerates.
                center.add(UNNotificationRequest(identifier: "\(requestId)-wd\(weekday)",
                                                 content: content, trigger: trigger))
            }
            return
        }

        let minute = nudgeMinuteOfDay()
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // repeats: true → a daily calendar trigger; survives relaunch (it lives in the notification
        // center, not the process), so the nudge keeps firing each evening without the app running.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}
