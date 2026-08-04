import XCTest
import StrandAnalytics
@testable import sleeppsg

/// Scoring primitives, pinned against values computed by hand.
///
/// These definitions are shared, in spirit, with `Tools/SleepBench/Sources/sleepbench/Metrics.swift`: the
/// two harnesses score the same recipe against different references, and a kappa that meant something
/// slightly different in each would make their numbers incomparable precisely when someone needs to compare
/// them. Pinning the arithmetic is how that stays true without the two files being one file.
final class ScoringTests: XCTestCase {

    // MARK: - Agreement

    func testKappaOnAHandComputedMatrix() {
        // 10 epochs: 4 wake (3 right), 6 light (5 right, 1 called wake).
        let ref = ["wake", "wake", "wake", "wake", "light", "light", "light", "light", "light", "light"]
        let pred = ["wake", "wake", "wake", "light", "light", "light", "light", "light", "light", "wake"]
        let c = confusion(ref: ref, pred: pred)
        // po = 8/10. Marginals: ref wake .4 light .6; pred wake .4 light .6 → pe = .16 + .36 = .52.
        // kappa = (.8 − .52) / (1 − .52) = .28 / .48 = 0.58333…
        XCTAssertEqual(c.accuracy, 0.8, accuracy: 1e-12)
        XCTAssertEqual(c.kappa, 0.28 / 0.48, accuracy: 1e-12)
    }

    func testPerfectAndChanceAgreement() {
        let labels = ["wake", "light", "deep", "rem", "light", "light"]
        XCTAssertEqual(confusion(ref: labels, pred: labels).kappa, 1.0, accuracy: 1e-12)
        // Every epoch called light against a 50/50 reference: accuracy = pe, so kappa is exactly 0.
        let ref = ["light", "wake", "light", "wake"]
        let all = ["light", "light", "light", "light"]
        XCTAssertEqual(confusion(ref: ref, pred: all).kappa, 0.0, accuracy: 1e-12)
    }

    func testPerStageF1IsHarmonicMeanOfPrecisionAndRecall() {
        // REM: 2 true REM epochs, 1 recovered; 1 false REM. precision 1/2, recall 1/2, F1 1/2.
        let ref = ["rem", "rem", "light", "light"]
        let pred = ["rem", "light", "rem", "light"]
        let p = confusion(ref: ref, pred: pred).prf("rem")
        XCTAssertEqual(p.precision, 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.recall, 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.f1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.support, 2)
    }

    /// A recipe that stops emitting a stage must score 0 on it, not n/a — a silent nil would let a
    /// collapsed stage disappear from a summary table instead of announcing itself.
    func testStageNeverEmittedScoresZeroNotNaN() {
        let p = confusion(ref: ["rem", "rem", "light"], pred: ["light", "light", "light"]).prf("rem")
        XCTAssertTrue(p.precision.isNaN, "precision is undefined when nothing was predicted")
        XCTAssertEqual(p.recall, 0.0, accuracy: 1e-12)
        XCTAssertEqual(p.f1, 0.0, accuracy: 1e-12)
        XCTAssertEqual(p.support, 2)
    }

    func testBinaryF1MatchesTheConfusionMatrixVersion() {
        let ref = ["rem", "rem", "light", "light", "rem"]
        let pred = ["rem", "light", "rem", "light", "rem"]
        XCTAssertEqual(binaryF1(ref: ref.map { $0 == "rem" }, pred: pred.map { $0 == "rem" }),
                       confusion(ref: ref, pred: pred).prf("rem").f1, accuracy: 1e-12)
    }

    // MARK: - Stage fractions

    func testStagePercentagesAlwaysCarryEveryStage() {
        let pct = stagePercentages(["light", "light", "wake", "wake"])
        XCTAssertEqual(Set(pct.keys), Set(stageOrder))
        XCTAssertEqual(pct["light"]!, 50, accuracy: 1e-12)
        XCTAssertEqual(pct["wake"]!, 50, accuracy: 1e-12)
        XCTAssertEqual(pct["deep"]!, 0, accuracy: 1e-12)
        XCTAssertEqual(pct["rem"]!, 0, accuracy: 1e-12)
    }

