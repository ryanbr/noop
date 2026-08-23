import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// #1567: the pass-level warning that a scoring run has no device registry behind it.
///
/// The flaw is shared across both platforms — an unresolvable device family does not error, it silently
/// becomes WHOOP5, and on a WHOOP 4.0 that reads a raw skin-temp ADC as centidegrees, misses the 28–42 °C
/// worn gate, and the night yields nothing. What differs is the ROUTE in: Kotlin's `analyzeRecent` takes an
/// optional owner source that a caller could omit; Swift's reads the registry itself, so the only way in is
/// that read failing.
///
/// Paired with Kotlin `OwnerSourceSkinTempScaleTest.anAbsentOwnerSourceNamesItselfAndTheFallbacksItIsUsing`
/// — deliberately NOT byte-identical strings, and the test below pins exactly which part is shared.
final class RegistryUnavailableLineTests: XCTestCase {

    /// The exact bytes.
    func testTheLineIsExactlyThis() {
        XCTAssertEqual(
            AnalyticsEngine.registryUnavailableLine(importedDeviceId: "my-whoop"),
            "analyzeRecent registry=unavailable owner->my-whoop skinTempScale->whoop5")
    }

    /// The shared grammar. Both platforms name the same two fallbacks a reader has to know about — which
    /// device the pass fell back to owning the day, and which temperature scale it therefore used — so the
    /// two logs stay comparable even though the cause tokens differ by design.
    ///
    /// Pinning the shape rather than the whole string is the point: if someone later "fixes the parity" by
    /// making the strings identical, the cause is lost and the line stops answering the question it exists
    /// for. If someone drops a fallback from the line, this fails.
    func testItNamesBothFallbacksTheReaderNeeds() {
        let line = AnalyticsEngine.registryUnavailableLine(importedDeviceId: "my-whoop")
        XCTAssertTrue(line.hasPrefix("analyzeRecent "), line)
        XCTAssertTrue(line.contains("owner->my-whoop"), "must say which owner it fell back to: \(line)")
        XCTAssertTrue(line.contains("skinTempScale->whoop5"), "must say which scale it used: \(line)")
        // The cause token is what SEPARATES the twins — Swift can only get here via a failed read.
        XCTAssertTrue(line.contains("registry=unavailable"), line)
        XCTAssertFalse(line.contains("ownerSource=absent"), "that is the Kotlin route, not this one: \(line)")
    }

    /// The id is not assumed to be the seeded default — a renamed or second strap has to read back honestly.
    func testTheOwnerIsWhicheverIdThePassFellBackTo() {
        XCTAssertEqual(
            AnalyticsEngine.registryUnavailableLine(importedDeviceId: "my-whoop-2"),
            "analyzeRecent registry=unavailable owner->my-whoop-2 skinTempScale->whoop5")
    }

    /// The reason any of this matters, stated in the analytics rather than in prose: an unresolved family
    /// is not a cosmetic mislabel. Same samples, same night, and the fallback scale produces NO reading.
    ///
    /// Values from the reported WHOOP 4.0 log: `raw p50=772`, worn gate 28–42 °C. Twin of the Kotlin
    /// assertion in `OwnerSourceSkinTempScaleTest`.
    func testTheFallbackScaleDropsAWhoop4NightEntirely() throws {
        let start = 1_787_000_000
        let sess = [SleepSession(start: start, end: start + 600, efficiency: 0.9,
                                 stages: [], restingHR: 50, avgHRV: 60.0)]
        let hrs = (0 ..< 600).map { HRSample(ts: start + $0, bpm: 55) }
        let temps = (0 ..< 600).map { SkinTempSample(ts: start + $0, raw: 772) }

        let correct = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps,
                                                                        family: .whoop4),
                                    "a WHOOP 4.0 night must yield a skin temperature")
        XCTAssertTrue((28.0 ... 42.0).contains(correct), "expected a worn-range reading, got \(correct)")

        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5),
                     "the WHOOP5 scale reads 772 as 7.72 °C and drops the whole night")
    }
}
