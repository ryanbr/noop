#if os(iOS)
import BackgroundTasks
import Foundation

/// The wake behind the stale-battery warning (#2556).
///
/// Its own task, deliberately, and that cost is the whole point. The check exists for a strap that has
/// STOPPED talking, so it cannot hang off anything whose trigger depends on the strap:
///
///  - The live battery crossings run off `live.onBatteryUpdate`, which only fires when a reading arrives.
///  - The re-score task is submitted only `if RescoreBackgroundScheduler.isRescoreOwed`, and a re-score is
///    owed only when new data lands. A missing strap produces none, so that task would never run.
///  - The Health write-back task is conditional on HealthKit authorization, an unrelated dependency that
///    would silently decide whether battery warnings work.
///
/// Each of those would have produced a warning that is correct in every unit test and never fires in the
/// field, which is what the first two attempts at this actually did.
///
/// iOS only: `BGTaskScheduler` does not exist on macOS, where the app is generally running anyway and the
/// foreground check covers it.
@MainActor
enum StaleBatteryBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".stalebattery"

    /// Roughly how often to ask. `BGAppRefreshTaskRequest` is an EARLIEST-begin request, never a promise,
    /// so the real cadence is the system's to choose. Half an hour matches the Android worker's period;
    /// both are far finer than the hours of silence the warning is about, so drift costs nothing.
    static let interval: TimeInterval = 30 * 60

    /// Register at launch, before the first scene connects.
    static func register(perform operation: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                // Arm the successor FIRST. A refresh request is single-shot, so doing the work before
                // re-arming means one expiry leaves the warning permanently unscheduled, which is the
                // failure mode this whole task exists to avoid.
                schedule()
                await operation()
                guard !Task.isCancelled else { return }
                completion.finish(success: true)
            }
            task.expirationHandler = {
                worker.cancel()
                completion.finish(success: false)
            }
        }
    }

    /// Keep exactly one pending request, so calling this at launch and on background transitions is
    /// idempotent and also repairs a request the system discarded.
    static func schedule(now: Date = Date()) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Its own copy, as every other scheduler here keeps: UIKit treats a double `setTaskCompleted` as a
    /// programmer error and a never-completed task as grounds for killing the app, so the normal path and
    /// the expiration handler must race to finish with exactly one winner.
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
}
#endif
