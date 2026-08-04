import StrandAnalytics
import XCTest

@testable import sleepbench

/// The stage-fraction and first-REM-latency primitives are pure functions over 30 s label arrays, so they
/// are pinned here on hand-built hypnograms — no database, no health data, no `--db` argument.
final class CalibrationMetricsTests: XCTestCase {

    /// A label array of `n` epochs all at `stage`.
    private func run(_ stage: String, _ n: Int) -> [String] { [String](repeating: stage, count: n) }

    // MARK: - stagePercentages

    func testStagePercentagesSumTo100AndMatchCounts() {
        let labels = run("wake", 10) + run("light", 50) + run("deep", 20) + run("rem", 20)
        let p = stagePercentages(labels)
        XCTAssertEqual(p["wake"]!, 10, accuracy: 1e-9)
        XCTAssertEqual(p["light"]!, 50, accuracy: 1e-9)
        XCTAssertEqual(p["deep"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(p["rem"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(stageOrder.reduce(0) { $0 + p[$1]! }, 100, accuracy: 1e-9)
    }

    /// A stage a recipe stops emitting must read as 0%, not as a missing key — otherwise the bias against a
    /// reference that DOES contain that stage would silently vanish instead of showing up as the regression
    /// it is. This is the shape of the #348 failure: a recipe reallocating a whole stage.
    func testStagePercentagesReportsUnusedStagesAsZero() {
        let p = stagePercentages(run("wake", 4))
        XCTAssertEqual(Set(p.keys), Set(stageOrder))
        XCTAssertEqual(p["wake"]!, 100, accuracy: 1e-9)
        for s in ["light", "deep", "rem"] { XCTAssertEqual(p[s]!, 0, accuracy: 1e-9) }
    }

    func testStagePercentagesOnEmptyLabelsIsAllZeroNotNaN() {
        let p = stagePercentages([])
        for s in stageOrder { XCTAssertEqual(p[s]!, 0, accuracy: 1e-9) }
    }

    // MARK: - stageBias

    /// Sign convention is load-bearing: the whole point of the metric is telling an over-call from an
    /// under-call, so POSITIVE must mean the recipe spends more of the night at that stage than the human.
    func testStageBiasIsPositiveWhenTheRecipeOverCalls() {
        let ref = run("wake", 10) + run("light", 90)      // 10% wake
        let pred = run("wake", 30) + run("light", 70)     // 30% wake
        let b = stageBias(ref: ref, pred: pred)
        XCTAssertEqual(b["wake"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(b["light"]!, -20, accuracy: 1e-9)
        XCTAssertEqual(b["deep"]!, 0, accuracy: 1e-9)
    }

    /// The #437 field symptom, reproduced numerically: a healthy night re-scored 6% -> 23% awake is a
    /// +17 pp wake bias, which is what this metric exists to surface.
    func testStageBiasReproducesTheRevertScaleSymptom() {
        let ref = run("wake", 6) + run("light", 94)
        let pred = run("wake", 23) + run("light", 77)
        XCTAssertEqual(stageBias(ref: ref, pred: pred)["wake"]!, 17, accuracy: 1e-9)
    }

    /// Two nights that miss in opposite directions cancel in the signed mean but not in the MAE, which is
    /// why both are reported: a mean bias near zero is not by itself evidence of good calibration.
    func testMeanBiasCancelsWhereMAEDoesNot() {
        let errs = [12.0, -12.0]
        XCTAssertEqual(mean(errs), 0, accuracy: 1e-9)
        XCTAssertEqual(mae(errs), 12, accuracy: 1e-9)
    }

    // MARK: - firstRemLatencyMinutes

    /// Latency is measured from staged ONSET, not from the start of the session — a night with a long
    /// awake-in-bed lead-in must not be credited with a long REM latency.
    func testFirstRemLatencyIsMeasuredFromOnsetNotSessionStart() {
        // 60 epochs awake in bed, then 20 light, then REM. Onset is epoch 60, REM at epoch 80.
        let labels = run("wake", 60) + run("light", 20) + run("rem", 10)
        XCTAssertEqual(firstRemLatencyMinutes(labels)!, 10.0, accuracy: 1e-9)  // 20 epochs x 30 s
    }

    func testFirstRemLatencyUsesTheThirtySecondGrid() {
        let labels = run("light", 2) + run("rem", 1)
        XCTAssertEqual(firstRemLatencyMinutes(labels)!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(epochSeconds, 30.0, accuracy: 1e-9)
    }

    func testFirstRemLatencyIsZeroWhenREMIsTheFirstSleepEpoch() {
        XCTAssertEqual(firstRemLatencyMinutes(run("wake", 5) + run("rem", 5))!, 0.0, accuracy: 1e-9)
    }

    /// A night with no REM is a DIFFERENT outcome from a night whose REM lands at minute zero. Collapsing
    /// them would let a recipe that stops emitting REM read as one with an excellent short latency.
    func testFirstRemLatencyIsNilWithoutREMAndWithoutSleep() {
        XCTAssertNil(firstRemLatencyMinutes(run("wake", 20) + run("light", 40)))
        XCTAssertNil(firstRemLatencyMinutes(run("wake", 100)))
        XCTAssertNil(firstRemLatencyMinutes([]))
    }

    // MARK: - percentile

    func testPercentileSpansMinToMax() {
        let v = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(percentile(v, 0.0), 1, accuracy: 1e-9)
        XCTAssertEqual(percentile(v, 1.0), 10, accuracy: 1e-9)
        XCTAssertEqual(percentile(v, 0.5), 6, accuracy: 1e-9)
    }

    func testPercentileIsOrderIndependentAndSafeOnEmpty() {
        XCTAssertEqual(percentile([5.0, 1, 3], 0.0), 1, accuracy: 1e-9)
        XCTAssertTrue(percentile([], 0.5).isNaN)
    }

    // MARK: - the grid the metrics run on

    /// `stagePercentages` and `firstRemLatencyMinutes` both consume `epochLabels` output in the harness, so
    /// the expansion from a `StageSegment` tiling has to land the stages where the metrics expect them.
    func testMetricsAgreeWithEpochLabelExpansion() {
        // 30 min wake, 30 min light, 30 min REM, on a 90 min session.
        let start = 1_700_000_000
        let segs = [
            StageSegment(start: start, end: start + 1800, stage: "wake"),
            StageSegment(start: start + 1800, end: start + 3600, stage: "light"),
            StageSegment(start: start + 3600, end: start + 5400, stage: "rem"),
        ]
        let labels = epochLabels(segs, start: start, end: start + 5400)
        XCTAssertEqual(labels.count, 180)
        let p = stagePercentages(labels)
        XCTAssertEqual(p["wake"]!, 100.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(p["light"]!, 100.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(p["rem"]!, 100.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(firstRemLatencyMinutes(labels)!, 30.0, accuracy: 1e-9)
        XCTAssertEqual(wakeMinutes(labels), 30.0, accuracy: 1e-9)
    }
}
