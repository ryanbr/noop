import XCTest
@testable import Strand

/// The analysis pass and the unprompted stress rescore are meant to yield to the UI. They said
/// `.utility` and did not: `await Task.detached(priority: .utility) { … }.value` from a main-actor
/// caller records a dependency, and the runtime raises the awaited task to the waiter's priority so a
/// high-priority waiter cannot be starved by what it waits on. The hop off the main actor was real the
/// whole time, so nothing blocked; the work simply competed with the UI instead of giving way to it.
///
/// These pin the difference rather than the fix's shape, so a future rewrite is free as long as the
/// unprompted work still yields.
final class UnescalatedWorkTests: XCTestCase {

    /// The property the callers actually need: the body runs at the priority it asked for, even though a
    /// main-actor caller is waiting on it.
    @MainActor
    func testUnescalatedWorkKeepsItsDeclaredPriority() async {
        let inside = await runUnescalated(priority: .utility) { Task.currentPriority }
        XCTAssertEqual(inside, .utility,
                       "unprompted work must keep the priority it declared, not the waiter's")
    }

    /// The control, and the reason the helper exists. If this ever stops escalating, the runtime changed
    /// and the helper can go — so this failing is informative rather than a nuisance.
    @MainActor
    func testAwaitingADetachedTaskEscalatesItInstead() async {
        let inside = await Task.detached(priority: .utility) { Task.currentPriority }.value
        XCTAssertNotEqual(inside, .utility,
                          "a plain awaited detached task is expected to be escalated to the waiter's priority")
    }

    /// A suspension point inside the body must not hand the priority back.
    @MainActor
    func testPriorityHoldsAcrossASuspensionInsideTheBody() async {
        let inside = await runUnescalated(priority: .utility) { () async -> TaskPriority in
            try? await Task.sleep(nanoseconds: 1_000_000)
            return Task.currentPriority
        }
        XCTAssertEqual(inside, .utility)
    }

    /// The value comes back intact; the helper is a priority fix, not a behaviour change.
    @MainActor
    func testTheResultIsReturnedUnchanged() async {
        let sum = await runUnescalated { (1...10).reduce(0, +) }
        XCTAssertEqual(sum, 55)
    }
}
