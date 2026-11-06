import XCTest
@testable import Strand

/// Pins the iOS tab-shell swipe: it may only land on a tab that exists. With Coach switched off the shell
/// has no tag 3, and stepping the raw tag showed a blank tab after a swipe from Sleep.
final class TabSwipeTests: XCTestCase {

    func testVisibleTagsKeepMoreAtFour() {
        XCTAssertEqual(TabSwipe.visibleTags(coachShown: true), [0, 1, 2, 3, 4])
        XCTAssertEqual(TabSwipe.visibleTags(coachShown: false), [0, 1, 2, 4])
    }

    func testSwipeSkipsTheMissingCoachTab() {
        let visible = TabSwipe.visibleTags(coachShown: false)
        XCTAssertEqual(TabSwipe.target(from: 2, forward: true, visible: visible), 4)
        XCTAssertEqual(TabSwipe.target(from: 4, forward: false, visible: visible), 2)
    }

    func testSwipeWithCoachShownStepsByOne() {
        let visible = TabSwipe.visibleTags(coachShown: true)
        XCTAssertEqual(TabSwipe.target(from: 2, forward: true, visible: visible), 3)
        XCTAssertEqual(TabSwipe.target(from: 3, forward: true, visible: visible), 4)
        XCTAssertEqual(TabSwipe.target(from: 4, forward: false, visible: visible), 3)
    }

    func testSwipeAlwaysLandsOnAVisibleTabAndStopsAtTheEnds() {
        for coachShown in [false, true] {
            let visible = TabSwipe.visibleTags(coachShown: coachShown)
            for current in visible {
                for forward in [false, true] {
                    let landed = TabSwipe.target(from: current, forward: forward, visible: visible)
                    XCTAssertTrue(visible.contains(landed), "Swipe from \(current) landed on missing tag \(landed).")
                }
            }
            XCTAssertEqual(TabSwipe.target(from: 4, forward: true, visible: visible), 4)
            XCTAssertEqual(TabSwipe.target(from: 0, forward: false, visible: visible), 0)
        }
    }

    func testATagThatJustDisappearedRecoversToTheFirstTab() {
        XCTAssertEqual(TabSwipe.target(from: 3, forward: true, visible: [0, 1, 2, 4]), 0)
        XCTAssertEqual(TabSwipe.target(from: 3, forward: false, visible: [0, 1, 2, 4]), 0)
    }
}
