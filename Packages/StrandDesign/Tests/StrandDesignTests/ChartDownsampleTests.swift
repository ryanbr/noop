import XCTest
@testable import StrandDesign

/// PERF (chart-invalidation-and-tooltips): `ChartDownsample.minMaxBucketed` gained a generic
/// date/value-keypath overload so app-target chart types outside this package (WorkoutRecoveryTrendChart,
/// TrainingLoadCard) can share the SAME implementation `TrendChart`/`OverviewHRChart` already use, instead
/// of hand-duplicating the algorithm the way `CompareView.Model.minMaxBucketed` had to. These pin the
/// generic overload's behaviour directly (a bare struct, not `TrendPoint`) and confirm the original
/// `TrendPoint` overload — now implemented by delegating to the generic form — is unchanged.
final class ChartDownsampleTests: XCTestCase {
    private struct Point {
        let date: Date
        let value: Double
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func points(_ n: Int, value: (Int) -> Double) -> [Point] {
        (0..<n).map { Point(date: day($0), value: value($0)) }
    }

    // MARK: - Generic overload

    func testAtOrBelowThresholdPassesThrough() {
        let pts = points(120) { Double($0) }
        let out = ChartDownsample.minMaxBucketed(pts, threshold: 120, targetCount: 400,
                                                   date: { $0.date }, value: { $0.value })
        XCTAssertEqual(out.count, pts.count)
        XCTAssertEqual(out.map(\.date), pts.map(\.date))
    }

    func testAboveThresholdAlwaysKeepsFirstAndLast() {
        let pts = points(1000) { Double($0) }
        let out = ChartDownsample.minMaxBucketed(pts, threshold: 120, targetCount: 400,
                                                   date: { $0.date }, value: { $0.value })
        XCTAssertLessThan(out.count, pts.count)
        XCTAssertEqual(out.first?.date, pts.first?.date)
        XCTAssertEqual(out.last?.date, pts.last?.date)
    }

    func testDownsamplePreservesTheGlobalPeakAndTrough() {
        // A single sharp spike and a single sharp dip inside an otherwise flat series must survive
        // bucketing — this is the whole point of min/max (vs. e.g. naive stride) downsampling.
        var values = [Double](repeating: 5, count: 1000)
        values[137] = 999     // peak
        values[864] = -999    // trough
        let pts = points(1000) { values[$0] }
        let out = ChartDownsample.minMaxBucketed(pts, threshold: 120, targetCount: 400,
                                                   date: { $0.date }, value: { $0.value })
        XCTAssertTrue(out.contains { $0.value == 999 }, "peak must survive bucketing")
        XCTAssertTrue(out.contains { $0.value == -999 }, "trough must survive bucketing")
    }

    func testOutputStaysSortedByDate() {
        let pts = points(1000) { Double($0 % 7) } // noisy, non-monotone values
        let out = ChartDownsample.minMaxBucketed(pts, threshold: 120, targetCount: 400,
                                                   date: { $0.date }, value: { $0.value })
        XCTAssertEqual(out.map(\.date), out.map(\.date).sorted())
    }

    func testDegenerateInputsPassThroughUnchanged() {
        XCTAssertEqual(ChartDownsample.minMaxBucketed([Point](), threshold: 120, targetCount: 400,
                                                        date: { $0.date }, value: { $0.value }).count, 0)
        let two = points(2) { Double($0) }
        XCTAssertEqual(ChartDownsample.minMaxBucketed(two, threshold: 120, targetCount: 400,
                                                        date: { $0.date }, value: { $0.value }).count, 2)
        // targetCount below the 4-vertex floor is rejected (documented guard) — passthrough, not a crash.
        let many = points(1000) { Double($0) }
        XCTAssertEqual(ChartDownsample.minMaxBucketed(many, threshold: 120, targetCount: 2,
                                                        date: { $0.date }, value: { $0.value }).count,
                       many.count)
    }

    // MARK: - `TrendPoint` overload (now delegates to the generic form) — same behaviour as before

    func testTrendPointOverloadMatchesGenericOverload() {
        let trendPoints = (0..<1000).map { TrendPoint(date: day($0), value: Double(($0 * 37) % 113)) }
        let viaConcreteOverload = ChartDownsample.minMaxBucketed(trendPoints, threshold: 120, targetCount: 400)
        let viaGenericOverload = ChartDownsample.minMaxBucketed(trendPoints, threshold: 120, targetCount: 400,
                                                                 date: { $0.date }, value: { $0.value })
        XCTAssertEqual(viaConcreteOverload.map(\.date), viaGenericOverload.map(\.date))
        XCTAssertEqual(viaConcreteOverload.map(\.value), viaGenericOverload.map(\.value))
    }

    func testNearestPointKeepsFullResolutionAndEarlierTie() {
        let pts = [0, 10, 20].map { TrendPoint(date: Date(timeIntervalSince1970: Double($0)), value: Double($0)) }
        XCTAssertNil(nearestTrendPoint(to: Date(), in: []))
        XCTAssertEqual(nearestTrendPoint(to: Date(timeIntervalSince1970: -1), in: pts)?.value, 0)
        XCTAssertEqual(nearestTrendPoint(to: Date(timeIntervalSince1970: 5), in: pts)?.value, 0)
        XCTAssertEqual(nearestTrendPoint(to: Date(timeIntervalSince1970: 16), in: pts)?.value, 20)
        XCTAssertEqual(nearestTrendPoint(to: Date(timeIntervalSince1970: 30), in: pts)?.value, 20)
    }

    func testNearestPointMatchesLinearLookupAcrossGaps() {
        // Compare the pre-optimization rule at every query position, including gaps, exact readings,
        // midpoint ties and dates outside the retained full-resolution series.
        let pts = [0, 2, 10, 18, 100, 102].enumerated().map { index, seconds in
            TrendPoint(date: Date(timeIntervalSince1970: Double(seconds)),
                       value: Double(index), segment: index < 3 ? "first" : "second")
        }
        for tick in -4...212 {
            let date = Date(timeIntervalSince1970: Double(tick) / 2)
            let expected = pts.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }
            let actual = nearestTrendPoint(to: date, in: pts)
            XCTAssertEqual(actual?.date, expected?.date)
            XCTAssertEqual(actual?.value, expected?.value)
            XCTAssertEqual(actual?.segment, expected?.segment)
        }
    }
}
