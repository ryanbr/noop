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

    // MARK: - #1331/#1008 delivery histogram

    /// The shape today's 5/MG log shows: one second written by TWO deliveries (two rows at ord 0 with
    /// different values), beside seconds written once. That is the mechanism the night-wide count exists
    /// to size, and it is invisible to an exact-duplicate check because the values differ.
    func testTwoDeliveriesOnOneSecondAreCounted() {
        let ts =   [100, 100, 101, 102, 102, 102]
        let rr = [872.0, 893.0, 800.0, 500.0, 537.0, 1309.0]
        let ords: [Int?] = [0, 0, 0, 0, 1, 2]   // 100 written twice; 102 is one delivery of three beats
        let line = HRVAnalyzer.deliveryHistogram(tsSec: ts, rrMs: rr, ords: ords)
        XCTAssertEqual(line, "rr deliveries secs[1/2/3/4+]=2/1/0/0 multiSec=33% multiRows=33%"
                       + " multiMs=36% maxDeliv=2 secsNoStart=0 ordUnknown=0")
    }

    /// A clean night: every second written by exactly one delivery, so nothing is flagged.
    func testSingleDeliveryPerSecondReadsClean() {
        let ts = Array(200 ..< 210)
        let line = HRVAnalyzer.deliveryHistogram(tsSec: ts, rrMs: ts.map { _ in 1000.0 },
                                                 ords: ts.map { _ in Int?(0) })
        XCTAssertEqual(line, "rr deliveries secs[1/2/3/4+]=10/0/0/0 multiSec=0% multiRows=0%"
                       + " multiMs=0% maxDeliv=1 secsNoStart=0 ordUnknown=0")
    }

    /// Rows predating the `ord` column must NOT read as "written once" — that would argue against the
    /// mechanism the histogram exists to detect. They are excluded and counted separately instead.
    func testNilOrdsAreExcludedNotAssumedFirst() {
        let line = HRVAnalyzer.deliveryHistogram(tsSec: [300, 300, 301],
                                                 rrMs: [900.0, 910.0, 920.0],
                                                 ords: [nil, nil, 0])
        XCTAssertEqual(line, "rr deliveries secs[1/2/3/4+]=1/0/0/0 multiSec=0% multiRows=0%"
                       + " multiMs=0% maxDeliv=1 secsNoStart=1 ordUnknown=2")
    }

    /// Beat-time rounds half-UP on both platforms. `.rounded()` (Swift, half-away-from-zero) and
    /// `kotlin.math.round` (half-toward-+infinity) agree only for positive values; this pins the explicit
    /// behaviour so the agreement cannot quietly become a coincidence again (#1473).
    func testMsRoundsHalfUpWithoutStdlibRounding() {
        XCTAssertEqual(HRVAnalyzer.msToInt(0.5), 1)
        XCTAssertEqual(HRVAnalyzer.msToInt(1.5), 2)
        XCTAssertEqual(HRVAnalyzer.msToInt(2.5), 3)   // half-to-even would give 2
        XCTAssertEqual(HRVAnalyzer.msToInt(2.4), 2)
        XCTAssertEqual(HRVAnalyzer.msToInt(0), 0)
    }

    /// Percentages round half-up by integer maths, so a tie cannot render differently per platform.
    func testPercentIsIntegerHalfUp() {
        XCTAssertEqual(HRVAnalyzer.pct(1, 8), 13)    // 12.5 -> 13, not 12
        XCTAssertEqual(HRVAnalyzer.pct(3, 8), 38)    // 37.5 -> 38
        XCTAssertEqual(HRVAnalyzer.pct(0, 0), 0)
    }
}
