import XCTest
import StrandAnalytics
@testable import Strand

/// The metric-card row the reporter actually pasted in #1637 — `SKIN TEMP  -0.0 °C`, `min -0.5 °C`.
///
/// Every other test for this fix sits one layer BELOW this: they pin the engine helpers and the
/// headline sentence, so reverting `valueText` to `metric.unit` would leave all of them green while
/// the exported page went back to printing °C. This is the one that fails.
///
/// Twin of Kotlin `TrendsReportValueTextTest`; same fixtures, same assertions.
final class TrendsReportValueTextTests: XCTestCase {

    private let celsius = ReportDisplayUnits.stored
    private let fahrenheit = ReportDisplayUnits(fahrenheit: true, effortFactor: 1.0)
    private let whoopAxis = ReportDisplayUnits(fahrenheit: false, effortFactor: 21.0 / 100.0)

    /// A minimal page carrying only what the formatter reads. The report/series are unused by
    /// `valueText`, so an empty report keeps the fixture honest about what is under test.
    private func page(_ units: ReportDisplayUnits) -> TrendsReportPage {
        TrendsReportPage(
            report: RangeReport(start: "2026-08-01", end: "2026-08-25", totalDays: 25,
                                metrics: [], headlines: []),
            range: .days30, series: [:], generatedOn: "Aug 26, 2026", units: units)
    }

    func testSkinTempRowCarriesTheChosenUnit() {
        // The reporter's Aug 14: 0.52 °C stored. The app showed Δ°F; the PDF showed °C.
        XCTAssertEqual(page(celsius).valueText(0.52, .skinTempDev), "+0.5 Δ°C")
        XCTAssertEqual(page(fahrenheit).valueText(0.52, .skinTempDev), "+0.9 Δ°F")
        // Their Aug 19 minimum.
        XCTAssertEqual(page(celsius).valueText(-0.5, .skinTempDev), "-0.5 Δ°C")
        XCTAssertEqual(page(fahrenheit).valueText(-0.5, .skinTempDev), "-0.9 Δ°F")
    }

    func testOnlyPositiveDeviationsGetAnExplicitSign() {
        XCTAssertEqual(page(celsius).valueText(0.0, .skinTempDev), "0.0 Δ°C")
        XCTAssertEqual(page(celsius).valueText(0.1, .skinTempDev), "+0.1 Δ°C")
        XCTAssertEqual(page(celsius).valueText(-0.1, .skinTempDev), "-0.1 Δ°C")
    }

    func testEffortRowFollowsTheChosenAxis() {
        // Native 0–100: a whole number, no unit — unchanged from before the fix.
        XCTAssertEqual(page(celsius).valueText(59.0, .strain), "59")
        // WHOOP 0–21: rescaled, one decimal, and the denominator named.
        XCTAssertEqual(page(whoopAxis).valueText(59.0, .strain), "12.4 / 21")
        XCTAssertEqual(page(whoopAxis).valueText(100.0, .strain), "21.0 / 21")
    }

    func testRowsWithNoDisplayPreferenceAreIdenticalUnderEverySetting() {
        let cases: [(ReportMetric, String)] = [
            (.hrv, "58 ms"), (.restingHr, "58 bpm"), (.recovery, "58"),
            (.respRate, "58.0 br/min"), (.sleepHours, "58.0 h"),
            (.workouts, "58.0 /day"), (.stress, "58.0"),
        ]
        for (metric, expected) in cases {
            for units in [celsius, fahrenheit, whoopAxis] {
                XCTAssertEqual(page(units).valueText(58.0, metric), expected,
                               "\(metric) moved under a display toggle")
            }
        }
    }

    /// Half away from zero, the rule the engine and the Android page share. Android rounded ties
    /// toward +∞ until #1637; these are the values that disagreed.
    func testNegativeTiesRoundAwayFromZero() {
        let p = page(celsius)
        XCTAssertEqual(p.round1Text(-0.25), "-0.3")
        XCTAssertEqual(p.round1Text(-0.35), "-0.4")
        XCTAssertEqual(p.round1Text(-0.45), "-0.5")
        XCTAssertEqual(p.round1Text(-0.15), "-0.2")
        XCTAssertEqual(p.round1Text(-0.05), "-0.1")
        XCTAssertEqual(p.round1Text(-0.75), "-0.8")
    }

    func testPositiveTiesAndOrdinaryValuesAreUnchanged() {
        let p = page(celsius)
        XCTAssertEqual(p.round1Text(0.25), "0.3")
        XCTAssertEqual(p.round1Text(0.35), "0.4")
        XCTAssertEqual(p.round1Text(0.75), "0.8")
        XCTAssertEqual(p.round1Text(0.9359999999999999), "0.9")
        XCTAssertEqual(p.round1Text(12.389999999999999), "12.4")
        XCTAssertEqual(p.round1Text(0.0), "0.0")
    }

    /// A negative tie must reach the SKIN TEMP row, not just the formatter.
    func testANegativeTieRendersIdenticallyToKotlinInTheRowItself() {
        XCTAssertEqual(page(celsius).valueText(-0.25, .skinTempDev), "-0.3 Δ°C")
    }
}
