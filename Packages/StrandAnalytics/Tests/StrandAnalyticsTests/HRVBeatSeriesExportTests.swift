import XCTest
@testable import StrandAnalytics

/// Beat-to-beat export: another app computes its own successive-difference HRV from these intervals, so a
/// night is exported only when NOOP would trust the same statistic from the same beats.
final class HRVBeatSeriesExportTests: XCTestCase {

    /// One beat per second, each stamped where the previous interval says it lands.
    func testACleanBeatTrainIsExportable() {
        let ts = Array(1_000..<1_600)
        let rr = ts.map { _ in 1_000.0 }
        XCTAssertTrue(HRVAnalyzer.beatSeriesIsExportable(tsSec: ts, rrMs: rr))
    }

    /// Two beats a second for a heart beating once a second: the stream banks more beat-time than the
    /// clock spans, and its successive differences are not the heart's.
    func testAnOverCountedNightIsNotExportable() {
        var ts: [Int] = [], rr: [Double] = []
        for i in 0..<600 {
            ts.append(1_000 + i); rr.append(900)
            ts.append(1_000 + i); rr.append(905)
        }
        XCTAssertFalse(HRVAnalyzer.beatSeriesIsExportable(tsSec: ts, rrMs: rr))
    }

    /// A banked record: five intervals decomposed across one timestamp. The sum is right, the individual
    /// values are not beat-to-beat measurements.
    func testADecomposedRecordIsNotExportable() {
        var ts: [Int] = [], rr: [Double] = []
        for record in 0..<120 {
            for _ in 0..<5 { ts.append(1_000 + record * 5); rr.append(1_000) }
        }
        XCTAssertFalse(HRVAnalyzer.beatSeriesIsExportable(tsSec: ts, rrMs: rr))
    }
}
