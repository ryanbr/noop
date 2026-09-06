import XCTest
@testable import Strand

/// Pins the Key Metrics tile's value/unit join (#492, and the `–%` it left behind).
///
/// The reported symptom was an empty Strain tile reading `–%`: the placeholder kept its unit, so "no data"
/// rendered as something that parses like a negative percentage. Android has always suppressed the unit on
/// its no-data sentinel; these pin the iOS twin so the two cannot drift apart again.
final class LiquidTodayTileValueTests: XCTestCase {

    /// The reported bug, exactly: a missing metric must not carry a unit.
    func testNoValuePlaceholderDropsItsUnit() {
        XCTAssertEqual(LiquidTodayView.tileDisplayValue(LiquidTodayView.noValueDash, unit: "%"),
                       LiquidTodayView.noValueDash)
        XCTAssertEqual(LiquidTodayView.tileDisplayValue(LiquidTodayView.noValueDash, unit: "kcal"),
                       LiquidTodayView.noValueDash)
    }

    /// A real value still gets its unit, and `%` binds tight where the others take a space — the existing
    /// convention, unchanged by the guard above.
    func testAValueKeepsItsUnitAndSpacing() {
        XCTAssertEqual(LiquidTodayView.tileDisplayValue("93", unit: "%"), "93%")
        XCTAssertEqual(LiquidTodayView.tileDisplayValue("1272", unit: "kcal"), "1272 kcal")
    }

    /// Effort passes an EMPTY unit now (it is a 0–100 / 0–21 load index, not a percentage), so the value
    /// must come through untouched on both the present and the absent path.
    func testAnEmptyUnitIsLeftAlone() {
        XCTAssertEqual(LiquidTodayView.tileDisplayValue("38.9", unit: ""), "38.9")
        XCTAssertEqual(LiquidTodayView.tileDisplayValue(LiquidTodayView.noValueDash, unit: ""),
                       LiquidTodayView.noValueDash)
    }
}
