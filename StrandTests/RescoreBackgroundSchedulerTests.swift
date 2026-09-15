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
    private var savedToken: Any?
    private var savedAfterCompleted: Any?

    override func setUp() {
        super.setUp()
        // These live in UserDefaults.standard, shared with every other test in the target. Save and
        // restore rather than assume this suite owns them.
        savedOwed = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedKey)
        savedSeconds = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        savedToken = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedTokenKey)
        savedAfterCompleted = UserDefaults.standard.object(
            forKey: RescoreBackgroundScheduler.owedAfterCompletedPassKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedTokenKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedAfterCompletedPassKey)
    }

    override func tearDown() {
        restore(savedOwed, RescoreBackgroundScheduler.owedKey)
        restore(savedSeconds, RescoreBackgroundScheduler.lastPassSecondsKey)
        restore(savedToken, RescoreBackgroundScheduler.owedTokenKey)
        restore(savedAfterCompleted, RescoreBackgroundScheduler.owedAfterCompletedPassKey)
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
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 12, owedToken: token)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// Only a completed pass banks a duration, and only a usable one — the policy reads this to decide
    /// whether a background wake can finish the work, so a garbage value must read as "no measurement"
    /// rather than as a number.
    func testOnlyAUsableDurationIsBanked() {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 474.778, accuracy: 0.001)

        RescoreBackgroundScheduler.markRescoreCompleted(seconds: .nan, owedToken: nil)   // fixture: bank a duration, settle nothing
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
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing
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
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing

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

    // MARK: - The backstop tick owes nothing

    /// The steady-state tick is a backstop: every real update forces its own pass, so a tick that cannot
    /// run here is simply skipped. Recording a debt for it would send a processing task off to run a
    /// forced full pass when most likely nothing changed — the churn #1146 exists to avoid.
    func testASkippedBackstopDoesNotConjureADebt() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, owesOnDefer: false,
                                             log: { logged.append($0) }) { ran = true }

        XCTAssertFalse(ran, "a backstop that cannot finish here must not start")
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed,
                       "a skipped backstop owes nothing — no real update went unscored")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("backstop"), logged[0])
        XCTAssertFalse(logged[0].contains("deferred"),
                       "must not promise a background task that is not coming: \(logged[0])")
    }

    /// ...but a debt a REAL pass already recorded survives a skipped backstop untouched. Clearing it
    /// here would strand the very work the mechanism exists to rescue.
    func testASkippedBackstopLeavesAnExistingDebtAlone() async {
        RescoreBackgroundScheduler.markRescoreOwed()

        await RescoreBackgroundScheduler.run(isBackground: true, owesOnDefer: false, log: { _ in }) {}

        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// A backstop still RUNS in the foreground, and in a background that can afford it — the flag changes
    /// only what a deferral records, never whether the pass happens.
    func testABackstopStillRunsWhenItCan() async {
        var foreground = false
        await RescoreBackgroundScheduler.run(isBackground: false, owesOnDefer: false,
                                             log: { _ in }) { foreground = true }
        XCTAssertTrue(foreground)

        var affordable = false
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 3, owedToken: nil)   // fixture: bank a duration, settle nothing
        await RescoreBackgroundScheduler.run(isBackground: true, owesOnDefer: false,
                                             log: { _ in }) { affordable = true }
        XCTAssertTrue(affordable)
    }

    // MARK: - #1681: whose debt is it?

    /// The reported bug. A pass records its debt, and while it is running a LATER trigger records another
    /// — for data that arrived after this pass had already read its inputs. Completion used to clear one
    /// global boolean unconditionally, erasing that newer debt before the correction it was recorded for
    /// ever ran. The night stayed scored from a partial sync until something unrelated happened to
    /// re-score it.

    // MARK: - #2238: a debt from a COMPLETED pass is not the same as one from an interrupted pass

    /// The distinction the Oura re-score storm turns on. A pass that finishes and is outvoted by a token
    /// recorded mid-pass HAS advanced the watermark, so its resume may ask the fingerprint whether anything
    /// changed. A pass that dies has not, so its resume must force.
    func testACompletedButUnsettledPassMarksItsDebtAsProven() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertFalse(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                       "a debt is unproven until the pass owning it finishes")

        _ = RescoreBackgroundScheduler.markRescoreOwed()   // a newer trigger lands mid-pass
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: mine)

        XCTAssertFalse(settled, "an outvoted pass must not settle the debt (#1681)")
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                      "#2238: this pass completed and advanced the watermark, so the resume may gate")
    }

    /// A pass that never reaches completion leaves the flag where `markRescoreOwed` put it: false. The
    /// resume then forces, which is the behaviour #1538 relies on.
    func testAnInterruptedPassLeavesItsDebtUnproven() {
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        // no markRescoreCompleted: the process died here

        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertFalse(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                       "#2238: an interrupted pass never advanced the watermark, so its resume must force")
    }

    /// The flag describes the CURRENT debt. A resume that starts its own pass and is then killed must not
    /// inherit the previous debt's proof, or the chain would gate on a watermark that was never advanced.
    func testAFreshDebtClearsThePreviousProof() {
        let first = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: first)
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedAfterCompletedPass)

        _ = RescoreBackgroundScheduler.markRescoreOwed()   // the resume's own pass starts, then dies

        XCTAssertFalse(RescoreBackgroundScheduler.isOwedAfterCompletedPass,
                       "#2238: proof belongs to the debt that earned it, not to whatever is owed next")
    }

    /// A settled pass clears the debt outright, so the flag is moot; pinned so a later change cannot leave
    /// a stale proof behind a cleared debt.
    func testASettledPassLeavesNoOutstandingProof() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: mine)

        XCTAssertTrue(settled)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertFalse(RescoreBackgroundScheduler.isOwedAfterCompletedPass)
    }

    func testADebtRecordedMidPassSurvivesThatPassCompleting() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()   // a later trigger, while the pass is still running

        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 9, owedToken: mine)

        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed,
                      "the newer debt must outlive the pass that did not pay it")
    }

    /// …and the pass that DOES hold the current token still settles, or the flag would never clear and
    /// every launch would re-score forever.
    func testTheHolderOfTheCurrentTokenSettles() {
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        let latest = RescoreBackgroundScheduler.markRescoreOwed()
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 9, owedToken: latest)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// The duration is telemetry about THIS pass and is banked either way — it is true regardless of
    /// whose debt is now outstanding, and the policy needs it to size a background wake.
    func testAPassThatCannotSettleStillBanksItsDuration() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 33.5, owedToken: mine)
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 33.5, accuracy: 0.001)
    }

    // MARK: - the settlement rule itself

    /// A pass with NO token never settles. That costs one extra pass; the other direction costs a night's
    /// scores until something unrelated re-scores it, which is the failure being fixed.
    func testNoTokenNeverSettles() {
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: nil, currentToken: "a"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "", currentToken: ""))
    }

    func testOnlyTheCurrentTokenSettles() {
        XCTAssertTrue(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: "a"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: "b"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: nil))
    }

    /// Each mark stamps a DISTINCT token. A counter would need read-modify-write, and two triggers marking
    /// at the same moment could both read N and both write N+1 — losing exactly the debt this protects.
    func testEveryMarkStampsADistinctToken() {
        let seen = Set((0..<50).map { _ in RescoreBackgroundScheduler.markRescoreOwed() })
        XCTAssertEqual(seen.count, 50)
    }

    // MARK: - the outcome has to be reportable

    /// Declining is the interesting outcome, and the caller can only SAY so if it is told. #1538 cost
    /// three nights because the log recorded that scoring had not happened without recording why; a pass
    /// that completes while leaving the mark set looks identical in a capture to one that cleared it.
    func testCompletionReportsWhetherItSettled() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertFalse(RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: mine),
                       "a pass that could not settle must report that, or the log cannot explain itself")

        let latest = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: latest))
    }
}

