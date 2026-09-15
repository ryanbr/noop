import XCTest
@testable import Strand

final class StepsDetailDensityIntegrationTests: XCTestCase {
    private let sparseHistory: [(day: String, value: Double)] = [
        ("2014-01-01", 900),
        ("2026-01-05", 800),
        ("2026-07-05", 700),
        ("2026-10-05", 600),
        ("2026-11-15", 500),
        ("2026-12-05", 400),
        ("2026-12-15", 300),
        ("2026-12-21", 200),
        ("2026-12-30", 100),
        ("2026-12-31", 0),
    ]

    func testEveryStepsDetailSourceForcesBarsDespiteLinePreference() throws {
        let stepMetrics = [
            try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "my-whoop")),
            try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "apple-health")),
            try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "xiaomi-band")),
            try XCTUnwrap(MetricCatalog.metric(key: "steps_est", source: "my-whoop")),
        ]

        for metric in stepMetrics {
            XCTAssertTrue(MetricDetailSteps.showsBars(metricKey: metric.key,
                                                      preferredStyleRaw: TrendChartStyle.line.rawValue),
                          metric.id)
        }
    }

    func testOtherMetricsKeepTheGlobalChartPreference() {
        XCTAssertFalse(MetricDetailSteps.showsBars(metricKey: "hrv",
                                                   preferredStyleRaw: TrendChartStyle.line.rawValue))
        XCTAssertTrue(MetricDetailSteps.showsBars(metricKey: "hrv",
                                                  preferredStyleRaw: TrendChartStyle.bar.rawValue))
    }

    func testOneReadingAndOneAggregatedBucketRemainBars() throws {
        let oneReading = MetricDetailSteps.presentation(
            readings: [("2026-03-08", 1_234)], range: .week)
        XCTAssertEqual(oneReading.series.count, 1)
        XCTAssertEqual(oneReading.series.first?.value, 1_234)

        let oneWeeklyBucket = MetricDetailSteps.presentation(
            readings: [("2026-03-02", 1_000), ("2026-03-04", 2_000)], range: .quarter)
        XCTAssertEqual(oneWeeklyBucket.series.count, 1)
        XCTAssertEqual(oneWeeklyBucket.series.first?.day, "2026-03-02")
        XCTAssertEqual(oneWeeklyBucket.series.first?.value, 1_500)
        let bucketCount = 1
        let mean = 1_500
        let noun = String(localized: "bar")
        let period = MetricDetailSteps.periodLabel(day: "2026-03-02", resolution: .weekly)
        XCTAssertEqual(
            oneWeeklyBucket.accessibilitySummary,
            String(localized: "Steps chart, \(bucketCount) weekly \(noun), latest \(mean) average steps per observed day, \(period)"))

        // Grouping follows the selected app locale; the displayed value is no longer a raw integer.
        let formatter = NumberFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = try XCTUnwrap(formatter.string(from: NSNumber(value: mean)))
        XCTAssertEqual(
            MetricDetailSteps.valueLabel(1_500, resolution: .weekly),
            String(localized: "\(formatted) average steps per observed day"))
    }

    func testSparseHistoryUsesTheExpectedResolutionForEveryRange() {
        let expected: [(ExploreRange, MetricDetailSteps.Resolution)] = [
            (.week, .daily), (.twoWeeks, .daily), (.threeWeeks, .daily), (.month, .daily),
            (.quarter, .weekly), (.half, .monthly), (.year, .monthly), (.all, .monthly),
        ]

        for (range, resolution) in expected {
            let presentation = MetricDetailSteps.presentation(readings: sparseHistory, range: range)
            XCTAssertEqual(presentation.resolution, resolution, range.label)
            XCTAssertFalse(presentation.series.isEmpty, range.label)
            XCTAssertEqual(presentation.series.last?.day,
                           resolution == .monthly ? "2026-12-01" :
                            (resolution == .weekly ? "2026-12-28" : "2026-12-31"), range.label)
        }

        XCTAssertEqual(MetricDetailSteps.widening(from: .twoWeeks).first, .twoWeeks)
        XCTAssertEqual(MetricDetailSteps.widening(from: .threeWeeks).first, .threeWeeks)
    }

    func testPreviousWindowIsTheImmediatelyPrecedingEqualCalendarPeriod() {
        let readings: [(day: String, value: Double)] = [
            ("2025-12-20", 99_999),
            ("2026-01-01", 500),
            ("2026-01-07", 1_500),
            ("2026-01-08", 1_000),
            ("2026-01-14", 3_000),
        ]

        let previous = MetricDetailSteps.previousPresentation(
            readings: readings, range: .week, currentAnchorDay: "2026-01-14")

        XCTAssertEqual(previous.series.map(\.day), ["2026-01-01", "2026-01-07"])
        XCTAssertEqual(previous.series.map(\.value), [500, 1_500])
    }

    func testAllStepsUsesFullHistoryAndRangeParticipatesInLoadIdentity() {
        XCTAssertTrue(MetricDetailSteps.requiresFullHistory(metricKey: "steps", range: .all))
        XCTAssertTrue(MetricDetailSteps.requiresFullHistory(metricKey: "steps_est", range: .all))
        XCTAssertFalse(MetricDetailSteps.requiresFullHistory(metricKey: "steps", range: .year))
        XCTAssertFalse(MetricDetailSteps.requiresFullHistory(metricKey: "hrv", range: .all))

        let month = MetricDetailSteps.loadIdentity(metricID: "apple-health:steps", refreshSequence: 4,
                                                   skinTemperatureStyle: "", range: .month)
        let all = MetricDetailSteps.loadIdentity(metricID: "apple-health:steps", refreshSequence: 4,
                                                 skinTemperatureStyle: "", range: .all)
        XCTAssertNotEqual(month, all)

        let old = MetricDetailSteps.presentation(
            readings: [("2014-01-01", 900), ("2026-12-31", 100)], range: .all)
        XCTAssertEqual(old.series.first?.day, "2014-01-01")
    }
}
