import XCTest
@testable import StrandAnalytics

/// The post-loop phase line. Mirrored by the Kotlin `AnalysisPhaseTallyTest` against the SAME literals:
/// the two platforms name their own phases (the passes genuinely differ after the day loop), but the
/// rendering — order, rounding, the total, the empty case — is one contract.
final class AnalysisPhaseTallyTests: XCTestCase {

    func testPhasesRenderInOrderWithATotal() {
        let line = AnalysisPhaseTally.logLine(scope: "postLoop", [
            (name: "baselines", seconds: 0.012),
            (name: "score2", seconds: 1.1),
            (name: "steps", seconds: 28.93),
        ])
        XCTAssertEqual(line, "analyzeRecent postLoop total=30042ms baselines=12ms score2=1100ms steps=28930ms")
    }

    /// The phases are printed in the order GIVEN, never sorted by cost. Execution order is the point: the
    /// line is read front to back as the pass runs, and a sort would hide where in the pass the time sits.
    func testOrderIsExecutionOrderNotCost() {
        let line = AnalysisPhaseTally.logLine(scope: "postLoop", [
            (name: "steps", seconds: 28.93),
            (name: "baselines", seconds: 0.012),
        ])
        XCTAssertEqual(line, "analyzeRecent postLoop total=28942ms steps=28930ms baselines=12ms")
    }

    /// A backwards wall-clock step (an NTP correction mid-pass is enough) yields a negative interval.
    /// It floors at zero rather than printing a negative duration — and, more to the point, that is the
    /// one input where Swift's round-half-away-from-zero and Kotlin's round-half-up would disagree.
    func testNegativeAndNonFinitePhasesFloorAtZero() {
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "postLoop", [(name: "skew", seconds: -0.0005)]),
                       "analyzeRecent postLoop total=0ms skew=0ms")
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "postLoop", [(name: "nan", seconds: Double.nan)]),
                       "analyzeRecent postLoop total=0ms nan=0ms")
    }

    /// The total is the sum of what was MEASURED, not of the pass. A phase nobody bracketed shows up as
    /// the gap between this number and `re-score: done`, which is how the next blind spot gets found.
    func testTotalIsTheSumOfMeasuredPhasesOnly() {
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "postLoop", [(name: "a", seconds: 0.5), (name: "b", seconds: 0.25)]),
                       "analyzeRecent postLoop total=750ms a=500ms b=250ms")
    }

    /// The scope is the caller's, not a constant. Android brackets only its persist helper (the JaCoCo
    /// method-size ratchet leaves no room in `analyzeRecentOnCpu`), so its line must not claim a `postLoop`
    /// total it never measured. Same phases, different scope, different line.
    func testScopeNamesWhatWasActuallyBracketed() {
        let phases: [(name: String, seconds: Double)] = [(name: "weekly", seconds: 0.07),
                                                         (name: "steps", seconds: 28.93)]
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "persistSteps", phases),
                       "analyzeRecent persistSteps total=29000ms weekly=70ms steps=28930ms")
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "postLoop", phases),
                       "analyzeRecent postLoop total=29000ms weekly=70ms steps=28930ms")
    }

    func testNoPhasesSaysSoRatherThanPrintingNothing() {
        XCTAssertEqual(AnalysisPhaseTally.logLine(scope: "postLoop", []), "analyzeRecent postLoop total=0ms (no phases)")
    }
}
