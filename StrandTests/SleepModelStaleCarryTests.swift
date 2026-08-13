import XCTest
import WhoopStore
@testable import Strand

/// The Night detail tiles must not present a stale value as this night's reading.
///
/// The regression, reported 2026-08-13: the Sleep tab's Respiratory tile read "15.6" every day for a
/// fortnight — the last value of a WHOOP CSV import that ended 2026-07-30 — because the tile's `latest`
/// was `series.last` with no age bound. This card is the worst place for it: unlike the Health tab's
/// Vital Signs tile it shows NO date beside the number, and it sits under a header that names the night.
/// Android mirrors these cases in `SleepTileCarryStalenessTest`.
final class SleepModelStaleCarryTests: XCTestCase {

    private func day(_ d: String, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: 90,
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

    /// The reported case: last respiratory value 2026-07-30, viewed on 2026-08-13.
    func testStaleRespiratoryRateDoesNotReachTheTile() {
        var days = [day("2026-07-29", resp: 16.2), day("2026-07-30", resp: 15.6)]
        days += (1...13).map { day(String(format: "2026-08-%02d", $0)) }   // live nights, no resp value

        let resp = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.respRateBpm }
        XCTAssertNil(resp.latest)
        // The trend line is HISTORICAL and survives — only the headline claims to be current.
        XCTAssertEqual(resp.series.count, 2)
        XCTAssertEqual(resp.typical ?? 0, 15.9, accuracy: 1e-9)
    }

    /// Sleep-derived siblings are unaffected: they carry a fresh value every night.
    func testFreshSiblingMetricsAreUntouched() {
        var days = [day("2026-07-30", resp: 15.6)]
        days += (1...13).map { day(String(format: "2026-08-%02d", $0)) }

        let eff = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.efficiency }
        XCTAssertEqual(eff.latest ?? 0, 90, accuracy: 1e-9)
    }

    /// The carry still does its job: one missed night must not blank a tile.
    func testRecentValueStillCarries() {
        let days = [day("2026-08-11", resp: 14.1), day("2026-08-12")]
        let resp = SleepModel.metric(days: days, now: noon("2026-08-13")) { $0.respRateBpm }
        XCTAssertEqual(resp.latest ?? 0, 14.1, accuracy: 1e-9)
    }
}
