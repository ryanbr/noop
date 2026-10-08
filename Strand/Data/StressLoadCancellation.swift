import Foundation

/// A cancelled screen load must not publish a result from a read or detached calculation that kept
/// running. Check both sides of the suspension so obsolete loads also stop before their next read.
/// Kotlin twin: `com.noop.ui.StressLoadCancellation`.
@MainActor
enum StressLoadCancellation {
    static func read<Value>(_ work: () async -> Value) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let value = await work()
        guard !Task.isCancelled else { return nil }
        return value
    }
}
