import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// The DAILY scheduled debug auto-export (#510 — maddognik) for Apple, in PARITY with Android's
/// `DebugExportScheduler`.
///
/// At the user's chosen time-of-day this writes the durable strap-log tail ([LiveState.scheduledExportText])
/// — and, when a raw 5/MG capture exists, copies that alongside — to the app's Documents directory under a
/// `yyMMdd-HHmm` timestamped filename, once per day, with no UI. It exists so a reporter chasing an
/// intermittent overnight fault gets a dated log waiting each morning instead of having to remember to hit
/// "Save strap log" at the right moment.
///
/// HONEST about platform limits (the whole point of doing this carefully on Apple):
/// - **macOS** — the app is usually running, so a foreground `DispatchSourceTimer` fires reliably at the
///   chosen minute, and `catchUpIfDue()` covers the case where the time passed while the app wasn't open.
///   This path is dependable.
/// - **iOS** — a sideloaded, backgrounded app can't guarantee a drop to the exact minute. We submit a
///   `BGAppRefreshTaskRequest` for *no earlier than* the chosen time and write when iOS next wakes us near
///   it. The Settings copy says exactly that — we never promise an exact background drop. (The app entry
///   point registers the handler id below via `register(perform:)`; if it isn't registered/permitted yet,
///   `submit` fails gracefully and the in-app "Run now" + the macOS path still work.)
///
/// Opt-in, default OFF — like every NOOP automation. Everything is on-device; nothing is sent anywhere.
///
/// RETENTION (#650): every write is pruned to `keepCount` generations (default 14), oldest first, and
/// the Test Centre export card offers a manual "Clear scheduled exports" for an immediate wipe — these
/// files sit in Documents (Files-visible) with no UI in the loop reminding anyone they exist, so a
/// default cap and a visible clear action both matter. Mirrors Android's `LogExport` retention.
@MainActor
enum ScheduledDebugExport {

    // MARK: - Persisted settings (own keys; mirror Android `DebugExportSettings` + the WindDownNudge shape)

    private enum K {
        static let enabled = "debugExport.enabled"          // master enable; default OFF
        static let time = "debugExport.timeMinutes"         // minutes since local midnight; default 07:00
        static let lastRun = "debugExport.lastRunDayKey"    // yyyy-MM-dd of the last completed drop (catch-up dedup)
        static let keepCount = "debugExport.keepCount"      // retention: generations to keep (#650)
    }

    /// 07:00 — a log waiting when you wake (matches Android's `DEFAULT_TIME`).
    static let defaultTimeMinutes = 7 * 60
    private static let minutesPerDay = 24 * 60

    // MARK: - Retention (#650: these accumulated in Documents with no cleanup and no visible cap)

    /// Retention choices offered by the scheduled-export keep-count picker. Mirrors Android's
    /// `EXPORT_KEEP_OPTIONS`. A longer range than `FolderBackup.keepOptions` (the `.noopbak` backup
    /// picker) since a scheduled export is a small text/JSON pair, not a whole-DB snapshot.
    static let keepOptions = [3, 7, 14, 30, 60]

    private static let defaultKeepCount = 14

