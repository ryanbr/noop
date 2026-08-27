import XCTest
import StrandAnalytics
@testable import Strand

/// The fused-record row renders a skin temperature that is STORED in °C. It printed a hardcoded "°C"
/// regardless of the reader's preference, so a Fahrenheit user saw a Celsius number on the fusion screen
/// while every other surface converted it.
final class FusionFormatUnitsTests: XCTestCase {

    /// An ABSOLUTE wrist reading (CSV / Apple Health) converts with the +32 offset.
    func testAbsoluteSkinTempFollowsTheReadersUnit() {
        XCTAssertEqual(FusionFormat.value(34.1, metricKey: "skin_temp", temperature: .celsius), "34.1 °C")
        // 34.1 °C = 93.38 °F
        XCTAssertEqual(FusionFormat.value(34.1, metricKey: "skin_temp", temperature: .fahrenheit), "93.4 °F")
    }

    /// A DEVIATION (the live BLE pipeline) scales by 9/5 with NO offset and is chipped "Δ". This is the
    /// half a naive `temperatureFromCelsius` call gets wrong: it would render +0.7 as "33.3 °F".
    func testDeviationSkinTempKeepsItsDeltaChipAndSkipsTheOffset() {
        XCTAssertEqual(FusionFormat.value(0.7, metricKey: "skin_temp", temperature: .celsius), "+0.7 Δ°C")
        // 0.7 × 9/5 = 1.26 — NOT 33.3
        XCTAssertEqual(FusionFormat.value(0.7, metricKey: "skin_temp", temperature: .fahrenheit), "+1.3 Δ°F")
        // The regression #111/#622 names by number: the absolute formula turned this into "24.4 °F".
        XCTAssertEqual(FusionFormat.value(-4.2, metricKey: "skin_temp", temperature: .fahrenheit), "-7.6 Δ°F")
    }

    /// Fusion is the screen that can show both modes side by side, so the split must come from the value
    /// and land either side of VitalBands' 20 °C boundary.
    func testTheModeIsDecidedByTheValueNotTheCaller() {
        XCTAssertTrue(FusionFormat.value(19.9, metricKey: "skin_temp", temperature: .celsius).contains("Δ"))
        XCTAssertFalse(FusionFormat.value(20.0, metricKey: "skin_temp", temperature: .celsius).contains("Δ"))
    }

    /// The unit must reach ONLY the temperature branch: every other metric formats identically either
    /// way, so a threaded parameter cannot quietly change bpm/ms/steps.
    func testNonTemperatureMetricsAreUnaffectedByTheUnit() {
        for key in ["resting_hr", "avg_hr", "hrv", "steps", "spo2", "active_kcal", "asleep_min"] {
            XCTAssertEqual(FusionFormat.value(62, metricKey: key, temperature: .celsius),
                           FusionFormat.value(62, metricKey: key, temperature: .fahrenheit),
                           "\(key) changed with the temperature unit")
        }
    }
}
