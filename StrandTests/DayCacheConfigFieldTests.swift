import XCTest
@testable import Strand

/// Swift twin of the Kotlin `DayCacheConfigFieldTest`: which config field dropped the day cache.
///
/// #2073 made a wholesale drop visible (`configDropped`), and a field log on build 487 showed it firing
/// for real: `reused=0/21 missBy=absent:21,configDropped:1`, against a healthy pass that reuses 20 of 21
/// and misses only today. The expensive passes cost up to 35 s of prep and 22 s of scoring, so which
/// field moved is the difference between a config the user actually changed and a value that drifts on
/// its own.
///
/// The signature is a plain "|"-joined value list, and the field NAMES live beside the reader rather than
/// the construction, which on the Kotlin side keeps them off a bytecode ratchet. That split is the risk
/// pinned here: a reader that guessed an index would name the wrong field and send someone hunting a bug
/// that is not there, which is worse than saying nothing.
final class DayCacheConfigFieldTests: XCTestCase {

    /// A signature with one value per known field, so a changed index has a name to resolve to.
    private func fullSig(_ mutate: (inout [String]) -> Void = { _ in }) -> String {
        var v = (0..<IntelligenceEngine.dayCacheConfigFields.count).map { "v\($0)" }
        mutate(&v)
        return v.joined(separator: "|")
    }

    func testTheMovedFieldIsNamed() {
        XCTAssertEqual(
            IntelligenceEngine.changedConfigField(previous: fullSig(), current: fullSig { $0[0] = "moved" }),
            "hrvBaseline"
        )
    }

    /// The field log's leading suspicion was a rolling baseline, which is index 0 and 1. Naming them
    /// apart is the whole point: one is HRV drifting, the other resting heart rate.
    func testTheTwoBaselinesAreToldApart() {
        XCTAssertEqual(
            IntelligenceEngine.changedConfigField(previous: fullSig(), current: fullSig { $0[1] = "moved" }),
            "rhrBaseline"
        )
        XCTAssertEqual(
            IntelligenceEngine.changedConfigField(previous: fullSig(), current: fullSig { $0[15] = "moved" }),
            "dayCycleMode"
        )
    }

    /// Several at once happens on a settings change that touches more than one knob.
    func testSeveralMoversAreAllNamed() {
        let after = fullSig { $0[0] = "a"; $0[14] = "b" }
        XCTAssertEqual(IntelligenceEngine.changedConfigField(previous: fullSig(), current: after),
                       "hrvBaseline+effortMethod")
    }

    /// The signature starts EMPTY rather than nil, so the first drop of a process has nothing to diff
    /// against. Reporting that as "unknown" would describe a shape mismatch that never happened.
    func testTheFirstDropOfAProcessSaysFirst() {
        XCTAssertEqual(IntelligenceEngine.changedConfigField(previous: "", current: fullSig()), "first")
    }

    /// The names and the construction can fall out of step, because they live apart. When they do, this
    /// refuses to name anything rather than resolve an index against a list that no longer describes it.
    /// A wrong field name is worse than none: a diagnostic asserting what it cannot attribute.
    func testAShapeMismatchIsRefusedRatherThanGuessed() {
        XCTAssertEqual(IntelligenceEngine.changedConfigField(previous: "a|b", current: "a|c"), "unknown")
        XCTAssertEqual(IntelligenceEngine.changedConfigField(previous: fullSig(), current: "a"), "unknown")
    }

    /// Equal signatures never reach the caller, but the helper still answers honestly if they do.
    func testAnUnchangedSignatureNamesNothing() {
        XCTAssertEqual(IntelligenceEngine.changedConfigField(previous: fullSig(), current: fullSig()), "none")
    }

    /// The two platforms must describe the same fields in the same order, or the same drop is reported
    /// as two different causes depending on which phone the reporter happens to hold.
    func testTheFieldListMatchesTheKotlinTwin() {
        XCTAssertEqual(IntelligenceEngine.dayCacheConfigFields, [
            "hrvBaseline", "rhrBaseline", "age", "sex", "stepTicksPerStep", "maxHROverride",
            "tzOffset", "sleepNeedHours", "sleepConsistency", "habitualMidsleep",
            "experimentalSleepV2", "motionAwareWake", "deepHrvWindow", "spo2CandidateDisplay",
            "effortMethod", "dayCycleMode",
        ])
    }
}
