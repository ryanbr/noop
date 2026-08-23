import XCTest
@testable import Strand

/// #1538: what a backgrounded re-score is allowed to attempt.
///
/// The rules exist because getting them wrong is expensive in both directions. Too eager and the phone
/// pays for a full eight-minute pass on every offload that it will never be allowed to finish — the
/// livelock in the report. Too shy and a night goes unscored while the app waits for a background task
/// that may not arrive for hours. Neither failure is visible from inside a single run, so they are pinned
/// here rather than discovered on someone's wrist.
final class RescoreBackgroundPolicyTests: XCTestCase {

    private func decide(background: Bool = true,
                        unfinished: Bool = false,
                        lastSeconds: Double? = nil,
                        budget: Double = 20) -> RescoreBackgroundPolicy.Decision {
        RescoreBackgroundPolicy.decide(isBackground: background,
                                       rescoreAlreadyOwed: unfinished,
                                       lastCompletedPassSeconds: lastSeconds,
                                       budgetSeconds: budget)
    }

    private func isDeferred(_ d: RescoreBackgroundPolicy.Decision) -> Bool {
        if case .deferToBackgroundTask = d { return true }
        return false
    }

    // MARK: - Foreground is never deferred

    /// The user is looking at the screen and there is no suspension deadline. Deferring here would be a
    /// pure regression: it would turn a pass that works today into one that waits for iOS.
    func testAForegroundPassAlwaysRuns() {
        XCTAssertEqual(decide(background: false), .run)
        XCTAssertEqual(decide(background: false, unfinished: true), .run)
        XCTAssertEqual(decide(background: false, lastSeconds: 9_999), .run)
    }

    // MARK: - The livelock

    /// The core fix. An earlier pass marked itself started and never finished, which survives process
    /// death — so the phone has already proved once that it cannot complete this work in the background.
    /// Attempting it again is what burned nearly eight minutes per offload in #1538 while producing
    /// nothing.
    func testAnInterruptedPriorAttemptDefersInsteadOfRetrying() {
        XCTAssertTrue(isDeferred(decide(unfinished: true)))
    }

    /// ...and it defers even when the last COMPLETED pass looks fast, because "unfinished" is evidence
    /// about this install right now, whereas the measurement may predate the history that made it slow.
    func testAnInterruptedAttemptOutranksAFastMeasurement() {
        XCTAssertTrue(isDeferred(decide(unfinished: true, lastSeconds: 2)))
    }

    // MARK: - The measurement

    /// A pass measured well inside the budget is exactly what SHOULD run in the background — that is the
    /// case this whole mechanism must not break.
    func testAPassThatFitsTheBudgetRuns() {
        XCTAssertEqual(decide(lastSeconds: 5), .run)
    }

    /// The reporter's install: 474.778 s against a 20 s budget.
    func testTheReportedPassDefers() {
        XCTAssertTrue(isDeferred(decide(lastSeconds: 474.778)))
    }

    /// The boundary is stated rather than inherited: equal to the budget still runs, over it defers.
    func testTheBudgetBoundary() {
        XCTAssertEqual(decide(lastSeconds: 20, budget: 20), .run)
        XCTAssertTrue(isDeferred(decide(lastSeconds: 20.001, budget: 20)))
    }

    /// The reason is carried into the strap log, so it has to name the numbers that drove the decision.
    /// #1538 was three nights of chasing BLE because the log recorded that scoring had not happened
    /// without ever recording why.
    func testTheDeferralReasonNamesTheMeasurementAndTheBudget() {
        guard case .deferToBackgroundTask(let reason) = decide(lastSeconds: 475, budget: 20) else {
            return XCTFail("expected a deferral")
        }
        XCTAssertTrue(reason.contains("475"), reason)
        XCTAssertTrue(reason.contains("20"), reason)
    }

    // MARK: - Unknown is not "too slow"

    /// Nothing has ever completed on this install, so there is no measurement to defer on. Running is the
    /// only way to acquire one, and a first attempt costs at most one pass.
    func testAnInstallWithNoMeasurementRuns() {
        XCTAssertEqual(decide(lastSeconds: nil), .run)
    }

    /// A corrupted or absent default must never be read as "slow". Refusing to score on the strength of
    /// a value that cannot be interpreted is a far worse failure than one wasted pass.
    func testUnreadableMeasurementsRunRatherThanDefer() {
        XCTAssertEqual(decide(lastSeconds: 0), .run)
        XCTAssertEqual(decide(lastSeconds: -1), .run)
        XCTAssertEqual(decide(lastSeconds: .nan), .run)
        XCTAssertEqual(decide(lastSeconds: .infinity), .run)
    }

    /// A nonsensical budget disables the measurement rule rather than deferring everything — the same
    /// principle, applied to the other input.
    func testANonPositiveBudgetDoesNotDeferEverything() {
        XCTAssertEqual(decide(lastSeconds: 9_999, budget: 0), .run)
        XCTAssertEqual(decide(lastSeconds: 9_999, budget: -5), .run)
    }

    /// The shipped budget is the one the app actually uses; pin it so a change is deliberate.
    func testTheDefaultBudgetIsTheShippedOne() {
        XCTAssertEqual(RescoreBackgroundPolicy.backgroundBudgetSeconds, 20)
        XCTAssertTrue(isDeferred(RescoreBackgroundPolicy.decide(
            isBackground: true, rescoreAlreadyOwed: false, lastCompletedPassSeconds: 21)))
    }
}
