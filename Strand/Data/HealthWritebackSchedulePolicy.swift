import Foundation

/// Pure scheduling policy for iOS's best-effort Apple Health write-back refresh.
///
/// The BackgroundTasks framework decides the actual delivery time; this interval is only the earliest
/// time at which NOOP asks to be considered again. Keeping the policy framework-free makes the cadence
/// and authorization gate testable in the macOS-hosted app test target.
enum HealthWritebackSchedulePolicy {
    static let refreshInterval: TimeInterval = 60 * 60

    static func shouldSchedule(isAuthorized: Bool) -> Bool {
        isAuthorized
    }

    static func earliestBeginDate(after date: Date) -> Date {
        date.addingTimeInterval(refreshInterval)
    }
}
