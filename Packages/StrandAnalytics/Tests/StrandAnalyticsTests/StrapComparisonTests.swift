import XCTest
@testable import StrandAnalytics

/// Pins the #1300 two-strap comparison (reuses the existing per-metric tolerances). Kotlin twin:
/// `StrapComparisonTest`.
final class StrapComparisonTests: XCTestCase {

    private let rhr = MetricArbitrationPolicy.MetricKind.restingHR
    private let hrv = MetricArbitrationPolicy.MetricKind.hrv
    private let steps = MetricArbitrationPolicy.MetricKind.steps
    private let spo2 = MetricArbitrationPolicy.MetricKind.spo2

    func testClassifiesAgreeMinorConflictSingle() {
        // RHR is an absolute tolerance (±3 agree / ±8 minor bpm).
        XCTAssertEqual(StrapComparison.agreement(metric: rhr, a: 55, b: 57), .agree)       // delta 2
        XCTAssertEqual(StrapComparison.agreement(metric: rhr, a: 55, b: 60), .minorDelta)  // delta 5
        XCTAssertEqual(StrapComparison.agreement(metric: rhr, a: 55, b: 70), .conflict)    // delta 15
        XCTAssertEqual(StrapComparison.agreement(metric: rhr, a: 55, b: nil), .single)     // one strap
        XCTAssertEqual(StrapComparison.agreement(metric: rhr, a: nil, b: nil), .single)
    }

    func testPercentToleranceUsesLargerMagnitude() {
        // Steps is a percentage tolerance; an 800-step gap on ~10.8k is within the agree band.
        XCTAssertEqual(StrapComparison.agreement(metric: steps, a: 10000, b: 10800), .agree)
    }

    func testCompareRowPerMetricEitherReportedSkipsOther() {
        let a: [MetricArbitrationPolicy.MetricKind: Double] = [rhr: 55, hrv: 60]
        let b: [MetricArbitrationPolicy.MetricKind: Double] = [rhr: 56, spo2: 97]
        let rows = StrapComparison.compare(a, b)
        XCTAssertEqual(rows.count, 3) // RHR (both) + HRV (a only) + SpO2 (b only); .other never
        XCTAssertEqual(rows.first { $0.metric == rhr }?.agreement, .agree)
        XCTAssertEqual(rows.first { $0.metric == hrv }?.agreement, .single)
        XCTAssertEqual(rows.first { $0.metric == rhr }?.b, 56)
        XCTAssertEqual(rows.first { $0.metric == spo2 }?.a, nil)
    }
}
