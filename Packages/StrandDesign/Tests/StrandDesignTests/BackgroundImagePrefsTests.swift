import XCTest
@testable import StrandDesign

/// Pins the custom-background pref contract (#custom-background): the three pref-key strings and the
/// four `BackgroundFillMode` rawValues must stay byte-identical to the Kotlin `NoopPrefs` /
/// `BackgroundFillMode` twins (`BackgroundImagePrefsParityTest`) — a drift on either platform would
/// read a different value out of the same UserDefaults/SharedPreferences key.
final class BackgroundImagePrefsTests: XCTestCase {

    func testKeyLiteralsMatchTheKotlinContract() {
        XCTAssertEqual(BackgroundImagePrefs.enabledKey, "noop.backgroundImageEnabled")
        XCTAssertEqual(BackgroundImagePrefs.fillModeKey, "noop.backgroundFillMode")
        XCTAssertEqual(BackgroundImagePrefs.presentKey, "noop.backgroundImagePresent")
    }

    func testFillModeRawValuesMatchTheKotlinContract() {
        XCTAssertEqual(BackgroundFillMode.fill.rawValue, "fill")
        XCTAssertEqual(BackgroundFillMode.fit.rawValue, "fit")
        XCTAssertEqual(BackgroundFillMode.stretch.rawValue, "stretch")
        XCTAssertEqual(BackgroundFillMode.tile.rawValue, "tile")
        // Exactly these four, in this order (parity with the Kotlin enum entries).
        XCTAssertEqual(BackgroundFillMode.allCases.map(\.rawValue), ["fill", "fit", "stretch", "tile"])
    }

    func testResolveIsTolerantAndDefaultsToFill() {
        XCTAssertEqual(BackgroundFillMode.resolve("tile"), .tile)
        XCTAssertEqual(BackgroundFillMode.resolve("nonsense"), .fill)
        XCTAssertEqual(BackgroundFillMode.resolve(""), .fill)
    }
}
