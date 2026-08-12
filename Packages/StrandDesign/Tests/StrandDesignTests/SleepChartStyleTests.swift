import XCTest
@testable import StrandDesign

/// Pins the Sleep-chart-style contract (#sleep-chart-style): the three rawValues and the storage key must
/// stay byte-identical to the Android `SleepChartStyle` / `UnitPrefs.KEY_SLEEP_CHART_STYLE` twins, so a
/// device reads its own choice consistently and the default resolves the same on either platform.
final class SleepChartStyleTests: XCTestCase {

    func testRawValuesMatchTheKotlinContract() {
        XCTAssertEqual(SleepChartStyle.classic.rawValue, "classic")
        XCTAssertEqual(SleepChartStyle.filled.rawValue, "filled")
        XCTAssertEqual(SleepChartStyle.ribbon.rawValue, "ribbon")
        // Exactly these three, in this order (parity with the Kotlin enum entries).
        XCTAssertEqual(SleepChartStyle.garminFilled.rawValue, "garminFilled")
        XCTAssertEqual(SleepChartStyle.allCases.map(\.rawValue), ["classic", "filled", "garminFilled", "ribbon"])
        // Style → ramp mapping: Fill/Classic keep NOOP, Garmin Fill → Garmin, Ribbon → Oura.
        XCTAssertEqual(SleepChartStyle.filled.stagePalette, .noop)
        XCTAssertEqual(SleepChartStyle.garminFilled.stagePalette, .garmin)
        XCTAssertEqual(SleepChartStyle.ribbon.stagePalette, .oura)
        XCTAssertTrue(SleepChartStyle.filled.isFilled && SleepChartStyle.garminFilled.isFilled)
        XCTAssertFalse(SleepChartStyle.ribbon.isFilled || SleepChartStyle.classic.isFilled)
    }

    func testStorageKeyMatchesTheAndroidPrefKey() {
        XCTAssertEqual(SleepChartStyle.storageKey, "sleep.chart.style")
    }

    func testResolveIsTolerantAndDefaultsToClassic() {
        XCTAssertEqual(SleepChartStyle.resolve("filled"), .filled)
        XCTAssertEqual(SleepChartStyle.resolve("ribbon"), .ribbon)
        XCTAssertEqual(SleepChartStyle.resolve("nonsense"), .classic)
        XCTAssertEqual(SleepChartStyle.resolve(""), .classic)
    }
}