    /// The #348 → #437 lesson, as an assertion: a change can raise kappa AND wreck a stage fraction, so a
    /// harness that reports only kappa cannot see the regression that reverted that PR.
    func testKappaCanRiseWhileWakeFractionBlowsOut() {
        let ref = Array(repeating: "light", count: 90) + Array(repeating: "wake", count: 10)
        // Incumbent: calls only 6 epochs wake, gets 4 of them right.
        var before = Array(repeating: "light", count: 100)
        for i in 90..<94 { before[i] = "wake" }
        for i in 0..<2 { before[i] = "wake" }
        // Candidate: calls 23 epochs wake, gets 9 of the 10 real ones — kappa up, wake fraction ruined.
        var after = Array(repeating: "light", count: 100)
        for i in 90..<99 { after[i] = "wake" }
        for i in 0..<14 { after[i] = "wake" }
        let kBefore = confusion(ref: ref, pred: before).kappa
        let kAfter = confusion(ref: ref, pred: after).kappa
        XCTAssertGreaterThan(kAfter, kBefore, "the candidate must win on kappa for this test to mean anything")
        XCTAssertEqual(stageBias(ref: ref, pred: before)["wake"]!, -4, accuracy: 1e-9)
        XCTAssertEqual(stageBias(ref: ref, pred: after)["wake"]!, 13, accuracy: 1e-9)
    }

    // MARK: - Latency

    func testFirstRemLatencyIsMeasuredFromOnsetNotWindowStart() {
        // 4 wake epochs, then light, then REM at index 6 → 2 epochs after onset → 1.0 min.
        let labels = ["wake", "wake", "wake", "wake", "light", "light", "rem", "light"]
        XCTAssertEqual(firstRemLatencyMinutes(labels)!, 1.0, accuracy: 1e-12)
    }

    func testNoRemIsNilRatherThanZero() {
        XCTAssertNil(firstRemLatencyMinutes(["wake", "light", "light", "deep"]))
        XCTAssertNil(firstRemLatencyMinutes(["wake", "wake"]))
    }

    /// Unscored epochs keep their slot in the arithmetic. Collapsing them first would shorten the truth
    /// latency by however much of the night the technician left unscored — and only the truth column,
    /// which is exactly the kind of asymmetry that makes a prediction look better than it is.
    func testLatencyOverAGridWithUnscoredEpochs() {
        let sparse: [String?] = ["wake", nil, nil, "light", nil, "light", "rem"]
        // onset at index 3, REM at index 6 → 3 epochs → 1.5 min, unscored slots included.
        XCTAssertEqual(firstRemLatencyMinutes(sparse)!, 1.5, accuracy: 1e-12)
        // Collapsing first would have given 2 epochs → 1.0 min. Pin that this is NOT what happens.
        XCTAssertNotEqual(firstRemLatencyMinutes(sparse.compactMap { $0 })!, 1.5)
        XCTAssertNil(firstRemLatencyMinutes([nil, nil, "wake"] as [String?]))
    }

    // MARK: - Epoch expansion

    func testEpochLabelsTileTheWindowFromSegments() {
        let segs = [StageSegment(start: 0, end: 60, stage: "wake"),
                    StageSegment(start: 60, end: 150, stage: "light"),
                    StageSegment(start: 150, end: 180, stage: "rem")]
        XCTAssertEqual(epochLabels(segs, start: 0, end: 180),
                       ["wake", "wake", "light", "light", "light", "rem"])
    }

    // MARK: - Descriptive statistics

    func testPearsonAndSpearmanOnAMonotoneButCurvedRelation() {
        let x = [1.0, 2, 3, 4, 5]
        let y = [1.0, 4, 9, 16, 25]
        XCTAssertEqual(spearman(x, y), 1.0, accuracy: 1e-12, "ranks are perfectly monotone")
        XCTAssertLessThan(pearson(x, y).r, 1.0, "the linear fit is not perfect")
        XCTAssertGreaterThan(pearson(x, y).r, 0.95)
    }

    func testSpearmanHandlesTies() {
        XCTAssertEqual(spearman([1.0, 2, 2, 3], [1.0, 2, 2, 3]), 1.0, accuracy: 1e-12)
    }
}
