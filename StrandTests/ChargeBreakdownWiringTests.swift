import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Swift twin of the Android `RecoveryDriversUiTest` wiring cases.
///
/// This suite could not exist before: the derivation lived as a private method inside `TodayView` (and a
/// byte-identical copy inside `CoupledView`), reachable only by rendering the view, so the iOS end of the
/// "What shaped it" path had no test at all while Android's did. `ChargeBreakdownWiring.breakdown` is that
/// derivation lifted out unchanged.
///
/// Case mapping against the Kotlin suite, stated so the gap is legible rather than implied:
///   * `rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable` - twinned below.
///   * `coldStartHistoryProducesNoRows` - twinned below.
///   * `scoredDayProducesDriverRows` - twinned below, and it carries the confidence assertion too, since
///     this API returns the tier in the same tuple where Kotlin has a separate `chargeConfidenceTier`.
///   * `nullDayProducesNoRows` - deliberately NOT twinned. This API takes a non-optional row, so the
///     nil-row guard stays in the view where it belongs; there is nothing here to assert.
final class ChargeBreakdownWiringTests: XCTestCase {

    private func day(_ d: String, hrv: Double? = 55, rhr: Int? = 55, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 450, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: nil,
                    exerciseCount: nil)
    }

    /// A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
    /// which is nobody's resting HR, so the row must be absent. The HRV row still stands, since that
    /// baseline is real. The display day itself carries a reading, so this pins the BASELINE being
    /// unusable rather than the reading being missing.
    ///
    /// The gate is not in this file: `RecoveryScorer.chargeDrivers` applies it (#1990). This pins the end
    /// of the path, the surface a user actually sees.
    func testRhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        let history = (1...6).map { day(String(format: "2026-01-%02d", $0), rhr: nil) }
        let today = day("2026-01-07", rhr: 55)
        let out = ChargeBreakdownWiring.breakdown(days: history + [today], row: today, sleepPerfPercent: 85)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"),
                      "the HRV baseline is real, so its row must still be there: \(labels)")
        XCTAssertFalse(labels.contains("Resting heart rate"),
                       "no usable resting-HR baseline, so no RHR row: \(labels)")
    }

    /// Two nights only: the HRV baseline is not usable yet, so there are no honest drivers and the sheet
    /// hides rather than showing fabricated rows.
    func testColdStartHistoryProducesNoBreakdown() {
        let days = [day("2026-01-01"), day("2026-01-02")]
        XCTAssertNil(ChargeBreakdownWiring.breakdown(days: days, row: days[1], sleepPerfPercent: 85))
    }

    /// The usable-baseline half of the pair: a real history banks both baselines, so both rows appear and
    /// the surfaced tier is past calibrating.
    func testAScoredDayProducesDriverRowsAndATier() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let out = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85)
        XCTAssertNotNil(out)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"), "\(labels)")
        XCTAssertTrue(labels.contains("Resting heart rate"), "\(labels)")
        XCTAssertNotEqual(out?.confidence, .calibrating)
    }
}
