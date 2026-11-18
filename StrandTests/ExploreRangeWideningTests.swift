import XCTest
@testable import Strand

/// The auto-expand chain a metric detail walks when the selected window holds no points.
final class ExploreRangeWideningTests: XCTestCase {

    /// Every range starts its chain with itself, so a window that holds data is shown as selected.
    /// A hand-written chain once omitted 2W and 3W, and both chips rendered "widened to all time".
    func testEveryRangeStartsWithItself() {
        for range in ExploreRange.allCases {
            XCTAssertEqual(range.widening.first, range, "\(range.label) skips its own window")
        }
    }

    func testTwoAndThreeWeeksWidenThroughTheNextLargerRanges() {
        XCTAssertEqual(ExploreRange.twoWeeks.widening,
                       [.twoWeeks, .threeWeeks, .month, .quarter, .half, .year, .all])
        XCTAssertEqual(ExploreRange.threeWeeks.widening,
                       [.threeWeeks, .month, .quarter, .half, .year, .all])
    }

    /// Ascending by window length, ending at ALL.
    func testChainsAscendAndEndAtAll() {
        for range in ExploreRange.allCases {
            let chain = range.widening
            XCTAssertEqual(chain.last, .all)
            let finite = chain.compactMap(\.days)
            XCTAssertEqual(finite, finite.sorted(), "\(range.label) widens out of order")
        }
    }
}
