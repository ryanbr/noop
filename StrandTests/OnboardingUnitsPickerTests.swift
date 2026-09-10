import XCTest
@testable import Strand

/// Guards the onboarding Units control (#781). The ProfileStep wizard step now carries a Metric/Imperial
/// segmented Picker so US users can pick their units during setup, instead of being locked to kg/cm until
/// they later found Settings. That Picker is bound to `@AppStorage(UnitPrefs.systemKey)` and tags its
/// segments with the `UnitSystem` rawValues, exactly like the Settings -> Units card.
///
/// These tests pin that wiring contract so a rename of the key or a rawValue can't silently leave the
/// onboarding picker writing one place while the formatter reads another (which is the bug #781 fixed).
final class OnboardingUnitsPickerTests: XCTestCase {

    /// The onboarding picker and the Settings card and the formatter must all read/write the SAME key,
    /// or the choice made in onboarding wouldn't reach the Weight/Height display.
    func testUnitSystemKeyIsTheSharedAppStorageKey() {
        XCTAssertEqual(UnitPrefs.systemKey, "units.system")
        XCTAssertEqual(UnitPrefs.distanceSystemKey, "units.distance")
    }

    /// The picker tags are the `UnitSystem` rawValues; they must round-trip through the same initializer
    /// the ProfileStep's `unitSystem` computed property uses, so a picked tag resolves back to the case.
    func testRawValuesRoundTripThroughInitializer() {
        XCTAssertEqual(UnitSystem(rawValue: UnitSystem.metric.rawValue), .metric)
        XCTAssertEqual(UnitSystem(rawValue: UnitSystem.imperial.rawValue), .imperial)
        XCTAssertEqual(UnitSystem.metric.rawValue, "metric")
        XCTAssertEqual(UnitSystem.imperial.rawValue, "imperial")
    }

    /// An unset or unknown stored value resolves to Metric, matching the wizard's `@AppStorage` default
    /// and the `?? .metric` fallback in ProfileStep's `unitSystem` computed property.
    func testUnknownRawDefaultsToMetric() {
        XCTAssertEqual(UnitSystem(rawValue: "nonsense") ?? .metric, .metric)
    }

    /// Picking Imperial must actually change what the Weight/Height steppers render. The steppers format
    /// through `UnitFormatter`, so prove the same stored SI value reads differently per picked system.
    func testPickingImperialChangesTheDisplayedWeightAndHeight() {
        let kg = 74.5
        let cm = 178.0
        XCTAssertEqual(UnitFormatter.massFromKilograms(kg, system: .metric), "74.5 kg")
        XCTAssertNotEqual(UnitFormatter.massFromKilograms(kg, system: .imperial),
                          UnitFormatter.massFromKilograms(kg, system: .metric))
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(cm, system: .metric), "178 cm")
        XCTAssertNotEqual(UnitFormatter.heightFromCentimeters(cm, system: .imperial),
                          UnitFormatter.heightFromCentimeters(cm, system: .metric))
    }
}
