import XCTest
@testable import Strand

/// #1538: what a backgrounded re-score is allowed to attempt, and how it paces itself.
///
/// The rules exist because getting them wrong is expensive in both directions. Too eager and the phone
/// pays for passes it is killed partway through — the livelock in the report, which on-device crash
/// reports showed to be iOS's background CPU limit (`cpu_resource_fatal`, 80% over 60 s). Too shy and a
/// night goes unscored while the app waits for a background task that may not arrive for hours. Neither
/// failure is visible from inside a single run, so they are pinned here rather than discovered on
/// someone's wrist.
final class RescoreBackgroundPolicyTests: XCTestCase {

    private func decide(background: Bool = true,
                        realUpdate: Bool = true,
                        unfinished: Bool = false,
                        running: Bool = false) -> RescoreBackgroundPolicy.Decision {
        RescoreBackgroundPolicy.decide(isBackground: background,
                                       isRealUpdate: realUpdate,
                                       rescoreAlreadyOwed: unfinished,
                                       passInProgress: running)
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
        XCTAssertEqual(decide(background: false, realUpdate: false), .run)
    }

    // MARK: - A real update runs, paced

    /// An offload in the background runs now. It paces itself under the CPU limit and resumes across
    /// wakes, so how long it takes is no longer a reason to hand it to a processing task that iOS may not
    /// grant until the afternoon — which is when last night's scores used to appear.
    func testABackgroundOffloadRuns() {
        XCTAssertEqual(decide(), .run)
    }

    // MARK: - The livelock

    /// An earlier pass marked itself started and never finished, and nothing is running now: that pass
    /// was killed. Attempting it again on every offload is what burned the phone in #1538.
    func testAnInterruptedPriorAttemptDefersInsteadOfRetrying() {
        XCTAssertTrue(isDeferred(decide(unfinished: true)))
    }

    /// A pass running in THIS process reads as owed through its own started-mark. That is not a killed
    /// pass, and deferring on it recorded a newer debt the running pass could then never settle (#1681),
    /// so every later offload deferred too. The engine re-arms a follow-up pass for a mid-run trigger.
    func testARunningPassIsNotMistakenForAKilledOne() {
        XCTAssertEqual(decide(unfinished: true, running: true), .run)
    }

    // MARK: - The backstop

    /// The steady-state tick cannot tell live HR from a real change, and a paced pass costs minutes, so a
    /// backgrounded tick does not run. Real updates run their own.
    func testABackgroundedBackstopDoesNotRun() {
        guard case .deferToBackgroundTask(let reason) = decide(realUpdate: false) else {
            return XCTFail("expected the backstop to be skipped")
        }
        XCTAssertTrue(reason.contains("backstop"), reason)
    }

    // MARK: - Pacing

    /// Resting as long as it worked holds a backgrounded pass near 50% CPU, under the 80% iOS kills at.
    func testABackgroundedPassRestsAsLongAsItWorked() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 6, isBackground: true), 6)
    }

    /// No CPU limit applies in the foreground, and the user is waiting on the result.
    func testTheForegroundNeverRests() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 6, isBackground: false), 0)
    }

    /// Work measured on the uptime clock can include a suspension; resting for all of it would stall a
    /// pass that has already been idle.
    func testARestIsCapped() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 3_600, isBackground: true),
                       RescoreBackgroundPolicy.maxBackgroundRestSeconds)
    }

    /// An unreadable measurement rests zero rather than stalling the pass on a value that means nothing.
    func testAnUnreadableMeasurementDoesNotRest() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 0, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: -1, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: .nan, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: .infinity, isBackground: true), 0)
    }

    /// The shipped constants are the ones the app uses; pin them so a change is deliberate.
    func testTheShippedPacingConstants() {
        XCTAssertEqual(RescoreBackgroundPolicy.backgroundRestPerWorkSecond, 1.0)
        XCTAssertEqual(RescoreBackgroundPolicy.maxBackgroundRestSeconds, 30)
    }
}
