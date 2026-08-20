import XCTest
@testable import WhoopProtocol

/// #1008: the per-chunk clock/packing diag. These assert the two readings the line exists to
/// distinguish — packing vs duplication — and that `corr` agrees with the decoder's own gate.
final class ChunkClockDiagTests: XCTestCase {

    func testNoRrYieldsNoLine() {
        XCTAssertNil(ChunkClockDiag.line(chunk: 1, deviceClockRef: 1_000, wallClockRef: 1_000,
                                         rrTimestamps: []))
    }

    /// One interval per second at a steady rate: `pack` and `dens` both sit at 1.00 — the honest case.
    func testHonestStreamPacksAndDensifiesAtOne() {
        let ts = Array(1_700_000_000 ..< 1_700_000_010)
        let line = ChunkClockDiag.line(chunk: 1, deviceClockRef: 1_000, wallClockRef: 1_000,
                                       rrTimestamps: ts)
        XCTAssertEqual(line, "Backfill: hist clock chunk=1 offset=+0s staleGate=closed"
                       + " rr=10 secs=10 pack=1.00 max=1 span=10s dens=1.00")
    }

    /// PACKING — the shape actually observed on 4.0 (`ord` 0...7 on one second). Every interval of a
    /// record lands on that record's single stamp, so `pack`/`max` blow up while `dens` stays at the true
    /// beat rate. This is what must NOT be misread as re-delivery.
    func testPackedRecordShowsHighPackButHonestDensity() {
        // 3 records, 10s apart, 8 intervals each — 24 beats over a 21s span (~1.14 beats/s).
        var ts: [Int] = []
        for record in 0 ..< 3 {
            ts.append(contentsOf: Array(repeating: 1_700_000_000 + record * 10, count: 8))
        }
        let line = ChunkClockDiag.line(chunk: 4, deviceClockRef: 1_000, wallClockRef: 1_048,
                                       rrTimestamps: ts)
        XCTAssertEqual(line, "Backfill: hist clock chunk=4 offset=+48s staleGate=closed"
                       + " rr=24 secs=3 pack=8.00 max=8 span=21s dens=1.14")
    }

    /// DUPLICATION — the same seconds delivered twice moves `pack` AND `dens` together (both double),
    /// which is how a strap log tells the two apart at a glance.
    func testDuplicatedDeliveryMovesPackAndDensityTogether() {
        let once = Array(1_700_000_000 ..< 1_700_000_010)
        let line = ChunkClockDiag.line(chunk: 2, deviceClockRef: 1_000, wallClockRef: 1_000,
                                       rrTimestamps: once + once)
        XCTAssertEqual(line, "Backfill: hist clock chunk=2 offset=+0s staleGate=closed"
                       + " rr=20 secs=10 pack=2.00 max=2 span=10s dens=2.00")
    }

    /// `staleGate` must mirror `extractHistoricalStreams`: an everyday drift of minutes is DISCARDED by the
    /// decoder, so it must not read as a correction the stored stamps never received.
    func testStaleGateClosedBelowThresholdAndOpenAboveIt() {
        let ts = [1_700_000_000]
        let below = ChunkClockDiag.line(chunk: 1, deviceClockRef: 0,
                                        wallClockRef: histStaleClockThresholdSec, rrTimestamps: ts)
        XCTAssertTrue(below!.contains("staleGate=closed"), "at exactly the threshold the decoder keeps rawTs")
        let above = ChunkClockDiag.line(chunk: 1, deviceClockRef: 0,
                                        wallClockRef: histStaleClockThresholdSec + 1, rrTimestamps: ts)
        XCTAssertTrue(above!.contains("staleGate=open"))
    }

    /// A strap RTC AHEAD of the phone must render as a negative offset, not an unsigned number — the
    /// trajectory across chunks is only readable if the sign survives.
    func testNegativeOffsetKeepsItsSign() {
        let line = ChunkClockDiag.line(chunk: 7, deviceClockRef: 1_200, wallClockRef: 1_000,
                                       rrTimestamps: [1_700_000_000])
        XCTAssertTrue(line!.contains("offset=-200s"), line!)
    }

    /// PARITY REGRESSION. `pack` of 9/8 is an exact binary tie (1.125). `printf("%.2f")` rounds
    /// half-to-EVEN and would render `1.12`, while Kotlin's `String.format` rounds half-UP and renders
    /// `1.13` — the two strap logs would silently disagree. Both platforms now round half-UP by integer
    /// math, so this asserts `1.13` and its Kotlin twin asserts the identical string.
    func testExactTieRoundsHalfUpNotHalfEven() {
        // 9 intervals over 8 stamped seconds: one second carries 2, the rest 1.
        var ts = Array(1_700_000_000 ..< 1_700_000_008)
        ts.append(1_700_000_000)
        let line = ChunkClockDiag.line(chunk: 1, deviceClockRef: 0, wallClockRef: 0, rrTimestamps: ts)
        XCTAssertTrue(line!.contains("pack=1.13"), line!)
    }

    /// Timestamps arrive in emission order, which is not guaranteed sorted across a record boundary;
    /// the span must come from the true min/max, not the first/last element.
    func testSpanUsesMinAndMaxNotFirstAndLast() {
        let line = ChunkClockDiag.line(chunk: 1, deviceClockRef: 0, wallClockRef: 0,
                                       rrTimestamps: [1_700_000_005, 1_700_000_000, 1_700_000_002])
        XCTAssertTrue(line!.contains("span=6s"), line!)
    }
}
