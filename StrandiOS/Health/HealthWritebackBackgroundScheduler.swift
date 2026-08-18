#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort periodic fallback for exporting locally-banked strap data to Apple Health.
///
/// Fresh WHOOP offloads still use the immediate completion hook in `AppModel`; this scheduler covers
/// data already in the local store when the app remains closed. `BGAppRefreshTaskRequest` does not
/// guarantee an exact cadence, so the one-hour date is deliberately only an earliest-begin request.
@MainActor
enum HealthWritebackBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".healthwriteback"

    /// Register at launch, before the first scene finishes connecting. The operation returns whether
    /// the HealthKit write completed; authorization absence is a successful no-op and cancels the next
    /// request in the app-owned closure.
    static func register(perform operation: @escaping @MainActor () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                // Refresh requests are single-shot. Arm the successor before doing any HealthKit work so
                // expiration cannot leave periodic export permanently unscheduled.
                schedule()
                let succeeded = await operation()
                guard !Task.isCancelled else { return }
                completion.finish(success: succeeded)
            }
            task.expirationHandler = {
                worker.cancel()
                completion.finish(success: false)
            }
        }
    }

    /// Keep exactly one pending request. Calling this on authorization, foreground, and background
    /// transitions is therefore idempotent and also repairs a request the system discarded.
    static func schedule(now: Date = Date()) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = HealthWritebackSchedulePolicy.earliestBeginDate(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    static func updateSchedule(isAuthorized: Bool) {
        if HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: isAuthorized) {
            schedule()
        } else {
            cancel()
        }
    }

    /// `BGTask` completion is single-shot even when normal completion races expiration.
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
