import XCTest
@testable import Strand

/// Formatting and parsing for the numbers a user types at the rack.
///
/// These exist because a real session could not enter a decimal weight at all. Two separate defects
/// combined: `trim` rendered one decimal place, and the entry fields read their text back through it
/// on every keystroke — so "45.5" became "45", then "455". The rounding half is pinned here; the
/// field half is pinned by `LiftSessionView`'s draft (there is no view test target for it).
final class LiftFormatNumberTests: XCTestCase {

    // MARK: - trim

    func testAWholeNumberLosesItsDecimalPoint() {
        XCTAssertEqual(LiftFormat.trim(8), "8")
        XCTAssertEqual(LiftFormat.trim(60.0), "60")
        XCTAssertEqual(LiftFormat.trim(0), "0")
    }

    func testOneDecimalSurvives() {
        XCTAssertEqual(LiftFormat.trim(7.5), "7.5")
        XCTAssertEqual(LiftFormat.trim(45.5), "45.5")
    }

    /// The defect: gym plates come in quarter-kilos, and microplates in smaller steps, so 12.25 is a
    /// weight people actually lift. One decimal turned it into "12.3" — and because the entry field
    /// read that back, the rounded value replaced what was typed.
    func testTwoDecimalsSurvive() {
        XCTAssertEqual(LiftFormat.trim(12.25), "12.25")
        XCTAssertEqual(LiftFormat.trim(2.75), "2.75")
        XCTAssertEqual(LiftFormat.trim(102.05), "102.05")
    }

    func testTrailingZeroesAreDropped() {
        XCTAssertEqual(LiftFormat.trim(45.50), "45.5", "not 45.50")
        XCTAssertEqual(LiftFormat.trim(45.00), "45", "not 45.00")
    }

    /// Beyond two decimals is rounded, not truncated, and never renders a third digit.
    func testBeyondTwoDecimalsRounds() {
        XCTAssertEqual(LiftFormat.trim(12.256), "12.26")
        XCTAssertEqual(LiftFormat.trim(12.254), "12.25")
        XCTAssertEqual(LiftFormat.trim(1.0 / 3.0), "0.33")
    }

    /// Always a point, never the device's separator: this is what the whole screen displays, and the
    /// entry fields normalise a typed comma to match it.
    func testTheSeparatorIsAlwaysAPoint() {
        XCTAssertFalse(LiftFormat.trim(7.5).contains(","))
        XCTAssertTrue(LiftFormat.trim(7.5).contains("."))
    }

    // MARK: - number

    func testBothSeparatorsParse() {
        XCTAssertEqual(LiftFormat.number("45.5"), 45.5)
        XCTAssertEqual(LiftFormat.number("45,5"), 45.5, "a German or French keyboard offers the comma")
        XCTAssertEqual(LiftFormat.number("12.25"), 12.25)
        XCTAssertEqual(LiftFormat.number("12,25"), 12.25)
    }

    /// A half-typed decimal must parse, or the value would vanish the instant the point is typed.
    func testAPartiallyTypedDecimalParses() {
        XCTAssertEqual(LiftFormat.number("45."), 45)
        XCTAssertEqual(LiftFormat.number("45,"), 45)
    }

    func testNonsenseIsNilRatherThanZero() {
        XCTAssertNil(LiftFormat.number(""))
        XCTAssertNil(LiftFormat.number("   "))
        XCTAssertNil(LiftFormat.number("kg"))
        XCTAssertNil(LiftFormat.number("."))
    }

    /// The round trip the entry field performs on every keystroke. Whatever a user types must come
    /// back as the same number — this is what silently produced 455 from 45.5.
    func testTypedTextSurvivesTheRoundTripThroughTheField() {
        for typed in ["45.5", "12.25", "60", "7.5", "102.05", "45,5"] {
            guard let value = LiftFormat.number(typed) else {
                XCTFail("\(typed) did not parse"); continue
            }
            let shown = LiftFormat.trim(value)
            XCTAssertEqual(LiftFormat.number(shown), value,
                           "\(typed) rendered as \(shown), which no longer reads back as \(value)")
        }
    }
}
