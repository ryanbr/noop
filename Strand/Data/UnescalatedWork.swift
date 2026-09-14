import Foundation

/// Run `work` off the caller's executor at `priority`, without the awaiting caller dragging it back up.
///
/// `await Task.detached(priority: .utility) { … }.value` does NOT run at `.utility` when a main-actor
/// caller awaits it. Awaiting a task records a DEPENDENCY, and the runtime raises the awaited task to
/// the waiter's priority so a high-priority waiter cannot be starved by what it is waiting on. Every
/// such call site reached from the main actor therefore ran the work at the UI's own quality of
/// service: the hop off the main actor was real and the main thread stayed free, but the work competed
/// with the UI for cores instead of yielding to it, which is the opposite of what `.utility` reads as.
///
/// Awaiting a CONTINUATION records no dependency. The runtime cannot see which task will resume it, so
/// it has nothing to escalate and the declared priority stands. Measured on Linux Swift 5.9, caller at
/// 21: an awaited detached task reports 21 inside the body, this reports 17, with and without a
/// suspension point in the body.
///
/// Use this ONLY where EVERY caller is unprompted. Work the wearer started and is watching should
/// escalate: finishing sooner is the whole point. Escalation is a bug only where the work was meant
/// to yield.
///
/// Judge that at the ENTRY POINT, not at the block that burns the CPU. The analysis pass looks like an
/// obvious candidate from inside `IntelligenceEngine`, and is not one: `analyzeRecent` is reached from
/// a fifteen-minute background tick AND from a just-logged workout, whose call site asks for it so the
/// new strain and calories "appear immediately", and from an Intelligence screen sitting empty while
/// the wearer waits for it to fill. One internal block, several kinds of caller, so the priority
/// belongs to whoever asked. Giving that pass a caller-aware priority is worth doing and is a larger
/// change than this one.
///
/// Cancellation is unchanged from the shape this replaces: a detached task already inherits none, and
/// the continuation is always resumed exactly once, so a cancelled caller cannot leak it.
func runUnescalated<T: Sendable>(
    priority: TaskPriority = .utility,
    _ work: @escaping @Sendable () async -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        Task.detached(priority: priority) { continuation.resume(returning: await work()) }
    }
}
