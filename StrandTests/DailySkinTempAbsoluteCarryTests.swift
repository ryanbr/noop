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

    /// `DailyMetric`'s initializer defaults only from `spo2Pct` onward — its first twelve parameters are
    /// required. Every case here needs two or three of them, so they go through this rather than each
    /// spelling out ten `nil`s, and the sleep-carry cases below cannot drift into compact calls that do
    /// not compile. (They did: these tests shipped uncompilable in #1879, and `StrandTests` runs only in
    /// the on-demand app-build, so nothing said so.)
    private func row(day: String = "2026-08-25",
                     totalSleepMin: Double? = nil,
                     deepMin: Double? = nil,
                     remMin: Double? = nil,
                     lightMin: Double? = nil,
                     restingHr: Int? = nil,
                     skinTempC: Double? = nil,
                     skinTempDevC: Double? = nil,
                     avgHrv: Double? = nil,
                     sleepHrOnly: Bool? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: nil, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: nil, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skinTempDevC, skinTempC: skinTempC, sleepHrOnly: sleepHrOnly)
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

    // MARK: - The same four seams, for the HR-only staging flag (#1801)

    /// `sleepHrOnly` rides the identical rebuild path as the absolute above, and the struct has no
    /// `copy()` — every seam respells the field list, so a new column is dropped by omission rather than
    /// by error. These four are that column's version of the tests above.

    func testScoringKeepsTheStagingFlag() throws {
        let scored = row(skinTempC: 34.6).with(recovery: 0.71, skinTempDevC: 0.52, skinTempC: 34.6)
        XCTAssertNil(scored.sleepHrOnly, "a row that never carried the flag must not invent one")
        let hrOnly = row(day: "2026-09-03", sleepHrOnly: true)
            .with(recovery: 0.71, skinTempDevC: nil, skinTempC: nil)
        XCTAssertEqual(hrOnly.sleepHrOnly, true, "scoring must not discard how the night was staged")
    }

    func testASleepEditKeepsTheStagingFlag() {
        let edited = row(day: "2026-09-03", sleepHrOnly: true)
            .with(totalSleepMin: 400, efficiency: 0.93, deepMin: 80, remMin: 100, lightMin: 220)
        // Correcting the wake window does not change whether the strap banked any motion.
        XCTAssertEqual(edited.sleepHrOnly, true)
    }

    func testAnImportedRowTakesTheComputedStagingFlag() {
        let imported = row(day: "2026-09-03")
        let computed = row(day: "2026-09-03", sleepHrOnly: true)
        XCTAssertEqual(imported.fillingNilFields(from: computed).sleepHrOnly, true,
                       "only a scoring pass knows the staging; an import's nil must not erase it")
    }

    func testTheFlagMovesWithTheSleepColumnsItDescribes() {
        let importRow = row(day: "2026-09-03", totalSleepMin: 300)
        let editedComputed = row(day: "2026-09-03", totalSleepMin: 400, sleepHrOnly: true)
        let merged = importRow.takingSleepFields(from: editedComputed)
        XCTAssertEqual(merged.totalSleepMin, 400)
        // The flag describes THOSE stage figures, so it travels with them rather than staying behind.
        XCTAssertEqual(merged.sleepHrOnly, true)
    }

    /// The Swift twin of the Kotlin coalesce cases: the flag belongs to the sleep GROUP.
    func testTheStagingFlagMovesWithTheSleepBlock() {
        let winner = row(day: "2026-09-03", restingHr: 55)
        let filler = row(day: "2026-09-03", totalSleepMin: 400, deepMin: 39,
                                 remMin: 54, lightMin: 57, sleepHrOnly: true)
        XCTAssertEqual(Repository.coalesceDay(winner, filler).sleepHrOnly, true)
    }

    func testAWinnerThatOwnsTheSleepBlockKeepsItsOwnStagingFlag() {
        let winner = row(day: "2026-09-03", totalSleepMin: 420, deepMin: 90, sleepHrOnly: false)
        let filler = row(day: "2026-09-03", totalSleepMin: 300, sleepHrOnly: true)
        XCTAssertEqual(Repository.coalesceDay(winner, filler).sleepHrOnly, false)
    }
}
