import XCTest
@testable import Strand

/// The Steps calibration affordance is a WHOOP 4.0 feature, except when a profile already owns a working
/// coefficient from an earlier 4.0 calibration. WHOOP 5.0 motion rows can advance the shared fitter's
/// sample-day counter, so that counter cannot stand in for an actual calibration (#1523).
final class TodayStepsPipelineTests: XCTestCase {

    private func active(model: WhoopModel?,
                        hasDayData: Bool,
                        calibrationCoefficient: Double = 0,
                        manualCoefficient: Double = 0,
                        sampleDays: Int = 0) -> Bool {
        TodayView.stepsPipelineActive(
            selectedModelRaw: model?.rawValue ?? "",
            hasDayData: hasDayData,
            calibrationCoefficient: calibrationCoefficient,
            manualCoefficient: manualCoefficient,
            calibrationSampleDays: sampleDays)
    }

    func testWhoop5PartialSampleDaysDoNotActivateFourPointZeroPipeline() {
        XCTAssertFalse(active(model: .whoop5mg, hasDayData: true, sampleDays: 3))
    }

    func testWhoop4WithDayDataActivatesBeforeCalibrationStarts() {
        XCTAssertTrue(active(model: .whoop4, hasDayData: true))
    }

    func testWhoop4WithoutDayDataIsNotActivatedByPartialSampleDays() {
        XCTAssertFalse(active(model: .whoop4, hasDayData: false, sampleDays: 3))
    }

    /// #1523 follow-up: these two asserted TRUE when the suite landed, on the grounds that a profile
    /// migrating from a calibrated 4.0 to a 5.0 should keep its estimate behaviour. That reasoning does
    /// not apply to THIS gate — `estSteps` is computed independently in `stepsEstByDay`, and all this
    /// decides is whether a blank tile offers to calibrate. A 5/MG reports steps natively, so it has
    /// nothing to calibrate, and showing it the 4.0 prompt is the complaint #1523 opened.
    func testFittedCoefficientDoesNotPromptOnAFivePointZero() {
        XCTAssertFalse(active(model: .whoop5mg,
                              hasDayData: true,
                              calibrationCoefficient: 0.42,
                              sampleDays: 5))
    }

    func testManualCoefficientDoesNotPromptOnAFivePointZero() {
        XCTAssertFalse(active(model: .whoop5mg,
                              hasDayData: true,
                              manualCoefficient: 0.35,
                              sampleDays: 1))
    }

    /// …but the coefficient paths must NOT simply be deleted, which is the tempting reading of the two
    /// above. A legacy 4.0 owner whose `selectedWhoopModel` key was never written has no family to match
    /// on, and only the coefficient says they are mid-estimate. Dropping these would silently take the
    /// calibration gear away from exactly the users #1491 restored it for.
    func testACoefficientStillActivatesWhenNoModelWasEverRecorded() {
        XCTAssertTrue(active(model: nil, hasDayData: true, calibrationCoefficient: 0.42))
        XCTAssertTrue(active(model: nil, hasDayData: true, manualCoefficient: 0.35))
    }

    func testUnsetModelAndPartialSampleDaysStayInactive() {
        XCTAssertFalse(active(model: nil, hasDayData: true, sampleDays: 3))
    }
}
