import XCTest
@testable import StrandAnalytics

/// The Kotlin `StagePercentagesTest` asserts the SAME vectors → the two apportionments stay byte-identical.
final class StagePercentagesTests: XCTestCase {

    func testWorkedExampleSumsTo100() {
        // 25 / 210 / 78 / 107 of a 420-minute night: independent rounding gives 6+50+19+25 on some nights
        // and 99/101 on others. Apportioned once, it is always 100.
        XCTAssertEqual(StagePercentages.wholePercentages([25, 210, 78, 107]), [6, 50, 19, 25])
    }

    func testEqualPartsSplitEvenly() {
        XCTAssertEqual(StagePercentages.wholePercentages([1, 1, 1, 1]), [25, 25, 25, 25])
    }

    func testLeftoverGoesToLargestRemainderThenLowestIndex() {
        // Three-way tie for one leftover unit → the lowest index takes it.
        XCTAssertEqual(StagePercentages.wholePercentages([10, 10, 10, 0]), [34, 33, 33, 0])
        // Two leftover units: the largest remainder first, then the lowest-index of the tied rest.
        XCTAssertEqual(StagePercentages.wholePercentages([5, 5, 5, 2]), [30, 29, 29, 12])
    }

    func testWholeNightInOneStage() {
        XCTAssertEqual(StagePercentages.wholePercentages([420, 0, 0, 0]), [100, 0, 0, 0])
    }

    func testNoMinutesIsNil() {
        XCTAssertNil(StagePercentages.wholePercentages([0, 0, 0, 0]))
        XCTAssertNil(StagePercentages.wholePercentages([]))
    }

    func testAlwaysSumsToExactly100() {
        let nights: [[Double]] = [
            [1, 2, 3, 4], [33, 33, 33, 1], [419, 1, 0, 0], [90, 240, 60, 30],
            [7, 7, 7, 7], [100, 33, 33, 34], [1, 0, 0, 0], [12.5, 12.5, 12.5, 12.5],
        ]
        for n in nights {
            let p = StagePercentages.wholePercentages(n)!
            XCTAssertEqual(p.reduce(0, +), 100, "\(n) apportioned to \(p)")
            XCTAssertTrue(p.allSatisfy { $0 >= 0 })
        }
    }
}
