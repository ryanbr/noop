import XCTest
import WhoopStore
@testable import Strand

/// #1946: a carried prior-night metric value must be stamped with its day so it is not passed off
/// as tonight's read. The `SleepModel.Metric` tuple now carries `latestDay` alongside `latest`, and
/// `carriedMetricCaption` returns "Carried · <date>" when the value is from a prior day. Byte-parity
/// twin of Kotlin `SleepCarriedStampTest`.
final class SleepCarriedStampTests: XCTestCase {

    private func day(_ d: String, resp: Double? = nil, eff: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: eff,
                    deepMin: 80, remMin: 90, lightMin: 200, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    private func noon(_ d: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.date(from: "\(d) 12:00")!
    }

    /// A value from TODAY's own day is NOT carried — `latestDay` is nil, no stamp.
    func testTodayValueIsNotCarried() {
        let days = [day("2026-08-13", resp: 15.6)]
        let resp = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.respRateBpm }
        XCTAssertEqual(resp.latest ?? 0, 15.6, accuracy: 1e-9)
        XCTAssertNil(resp.latestDay, "today's own value must not be marked as carried")
        XCTAssertNil(SleepModel.carriedMetricCaption(latestDay: resp.latestDay, latest: resp.latest))
    }

    /// A value from a PRIOR day within the carry window IS carried — `latestDay` is set, and the
    /// caption stamps it.
    func testPriorDayValueIsCarriedAndStamped() {
        let days = [day("2026-08-11", resp: 14.1), day("2026-08-12")]
        let resp = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.respRateBpm }
        XCTAssertEqual(resp.latest ?? 0, 14.1, accuracy: 1e-9)
        XCTAssertEqual(resp.latestDay, "2026-08-11", "the carried value's source day is tracked")
        let caption = SleepModel.carriedMetricCaption(latestDay: resp.latestDay, latest: resp.latest)
        XCTAssertNotNil(caption, "a carried value must produce a stamp caption")
        XCTAssertTrue(caption!.contains("Carried"), caption!)
        XCTAssertTrue(caption!.contains("11"), caption!)
    }

    /// A nil latest has no stamp — the tile falls through to "vs typical" or "—".
    func testNoValueHasNoStamp() {
        XCTAssertNil(SleepModel.carriedMetricCaption(latestDay: "2026-08-11", latest: nil))
        XCTAssertNil(SleepModel.carriedMetricCaption(latestDay: nil, latest: 15.6))
        XCTAssertNil(SleepModel.carriedMetricCaption(latestDay: nil, latest: nil))
    }

    /// A stale value (outside the carry window) has no latest and no stamp — it was already nilled
    /// by `freshestCarried`.
    func testStaleValueHasNoLatestAndNoStamp() {
        var days = [day("2026-07-29", resp: 16.2), day("2026-07-30", resp: 15.6)]
        days += (1...13).map { day(String(format: "2026-08-%02d", $0)) }
        let resp = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.respRateBpm }
        XCTAssertNil(resp.latest)
        XCTAssertNil(resp.latestDay)
        XCTAssertNil(SleepModel.carriedMetricCaption(latestDay: resp.latestDay, latest: resp.latest))
    }

    /// A fresh sibling metric (efficiency, present every night) is NOT carried when today has a value.
    func testFreshSiblingIsNotCarried() {
        let days = [day("2026-08-12", eff: 90), day("2026-08-13", eff: 88)]
        let eff = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.efficiency }
        XCTAssertEqual(eff.latest ?? 0, 88, accuracy: 1e-9)
        XCTAssertNil(eff.latestDay, "today's own efficiency is not carried")
    }
}
