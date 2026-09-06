import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
import WidgetKit
#endif

/// PRD-K5: a user-scheduled, LOCAL notification that delivers a one-line morning coaching brief,
/// generated on-device via the user's already-configured Coach provider, at a chosen time each day.
/// Tap → opens Coach with the full brief. No push server, no cloud — the network call is the SAME
/// bring-your-own-key request Coach already makes on every send, just user-armed on a daily timer
/// instead of triggered by a tap. Default OFF, like every NOOP automation.
///
/// Cross-platform (macOS + iOS), same architecture as `ScheduledDebugExport`:
/// - **macOS** — the app is usually running; a foreground `DispatchSourceTimer` fires at the chosen
///   minute, and `catchUpIfDue` covers the time having passed while the app wasn't open.
/// - **iOS** — a sideloaded, backgrounded app can't guarantee a wake at the exact minute. A
///   `BGAppRefreshTaskRequest` is submitted for *no earlier than* the chosen time; iOS decides when it
///   actually runs. If the slot is missed entirely (app never woken), the next foreground open's
///   `activateIfEnabled` catches up and generates then instead — same honest "best-effort" posture
///   `ScheduledDebugExport`'s Settings copy already uses.
///
/// Triple-gated network call: `enabled` (this feature, default OFF) + a saved Coach key + the existing
/// `dataConsent`. `generateBrief` is `AICoachEngine.generateBrief()`, itself gated on both of those; this
/// scheduler additionally never marks a day "done" on a failed generation, so a missing key/consent (or
/// a transient network failure) simply retries next wake rather than going permanently silent.
@MainActor
enum CoachBriefScheduler {

    // MARK: - Persisted settings (own keys; mirrors ScheduledDebugExport's shape)

    private enum K {
        static let enabled = "coachBrief.enabled"          // master enable; default OFF
        static let time = "coachBrief.timeMinutes"         // minutes since local midnight; default 07:00
        static let lastRun = "coachBrief.lastRunDayKey"    // yyyy-MM-dd of the last GENERATED brief (dedup)
        static let storedBrief = "coachBrief.storedText"   // the full brief, for the notification tap-through
        static let hasUnconsumed = "coachBrief.hasUnconsumedBrief"
        // K10: the brief text mirrored into the App Group so the widget extension (separate process)
        // can read it. The app's own UserDefaults.standard isn't visible to the widget.
        static let widgetBriefKey = "coachBrief.widgetText"
        static let widgetBriefDateKey = "coachBrief.widgetDate"
    }

    /// 07:00 — a brief waiting when you check your phone (matches `ScheduledDebugExport`'s default).
    static let defaultTimeMinutes = 7 * 60
    private static let minutesPerDay = 24 * 60

