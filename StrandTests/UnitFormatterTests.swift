import XCTest
@testable import Strand

/// Pins the exact conversion factors and the formatted-string shapes for the Imperial/Metric display
/// layer (D#103). NOOP stores everything in SI; this is the only place the conversions live, so a wrong
/// factor here would silently mis-display every weight/distance/height/temperature in the app. These
/// tests exist specifically so that can't ship. Mirrors the Android UnitFormatterTest case-for-case.
final class UnitFormatterTests: XCTestCase {

    // MARK: - Factors (the load-bearing numbers)

    func testDistanceFactorIsExact() {
        // 1 km = 0.621371 mi
        XCTAssertEqual(UnitFormatter.milesPerKilometer, 0.621371, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.kmToMiles(1), 0.621371, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kmToMiles(10), 6.21371, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kmToMiles(0), 0, accuracy: 1e-12)
    }

    func testMassFactorIsExact() {
        // 1 kg = 2.20462 lb
        XCTAssertEqual(UnitFormatter.poundsPerKilogram, 2.20462, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.kgToPounds(1), 2.20462, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.kgToPounds(75), 165.3465, accuracy: 1e-4)
    }

    func testHeightFactorIsExact() {
        // 1 inch = 2.54 cm  →  1 cm = 0.393700787 in
        XCTAssertEqual(UnitFormatter.centimetersPerInch, 2.54, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.cmToInches(2.54), 1, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.cmToInches(30.48), 12, accuracy: 1e-9)
    }

