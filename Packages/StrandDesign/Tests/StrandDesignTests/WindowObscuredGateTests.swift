import XCTest
@testable import StrandDesign

/// #2394 / #2397: the macOS window-visibility gate, tested as the LIST decision it actually is.
///
/// The first version of this suite could only hand the decision two summary Bools, `hasWindows` and
/// `anyWindowOnScreen`, and it passed while the gate never once closed. The bug was in the filter that
/// produced those summaries: `canBecomeMain` answers false for a hidden or miniaturised window, so the
/// app window left the list at exactly the moment the gate should have closed, the list went empty, and
/// the empty-list rule read that as "not obscured". No test over a summary can see that, because the
/// summary is where the information was already lost.
///
/// So the cases below are the window states @nichtlegacy measured on the shipped build, expressed the
/// way `refreshWindowObscured` now expresses them:
///
///     visible     titled=2 (one on screen)   obscured=N
///     hidden      titled=2 (none on screen)  obscured=Y
///     minimised   titled=2 (none on screen)  obscured=Y
///
/// The hidden and minimised cases FAIL against the old predicate, which is the property the source
/// census in `QuietMotionCoverageTests` could not provide and the reason this file exists.
final class WindowObscuredGateTests: XCTestCase {

    private func window(onScreen: Bool) -> NoopMotionState.WindowVisibility {
        NoopMotionState.WindowVisibility(onScreen: onScreen)
    }

    func testAWindowOnScreenIsNotObscured() {
        XCTAssertFalse(NoopMotionState.obscured([window(onScreen: true)]))
    }

    /// Cmd+H. The window is still in the list (that is what `.titled` buys) and simply not on screen.
    func testAHiddenAppIsObscured() {
        XCTAssertTrue(NoopMotionState.obscured([window(onScreen: false)]))
    }

    /// Sent to the Dock. Indistinguishable from hidden at this layer, and should be.
    func testAMiniaturisedWindowIsObscured() {
        XCTAssertTrue(NoopMotionState.obscured([window(onScreen: false)]))
    }

    /// The reporter's `titled=2` counts, both states. A second titled window (a sheet, or Settings)
    /// must not hold the gate open on its own, and must not close it while the main window is up.
    func testASecondTitledWindowFollowsTheSameRule() {
        XCTAssertFalse(NoopMotionState.obscured([window(onScreen: true), window(onScreen: false)]))
        XCTAssertTrue(NoopMotionState.obscured([window(onScreen: false), window(onScreen: false)]))
    }

    /// The case that decides the empty-list rule rather than following from it.
    ///
    /// During launch AppKit has no windows yet, and someone can close the window and leave NOOP running
    /// as a menu-bar app. Reading that as "nothing on screen" would pose every surface still until the
    /// next occlusion notification arrived, so the app's first frame would show static gauges on the way
    /// to a live screen. With no window there is no view hierarchy and so no frame loop to stop.
    ///
    /// This rule is only safe while the filter is state-INDEPENDENT, which is precisely what #2397 broke:
    /// under `canBecomeMain` a hidden window emptied the list and this clause answered the live question.
    func testNoWindowsIsNotObscured() {
        XCTAssertFalse(NoopMotionState.obscured([]))
    }

    /// The status-item window never reaches here (the caller filters on `.titled`), but if the filter is
    /// ever loosened, an always-on-screen window would hold the gate open forever, which is the other way
    /// this fix can be made inert. Pinned as the shape that must not appear.
    func testAnAlwaysOnScreenWindowWouldHoldTheGateOpen() {
        XCTAssertFalse(NoopMotionState.obscured([window(onScreen: false), window(onScreen: true)]))
    }
}
