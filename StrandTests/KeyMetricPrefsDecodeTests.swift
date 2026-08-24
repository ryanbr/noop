import XCTest
@testable import Strand

/// #1518: `decodeEnabled` trimmed the whole string but not each token, so a single space cost the user a
/// tile they had enabled.
///
/// `KeyMetric(rawValue:)` matches exactly, so `"charge, effort"` decoded to `[charge]` — the space made
/// `" effort"` unparseable and the loop dropped it silently. Kotlin's twin already trimmed per token
/// (`KeyMetric.fromRaw(token.trim())`), as does `DashboardCards.decodeEnabled`, so Swift was the only
/// decoder of the three that could lose an enabled tile.
///
/// Latent rather than live: `encode` joins rawValues with no spaces and this key is not carried in
/// `.noopbak`, so nothing in the app writes a spaced value today. These pin the contract anyway, because
/// the cost of the assumption is silent and the fix is a single call.
final class KeyMetricPrefsDecodeTests: XCTestCase {

    /// The regression: spaced tokens are real selections and must survive.
    func testSpacedTokensStillDecode() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, effort"),
                       KeyMetricPrefs.decodeEnabled("charge,effort"))
    }

    /// Order is the user's saved order and must be preserved through the trim.
    func testOrderSurvivesTrimming() {
        let spaced = KeyMetricPrefs.decodeEnabled("effort , charge")
        let tight = KeyMetricPrefs.decodeEnabled("effort,charge")
        XCTAssertEqual(spaced, tight)
        XCTAssertEqual(spaced.first, tight.first)
    }

    /// De-duplication still keys on the metric, not the raw text, so a spaced repeat is still a repeat.
    func testSpacedDuplicateIsStillDeduped() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, charge").count, 1)
    }

    /// An unknown token is still dropped — trimming must not turn junk into a match.
    func testUnknownTokensAreStillDropped() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("charge, notAMetric"),
                       KeyMetricPrefs.decodeEnabled("charge"))
    }

    /// An empty or whitespace-only string still yields the full default order (a fresh install).
    func testBlankStringStillYieldsTheDefaultOrder() {
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("   "), KeyMetric.defaultOrder)
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), KeyMetric.defaultOrder)
    }

    /// Queue 11c follow-up (2026-08-24): `.skinTemp` is a NEW persisted case (Skin Temp was already a
    /// "Your Cards" `DashboardCard` option, never a Key Metrics one). Pins the two contract points that
    /// matter for adding a case without disturbing anyone's saved layout: the raw token round-trips
    /// ("skinTemp", byte-identical to Kotlin's `KeyMetric.SKIN_TEMP.raw`), and it does NOT join
    /// `defaultOrder` — a fresh install's default (and an existing user's saved layout) stays
    /// byte-identical to before this case existed.
    func testSkinTempRawTokenRoundTripsAndIsNotInDefaultOrder() {
        XCTAssertEqual(KeyMetric(rawValue: "skinTemp"), .skinTemp)
        XCTAssertEqual(KeyMetric.skinTemp.rawValue, "skinTemp")
        XCTAssertFalse(KeyMetric.defaultOrder.contains(.skinTemp))
        XCTAssertFalse(KeyMetricPrefs.decodeEnabled("").contains(.skinTemp))
    }
}