    /// Category id the posted notification carries, so `NotificationPresenter` can recognise a brief tap
    /// (as opposed to any other local notification) and route it to Coach.
    static let notificationCategoryId = "coach-brief"
    private static let requestIdPrefix = "coach-brief-"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// Time-of-day to generate, minutes since local midnight. Clamped to a valid minute. Default 07:00.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(v, 0), minutesPerDay - 1)
    }

    /// The most recently generated full brief text (for the notification tap-through), or nil before the
    /// first successful generation.
    static var storedBrief: String? { UserDefaults.standard.string(forKey: K.storedBrief) }

    /// True when a generated brief hasn't yet been surfaced in the Coach transcript. Set right after a
    /// successful generation; cleared by `consumeStoredBrief()`.
    static var hasUnconsumedBrief: Bool { UserDefaults.standard.bool(forKey: K.hasUnconsumed) }

    /// Coach reads this once (on appear, with an empty transcript) to surface the stored brief as its
    /// first message without re-generating or re-sending anything. Returns nil (and leaves state
    /// untouched) when there's nothing unconsumed, so a normal open is unaffected.
    static func consumeStoredBrief() -> String? {
        guard hasUnconsumedBrief, let text = storedBrief else { return nil }
        UserDefaults.standard.set(false, forKey: K.hasUnconsumed)
        return text
    }

    // MARK: - K10: Widget-facing API (App Group, iOS only)

    #if os(iOS)
    /// The stored brief text for the widget (App Group), or nil before the first successful generation.
    /// The widget extension reads this — it can't see the app's `UserDefaults.standard`.
    static var widgetBriefText: String? {
        UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: K.widgetBriefKey)
    }

    /// Wall-clock date the widget brief was generated, so the widget can show honest staleness.
    static var widgetBriefDate: Date? {
        UserDefaults(suiteName: WidgetSnapshot.suiteName)?.object(forKey: K.widgetBriefDateKey) as? Date
    }

    /// Publish (or clear) the brief into the App Group so the widget extension can read it. Called
    /// from `catchUpIfDue` / `generateNow` after a successful generation, and from `setEnabled(false)`
    /// to clear the widget when the user turns the feature off.
    static func publishToWidget(_ text: String?) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return }
        if let text {
            defaults.set(text, forKey: K.widgetBriefKey)
            defaults.set(Date(), forKey: K.widgetBriefDateKey)
        } else {
            defaults.removeObject(forKey: K.widgetBriefKey)
            defaults.removeObject(forKey: K.widgetBriefDateKey)
        }
        // Nudge WidgetKit to reload the coach-brief widget's timeline so it picks up the new text
        // without waiting for the next scheduled refresh. The kind string must match the widget's
        // `kind` property (see CoachBriefWidget.swift in StrandiOSWidgets).
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
    #endif

    /// The WidgetKit kind string for the coach-brief widget. Must match the `kind` property on
    /// `CoachBriefWidget` in `StrandiOSWidgets/`. Declared here so `publishToWidget` can reload
    /// timelines without importing the widget extension's type (the app target can't see it).
    static let widgetKind = "CoachBriefWidget"

    // MARK: - Enable / configure (Settings calls these)

    /// The result of enabling the schedule — mirrors `WindDownNudge.EnableOutcome` so the UI can revert
    /// the toggle and point at Settings on denial instead of persisting a dead "on" state.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization first (asks once if
    /// undetermined; reports `.denied` rather than silently scheduling something the OS will never
    /// deliver). `completion` always runs on the main actor.
    static func setEnabled(_ on: Bool,
                            generateBrief: @escaping () async -> String?,
                            completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            cancel()
            #if os(iOS)
            publishToWidget(nil)  // K10: clear the widget when the feature is turned off
            #endif
            completion?(.off)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    scheduleNext(generateBrief: generateBrief)
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: K.enabled)
                                scheduleNext(generateBrief: generateBrief)
                                completion?(.scheduled)
                            } else {
                                UserDefaults.standard.set(false, forKey: K.enabled)
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Update the time-of-day and reschedule so the new time takes effect immediately.
    static func setTimeMinutes(_ minutes: Int, generateBrief: @escaping () async -> String?) {
        UserDefaults.standard.set(min(max(minutes, 0), minutesPerDay - 1), forKey: K.time)
        if isEnabled { scheduleNext(generateBrief: generateBrief) }
    }

    /// Call whenever Coach (or its settings) appears so the schedule self-heals (re-arms the macOS timer
    /// after a relaunch, re-submits the iOS request) and a slot missed while the app wasn't open still
    /// generates once. No-op when the feature is off.
    static func activateIfEnabled(generateBrief: @escaping () async -> String?) {
        guard isEnabled else { return }
        scheduleNext(generateBrief: generateBrief)
        Task { await catchUpIfDue(generateBrief: generateBrief) }
    }

    /// The explicit "Generate now" button: always generates and stores, ignoring the once-per-day dedup,
    /// so a tap produces a fresh brief there and then. Does NOT post a notification (the user is already
    /// looking at Coach) and does NOT touch `lastRun`, so today's scheduled slot still fires normally.
    /// Returns the brief text, or nil on failure (no key/consent/network) — the caller surfaces that.
    @discardableResult
    static func generateNow(generateBrief: () async -> String?) async -> String? {
        await generateBrief()
    }

    // MARK: - Due check + generation

    /// If today's brief is due (we're at/after the chosen time and haven't generated today), generate it
    /// once: store the text, mark today done, and post the notification. Covers macOS launches where the
    /// time passed while the app wasn't open, and the iOS foreground/BGTask paths.
    ///
    /// Returns whether this call can be considered successful: `true` when there was nothing to do
    /// (feature off, not yet time, or already ran today) or generation succeeded; `false` only when
    /// generation was attempted and failed (so the iOS BGTask handler can report the real outcome and
    /// retry on the next wake instead of marking the day done on a failure).
    @discardableResult
    static func catchUpIfDue(generateBrief: () async -> String?) async -> Bool {
        guard isEnabled else { return true }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= timeMinutes else { return true }                                  // not yet time today
        guard UserDefaults.standard.string(forKey: K.lastRun) != dayKey(now) else { return true } // already ran today

        guard let text = await generateBrief() else {
            // No key/consent/network, or the provider returned nothing. Never mark the day done, so the
            // next wake (BGTask retry, or the next foreground open) tries again. Post a low-key retry
            // notification rather than silently doing nothing — the PRD's "unavailable, tap to retry".
            postNotification(title: String(localized: "Coach brief unavailable"),
                              body: String(localized: "Couldn't generate today's brief. Tap to try again in Coach."),
                              isRetry: true)
            return false
        }

        UserDefaults.standard.set(dayKey(now), forKey: K.lastRun)
        UserDefaults.standard.set(text, forKey: K.storedBrief)
        UserDefaults.standard.set(true, forKey: K.hasUnconsumed)
        #if os(iOS)
        publishToWidget(text)  // K10: mirror into the App Group for the widget
        #endif
        postNotification(title: String(localized: "Today's coaching brief"),
                          body: oneLineSummary(from: text))
        return true
    }

    /// Pure: the notification body is the brief's first non-empty line, trimmed and length-capped so it
    /// fits a notification banner. Unit-testable without any I/O.
    static func oneLineSummary(from brief: String, maxLength: Int = 120) -> String {
        let firstLine = brief
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? brief
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return trimmed[..<cut].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func postNotification(title: String, body: String, isRetry: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = notificationCategoryId
        // Immediate delivery (trigger nil) — this fires the moment generation completes, it is not a
        // pre-scheduled fixed-content trigger like `WindDownNudge`'s. One id per day, so a retry
        // replaces rather than stacks the earlier attempt's notification.
        let request = UNNotificationRequest(identifier: requestIdPrefix + dayKey(Date()),
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// yyyy-MM-dd local-day key for the once-per-day dedup. POSIX locale so the key is stable everywhere.
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Seconds from now until the next wall-clock occurrence of `minuteOfDay` (today if still ahead, else
    /// tomorrow). Mirrors `ScheduledDebugExport.secondsToNextOccurrence`.
    private static func secondsToNextOccurrence(_ minuteOfDay: Int, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        comps.second = 0
        var target = cal.date(from: comps) ?? now
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return max(1, target.timeIntervalSince(now))
    }

    // MARK: - Scheduling

    private static var macTimer: DispatchSourceTimer?

    /// (Re)arm the next occurrence. macOS uses a foreground `DispatchSourceTimer`; iOS submits a
    /// background-refresh request. Both target the next wall-clock occurrence of `timeMinutes`.
    private static func scheduleNext(generateBrief: @escaping () async -> String?) {
        #if os(macOS)
        macTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = secondsToNextOccurrence(timeMinutes)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            Task { @MainActor in
                guard isEnabled else { return }
                _ = await catchUpIfDue(generateBrief: generateBrief)
                scheduleNext(generateBrief: generateBrief)
            }
        }
        timer.resume()
        macTimer = timer
        #elseif os(iOS)
        submitBackgroundRequest()
        #endif
    }

    /// Cancel any armed schedule.
    private static func cancel() {
        #if os(macOS)
        macTimer?.cancel()
        macTimer = nil
        #elseif os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        #endif
    }

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// iOS BGTask identifier, derived from the running bundle id so it tracks `BUNDLE_ID_PREFIX` and
    /// matches the iOS target's `BGTaskSchedulerPermittedIdentifiers` (Info.plist / project.yml).
    static let bgTaskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".coachbrief"

    /// Register the BGTask handler. MUST be called from the app's launch (before launch finishes) — call
    /// this from `StrandiOSApp.init()` with `{ [weak coach] in await coach?.generateBrief() }`. Safe to
    /// leave uncalled: `submitBackgroundRequest()` then fails gracefully and the foreground catch-up
    /// (`activateIfEnabled`, called from Coach's `.task`) still generates on next open.
    static func register(generateBrief: @escaping () async -> String?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                task.expirationHandler = { completion.finish(success: false) }
                guard isEnabled else {
                    completion.finish(success: true)
                    return
                }
                let succeeded = await catchUpIfDue(generateBrief: generateBrief)
                // Single-shot; request the next occurrence regardless of this run's outcome so a failed
                // generation still retries at the next wake rather than going silent for good.
                submitBackgroundRequest()
                completion.finish(success: succeeded)
            }
            task.expirationHandler = { worker.cancel(); completion.finish(success: false) }
        }
    }

    /// `BGTask` completion is single-shot even when the normal path races expiration.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            task.expirationHandler = nil
        }
    }

    /// Submit a background-refresh request for *no earlier than* the next chosen time. iOS decides when
    /// (and whether) to actually run it — best-effort, same honesty as `ScheduledDebugExport`.
    private static func submitBackgroundRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: secondsToNextOccurrence(timeMinutes))
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
