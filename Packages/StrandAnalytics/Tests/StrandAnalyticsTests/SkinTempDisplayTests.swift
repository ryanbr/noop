import XCTest
@testable import StrandAnalytics

final class SkinTempDisplayTests: XCTestCase {

    func testKindSplitsAbsoluteAndDeviation() {
        XCTAssertEqual(SkinTempDisplay.kind(of: 34.2), .absolute)
        XCTAssertEqual(SkinTempDisplay.kind(of: 20.0), .absolute)
        XCTAssertEqual(SkinTempDisplay.kind(of: 0.1), .deviation)
        XCTAssertEqual(SkinTempDisplay.kind(of: -0.1), .deviation)
        XCTAssertEqual(SkinTempDisplay.kind(of: 19.9), .deviation)
    }

    func testUnitSymbolMarksDeviation() {
        XCTAssertEqual(SkinTempDisplay.unitSymbol(kind: .absolute, fahrenheit: false), "°C")
        XCTAssertEqual(SkinTempDisplay.unitSymbol(kind: .absolute, fahrenheit: true), "°F")
        XCTAssertEqual(SkinTempDisplay.unitSymbol(kind: .deviation, fahrenheit: false), "Δ°C")
        XCTAssertEqual(SkinTempDisplay.unitSymbol(kind: .deviation, fahrenheit: true), "Δ°F")
    }

    func testNumberStringAbsoluteUnsigned() {
        XCTAssertEqual(
            SkinTempDisplay.numberString(34.24, kind: .absolute, fahrenheit: false),
            "34.2"
        )
    }

    func testNumberStringDeviationAlwaysSigned() {
        XCTAssertEqual(
            SkinTempDisplay.numberString(-0.1, kind: .deviation, fahrenheit: false),
            "-0.1"
        )
        XCTAssertEqual(
            SkinTempDisplay.numberString(0.3, kind: .deviation, fahrenheit: false),
            "+0.3"
        )
    }

    func testFahrenheitConversionAbsoluteVsDelta() {
        // 0 °C absolute → 32 °F
        XCTAssertEqual(
            SkinTempDisplay.numberString(0, kind: .absolute, fahrenheit: true, decimals: 0),
            "32"
        )
        // 1 °C deviation → 1.8 Δ°F (no +32)
        XCTAssertEqual(
            SkinTempDisplay.numberString(1.0, kind: .deviation, fahrenheit: true),
            "+1.8"
        )
    }

    func testFormatCombinesNumberAndUnit() {
        XCTAssertEqual(
            SkinTempDisplay.format(-0.1, fahrenheit: false),
            "-0.1 Δ°C"
        )
        XCTAssertEqual(
            SkinTempDisplay.format(34.2, fahrenheit: false),
            "34.2 °C"
        )
    }

    func testParityWithIsAbsoluteSkinTemp() {
        for v in [-2.0, -0.1, 0.0, 0.5, 19.9, 20.0, 30.6, 34.24] {
            let abs = VitalBands.isAbsoluteSkinTemp(v)
            XCTAssertEqual(SkinTempDisplay.kind(of: v) == .absolute, abs, "v=\(v)")
        }
    }
}
