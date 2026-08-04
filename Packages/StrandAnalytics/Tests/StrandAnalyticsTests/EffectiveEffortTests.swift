import XCTest
@testable import StrandAnalytics

/// #1001 — the single Effort figure every read-out on Today resolves through.
///
/// The bug: Effort was resolved independently in three places. Only the hero ring knew about the live
/// in-progress recompute; the Key Metrics tile and the HR chart's edge badge read the stored daily row,
/// which is rewritten only when the heavy daily pass runs. On a morning with a real HR climb the ring
/// showed 2.3 while the other two still showed 0.5.
///
/// These pin the resolution rule itself, and in particular the MAX — which is not a tie-break but the
/// never-drop floor from #489/#506, where a sparse-HR live under-read replaced a real 38.3 with 0.
final class EffectiveEffortTests: XCTestCase {

    /// The reported case: a live value ahead of a stale row wins, so every read-out moves together.
    func testLiveAheadOfAStaleRowWins() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 2.3, stored: 0.5)!, 2.3, accuracy: 1e-9)
    }

    /// The #489/#506 floor: a live UNDER-read must never pull a read-out below what today already earned.
    func testAStoredValueFloorsALiveUnderRead() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0.0, stored: 38.3)!, 38.3, accuracy: 1e-9)
    }

    /// Past days carry no live value and use the row unchanged.
    func testNoLiveValueUsesTheStoredRow() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: 12.5)!, 12.5, accuracy: 1e-9)
    }

    /// Before the day has enough HR to score there is no row yet, so the live value stands alone.
    func testNoStoredRowUsesTheLiveValue() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 4.0, stored: nil)!, 4.0, accuracy: 1e-9)
    }

    /// Neither source is "No Data" — the read-outs must not invent a zero.
    func testNeitherSourceIsNil() {
        XCTAssertNil(StrainScorer.effectiveEffort(live: nil, stored: nil))
    }

    /// A genuine zero is a value, not an absence: a still day scores 0 and must render as 0, not "—".
    func testAGenuineZeroIsKept() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0.0, stored: 0.0)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: 0.0)!, 0.0, accuracy: 1e-9)
    }

    /// Equal sources are stable — resolving twice cannot make a read-out flicker.
    func testEqualSourcesResolveToThatValue() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 7.25, stored: 7.25)!, 7.25, accuracy: 1e-9)
    }
}
