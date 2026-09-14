import XCTest
@testable import Strand
import WhoopStore

/// Correcting a finished session. The parsing is the part that can quietly store the wrong number.
@MainActor
final class LiftSessionEditTests: XCTestCase {

    private func row(weightKg: Double? = 60, reps: Int? = 8, rpe: Double? = nil) -> LiftSetRow {
        LiftSetRow(id: "s1", deviceId: "d", sessionId: "x", ord: 0, exercise: "Squat",
                   primaryMuscle: .quads, setIndex: 1, weightKg: weightKg, reps: reps, rpe: rpe,
                   isWarmup: false, startTs: 100, endTs: 140, restSec: 90, note: nil)
    }

    /// Opening and saving an untouched pound value must not nudge the stored kilograms.
    func testAnUntouchedFieldIsNotWrittenBack() {
        let before = LiftSessionEditSheet.form(for: row(), system: .imperial)
        var after = before
        after.reps = "10"
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg, 60, "exactly the stored kilograms, not a round trip through pounds")
        XCTAssertEqual(edited.reps, 10)
    }

    func testAChangedWeightIsReadInTheDisplayUnit() {
        let before = LiftSessionEditSheet.form(for: row(), system: .imperial)
        var after = before
        after.weight = "135"
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(), system: .imperial)
        XCTAssertEqual(edited.weightKg ?? 0, LiftFormat.kilograms(fromDisplay: 135, system: .imperial),
                       accuracy: 1e-9)
    }

    func testADecimalCommaAndAClearedFieldAreHonoured() {
        let before = LiftSessionEditSheet.form(for: row(rpe: 8), system: .metric)
        var after = before
        after.weight = "62,5"
        after.rpe = ""
        let edited = LiftSessionEditSheet.applying(after, over: before, to: row(rpe: 8), system: .metric)
        XCTAssertEqual(edited.weightKg, 62.5)
        XCTAssertNil(edited.rpe, "a cleared field clears the value rather than keeping the old one")
    }

    func testMarkingAWarmUpAfterTheFactApplies() {
        let before = LiftSessionEditSheet.form(for: row(), system: .metric)
        var after = before
        after.isWarmup = true
        XCTAssertTrue(LiftSessionEditSheet.applying(after, over: before, to: row(), system: .metric).isWarmup)
    }
}
