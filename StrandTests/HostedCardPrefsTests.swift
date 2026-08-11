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
        // Every id must be origin-namespaced so it routes to the right provider and can't collide with a
        // Today DashboardCard id.
        for card in HostedCard.allCases {
            XCTAssertTrue(card.rawValue.contains("."), "hosted id must be namespaced: \(card.rawValue)")
        }
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
