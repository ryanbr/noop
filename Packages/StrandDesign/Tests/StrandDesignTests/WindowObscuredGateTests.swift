import XCTest
@testable import StrandDesign

/// #2393: the pure half of the macOS window-visibility gate.
///
/// A decorative `TimelineView(.animation…)` keeps drawing when the app is hidden. A reporter measured
/// NOOP at a third to half a CPU core permanently on an M1 Pro, the largest single process on their
/// machine, and hiding the app with Cmd+H did not reduce it. `windowObscured` is the term that stops
/// it, and because it rides `poseStill`, every censused animation inherits it at once.
///
/// Only the decision is testable here. AppKit's window list is not available to a package test, so
/// what is pinned is the rule that decides what the list MEANS.
final class WindowObscuredGateTests: XCTestCase {

    func testAWindowOnScreenIsNotObscured() {
        XCTAssertFalse(NoopMotionState.obscured(hasWindows: true, anyWindowOnScreen: true))
    }

    func testWindowsWithNoneOnScreenAreObscured() {
        XCTAssertTrue(NoopMotionState.obscured(hasWindows: true, anyWindowOnScreen: false))
    }

    /// The case that decides the rule rather than following from it.
    ///
    /// During launch AppKit has no windows yet. Reading that as "nothing is on screen" would pose every
    /// surface still until the first occlusion notification arrived, so the app's first frame would show
    /// static gauges on the way to a live screen — a visible glitch introduced by an optimisation. An
    /// app with no windows draws nothing anyway, so this reading costs nothing and the other one costs
    /// the glitch.
    func testNoWindowsYetIsNotObscured() {
        XCTAssertFalse(NoopMotionState.obscured(hasWindows: false, anyWindowOnScreen: false))
        XCTAssertFalse(NoopMotionState.obscured(hasWindows: false, anyWindowOnScreen: true))
    }
}
