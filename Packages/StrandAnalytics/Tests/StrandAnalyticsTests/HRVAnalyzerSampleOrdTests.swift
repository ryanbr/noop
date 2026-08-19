import XCTest
@testable import StrandAnalytics

/// #1008: `ord` is the per-TIMESTAMP occurrence counter assigned at write time, so it restarts at 0 for
/// every delivery. That is what separates the two remaining explanations for a second carrying many beats.
/// Kotlin twin: `HrvAnalyzerSampleOrdTest`.
final class HRVAnalyzerSampleOrdTests: XCTestCase {

    func testASecondDeliveredOnceReadsAsOneContiguousRun() {
        // Four beats on one second, written by a single delivery: ord counts 0,1,2,3.
        let out = HRVAnalyzer.densestSecondWindowSample(
            tsSec: [100, 100, 100, 100], rrMs: [700, 750, 800, 850],
            srcCodes: [nil, nil, nil, nil], ords: [0, 1, 2, 3])
        XCTAssertTrue(out.contains("700#0"), out)
        XCTAssertTrue(out.contains("850#3"), out)
    }

    func testASecondBuiltAcrossTwoDeliveriesRepeatsTheCounter() {
        // The tell: ord restarts, so the same second shows 0,1 twice. No other stored field says this.
        let out = HRVAnalyzer.densestSecondWindowSample(
            tsSec: [100, 100, 100, 100], rrMs: [700, 750, 800, 850],
            srcCodes: [nil, nil, nil, nil], ords: [0, 1, 0, 1])
        XCTAssertTrue(out.contains("700#0"), out)
        XCTAssertTrue(out.contains("800#0"), out)   // the repeat
        XCTAssertTrue(out.contains("850#1"), out)
    }

    func testAbsentOrdsLeaveTheLineUnchanged() {
        // Rows written before reads surfaced ord must not gain a stray marker.
        let out = HRVAnalyzer.densestSecondWindowSample(
            tsSec: [100, 100], rrMs: [700, 800], srcCodes: [nil, nil])
        XCTAssertFalse(out.contains("#"), out)
    }
}
