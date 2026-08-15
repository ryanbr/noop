import XCTest
import WhoopStore
@testable import Strand

/// `Repository.nonEmptyMetricIDs` answers "which catalog rows get the faint no-data dot" from a handful of
/// DISTINCT-key queries instead of one full series read per metric. That is only safe while it mirrors
/// `exploreSeries`' source precedence exactly — the two are separate code paths that must agree, or the
/// Explore list marks a metric empty and then opens a detail screen full of readings.
///
/// These pin the three rules that make them agree.
final class MetricEmptinessProbeTests: XCTestCase {

    private let whoop = Repository.whoopSource

    private func metric(_ key: String, source: String) -> MetricDescriptor {
        MetricDescriptor(key: key, title: key, category: "Test", unit: "", source: source,
                         icon: "circle", decimals: 0, higherIsBetter: nil)
    }

    /// A day carrying only `avgHrv`, so the daily-column layer has exactly one key to find.
    private func dayWithHRV(_ dayStr: String, avgHrv: Double?) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: avgHrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: Stored series

    func testAStoredKeyCountsAsNonEmpty() {
        let m = metric("steps", source: whoop)
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [whoop: ["steps"]], days: [],
                                               whoopSource: whoop)
        XCTAssertEqual(ids, [m.id])
    }

    func testAKeyNoSourceHoldsIsEmpty() {
        let m = metric("vo2max", source: whoop)
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [whoop: ["steps"]], days: [],
                                               whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: Source isolation

    func testAKeyIsOnlyFoundUnderItsOwnSource() {
        // The same key under a DIFFERENT source must not satisfy this metric — Explore lists
        // "Steps · Whoop" and "Steps · Mi Band" as separate rows, and each has its own answer.
        let mi = metric("steps", source: "xiaomi-band")
        let ids = Repository.nonEmptyMetricIDs([mi], keysBySource: [whoop: ["steps"]], days: [],
                                               whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    func testEachSourceIsAnsweredFromItsOwnKeySet() {
        let a = metric("steps", source: whoop)
        let b = metric("steps", source: "xiaomi-band")
        let ids = Repository.nonEmptyMetricIDs([a, b],
                                               keysBySource: [whoop: [], "xiaomi-band": ["steps"]],
                                               days: [], whoopSource: whoop)
        XCTAssertEqual(ids, [b.id])
    }

    // MARK: The daily-column fallback

    func testADailyColumnValueCountsEvenWithNoStoredSeries() {
        // `exploreSeries` layers the merged daily column under the WHOOP series, so a metric backed ONLY
        // by that column has data. Missing this was the trap in replacing the old probe: a DISTINCT-key
        // query alone would have marked HRV empty for every strap-only user.
        let m = metric("hrv", source: whoop)
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [whoop: []],
                                               days: [dayWithHRV("2026-08-01", avgHrv: 48)],
                                               whoopSource: whoop)
        XCTAssertEqual(ids, [m.id])
    }

    func testDaysWithOnlyNilsDoNotCount() {
        let m = metric("hrv", source: whoop)
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [whoop: []],
                                               days: [dayWithHRV("2026-08-01", avgHrv: nil)],
                                               whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    func testTheDailyColumnFallbackIsWhoopOnly() {
        // `exploreSeries` gates the daily layer on the WHOOP source; every other source goes through
        // `series(...)`, which reads that source's rows verbatim. An Apple-Health metric must therefore
        // NOT inherit data from the merged daily column.
        let apple = metric("hrv", source: "apple-health")
        let ids = Repository.nonEmptyMetricIDs([apple], keysBySource: ["apple-health": []],
                                               days: [dayWithHRV("2026-08-01", avgHrv: 48)],
                                               whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    func testAKeyWithNoDailyColumnFallsBackToNothing() {
        // `sleep_latency` has no daily column, so days full of other values must not rescue it.
        let m = metric("sleep_latency", source: whoop)
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [whoop: []],
                                               days: [dayWithHRV("2026-08-01", avgHrv: 48)],
                                               whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: Degenerate input

    func testAnUnknownSourceIsTreatedAsEmptyRatherThanCrashing() {
        let m = metric("steps", source: "nutrition-csv")
        let ids = Repository.nonEmptyMetricIDs([m], keysBySource: [:], days: [], whoopSource: whoop)
        XCTAssertTrue(ids.isEmpty)
    }

    func testAnEmptyCatalogYieldsAnEmptySet() {
        XCTAssertTrue(Repository.nonEmptyMetricIDs([], keysBySource: [whoop: ["steps"]], days: [],
                                                   whoopSource: whoop).isEmpty)
    }
}
