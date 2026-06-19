import XCTest
@testable import StrandAnalytics

final class IllnessSignalEngineTests: XCTestCase {

    private let labels = [
        "restingHR": "RHR +6",
        "skinTemp": "skin temp +0.7 °C",
        "hrv": "HRV −22%",
        "respiration": "respiration up",
    ]

    private func reading(_ z: Double) -> IllnessSignalEngine.SignalReading {
        IllnessSignalEngine.SignalReading(zIllnessward: z)
    }

    // MARK: - Classic illness pattern (no tags) → raised

    func testClassicThreeSignalPatternRaises() {
        // RHR, skin temp and HRV all well over the firing threshold, no confounders.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .raised)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertEqual(r.signalCount, 3)
        XCTAssertEqual(r.firedSignals, ["RHR +6", "skin temp +0.7 °C", "HRV −22%"])
        XCTAssertTrue(r.suppressedBy.isEmpty)
        XCTAssertTrue(r.copy.contains("not a diagnosis"))
    }

    // MARK: - Same pattern + alcohol tag → suppressed (the core false-positive test)

    func testAlcoholTagSuppresses() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let raised = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        let suppressed = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true), firedLabels: labels)
        XCTAssertEqual(suppressed.level, .suppressed)
        XCTAssertEqual(suppressed.suppressedBy, ["alcohol"])
        // Dampened well below the raised score.
        XCTAssertLessThan(suppressed.score, raised.score)
        XCTAssertEqual(suppressed.score, raised.score * IllnessSignalEngine.confounderDampen, accuracy: 1e-9)
        XCTAssertTrue(suppressed.copy.contains("alcohol"))
        XCTAssertTrue(suppressed.copy.contains("not illness"))
        XCTAssertTrue(suppressed.copy.contains("not a diagnosis"))
    }

    func testStressSaunaTravelEachDowngradeWithReason() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let stress = IllnessSignalEngine.evaluate(inputs, context: .init(stress: true), firedLabels: labels)
        XCTAssertEqual(stress.level, .suppressed)
        XCTAssertEqual(stress.suppressedBy, ["stress"])

        let sauna = IllnessSignalEngine.evaluate(inputs, context: .init(sauna: true), firedLabels: labels)
        XCTAssertEqual(sauna.suppressedBy, ["sauna"])

        let travel = IllnessSignalEngine.evaluate(
            inputs, context: .init(travelPhaseJump: true), firedLabels: labels)
        XCTAssertEqual(travel.suppressedBy, ["travel"])
        XCTAssertTrue(travel.copy.contains("travel"))
    }

    func testMultipleConfoundersJoinNaturally() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true, stress: true), firedLabels: labels)
        XCTAssertEqual(r.suppressedBy, ["alcohol", "stress"])
        XCTAssertTrue(r.copy.contains("alcohol and stress"))
    }

    // MARK: - Already-sick tag → "rest up" copy, not "early warning"

    func testAlreadyUnwellSwitchesCopy() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alreadyUnwell: true), firedLabels: labels)
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("Rest up"))
        XCTAssertTrue(r.copy.contains("numbers agree"))
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    // MARK: - Gates: single noisy night / untrusted baseline → silent

    func testSingleSignalDoesNotRaise() {
        // Only one signal over threshold → below corroboration gate → quiet.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(4.0))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 1)
    }

    func testUntrustedBaselineStaysSilent() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(baselineTrusted: false), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    func testBelowThresholdSignalsAreMildNotRaised() {
        // Two signals just over the firing threshold but composite below raiseThreshold → mild.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(2.6), skinTemp: reading(2.6))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertEqual(r.level, .mild)
        XCTAssertLessThan(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.mildThreshold)
    }

    func testAbsentSignalsDoNotCount() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2),
            skinTemp: IllnessSignalEngine.SignalReading(zIllnessward: 9.0, present: false),
            hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // The absent skin-temp does not fire despite its huge z.
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertFalse(r.firedSignals.contains("skin temp +0.7 °C"))
    }

    // MARK: - Copy never names a condition

    func testCopyNeverNamesACondition() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let banned = ["covid", "flu", "fever", "infection", "sick with", "illness with", "disease"]
        for ctx in [IllnessSignalEngine.Context(),
                    .init(alcohol: true),
                    .init(alreadyUnwell: true)] {
            let copy = IllnessSignalEngine.evaluate(inputs, context: ctx, firedLabels: labels).copy.lowercased()
            for b in banned { XCTAssertFalse(copy.contains(b), "copy contained banned term \(b): \(copy)") }
        }
    }

    func testScorePerSignalCapping() {
        // A single enormous z is capped, so it alone can't saturate the composite.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(100.0), skinTemp: reading(2.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // RHR caps at perSignalCap (40) + skinTemp small contribution.
        let expectedSkin = IllnessSignalEngine.kZToScore * (2.5 - IllnessSignalEngine.signalZThreshold)
        XCTAssertEqual(r.score, IllnessSignalEngine.perSignalCap + expectedSkin, accuracy: 1e-9)
    }
}
