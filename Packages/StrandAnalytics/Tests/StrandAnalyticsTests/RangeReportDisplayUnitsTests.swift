import XCTest
@testable import StrandAnalytics

/// The #1637 display-unit conversion: the exported trends report printed skin temperature in °C
/// while the app was set to °F, and printed Effort on the stored 0–100 axis while the app was set
/// to WHOOP's 0–21. Both surfaces of the document — the metric cards and the headline sentences —
/// now resolve through `displayValue` / `displayUnit`.
///
/// The oracle for the Android `RangeReportDisplayUnitsTest`; keep the two in lockstep (same
/// fixtures, same assertions — cross-platform parity is the contract).
final class RangeReportDisplayUnitsTests: XCTestCase {

    private let celsius = ReportDisplayUnits.stored
    private let fahrenheit = ReportDisplayUnits(fahrenheit: true, effortFactor: 1.0)
    private let whoopAxis = ReportDisplayUnits(fahrenheit: false, effortFactor: 21.0 / 100.0)

    // MARK: - The identity

    func testStoredIsTheIdentity() {
        XCTAssertFalse(ReportDisplayUnits.stored.fahrenheit)
        XCTAssertEqual(ReportDisplayUnits.stored.effortFactor, 1.0, accuracy: 1e-12)
        for metric in ReportMetric.allCases {
            XCTAssertEqual(RangeReportEngine.displayValue(42.5, metric: metric, units: celsius),
                           42.5, accuracy: 1e-12,
                           "\(metric) must pass through untouched under .stored")
        }
    }

    // MARK: - Skin temp: a DEVIATION scales ×9/5 with no +32 offset

    func testSkinTempDeviationScalesWithoutTheOffset() {
        // The reporter's night: 0.52 °C stored, rendered 0.9 Δ°F (NOT 32.9).
        XCTAssertEqual(RangeReportEngine.displayValue(0.52, metric: .skinTempDev, units: fahrenheit),
                       0.9359999999999999, accuracy: 1e-12)
        XCTAssertEqual(RangeReportEngine.displayValue(-0.5, metric: .skinTempDev, units: fahrenheit),
                       -0.9, accuracy: 1e-12)
        XCTAssertEqual(RangeReportEngine.displayValue(0.0, metric: .skinTempDev, units: fahrenheit),
                       0.0, accuracy: 1e-12)
        // A whole-degree deviation is 1.8 °F, never 33.8 — the +32 offset would be wrong for a delta.
        XCTAssertEqual(RangeReportEngine.displayValue(1.0, metric: .skinTempDev, units: fahrenheit),
                       1.8, accuracy: 1e-12)
        // °C leaves the stored value alone.
        XCTAssertEqual(RangeReportEngine.displayValue(0.52, metric: .skinTempDev, units: celsius),
                       0.52, accuracy: 1e-12)
    }

    func testSkinTempCarriesTheDeltaSymbolTheAppShows() {
        XCTAssertEqual(RangeReportEngine.displayUnit(.skinTempDev, units: celsius), "Δ°C")
        XCTAssertEqual(RangeReportEngine.displayUnit(.skinTempDev, units: fahrenheit), "Δ°F")
        // The Effort axis has no bearing on the temperature unit.
        XCTAssertEqual(RangeReportEngine.displayUnit(.skinTempDev, units: whoopAxis), "Δ°C")
    }

    // MARK: - Effort: the 0–100 ↔ 0–21 axis

    func testEffortRescalesAndNamesItsDenominator() {
        XCTAssertEqual(RangeReportEngine.displayValue(59.0, metric: .strain, units: whoopAxis),
                       12.389999999999999, accuracy: 1e-12)
        XCTAssertEqual(RangeReportEngine.displayValue(100.0, metric: .strain, units: whoopAxis),
                       21.0, accuracy: 1e-12)
        XCTAssertEqual(RangeReportEngine.displayValue(0.0, metric: .strain, units: whoopAxis),
                       0.0, accuracy: 1e-12)
        // Unitless on its native axis (unchanged); named once rescaled, so a bare "12.4" can never
        // be mistaken for a 0–100 score.
        XCTAssertEqual(RangeReportEngine.displayUnit(.strain, units: celsius), "")
        XCTAssertEqual(RangeReportEngine.displayUnit(.strain, units: whoopAxis), "/ 21")
    }

    // MARK: - Every other metric is untouched by every setting

