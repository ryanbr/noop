import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The classic Today dashboard's two vital cards that were printing something other than what they
/// claimed. Both defects were invisible to the build and to every existing test, because the shared
/// resolvers that answer these questions correctly (`SkinTempDisplay`, `Repository.lastRespDay`) were
/// used by Liquid Today, the Health tab and the Sleep tab — and by this screen alone, not at all.
final class TodayVitalCardTests: XCTestCase {

    private func day(_ d: String, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: 90,
                    deepMin: 80, remMin: 90, lightMin: 200, disturbances: nil,
                    restingHr: 60, avgHrv: 45, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    // MARK: Skin Temp — a bimodal column, one format

    /// An IMPORTED night stores an absolute wrist temperature in the same column the BLE pipeline uses
    /// for a deviation. The old `%+.1f°` signed it regardless, so this read "+33.4°" — a deviation from
    /// baseline that no human body produces.
    func testAbsoluteImportIsNotPrintedAsADeviation() {
        let shown = TodayView.skinTempCardValue(33.4, fahrenheit: false)
        XCTAssertEqual(shown, "33.4 °C")
        XCTAssertFalse(shown.hasPrefix("+"), "an absolute reading must not be signed")
    }

    /// A live deviation keeps its sign — that is the whole point of the ± presentation — and says so.
    func testDeviationKeepsItsSignAndIsLabelled() {
        XCTAssertEqual(TodayView.skinTempCardValue(-0.1, fahrenheit: false), "-0.1 Δ°C")
        XCTAssertEqual(TodayView.skinTempCardValue(0.3, fahrenheit: false), "+0.3 Δ°C")
    }

    /// °F was ignored on this screen alone. A DELTA converts by the scale factor only: +1.0 °C of
    /// deviation is +1.8 °F, never 33.8 — the offset belongs to absolute readings.
    func testFahrenheitConvertsDeviationAndAbsoluteDifferently() {
        XCTAssertEqual(TodayView.skinTempCardValue(1.0, fahrenheit: true), "+1.8 Δ°F")
        XCTAssertEqual(TodayView.skinTempCardValue(33.4, fahrenheit: true), "92.1 °F")
    }

    func testNoReadingReadsAsAnEmDash() {
        XCTAssertEqual(TodayView.skinTempCardValue(nil, fahrenheit: false), "—")
    }

    // MARK: Respiratory — the carry has to be bounded

    /// The reported regression, on the card this screen shows: a WHOOP CSV import ending 2026-07-30,
    /// viewed on 2026-08-13, with thirteen live nights after it that recorded pulse and HRV but no
    /// respiration. The only respiratory value anywhere is a fortnight old, and every unbounded "latest
    /// respiratory" search — the card's old sparkline tail among them — hands it back as today's. The
    /// bounded selector refuses it, so the card reads "—".
    func testFortnightOldImportNoLongerCarries() {
        var days = [day("2026-07-29", resp: 16.2), day("2026-07-30", resp: 15.6)]
        days += (1...13).map { day(String(format: "2026-08-%02d", $0)) }

        XCTAssertEqual(days.last(where: { $0.respRateBpm != nil })?.day, "2026-07-30",
                       "the fixture reproduces the report: the newest respiratory value IS the old import")
        XCTAssertNil(Repository.lastRespDay(days: days, todayKey: "2026-08-13"))
    }

    /// The carry still earns its keep: one missed night must not blank the card.
    func testARecentNightStillCarries() {
        let days = [day("2026-08-11", resp: 14.1), day("2026-08-12")]
        XCTAssertEqual(Repository.lastRespDay(days: days, todayKey: "2026-08-13")?.respRateBpm, 14.1)
    }

    /// Today's own row is never "carried": the bound looks strictly backwards, so a still-forming today
    /// cannot be picked up as its own prior night.
    func testTodayIsNotItsOwnCarry() {
        let days = [day("2026-08-13", resp: 15.0)]
        XCTAssertNil(Repository.lastRespDay(days: days, todayKey: "2026-08-13"))
    }
}
