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

    // MARK: - dominantKind (#1705)

    func testDominantKindIsTheNewestEntrys() {
        XCTAssertEqual(SkinTempDisplay.dominantKind(valuesAscendingByDay: [34.6, 35.1, -0.2]), .deviation)
        XCTAssertEqual(SkinTempDisplay.dominantKind(valuesAscendingByDay: [-0.2, 0.1, 34.6]), .absolute)
        XCTAssertNil(SkinTempDisplay.dominantKind(valuesAscendingByDay: []))
    }

    func testDominantKindOfASingleKindWindowIsThatKind() {
        XCTAssertEqual(SkinTempDisplay.dominantKind(valuesAscendingByDay: [-0.24, 0.21, 0.01]), .deviation)
        XCTAssertEqual(SkinTempDisplay.dominantKind(valuesAscendingByDay: [32.39, 34.60, 36.64]), .absolute)
    }

    /// The regression guard the issue asked for: filtering by `dominantKind` must leave a window that
    /// no aggregate can straddle. Values are the reported ones — a 313-row absolute import
    /// (32.39…36.64, mean 34.60) coexisting with computed deviations inside ±0.3.
    func testFilteringByDominantKindLeavesOneScale() {
        let mixed: [Double] = [34.60, 35.12, 32.39, 36.64, -0.24, 0.21, 0.01, 0.11, 0.0]
        guard let keep = SkinTempDisplay.dominantKind(valuesAscendingByDay: mixed) else {
            return XCTFail("a non-empty window must have a kind")
        }
        let kept = mixed.filter { SkinTempDisplay.kind(of: $0) == keep }
        XCTAssertEqual(kept, [-0.24, 0.21, 0.01, 0.11, 0.0])
        XCTAssertTrue(kept.allSatisfy { SkinTempDisplay.kind(of: $0) == keep })
        // The defect: unfiltered, the mean of a should-be-near-zero deviation window clears a degree
        // and then reads BELOW 20, so it gets labelled Δ°C — plausible-looking and wrong.
        let unfilteredMean = mixed.reduce(0, +) / Double(mixed.count)
        XCTAssertGreaterThan(unfilteredMean, 1.0)
        XCTAssertEqual(SkinTempDisplay.kind(of: unfilteredMean), .deviation)
        let filteredMean = kept.reduce(0, +) / Double(kept.count)
        XCTAssertLessThan(abs(filteredMean), 0.3)
    }
}
