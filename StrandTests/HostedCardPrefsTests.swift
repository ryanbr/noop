import XCTest
@testable import Strand

/// Pins the Today-hosted card selection (#today-hosted-cards): the origin-namespaced rawValues (a
/// byte-identical cross-platform contract), the EMPTY opt-in default, and the encode/decode idiom (JSON
/// array, unknown-id drop, de-dupe, order-preserving). Mirrors the Android `HostedCardPrefsTest`
/// case-for-case; a drift on either side fails one of the twins.
final class HostedCardPrefsTests: XCTestCase {

    /// The rawValues are persisted + cross the .noopbak wire, so they are frozen. Origin-namespaced.
    func testRawValuesAreTheFrozenNamespacedContract() {
        XCTAssertEqual(HostedCard.sleepMarks.rawValue, "sleep.sleepMarks")
        XCTAssertEqual(HostedCard.asleepDuration.rawValue, "sleep.asleepDuration")
        // Byte-identical to the Kotlin `HostedCard.STRESS_TODAY`. This id rides .noopbak, so a
        // difference of one character means an Android backup restored here silently drops the card.
        XCTAssertEqual(HostedCard.stressToday.rawValue, "stress.today")
        XCTAssertEqual(HostedCard.trendHRV.rawValue, "trends.hrv")
        XCTAssertEqual(HostedCard.trendRestingHR.rawValue, "trends.restingHr")
        XCTAssertEqual(HostedCard.trendEffort.rawValue, "trends.effort")
    }

    /// The two local-day counters have to agree, and nothing but this test can check them.
    ///
    /// `StressDayCurve` returns the day the widget then STORES, and the widget's read path compares
    /// that against `WidgetSnapshot.localDayNumber` to decide whether the stored curve is still today's.
    /// They are separate copies because no module sees both: the macOS app does not compile the widget
    /// sources, and the widget extension links no packages. This target sees both, so it is the only
    /// place a divergence can be caught, and a divergence would silently drop a valid curve.
    func testTheTwoLocalDayCountersAgree() {
        var cal = Calendar(identifier: .gregorian)
        for zone in ["Europe/London", "America/New_York", "Australia/Lord_Howe", "UTC"] {
            cal.timeZone = TimeZone(identifier: zone)!
            for offset in stride(from: 0, to: 400, by: 7) {
                let d = Date(timeIntervalSince1970: 1_735_732_800 + Double(offset) * 86_400 + 43_200)
                XCTAssertEqual(StressDayCurve.localDayNumber(d, calendar: cal),
                               WidgetSnapshot.localDayNumber(d, calendar: cal),
                               "\(zone) at \(d)")
            }
        }
        // Every id must be origin-namespaced so it routes to the right provider and can't collide with a
        // Today DashboardCard id.
        for card in HostedCard.allCases {
            XCTAssertTrue(card.rawValue.contains("."), "hosted id must be namespaced: \(card.rawValue)")
        }
    }

    /// Every hosted card opens the tab it mirrors, and the tap-to-log card opens nothing.
    ///
    /// Worth pinning because the failure is silent: a card wired to the wrong route still renders, still
    /// taps, and simply lands somewhere else. Nothing about the screen looks wrong.
    func testEachHostedCardOpensItsOwnTab() {
        // The tap-to-log card must NOT navigate: its buttons are its purpose, and a wrapper would put a
        // second meaning behind the same press.
        XCTAssertNil(HostedCard.sleepMarks.route)
        for card in HostedCard.allCases where card != .sleepMarks {
            XCTAssertNotNil(card.route, "\(card.rawValue) taps through to nothing")
        }
        // Sleep-origin cards land on the Sleep tab.
        let sleepOrigin = String(localized: "Sleep")
        for card in HostedCard.allCases where card.origin == sleepOrigin && card != .sleepMarks {
            XCTAssertEqual(card.route, .sleep, "\(card.rawValue) should open Sleep")
        }
        // Named explicitly, as the Kotlin twin names it: the generic checks above would still pass if
        // this card were quietly pointed at the wrong tab.
        XCTAssertEqual(HostedCard.stressToday.route, .stress)
        // The metric's own page, with the SOURCE pinned: `rhr` exists under both my-whoop and
        // xiaomi-band, so a bare key would resolve by catalog declaration order.
        XCTAssertEqual(HostedCard.trendHRV.route, .metricSourced(key: "hrv", source: "my-whoop"))
        XCTAssertEqual(HostedCard.trendRestingHR.route, .metricSourced(key: "rhr", source: "my-whoop"))
        XCTAssertEqual(HostedCard.trendEffort.route, .metricSourced(key: "strain", source: "my-whoop"))
    }

    /// Opt-in surface: nothing is hosted until the user adds a card.
    func testDefaultIsEmpty() {
        XCTAssertEqual(HostedCard.defaultSelection, [])
        XCTAssertEqual(HostedCardPrefs.decodeEnabled(""), [])
        XCTAssertEqual(HostedCardPrefs.decodeEnabled("   "), [])
    }

    func testEncodeDecodeRoundTripsInOrder() {
        let selection: [HostedCard] = [.sleepMarks]
        let encoded = HostedCardPrefs.encode(selection)
        XCTAssertEqual(encoded, "[\"sleep.sleepMarks\"]")
        XCTAssertEqual(HostedCardPrefs.decodeEnabled(encoded), selection)
    }

    /// Unknown ids are dropped, duplicates collapsed — and an all-unknown decode stays EMPTY (unlike the
    /// dashboard, an opt-in surface has no sensible non-empty default to back-fill).
    func testDecodeDropsUnknownAndDedupesNeverBackfills() {
        XCTAssertEqual(
            HostedCardPrefs.decodeEnabled("[\"sleep.sleepMarks\",\"trends.bogus\",\"sleep.sleepMarks\"]"),
            [.sleepMarks]
        )
        XCTAssertEqual(HostedCardPrefs.decodeEnabled("[\"nope\",\"also.nope\"]"), [])
    }

    /// Accepts the legacy comma-joined form as well as the canonical JSON array.
    func testDecodeAcceptsLegacyCommaForm() {
        XCTAssertEqual(HostedCardPrefs.decodeEnabled("sleep.sleepMarks"), [.sleepMarks])
    }
}
