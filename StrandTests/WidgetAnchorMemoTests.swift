import XCTest
import WhoopStore
@testable import Strand

/// Pins the #1051-shaped anchor memo: the Live Activity resolves the widget anchor on every ~1-3 Hz live-HR
/// tick, so `WidgetAnchorMemo` must reuse the last row while its key is unchanged and recompute exactly when
/// `days` changes (`refreshSeq`) or the day rolls. `compute` is injected here to count recomputes without a
/// live `Repository` — the twin of Android's `NotifyDayStateCacheTest`.
final class WidgetAnchorMemoTests: XCTestCase {

    private func row(_ recovery: Double) -> DailyMetric {
        DailyMetric(day: "2026-08-06", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery,
                    strain: nil, exerciseCount: nil)
    }

    func testReusesAnchorWhileKeyUnchanged() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0
        func resolve() -> DailyMetric? {
            memo.resolve(days: [], seq: 5, logicalKey: "2026-08-06", localKey: "2026-08-06") { _, _, _ in
                computeCalls += 1
                return self.row(Double(computeCalls))
            }
        }
        let first = resolve()
        for _ in 0..<1_000 { XCTAssertEqual(resolve(), first) }
        XCTAssertEqual(computeCalls, 1, "unchanged key must reuse the memoized anchor")
        XCTAssertEqual(first?.recovery, 1.0)
    }

    func testRefreshSeqBumpRecomputes() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0
        let compute: ([DailyMetric], String, String) -> DailyMetric? = { _, _, _ in
            computeCalls += 1
            return self.row(Double(computeCalls))
        }
        _ = memo.resolve(days: [], seq: 1, logicalKey: "d", localKey: "d", compute: compute)
        // A new day-list instance bumps refreshSeq → the anchor may have moved, so recompute.
        _ = memo.resolve(days: [], seq: 2, logicalKey: "d", localKey: "d", compute: compute)
        XCTAssertEqual(computeCalls, 2, "a new refreshSeq (days changed) must recompute")
    }

    func testDayRolloverRecomputes() {
        var memo = WidgetAnchorMemo()
        var computeCalls = 0
        let compute: ([DailyMetric], String, String) -> DailyMetric? = { _, _, _ in
            computeCalls += 1
            return self.row(Double(computeCalls))
        }
        _ = memo.resolve(days: [], seq: 1, logicalKey: "2026-08-06", localKey: "2026-08-06", compute: compute)
        // Local midnight roll (localKey moves, logicalKey not yet).
        _ = memo.resolve(days: [], seq: 1, logicalKey: "2026-08-06", localKey: "2026-08-07", compute: compute)
        // Logical 04:00 roll (logicalKey moves too).
        _ = memo.resolve(days: [], seq: 1, logicalKey: "2026-08-07", localKey: "2026-08-07", compute: compute)
        XCTAssertEqual(computeCalls, 3, "each local/logical day-key change must recompute")
    }
}
