import XCTest
@testable import Strand

/// The #345 "May be incomplete" gate: sparse motion is necessary, a short total is what makes it worth
/// saying. Twin of Kotlin `SleepSparseNoteGateTest`.
///
/// The numbers here are the shape of the false positive this closes: nights of 10.5h, 12h and 12.75h that
/// carried the sparse flag and were captioned as possibly reading short.
final class SleepSparseNoteGateTests: XCTestCase {

    private let need = 8.0

    func testALongNightNeverEarnsTheCaveatHoweverSparseItsMotion() {
        for hours in [8.0, 10.5, 12.0, 12.75] {
            XCTAssertFalse(SleepView.stageSparseNoteApplies(stagingSparse: true,
                                                            asleepMin: hours * 60, needHours: need),
                           "a \(hours)h night cannot honestly be captioned as possibly reading short")
        }
    }

    func testAGenuinelyShortSparseNightStillWarns() {
        XCTAssertTrue(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: 60, needHours: need))
        XCTAssertTrue(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: 7.9 * 60, needHours: need))
    }

    func testANightThatStagedToNothingIsTheStrongestCaseNotAnExemption() {
        XCTAssertTrue(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: 0, needHours: need))
    }

    func testSparseStaysNecessary() {
        XCTAssertFalse(SleepView.stageSparseNoteApplies(stagingSparse: false, asleepMin: 60, needHours: need))
        XCTAssertFalse(SleepView.stageSparseNoteApplies(stagingSparse: false, asleepMin: 0, needHours: need))
    }

    func testTheBoundaryIsTheNeedItself() {
        XCTAssertTrue(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: need * 60 - 1, needHours: need))
        XCTAssertFalse(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: need * 60, needHours: need))
    }

    func testTheDefaultNeedIsTheSharedEngineConstant() {
        // 8h by default, so a 7h sparse night warns and a 9h one does not, with no needHours passed.
        XCTAssertTrue(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: 7 * 60))
        XCTAssertFalse(SleepView.stageSparseNoteApplies(stagingSparse: true, asleepMin: 9 * 60))
    }
}
