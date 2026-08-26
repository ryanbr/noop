import XCTest
import WhoopStore
@testable import Strand

/// The nightly absolute (#1636) must survive every path that REBUILDS a `DailyMetric`.
///
/// The column is written once, on the scoring pass, and then carried by separate merges before it
/// reaches a screen. Each of those spells its fields out by name, so a new column is dropped by
/// omission rather than by a compile error — a value that persists correctly and then disappears on the
/// way to being read, which no migration test would catch.
///
/// Twin of the Kotlin `DailySkinTempAbsoluteCarryTest`, with two tests that have no Kotlin counterpart:
/// the `with(...)` rebuild helpers are a Swift-only shape (Kotlin's data-class `copy` carries every field
/// automatically, so there is no equivalent seam to drop a column at).
final class DailySkinTempAbsoluteCarryTests: XCTestCase {

    private func row(day: String = "2026-08-25",
                     skinTempC: Double? = nil,
                     skinTempDevC: Double? = nil,
                     avgHrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: avgHrv,
                    recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skinTempDevC, skinTempC: skinTempC)
    }

    /// An imported winner carries no absolute, so the computed filler's must survive the coalesce.
    func testCoalesceTakesTheStrapAbsoluteWhenTheWinnerHasNone() throws {
        let winner = row(skinTempDevC: 0.2, avgHrv: 44.0)      // an import: deviation only
        let filler = row(skinTempC: 34.6, skinTempDevC: 0.2)   // the strap's own scored night
        XCTAssertEqual(try XCTUnwrap(Repository.coalesceDay(winner, filler).skinTempC),
                       34.6, accuracy: 0.001)
    }

    /// A winner that HAS one keeps it — the filler must never overwrite a measured value.
    func testCoalesceKeepsTheWinnersOwnAbsolute() throws {
        let winner = row(skinTempC: 34.6)
        let filler = row(skinTempC: 30.1)
        XCTAssertEqual(try XCTUnwrap(Repository.coalesceDay(winner, filler).skinTempC),
                       34.6, accuracy: 0.001)
    }

    func testCoalesceLeavesItNilWhenNeitherSideMeasuredOne() {
        XCTAssertNil(Repository.coalesceDay(row(), row()).skinTempC)
    }

    /// The sleep-edit rebuild replaces only sleep-derived fields; a thermal column must ride through.
    func testASleepEditKeepsTheNightsAbsolute() throws {
        let scored = row(skinTempC: 34.6, skinTempDevC: 0.2)
        let edited = scored.with(totalSleepMin: 400, efficiency: 0.93,
                                 deepMin: 80, remMin: 100, lightMin: 220)
        XCTAssertEqual(try XCTUnwrap(edited.skinTempC), 34.6, accuracy: 0.001,
                       "editing the sleep window must not discard the night's temperature")
    }

    /// Cross-bucket: imports win the row, but the absolute is on-device only, so the computed value
    /// has to come through or a user with any WHOOP-export history would never see one.
    func testMergeFillsTheAbsoluteFromTheComputedRow() throws {
        let imported = [row(skinTempDevC: 0.2)]
        let computed = [row(skinTempC: 34.6, skinTempDevC: 0.2)]
        let merged = Repository.mergeDaily(imported: imported, computed: computed)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(try XCTUnwrap(merged.first?.skinTempC), 34.6, accuracy: 0.001)
        // And the deviation every downstream gate reads is untouched by carrying the absolute.
        XCTAssertEqual(try XCTUnwrap(merged.first?.skinTempDevC), 0.2, accuracy: 0.001)
    }

    /// Re-scoring writes both thermal values together; neither may clobber the other.
    func testScoringWritesTheAbsoluteAndDeviationTogether() throws {
        let scored = row().with(recovery: 0.71, skinTempDevC: 0.52, skinTempC: 34.6)
        XCTAssertEqual(try XCTUnwrap(scored.skinTempC), 34.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(scored.skinTempDevC), 0.52, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(scored.recovery), 0.71, accuracy: 0.001)
    }
}
