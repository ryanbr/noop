import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Correcting a finished session: the parsing, and adding and removing sets. Both can quietly store the
/// wrong thing, which the screen alone would not show.
@MainActor
final class LiftSessionEditTests: XCTestCase {

    private typealias Sheet = LiftSessionEditSheet

    private func row(_ id: String = "s1", ord: Int = 0, setIndex: Int = 1,
                     weightKg: Double? = 60, reps: Int? = 8, rpe: Double? = nil) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: "d", sessionId: "x", ord: ord, exercise: "Squat",
                   primaryMuscle: .quads, secondaryMuscles: [.glutes], setIndex: setIndex,
                   weightKg: weightKg, reps: reps, rpe: rpe,
                   isWarmup: false, startTs: 100, endTs: 140, restSec: 90, note: nil)
    }

    private func entries(_ rows: [LiftSetRow]) -> [Sheet.Entry] {
        rows.map { Sheet.Entry(id: $0.id, form: Sheet.form(for: $0, system: .metric)) }
    }

    // MARK: - Editing a set's fields

    /// Opening and saving an untouched pound value must not nudge the stored kilograms.
    func testAnUntouchedFieldIsNotWrittenBack() {
        let before = Sheet.form(for: row(), system: .imperial)
        var after = before
        after.reps = "10"
        let edited = Sheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg, 60, "exactly the stored kilograms, not a round trip through pounds")
        XCTAssertEqual(edited.reps, 10)
    }

    func testAChangedWeightIsReadInTheDisplayUnit() {
        let before = Sheet.form(for: row(), system: .imperial)
        var after = before
        after.weight = "135"
        let edited = Sheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg ?? 0, LiftFormat.kilograms(fromDisplay: 135, system: .imperial),
                       accuracy: 1e-9)
    }

    func testADecimalCommaAndAClearedFieldAreHonoured() {
        let before = Sheet.form(for: row(rpe: 8), system: .metric)
        var after = before
        after.weight = "62,5"
        after.rpe = ""
        let edited = Sheet.applying(after, over: before, to: row(rpe: 8), system: .metric)
        XCTAssertEqual(edited.weightKg, 62.5)
        XCTAssertNil(edited.rpe, "a cleared field clears the value rather than keeping the old one")
    }

    func testMarkingAWarmUpAfterTheFactApplies() {
        let before = Sheet.form(for: row(), system: .metric)
        var after = before
        after.isWarmup = true
        XCTAssertTrue(Sheet.applying(after, over: before, to: row(), system: .metric).isWarmup)
    }

    // MARK: - Adding and removing sets

    func testAnUntouchedSessionWritesNothing() {
        let rows = [row("a", ord: 0, setIndex: 1), row("b", ord: 1, setIndex: 2)]
        let change = Sheet.changes(from: rows, to: [.init(name: "Squat", entries: entries(rows))], system: .metric)
        XCTAssertTrue(change.upserts.isEmpty)
        XCTAssertTrue(change.deletedIds.isEmpty)
    }

    /// An added set is a new row, numbered after the exercise's others and ordered after every set the
    /// session had, with the exercise's muscles and no timing to invent.
    func testAnAddedSetBecomesANewRow() {
        let rows = [row("a", ord: 0, setIndex: 1), row("b", ord: 1, setIndex: 2)]
        var list = entries(rows)
        list.append(.init(id: "new", form: .init(weight: "62.5", reps: "6", rpe: "", isWarmup: false)))
        let change = Sheet.changes(from: rows, to: [.init(name: "Squat", entries: list)], system: .metric)

        XCTAssertEqual(change.upserts.count, 1)
        let added = change.upserts[0]
        XCTAssertEqual(added.id, "new")
        XCTAssertEqual(added.setIndex, 3)
        XCTAssertEqual(added.ord, 2)
        XCTAssertEqual(added.weightKg, 62.5)
        XCTAssertEqual(added.reps, 6)
        XCTAssertEqual(added.primaryMuscle, .quads)
        XCTAssertEqual(added.secondaryMuscles, [.glutes])
        XCTAssertNil(added.startTs)
        XCTAssertTrue(change.deletedIds.isEmpty)
    }

    /// Removing a set deletes its row and closes the gap, so the session still reads 1, 2.
    func testARemovedSetIsDeletedAndTheRestRenumbered() {
        let rows = [row("a", ord: 0, setIndex: 1), row("b", ord: 1, setIndex: 2), row("c", ord: 2, setIndex: 3)]
        let list = entries(rows).filter { $0.id != "b" }
        let change = Sheet.changes(from: rows, to: [.init(name: "Squat", entries: list)], system: .metric)

        XCTAssertEqual(change.deletedIds, ["b"])
        XCTAssertEqual(change.upserts.map(\.id), ["c"], "only the set whose number moved is rewritten")
        XCTAssertEqual(change.upserts.first?.setIndex, 2)
    }

    /// A set discarded at finish is saved at 0 × 0 and shows only here; typing its numbers makes it a
    /// performed set again, which every figure then counts.
    func testFillingInADiscardedSetMakesItCountAgain() {
        let discarded = row("z", weightKg: 0, reps: 0)
        XCTAssertFalse(LiftMetrics.isPerformed(reps: discarded.reps))
        let before = Sheet.form(for: discarded, system: .metric)
        XCTAssertEqual(before.reps, "0")
        var after = before
        after.weight = "70"
        after.reps = "8"
        let edited = Sheet.applying(after, over: before, to: discarded, system: .metric)
        XCTAssertEqual(edited.weightKg, 70)
        XCTAssertTrue(LiftMetrics.isPerformed(reps: edited.reps))
    }
}
