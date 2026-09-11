import XCTest
@testable import StrandAnalytics

/// #2073: the day-cache reuse line reported only HOW MANY nights were reused, never why the rest missed.
///
/// A field log showed `reused=0/21` on 13 of 17 passes, each costing about 50 seconds of prep and 1.75M
/// row reads, every 15 minutes on battery. A healthy pass reuses all but today, whose heart rate is still
/// growing, so a total miss means something shared by every key moved. Those are different bugs and the
/// count could not tell them apart.
///
/// Keys are `owner|hrCount:hrMaxTs:anchor:detail|streams`. Same cases as the Kotlin twin.
final class DayCacheMissReasonTests: XCTestCase {
    private func key(_ owner: String, _ hr: String, _ streams: String) -> String { "\(owner)|\(hr)|\(streams)" }

    func testAnIdenticalKeyIsNotAMiss() {
        let k = key("my-whoop", "100:200:nil:s", "a|rrAlias5=true")
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(cachedKey: k, freshKey: k), "none")
    }

    func testTodaysGrowingHeartRateIsNamedAsTheHrSegment() {
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(
            cachedKey: key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
            freshKey: key("my-whoop", "140:260:nil:s", "a|rrAlias5=true")), "hr")
    }

    func testAMovedOwnerIsNamedBecauseItInvalidatesEveryDayAtOnce() {
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(
            cachedKey: key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
            freshKey: key("whoop-5A0", "100:200:nil:s", "a|rrAlias5=true")), "owner")
    }

    /// The one input computed ONCE per pass and folded into all 21 keys, so a single flip is a total miss.
    func testThePassGlobalRrAliasIsCalledOutSeparately() {
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(
            cachedKey: key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
            freshKey: key("my-whoop", "100:200:nil:s", "a|rrAlias5=false")), "rrAlias5")
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(
            cachedKey: key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
            freshKey: key("my-whoop", "100:200:nil:s", "b|rrAlias5=true")), "streams")
    }

    func testAKeyThatIsNotTheExpectedShapeSaysSo() {
        XCTAssertEqual(AnalyzeRecentDayCache.missReason(cachedKey: "nopipes", freshKey: "alsonone"), "shape")
    }
}