    func testTemperatureFactorIsExact() {
        // °F = °C * 9/5 + 32
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(0), 32, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(100), 212, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(37), 98.6, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(-40), -40, accuracy: 1e-9)   // the crossover
    }

    // MARK: - Distance formatting

    func testDistanceFromMetersMetric() {
        XCTAssertEqual(UnitFormatter.distanceFromMeters(1200, system: .metric), "1.2 km")
        XCTAssertEqual(UnitFormatter.distanceFromMeters(850, system: .metric), "850 m")
    }

    func testDistanceFromMetersImperial() {
        // 5000 m = 5 km = 3.106855 mi
        XCTAssertEqual(UnitFormatter.distanceFromMeters(5000, system: .imperial), "3.1 mi")
        // 100 m is well below a tenth of a mile → yards (100 m ≈ 109 yd)
        XCTAssertEqual(UnitFormatter.distanceFromMeters(100, system: .imperial), "109 yd")
    }

    func testPaceFormatsAndConvertsPerUnit() {
        // #1195: the live-workout distance/pace surface. Must byte-match the Kotlin formatter.
        // 5:00 /km (300 s/km) stays 5:00 /km in metric.
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(300, system: .metric), "5:00 /km")
        // Same pace per MILE: 300 / 0.621371 = 482.8 s ≈ 8:03 /mi.
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(300, system: .imperial), "8:03 /mi")
        // Seconds pad to two digits.
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(245, system: .metric), "4:05 /km")
    }

    func testPaceIsDashWhenUndefined() {
        // nil (no distance yet) and non-positive are both "—" — never "0:00", which reads as instant.
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(nil, system: .metric), "—")
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(0, system: .imperial), "—")
        XCTAssertEqual(UnitFormatter.paceFromSecPerKm(-1, system: .metric), "—")
    }

    func testDistanceFromKilometers() {
        XCTAssertEqual(UnitFormatter.distanceFromKilometers(12.4, system: .metric), "12.4 km")
        // 12.4 km * 0.621371 = 7.704... → "7.7 mi"
        XCTAssertEqual(UnitFormatter.distanceFromKilometers(12.4, system: .imperial), "7.7 mi")
    }

    // MARK: - Mass formatting

    func testMassFromKilograms() {
        XCTAssertEqual(UnitFormatter.massFromKilograms(74.5, system: .metric), "74.5 kg")
        // 74.5 * 2.20462 = 164.24419 → "164.2 lb"
        XCTAssertEqual(UnitFormatter.massFromKilograms(74.5, system: .imperial), "164.2 lb")
    }

    // MARK: - Height formatting

    func testHeightFromCentimetersMetric() {
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(178, system: .metric), "178 cm")
    }

    func testHeightFromCentimetersImperial() {
        // 178 cm = 70.07 in = 5 ft 10 in
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(178, system: .imperial), "5′ 10″")
        // 152.4 cm = exactly 60 in = 5 ft 0 in
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(152.4, system: .imperial), "5′ 0″")
    }

    func testHeightRoundingCarriesInchesIntoFeet() {
        // 182.7 cm ≈ 71.93 in → rounds to 72 in, which must carry to 6 ft 0 in (never "5 ft 12 in").
        let (ft, inch) = UnitFormatter.cmToFeetInches(182.7)
        XCTAssertEqual(ft, 6)
        XCTAssertEqual(inch, 0)
    }

    // MARK: - Temperature formatting

    func testAbsoluteTemperature() {
        XCTAssertEqual(UnitFormatter.temperatureFromCelsius(33.4, unit: .celsius), "33.4 °C")
        // 33.4 °C = 92.12 °F → "92.1 °F"
        XCTAssertEqual(UnitFormatter.temperatureFromCelsius(33.4, unit: .fahrenheit), "92.1 °F")
    }

    func testTemperatureDeltaHasNoOffset() {
        // A +0.6 °C deviation is a 1.08 °F deviation — scale by 9/5, do NOT add 32.
        XCTAssertEqual(UnitFormatter.temperatureDeltaFromCelsius(0.6, unit: .fahrenheit), "1.1 °F")
        XCTAssertEqual(UnitFormatter.temperatureDeltaFromCelsius(0.6, unit: .celsius), "0.6 °C")
    }

    /// The Double-returning delta converter and the String one must not drift: callers that need
    /// locale-aware decimals (the illness-signal label formats through AppLanguage.activeLocale) use the
    /// Double form, and a second copy of the 9/5 rule is exactly what that split invites.
    func testDeltaConverterAgreesWithTheFormatter() {
        XCTAssertEqual(UnitFormatter.celsiusDeltaToFahrenheit(0.6), 1.08, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusDeltaToFahrenheit(-4.2), -7.56, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusDeltaToFahrenheit(0), 0, accuracy: 1e-9)
        for c in stride(from: -5.0, through: 5.0, by: 0.25) {
            XCTAssertEqual(
                String(format: "%.1f", UnitFormatter.celsiusDeltaToFahrenheit(c)) + " °F",
                UnitFormatter.temperatureDeltaFromCelsius(c, unit: .fahrenheit),
                "diverged at \(c) °C")
        }
    }

    /// A delta must never pick up the +32: at 0 the two conversions differ by exactly the offset, which
    /// is what made a −4.2 °C deviation read as a fever once before (#111/#622).
    func testDeltaAndAbsoluteConversionsAreDistinct() {
        XCTAssertEqual(UnitFormatter.celsiusToFahrenheit(0), 32.0, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.celsiusDeltaToFahrenheit(0), 0.0, accuracy: 1e-9)
    }

    /// The illness-signal phrase. Expected strings generated by compiling SkinTempDisplay standalone
    /// with swiftc and pasted verbatim — the oracle rule, not arithmetic done by eye.
    func testSkinTempSignalPhraseHandlesBothModes() {
        // Deviation (live BLE): signed, "Δ" chip, ×9/5 with NO offset.
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(0.7, fahrenheit: false, locale: nil), "+0.7 Δ°C")
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(0.7, fahrenheit: true, locale: nil), "+1.3 Δ°F")
        // Absolute (CSV / Apple Health): unsigned, bare chip, +32 offset applied.
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(34.1, fahrenheit: false, locale: nil), "34.1 °C")
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(34.1, fahrenheit: true, locale: nil), "93.4 °F")
    }

    /// The 20 °C boundary decides the mode, and it belongs to the ABSOLUTE side.
    func testSkinTempSignalPhraseSplitsAtTwentyDegrees() {
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(19.9, fahrenheit: false, locale: nil), "+19.9 Δ°C")
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(20.0, fahrenheit: false, locale: nil), "20.0 °C")
    }

    /// The whole reason the number is formatted here instead of by SkinTempDisplay: the banner passes
    /// AppLanguage.activeLocale, and a German reader must see "0,7" rather than "0.7".
    func testSkinTempSignalPhraseHonoursTheLocalesDecimalSeparator() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(0.7, fahrenheit: false, locale: de), "+0,7 Δ°C")
        XCTAssertEqual(UnitFormatter.skinTempSignalPhrase(34.1, fahrenheit: false, locale: de), "34,1 °C")
        XCTAssertEqual(
            UnitFormatter.skinTempSignalPhrase(0.7, fahrenheit: true, locale: Locale(identifier: "fr_FR")),
            "+1,3 Δ°F")
    }

    // #111/#622: skin_temp holds EITHER a signed deviation (v < 20 °C) or an absolute reading (v >= 20 °C).
    // A DEVIATION converts ×9/5 with NO +32 (the absolute formula turned a −4.2 °C deviation into the
    // nonsense "24.4 °F") and is labelled as a signed baseline delta — "Δ°C" / "Δ°F", sign always shown —
    // so −0.1 never reads as a broken thermometer (#622/#1224). An ABSOLUTE reading gets the full C→F and
    // a plain unit. Pin both branches.
    func testSkinTempMetricPicksDeltaVsAbsoluteByValue() {
        guard let skin = MetricCatalog.all.first(where: { $0.key == "skin_temp" }) else {
            return XCTFail("skin_temp descriptor missing")
        }
        // DEVIATION (< 20 °C): ×9/5, no +32, signed Δ unit — NOT the bogus absolute 24.4 °F.
        XCTAssertEqual(skin.format(-4.2, system: .imperial, temperature: .fahrenheit), "-7.6 Δ°F")
        XCTAssertEqual(skin.format(0.6, system: .imperial, temperature: .fahrenheit), "+1.1 Δ°F")
        // ABSOLUTE (>= 20 °C, e.g. an imported WHOOP export reading): full C→F with +32, plain unit — 34 °C = 93.2 °F.
        XCTAssertEqual(skin.format(34.0, system: .imperial, temperature: .fahrenheit), "93.2 °F")
        // Celsius takes the same split: a deviation stays signed "Δ°C", an absolute reading a plain "°C".
        XCTAssertEqual(skin.format(0.6, system: .metric, temperature: .celsius), "+0.6 Δ°C")
        XCTAssertEqual(skin.format(34.0, system: .metric, temperature: .celsius), "34.0 °C")
    }

    // MARK: - Preference resolution

    func testTemperatureOverrideResolution() {
        // No explicit override → follows the length/mass system.
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .metric, override: ""), .celsius)
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .imperial, override: ""), .fahrenheit)
        // Explicit override wins regardless of the system.
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .imperial, override: "celsius"), .celsius)
        XCTAssertEqual(UnitPrefs.resolveTemperature(system: .metric, override: "fahrenheit"), .fahrenheit)
    }

    // MARK: - Unit labels

    func testUnitLabels() {
        XCTAssertEqual(UnitFormatter.distanceUnit(.metric), "km")
        XCTAssertEqual(UnitFormatter.distanceUnit(.imperial), "mi")
        XCTAssertEqual(UnitFormatter.massUnit(.metric), "kg")
        XCTAssertEqual(UnitFormatter.massUnit(.imperial), "lb")
        XCTAssertEqual(UnitFormatter.temperatureUnit(.celsius), "°C")
        XCTAssertEqual(UnitFormatter.temperatureUnit(.fahrenheit), "°F")
    }
}
