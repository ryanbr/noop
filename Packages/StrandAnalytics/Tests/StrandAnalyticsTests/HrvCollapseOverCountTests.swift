import XCTest
@testable import StrandAnalytics

/// #1008/#1118/#1331: `HRVAnalyzer.collapseOverCount` — the SHADOW de-dup of the WHOOP 4.0 R-R over-count.
/// Pins that a synthetic over-count (each real beat emitted three times — an exact duplicate plus a
/// two-optical-channel twin ~34 ms off, the #1008 signature) collapses back to ~one beat per real
/// interval, so coverage drops from ~3x toward ~1.0 and the stream becomes beat-accurate again (which is
/// what would let it pass #1127's RSA gate — the #1331 fix). Mirrors the Android HrvCollapseOverCountTest.
final class HrvCollapseOverCountTests: XCTestCase {

    /// 60 real beats, one per second at 1000 ms, each emitted 3x in its second: exact dup + a ~34 ms twin.
    private func overCounted() -> (tsSec: [Int], rrMs: [Double]) {
        var ts: [Int] = []
        var rr: [Double] = []
        for s in 0..<60 {
            let base = 1000.0
            ts.append(s); rr.append(base)             // channel A: the beat
            ts.append(s); rr.append(base)             // exact duplicate
            ts.append(s); rr.append(base + 34.0)      // channel B: same beat, ~34 ms off, same second
        }
        return (ts, rr)
    }

    func testCollapseOverCountRecoversOneBeatPerInterval() {
        let (ts, rr) = overCounted()
        XCTAssertEqual(rr.count, 180, "fixture is 3x over-counted")
        let rawCov = HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr)
        XCTAssertGreaterThan(rawCov, 2.5, "raw over-counted coverage should be ~3x, was \(rawCov)")

        let dd = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: rr)
        // Exact dup + the 34 ms twin (< 40 ms tol) both collapse → one beat per second.
        XCTAssertEqual(dd.rrMs.count, 60, "deduped to one beat per real interval")
        XCTAssertEqual(dd.tsSec.count, 60, "ts and rr stay in lockstep")
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: dd.tsSec, rrMs: dd.rrMs), 1.0, accuracy: 0.1,
                       "deduped coverage collapses toward 1.0")
    }

    func testCollapseOverCountExactDupOnlyKeepsTheChannelTwin() {
        // rrTolMs 0 collapses ONLY exact same-second duplicates (safe floor — no real-beat loss). The
        // ~34 ms channel twin survives, so 180 (=60x[beat + exact-dup + twin]) → 120 (=60x[beat + twin])
        // and coverage stays ~2x. This is the reference line the shadow logs beside the ~40 ms one.
        let (ts, rr) = overCounted()
        let ex = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: rr, rrTolMs: 0)
        XCTAssertEqual(ex.rrMs.count, 120, "exact-dup removed, channel twin kept")
        XCTAssertEqual(ex.tsSec.count, 120)
        XCTAssertGreaterThan(HRVAnalyzer.rrCoverage(tsSec: ex.tsSec, rrMs: ex.rrMs), 1.8,
                             "exact-dup coverage stays ~2x (twins remain)")
    }

    func testCollapseOverCountLeavesACleanStreamUntouched() {
        // A beat-accurate stream (one beat per second, no same-second duplicates) passes through as-is.
        let ts = Array(0..<60)
        let rr = [Double](repeating: 1000.0, count: 60)
        let dd = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: rr)
        XCTAssertEqual(dd.rrMs.count, 60)
        XCTAssertEqual(dd.tsSec, ts)
    }
}
