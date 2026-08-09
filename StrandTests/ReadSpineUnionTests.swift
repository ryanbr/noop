import XCTest
import WhoopStore
@testable import Strand

/// #-: the per-column duplicate-day coalesce (`Repository.coalesceDay`). Byte-identical twin of the Android
/// `ReadSpineUnionTest` cases (same fixtures, same numbers). A day two source ids in the SAME bucket both
/// cover is folded per column — the winner keeps every column it carries and the filler supplies only the
/// nils — with the sleep block and the raw red/IR pair moving as whole groups. Ported from
/// tanarchytan/noop @de370b85.
final class ReadSpineUnionTests: XCTestCase {

    /// Swift `DailyMetric` carries no `deviceId` (external to the row); the value columns are the parity
    /// contract, so the fixtures set only those.
    private func dm(_ day: String,
                    totalSleepMin: Double? = nil, efficiency: Double? = nil, deepMin: Double? = nil,
                    remMin: Double? = nil, lightMin: Double? = nil, disturbances: Int? = nil,
                    restingHr: Int? = nil, avgHrv: Double? = nil, recovery: Double? = nil,
                    strain: Double? = nil, exerciseCount: Int? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
                    steps: steps)
    }

    /// A hollow winner (steps and nothing else) keeps every column the other strap's fully-scored row
    /// carries, instead of the old whole-row first-wins that discarded it.
    func testAHollowWinningRowKeepsTheOtherStrapsColumns() {
        let day = "2026-07-29"
        let active = dm(day, steps: 10_775)
        let other = dm(day, totalSleepMin: 435, efficiency: 91, deepMin: 96, remMin: 110, lightMin: 229,
                       restingHr: 64, avgHrv: 37.06, recovery: 93.2, strain: 8.4)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.steps, 10_775)          // the winner's own reading survives
        XCTAssertEqual(merged.totalSleepMin, 435)
        XCTAssertEqual(merged.deepMin, 96)
        XCTAssertEqual(merged.recovery, 93.2)
        XCTAssertEqual(merged.restingHr, 64)
        XCTAssertEqual(merged.avgHrv ?? 0, 37.06, accuracy: 1e-9)
        XCTAssertEqual(merged.strain, 8.4)
    }

    /// A measured zero is a READING, not an absence — a 0 steps / 0 strain / 0 HRV winner is kept.
    func testAMeasuredZeroIsAValueNotAnAbsence() {
        let day = "2026-07-29"
        let active = dm(day, avgHrv: 0, strain: 0, steps: 0)
        let other = dm(day, avgHrv: 42, strain: 14.7, steps: 9_120)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.steps, 0)
        XCTAssertEqual(merged.strain, 0)
        XCTAssertEqual(merged.avgHrv, 0)
    }

    /// The sleep block moves as a GROUP: a winner carrying a sleep total keeps its OWN (nil) stages rather
    /// than borrowing the other strap's — a total never sits beside foreign stages.
    func testASleepBlockIsNeverAssembledFromTwoStraps() {
        let day = "2026-07-29"
        let active = dm(day, totalSleepMin: 402)
        let other = dm(day, totalSleepMin: 435, deepMin: 96, remMin: 110, lightMin: 229)
        let merged = Repository.coalesceDay(active, other)
        XCTAssertEqual(merged.totalSleepMin, 402)     // the winner's total stands
        XCTAssertNil(merged.deepMin)                  // stages must not be borrowed
        XCTAssertNil(merged.remMin)
        XCTAssertNil(merged.lightMin)
    }
}
