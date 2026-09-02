import XCTest
@testable import StrandAnalytics

final class ClockFormatTests: XCTestCase {
    func testSystemDefersToTheDevice() {
        XCTAssertTrue(ClockFormat.uses24Hour(preference: .system, systemUses24Hour: true))
        XCTAssertFalse(ClockFormat.uses24Hour(preference: .system, systemUses24Hour: false))
    }

    func testAnExplicitChoiceOverridesTheDevice() {
        // The whole point of the setting: a reader in a 24-hour region can ask for 12-hour and get it.
        XCTAssertFalse(ClockFormat.uses24Hour(preference: .twelveHour, systemUses24Hour: true))
        XCTAssertTrue(ClockFormat.uses24Hour(preference: .twentyFourHour, systemUses24Hour: false))
    }

    func testUnknownStoredValuesFallBackToSystemNotToAClock() {
        XCTAssertEqual(ClockFormatPreference.from(stored: nil), .system)
        XCTAssertEqual(ClockFormatPreference.from(stored: ""), .system)
        XCTAssertEqual(ClockFormatPreference.from(stored: "24h"), .system,
                       "an unparseable value must not pin every reader to one clock")
        XCTAssertEqual(ClockFormatPreference.from(stored: "twelveHour"), .twelveHour)
        XCTAssertEqual(ClockFormatPreference.from(stored: "twentyFourHour"), .twentyFourHour)
    }

    /// The stored vocabulary is shared with Android, which writes these exact strings. Pinning the
    /// literals here means renaming a case cannot silently make the two platforms disagree about what a
    /// user's saved preference means.
    func testStoredVocabularyIsPinned() {
        XCTAssertEqual(ClockFormatPreference.system.rawValue, "system")
        XCTAssertEqual(ClockFormatPreference.twelveHour.rawValue, "twelveHour")
        XCTAssertEqual(ClockFormatPreference.twentyFourHour.rawValue, "twentyFourHour")
        XCTAssertEqual(ClockFormatPreference.defaultsKey, "clockFormatPreference")
    }

    func testHourMinutePattern() {
        XCTAssertEqual(ClockFormat.hourMinutePattern(uses24Hour: true), "HH:mm")
        XCTAssertEqual(ClockFormat.hourMinutePattern(uses24Hour: false), "h:mm a")
    }

    /// The template must never be `j`: that is the locale-resolved hour, and routing the reader's choice
    /// back through it is the bug this setting exists to fix.
    func testHourMinuteTemplateNeverDefersToTheLocaleHour() {
        XCTAssertEqual(ClockFormat.hourMinuteTemplate(uses24Hour: true), "Hmm")
        XCTAssertEqual(ClockFormat.hourMinuteTemplate(uses24Hour: false), "hmm")
        XCTAssertFalse(ClockFormat.hourMinuteTemplate(uses24Hour: true).contains("j"))
        XCTAssertFalse(ClockFormat.hourMinuteTemplate(uses24Hour: false).contains("j"))
    }
}
