import XCTest
@testable import Strand

/// #1538: the bookkeeping that makes a deferred re-score actually happen.
///
/// The durable mark is the whole mechanism. If it is not set when work is handed to a background task,
/// the task wakes, finds nothing owed, and returns having done nothing — the deferral would silently DROP
/// the pass rather than move it, which is strictly worse than the livelock it replaced. That failure is
/// invisible on macOS (where the app is never backgrounded, so the branch is never taken) and invisible in
/// a single run on iOS (the score just never appears), which is why it is pinned here.
@MainActor
final class RescoreBackgroundSchedulerTests: XCTestCase {

    private var savedOwed: Any?
    private var savedSeconds: Any?

    override func setUp() {
        super.setUp()
        // These live in UserDefaults.standard, shared with every other test in the target. Save and
        // restore rather than assume this suite owns them.
        savedOwed = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedKey)
        savedSeconds = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
    }

    override func tearDown() {
        restore(savedOwed, RescoreBackgroundScheduler.owedKey)
        restore(savedSeconds, RescoreBackgroundScheduler.lastPassSecondsKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - The durable mark

    /// A pass that starts owes a re-score until it finishes. The mark is what a LATER process reads to
    /// discover that an earlier one was killed — the killed process never gets to report anything itself.
    func testAStartedPassOwesUntilItCompletes() {
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
        RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 12)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// Only a completed pass banks a duration, and only a usable one — the policy reads this to decide
    /// whether a background wake can finish the work, so a garbage value must read as "no measurement"
    /// rather than as a number.
    func testOnlyAUsableDurationIsBanked() {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778)
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 474.778, accuracy: 0.001)

        RescoreBackgroundScheduler.markRescoreCompleted(seconds: .nan)
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 474.778, accuracy: 0.001,
                       "a NaN must not overwrite a good measurement")

        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        XCTAssertNil(RescoreBackgroundScheduler.lastCompletedPassSeconds)
    }

    // MARK: - Deferral must move the work, never drop it

    /// The bug this file exists for: deferring has to record the debt, or the background task it defers
    /// to has nothing to find.
    func testDeferringMarksTheWorkOwedAndDoesNotRunIt() async {
        // A measured pass far over the background budget, so the policy defers.
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, log: { logged.append($0) }) {
            ran = true
        }

        XCTAssertFalse(ran, "the pass must not be started in a context that cannot finish it")
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed,
                      "the deferred work must be recorded, or the background task does nothing")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("deferred"), logged[0])
        XCTAssertTrue(logged[0].contains("475"), logged[0])
    }

    /// A foregrounded pass runs, whatever the measurement says. This is the case the mechanism must not
    /// break: there is no suspension deadline, so deferring would be a pure regression.
    func testAForegroundPassRunsEvenWhenSlow() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778)

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: false, log: { logged.append($0) }) {
            ran = true
        }

        XCTAssertTrue(ran)
        XCTAssertTrue(logged.isEmpty, "a pass that simply runs should not narrate itself")
    }

    /// A background pass with no measurement yet is allowed to run — that is how the measurement is
    /// acquired, and a first attempt costs at most one pass.
    func testAnUnmeasuredBackgroundPassRuns() async {
        var ran = false
        await RescoreBackgroundScheduler.run(isBackground: true, log: { _ in }) { ran = true }
        XCTAssertTrue(ran)
    }

    /// Once work is owed, a further background trigger defers instead of starting a duplicate pass. This
    /// is the livelock fix: #1538 paid for a full eight-minute pass on every offload because nothing
    /// remembered that the previous one had not finished.
    func testASecondBackgroundTriggerDoesNotStartADuplicatePass() async {
        RescoreBackgroundScheduler.markRescoreOwed()

        var ran = false
        await RescoreBackgroundScheduler.run(isBackground: true, log: { _ in }) { ran = true }
        XCTAssertFalse(ran)
    }
}
