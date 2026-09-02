import XCTest
@testable import StrandAnalytics

/// #1821: these assert against a REAL `DateFormatter`, not against the identifier string.
///
/// The hour-cycle locale is the mechanism that carries the setting into every formatter that never says
/// "HH:mm" - the ones using `timeStyle = .short` or a `"jmm"` template. If the identifier syntax were
/// wrong, Foundation would quietly fall back to the base locale and every one of those sites would keep
/// showing the region default while the setting appeared to be applied. That failure is silent, so it has
/// to be caught by exercising Foundation itself.
final class ClockFormatLocaleTests: XCTestCase {
    private func shortTime(_ base: String, uses24Hour: Bool) -> String {
        let id = ClockFormat.hourCycleLocaleIdentifier(base: base, uses24Hour: uses24Hour)
        let f = DateFormatter()
        f.locale = Locale(identifier: id)
        f.timeZone = TimeZone(identifier: "UTC")
        f.timeStyle = .short
        f.dateStyle = .none
        // 2026-01-02 22:57 UTC — the reported "22:57" / "10:57 PM".
        return f.string(from: Date(timeIntervalSince1970: 1_767_394_620))
    }

    func testTimeStyleShortHonoursTheForcedHourCycle() {
        // en_GB is a 24-hour region: asking for 12-hour must actually change it.
        XCTAssertTrue(shortTime("en_GB", uses24Hour: false).contains("10"),
                      "12-hour was requested on a 24-hour region and did not take effect")
        XCTAssertTrue(shortTime("en_GB", uses24Hour: true).contains("22"))
        // en_US is a 12-hour region: the reverse must work too, or the setting is one-directional.
        XCTAssertTrue(shortTime("en_US", uses24Hour: true).contains("22"),
                      "24-hour was requested on a 12-hour region and did not take effect")
        XCTAssertTrue(shortTime("en_US", uses24Hour: false).contains("10"))
    }

    /// The other half of the surface: templates containing `j`, which resolve the hour from the locale.
    func testJTemplateHonoursTheForcedHourCycle() {
        func viaTemplate(_ base: String, uses24Hour: Bool) -> String {
            let id = ClockFormat.hourCycleLocaleIdentifier(base: base, uses24Hour: uses24Hour)
            let f = DateFormatter()
            f.locale = Locale(identifier: id)
            f.timeZone = TimeZone(identifier: "UTC")
            f.setLocalizedDateFormatFromTemplate("jmm")
            return f.string(from: Date(timeIntervalSince1970: 1_767_394_620))
        }
        XCTAssertTrue(viaTemplate("en_GB", uses24Hour: false).contains("10"))
        XCTAssertTrue(viaTemplate("en_US", uses24Hour: true).contains("22"))
    }

    func testIdentifierShape() {
        XCTAssertEqual(ClockFormat.hourCycleLocaleIdentifier(base: "en_GB", uses24Hour: true), "en_GB@hours=h23")
        XCTAssertEqual(ClockFormat.hourCycleLocaleIdentifier(base: "fr_FR", uses24Hour: false), "fr_FR@hours=h12")
    }
}