    /// How many scheduled-export GENERATIONS (a day's log + raw-capture pair counts once) to keep
    /// before `performExport` prunes older ones, oldest first. Mirrors `FolderBackup.keepCount`'s
    /// shape (0-means-unset sentinel, clamp to a sane 1...100).
    static var keepCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.keepCount)   // 0 when never set
            return v == 0 ? defaultKeepCount : min(max(v, 1), 100)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: K.keepCount) }
    }

    /// Filename prefixes for the two scheduled-export file kinds this type writes into Documents (the
    /// log `.txt` and the raw-capture `.json`). Nothing else in Documents matches either prefix, so
    /// retention and the manual clear action only ever touch scheduled drops.
    private static let logPrefix = "noop-strap-log-"
    private static let rawPrefix = "noop-raw-capture-"

    /// The `yyMMdd-HHmm` stamp embedded in one scheduled-export filename (log `.txt` or raw `.json`),
    /// or nil if `name` isn't one of ours. Mirrors Android `LogExport.scheduledExportStamp`. Pure — no
    /// file IO — so retention math is unit-testable.
    static func exportStamp(fromFilename name: String) -> String? {
        if name.hasPrefix(logPrefix), name.hasSuffix(".txt") {
            return String(name.dropFirst(logPrefix.count).dropLast(4))
        }
        if name.hasPrefix(rawPrefix), name.hasSuffix(".json") {
            return String(name.dropFirst(rawPrefix.count).dropLast(5))
        }
        return nil
    }

    /// Scheduled-export STAMPS (not filenames) to prune to keep only the `keep` newest generations — a
    /// day's log+raw pair shares a stamp and counts once. Mirrors Android
    /// `LogExport.scheduledExportStampsToPrune`. `yyMMdd-HHmm` is fixed-width and zero-padded, so a
    /// plain string sort orders it correctly with no date parsing needed (same trick as the Android
    /// twin's `yyyyMMdd-HHmmss`). Empty when already within budget.
    static func exportStampsToPrune(_ names: [String], keep: Int) -> Set<String> {
        let stamps = Array(Set(names.compactMap { exportStamp(fromFilename: $0) })).sorted(by: >)
        guard stamps.count > keep else { return [] }
        return Set(stamps.dropFirst(keep))
    }

    /// Best-effort retention: delete scheduled-export files under `docs` beyond `keep` generations,
    /// oldest first. Called after every write in `performExport`. Failures are ignored — a transient
    /// hiccup here must never fail the export itself.
    private static func pruneScheduledExports(in docs: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return }
        let toPrune = exportStampsToPrune(names, keep: keep)
        guard !toPrune.isEmpty else { return }
        for name in names {
            guard let stamp = exportStamp(fromFilename: name), toPrune.contains(stamp) else { continue }
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
    }

    /// Manual "Clear scheduled exports" action: delete every scheduled-export file under Documents
    /// right now, regardless of the retention setting. Never touches an interactive save/share (those
    /// go through `FileExport`'s save panel / share sheet, not Documents) or anything else the user or
    /// another feature put in Documents. Returns the number of files removed.
    @discardableResult
    static func clearScheduledExports() -> Int {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return 0 }
        var removed = 0
        for name in names where exportStamp(fromFilename: name) != nil {
            if (try? fm.removeItem(at: docs.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// iOS BGTask identifier. Derived from the running bundle id (rather than hardcoded) so it tracks
    /// BUNDLE_ID_PREFIX (see Config/BundleId.xcconfig) automatically and always matches the iOS target's
    /// `BGTaskSchedulerPermittedIdentifiers` (Info.plist), which is built from `$(PRODUCT_BUNDLE_IDENTIFIER)`
    /// the same way. Must also be registered at launch for `submit` to succeed — wired in the app entry point.
    static let bgTaskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".debugexport"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// A delivered BGAppRefresh request is single-shot and should schedule its successor only while the
    /// user still has scheduled exports enabled. Kept outside the iOS-only `register` block so the
    /// disable-versus-delivery race is testable on every platform.
    static func backgroundTaskShouldResubmit(enabled: Bool) -> Bool { enabled }

    /// Time-of-day to export, minutes since local midnight. Clamped to a valid minute. Default 07:00.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(v, 0), minutesPerDay - 1)
    }

    // MARK: - Public API (Settings calls these)

    /// Enable/disable and (re)schedule. Disabling cancels the schedule and stops the drops.
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.enabled)
        if on {
            scheduleNext()
            catchUpIfDue()
        } else {
            cancel()
        }
    }

    /// Update the time-of-day and reschedule so the new time takes effect immediately (the Android
    /// `applyTimeChange` analogue).
    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), minutesPerDay - 1), forKey: K.time)
        if isEnabled { scheduleNext() }
    }

    /// Call on app start AND when the Settings screen appears so the schedule self-heals (re-arms the
    /// macOS timer after a relaunch, re-submits the iOS request) and a drop missed while the app wasn't
    /// running is written once. No-op when the feature is off.
    static func activateIfEnabled() {
        guard isEnabled else { return }
        scheduleNext()
        catchUpIfDue()
    }

    /// User-initiated immediate export (the "Run now" button). Always writes, ignoring the daily dedup,
    /// so a tap produces a file there and then. The caller may pass the current raw 5/MG capture URL (from
    /// `live.puffinCaptureURL`) so a scheduled drop carries the same matched pair the one-tap "Export raw +
    /// log" does. Returns the written log file URL or nil if the body couldn't be written.
    @discardableResult
    static func runNow(captureURL: URL? = nil) -> URL? {
        performExport(markDay: false, captureURL: captureURL)
    }

    // MARK: - Scheduling

    private static var macTimer: DispatchSourceTimer?

    /// (Re)arm the next occurrence. macOS uses a foreground `DispatchSourceTimer`; iOS submits a
    /// background-refresh request. Both target the next wall-clock occurrence of `timeMinutes`.
    private static func scheduleNext() {
        #if os(macOS)
        macTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = secondsToNextOccurrence(timeMinutes)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            guard isEnabled else { return }
            _ = performExport(markDay: true)
            // Re-arm for the following day (the timer is one-shot so a clock change can't drift it).
            scheduleNext()
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

    /// If today's drop is due (we're at/after the chosen time and haven't written today), write it once.
    /// Covers macOS launches where the time passed while the app wasn't open, and the iOS foreground path.
    ///
    /// Returns whether this call can be considered successful: `true` when there was nothing to do
    /// (feature off, not yet time, or already ran today — nothing was attempted, so nothing failed) or the
    /// export was attempted and wrote successfully; `false` only when an export was actually attempted and
    /// `performExport` failed to write. The iOS BGTask handler uses this to report the real outcome to
    /// `setTaskCompleted(success:)` instead of a hardcoded success.
    @discardableResult
    private static func catchUpIfDue() -> Bool {
        guard isEnabled else { return true }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= timeMinutes else { return true }      // not yet time today
        guard UserDefaults.standard.string(forKey: K.lastRun) != dayKey(now) else { return true } // already ran today
        return performExport(markDay: true) != nil
    }

    /// Seconds from now until the next wall-clock occurrence of `minuteOfDay` (today if still ahead, else
    /// tomorrow). Mirrors Android's `delayToNextOccurrenceMs`.
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

    // MARK: - The export itself

    /// Write the durable strap-log tail to `Documents/noop-strap-log-<yyMMdd-HHmm>.txt`, and (when the
    /// caller supplies one) copy the raw 5/MG capture beside it. Reuses the already-shipped writers (the
    /// durable tail from `LiveState`, the timestamped naming from `FileExport`) so a scheduled drop reads
    /// the same as a manual share. `markDay` records today so the daily dedup/catch-up doesn't
    /// double-write; the "Run now" button passes false so a manual tap always produces a file.
    @discardableResult
    private static func performExport(markDay: Bool, captureURL: URL? = nil) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = FileExport.timestamp()
        let logURL = docs.appendingPathComponent("noop-strap-log-\(stamp).txt")
        do {
            try LiveState.scheduledExportText(extraHeaderLines: DebugDataDiagnostics.strapStateLines())
                .write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        // Best-effort: copy the supplied raw 5/MG capture alongside, so a "Run now" drop carries the same
        // matched pair the one-tap "Export raw + log" does. The background timer path passes nil (no live
        // session), so it writes just the log — honest about what's available with no session open.
        if let capture = captureURL, FileManager.default.fileExists(atPath: capture.path) {
            let dest = docs.appendingPathComponent("noop-raw-capture-\(stamp).json")
            try? FileManager.default.copyItem(at: capture, to: dest)
        }
        if markDay {
            UserDefaults.standard.set(dayKey(Date()), forKey: K.lastRun)
        }
        // Retention (#650): these accumulate in Documents with no UI in the loop to notice, so prune
        // after every write (scheduled OR manual "Run now") — mirrors Android pruning on every
        // `writeScheduledExport` call.
        pruneScheduledExports(in: docs, keep: keepCount)
        return logURL
    }

    /// yyyy-MM-dd local-day key for the once-per-day dedup. POSIX locale so the key is stable everywhere.
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// Register the BGTask handler. MUST be called from the app's launch (before launch finishes) AND the
    /// identifier MUST be listed in `BGTaskSchedulerPermittedIdentifiers` (Info.plist) for iOS to deliver
    /// the task. Both live in the iOS app target — call this from `StrandiOSApp.init()`. Safe to leave
    /// uncalled: `submitBackgroundRequest()` fails gracefully and the macOS path + "Run now" still work.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            // iOS can kill the process before our work below returns if the background budget runs out;
            // report that honestly as a failure (so the run is retried) instead of leaving the task
            // marked incomplete, and instead of the old hardcoded `success: true`.
            task.expirationHandler = { completion.finish(success: false) }
            // BGAppRefresh is single-shot. `setEnabled(false)` cancels the pending request, but iOS can
            // already be delivering one when it does — `cancel` loses that race. Gate the successor on a
            // fresh enabled read so a stale delivery can't resurrect a daily background wake the user
            // turned off. Disabled is a terminal no-op: nothing to export, nothing to resubmit.
            guard backgroundTaskShouldResubmit(enabled: isEnabled) else {
                completion.finish(success: true)
                return
            }
            // Write the drop, then immediately request the next one.
            // `catchUpIfDue()` already no-ops (returning true) when nothing is due.
            let succeeded = catchUpIfDue()
            submitBackgroundRequest()
            completion.finish(success: succeeded)
        }
    }

    /// Guards `BGTask.setTaskCompleted` against being called twice — once from the normal completion
    /// path and once from `expirationHandler` — which BGTaskScheduler treats as a programmer error.
    /// Plain lock rather than actor isolation: the expiration handler can be invoked by the system on a
    /// queue other than the one running the registration closure.
    private final class TaskCompletionGuard {
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
            // Break the retain cycle set up in `register()` (task → expirationHandler closure → self →
            // task). The handler is useless once the task is completed, so drop it here; without this the
            // guard + task + closure leak until the system happens to release the task. Harmless to nil
            // after completion.
            task.expirationHandler = nil
        }
    }

    /// Submit a background-refresh request for *no earlier than* the next chosen time. Honest: iOS decides
    /// when (and whether) to actually run it, so this is best-effort. `try?` swallows the
    /// "identifier not permitted/registered" error so a build that hasn't wired Info.plist still behaves.
    private static func submitBackgroundRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: secondsToNextOccurrence(timeMinutes))
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