    func testMetricsWithNoDisplayPreferenceNeverMove() {
        for metric in ReportMetric.allCases where metric != .skinTempDev && metric != .strain {
            for units in [celsius, fahrenheit, whoopAxis] {
                XCTAssertEqual(RangeReportEngine.displayValue(42.5, metric: metric, units: units),
                               42.5, accuracy: 1e-12, "\(metric) moved under a display toggle")
                XCTAssertEqual(RangeReportEngine.displayUnit(metric, units: units), metric.unit,
                               "\(metric) changed unit under a display toggle")
            }
        }
    }

    // MARK: - The headline sentences agree with the cards

    func testHeadlineRendersSkinTempInTheChosenUnit() {
        let stat = MetricRangeStat(
            metric: .skinTempDev, n: 4, mean: 0.16,
            min: DayValue(day: "2026-08-19", value: -0.5),
            max: DayValue(day: "2026-08-14", value: 0.52),
            firstHalfMean: -0.2, secondHalfMean: 0.52,
            trend: .rising, latest: DayValue(day: "2026-08-25", value: 0.3))
        XCTAssertEqual(RangeReportEngine.headline(stat, units: celsius),
                       "Skin temp is trending up (avg -0.2 Δ°C → 0.5 Δ°C).")
        XCTAssertEqual(RangeReportEngine.headline(stat, units: fahrenheit),
                       "Skin temp is trending up (avg -0.4 Δ°F → 0.9 Δ°F).")
    }

    func testHeadlineRendersEffortOnTheChosenAxis() {
        let stat = MetricRangeStat(
            metric: .strain, n: 4, mean: 49.5,
            min: DayValue(day: "2026-08-02", value: 30),
            max: DayValue(day: "2026-08-20", value: 70),
            firstHalfMean: 40.0, secondHalfMean: 59.0,
            trend: .rising, latest: DayValue(day: "2026-08-25", value: 55))
        XCTAssertEqual(RangeReportEngine.headline(stat, units: celsius),
                       "Strain is trending up (avg 40.0 → 59.0) - a good sign.")
        XCTAssertEqual(RangeReportEngine.headline(stat, units: whoopAxis),
                       "Strain is trending up (avg 8.4 / 21 → 12.4 / 21) - a good sign.")
    }

    func testHeadlineForAnUnconfigurableMetricIsIdenticalUnderEverySetting() {
        let stat = MetricRangeStat(
            metric: .hrv, n: 4, mean: 58.0,
            min: DayValue(day: "2026-08-03", value: 50),
            max: DayValue(day: "2026-08-11", value: 66),
            firstHalfMean: 62.4, secondHalfMean: 55.1,
            trend: .falling, latest: DayValue(day: "2026-08-25", value: 55.1))
        let expected = "HRV is trending down (avg 62.4 ms → 55.1 ms) - worth a look."
        for units in [celsius, fahrenheit, whoopAxis] {
            XCTAssertEqual(RangeReportEngine.headline(stat, units: units), expected)
        }
    }

    // MARK: - A display toggle never moves the statistics or the verdict

    func testBuildLeavesStatsInStoredUnitsAndKeepsTheSameTrend() {
        let skin: [String: Double] = [
            "2026-08-01": -0.3,
            "2026-08-02": -0.1,
            "2026-08-03": 0.2,
            "2026-08-04": 0.52,
        ]
        let stored = RangeReportEngine.build(metrics: [.skinTempDev: skin],
                                             start: "2026-08-01", end: "2026-08-04")
        let shown = RangeReportEngine.build(metrics: [.skinTempDev: skin],
                                            start: "2026-08-01", end: "2026-08-04",
                                            units: fahrenheit)
        // The statistics themselves stay in STORED units under both settings, so nothing that reads
        // them (comparison, ranking, anything persisted) depends on a cosmetic toggle.
        XCTAssertEqual(stored.metrics, shown.metrics)
        XCTAssertEqual(shown.stat(.skinTempDev)?.max.value, 0.52)
        // Only the rendered sentence differs.
        XCTAssertNotEqual(stored.headlines, shown.headlines)
        XCTAssertTrue(shown.headlines[0].contains("Δ°F"))
        XCTAssertTrue(stored.headlines[0].contains("Δ°C"))
    }

    func testDefaultBuildIsUnchangedByThisFeature() {
        let skin: [String: Double] = ["2026-08-01": -0.3, "2026-08-02": 0.5]
        let implicitDefault = RangeReportEngine.build(metrics: [.skinTempDev: skin],
                                                      start: "2026-08-01", end: "2026-08-02")
        let explicitStored = RangeReportEngine.build(metrics: [.skinTempDev: skin],
                                                     start: "2026-08-01", end: "2026-08-02",
                                                     units: .stored)
        XCTAssertEqual(implicitDefault, explicitStored)
    }
}
