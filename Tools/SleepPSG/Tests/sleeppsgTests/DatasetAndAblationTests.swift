import XCTest
import WhoopProtocol
@testable import sleeppsg

/// The dataset reader and the leave-one-subject-out machinery, on synthetic fixtures written to a temp
/// directory. No PhysioNet download, no health data, no network — these run in CI.
final class SleepAccelTests: XCTestCase {

    private func makeFixture(labels: String, heartRate: String, motion: String) throws -> String {
        let root = NSTemporaryDirectory() + "sleeppsg-fixture-" + UUID().uuidString
        let fm = FileManager.default
        for d in ["labels", "heart_rate", "motion"] {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        try labels.write(toFile: root + "/labels/9001_labeled_sleep.txt", atomically: true, encoding: .utf8)
        try heartRate.write(toFile: root + "/heart_rate/9001_heartrate.txt", atomically: true, encoding: .utf8)
        try motion.write(toFile: root + "/motion/9001_acceleration.txt", atomically: true, encoding: .utf8)
        addTeardownBlock { try? fm.removeItem(atPath: root) }
        return root
    }

    /// The AASM collapse. N1 and N2 both become light and N3 becomes deep, which is the standard
    /// four-class reduction; anything the collapse does not claim to handle becomes nil and leaves the
    /// denominator rather than being counted as wake.
    func testStageCodeCollapse() {
        XCTAssertEqual(SleepAccel.stageForCode(0), "wake")
        XCTAssertEqual(SleepAccel.stageForCode(1), "light")
        XCTAssertEqual(SleepAccel.stageForCode(2), "light")
        XCTAssertEqual(SleepAccel.stageForCode(3), "deep")
        XCTAssertEqual(SleepAccel.stageForCode(4), "deep")
        XCTAssertEqual(SleepAccel.stageForCode(5), "rem")
        XCTAssertNil(SleepAccel.stageForCode(-1))
        XCTAssertNil(SleepAccel.stageForCode(7))
    }

    /// The load path: label grid, time base, and the per-second collapse of the raw accelerometer.
    func testLoadAlignsTruthEpochsToTheStagerGrid() throws {
        // Four scored epochs, one of them unscored (-1), and a REM epoch last.
        let labels = "0 0\n30 1\n60 -1\n90 5\n"
        // Heart rate is comma-separated in this dataset; motion is space-separated.
        let hr = "0.0,60\n1.5,61\n119.0,58\n"
        // Two raw samples inside second 0 and one inside second 1, so the per-second mean is checkable.
        // 0.90 belongs to second 0 — the bucket is a FLOOR, so a sample late in a second is not pushed
        // into the next one, which would shift motion against heart rate by up to a second.
        let motion = "0.10 0.0 0.0 1.0\n0.90 1.0 0.0 0.0\n1.20 0.0 1.0 0.0\n"
        let root = try makeFixture(labels: labels, heartRate: hr, motion: motion)

        XCTAssertEqual(SleepAccel.resolveRoot(root), root)
        XCTAssertEqual(SleepAccel.subjectIDs(root: root), ["9001"])
        let s = try XCTUnwrap(SleepAccel.load(root: root, id: "9001"))

        XCTAssertEqual(s.start, SleepAccel.timeBase)
        XCTAssertEqual(s.end, SleepAccel.timeBase + 120)
        XCTAssertEqual(s.truth, ["wake", "light", nil, "rem"])
        XCTAssertEqual(s.scoredEpochs, 3)
        XCTAssertEqual(s.scoredMinutes, 1.5, accuracy: 1e-12)

        // The window start is a multiple of 30, so the recipe's wall-clock epoch grid coincides with the
        // PSG scoring grid and no epoch is compared against a label it only half overlaps.
        XCTAssertEqual(s.start % 30, 0)

        XCTAssertEqual(s.hr.map { $0.ts }, [SleepAccel.timeBase, SleepAccel.timeBase + 1, SleepAccel.timeBase + 119])
        XCTAssertEqual(s.hr.map { $0.bpm }, [60, 61, 58])

        XCTAssertEqual(s.grav.count, 2)
        XCTAssertEqual(s.grav[0].ts, SleepAccel.timeBase)
        XCTAssertEqual(s.grav[0].x, 0.5, accuracy: 1e-12, "second 0 averages its two raw samples")
        XCTAssertEqual(s.grav[0].z, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.grav[1].ts, SleepAccel.timeBase + 1)
        XCTAssertEqual(s.grav[1].y, 1.0, accuracy: 1e-12)
    }

    /// Rows outside the recipe's own read window are dropped during the read. `SleepStagerV2.stageSession`
    /// clips its inputs to `[start − 330, end + 390)` before doing anything, so this discards only rows the
    /// recipe provably never touches — which matters because each subject's files span DAYS around the lab
    /// night and the daytime 50 Hz motion would otherwise dominate memory.
    func testSamplesOutsideTheRecipesReadWindowAreDropped() throws {
        // One labelled epoch at t = 0, so the read window is [-330, 420).
        let root = try makeFixture(
            labels: "0 2\n",
            heartRate: "-400.0,70\n-100.0,60\n0.0,61\n500.0,80\n",
            motion: "-400.0 0 0 1\n-100.0 0 0 1\n0.0 0 0 1\n500.0 0 0 1\n")
        let s = try XCTUnwrap(SleepAccel.load(root: root, id: "9001"))
        XCTAssertEqual(s.hr.map { $0.ts - SleepAccel.timeBase }, [-100, 0])
        XCTAssertEqual(s.grav.map { $0.ts - SleepAccel.timeBase }, [-100, 0])
    }

    /// Negative times (the dataset records before PSG lights-out) must not produce negative timestamps:
    /// the recipe's `((start + 29) / 30) * 30` truncates toward zero, which is only the intended floor on
    /// non-negative input.
    func testPreRecordingSamplesStayPositive() throws {
        // t = −300.5 is before lights-out but still inside the recipe's read window (−330 onward), so it
        // survives clipping and exercises the negative-time path. Floor puts it in second −301.
        let root = try makeFixture(labels: "0 0\n30 2\n",
                                   heartRate: "-300.5,70\n0.0,60\n",
                                   motion: "-300.5 0.0 0.0 1.0\n0.0 0.0 0.0 1.0\n")
        let s = try XCTUnwrap(SleepAccel.load(root: root, id: "9001"))
        XCTAssertTrue(s.hr.allSatisfy { $0.ts > 0 })
        XCTAssertTrue(s.grav.allSatisfy { $0.ts > 0 })
        XCTAssertEqual(s.hr.first?.ts, SleepAccel.timeBase - 301)
        XCTAssertEqual(s.grav.first?.ts, SleepAccel.timeBase - 301)
    }

    /// The byte-level row parser: mixed separators, blank lines, a trailing line with no newline, and a
    /// short row that must be dropped rather than half-read.
    func testRowParserToleratesRealFileShapes() throws {
        let root = try makeFixture(labels: "0 0\n30 5\n",
                                   heartRate: "0.0,60\n\n10.0 61\n20.0,62",
                                   motion: "0.0 1.0 0.0 0.0\n1.0 0.0\n2.0 0.0 0.0 1.0")
        let s = try XCTUnwrap(SleepAccel.load(root: root, id: "9001"))
        XCTAssertEqual(s.hr.map { $0.bpm }, [60, 61, 62], "blank line skipped, both separators accepted")
        XCTAssertEqual(s.grav.count, 2, "the 2-value motion row is dropped, not padded with garbage")
    }

    /// Passing the directory that CONTAINS the extracted dataset must work too — the published zip expands
    /// into a long-named subdirectory nobody types by hand.
    func testResolveRootAcceptsTheParentDirectory() throws {
        let root = try makeFixture(labels: "0 0\n", heartRate: "0.0,60\n", motion: "0.0 0 0 1\n")
        let parent = (root as NSString).deletingLastPathComponent
        XCTAssertEqual(SleepAccel.resolveRoot(parent + "/" + (root as NSString).lastPathComponent), root)
    }
}

final class AblationTests: XCTestCase {

    /// A subject's own epochs must never appear in the fold that scores it. This is the leak the whole
    /// design exists to prevent — consecutive 30 s epochs from one night are nearly identical, so an
    /// epoch-level split lets any model memorise the subject and score near-perfectly.
    func testHeldOutSubjectIsNeverInItsOwnTrainingFold() {
        // Two subjects with OPPOSITE physiology→REM mappings and no clock signal at all. A model that
        // leaked the held-out subject's rows would score well; one that generalises cannot, because the
        // training fold teaches it exactly the wrong sign.
        var rows: [AblationRow] = []
        for i in 0..<200 {
            let x = Double(i % 2)
            rows.append(AblationRow(subject: "A", isRem: x > 0.5,
                                    clock: [0.5, 0.25], physiology: [x, 0, 0, 0.5]))
            rows.append(AblationRow(subject: "B", isRem: x < 0.5,
                                    clock: [0.5, 0.25], physiology: [x, 0, 0, 0.5]))
        }
        let res = Ablation.run(rows)
        let phys = res.first { $0.model == .physiology }!
        XCTAssertLessThan(phys.pooledF1, 0.55,
                          "physiology F1 near 1.0 here would mean the held-out subject leaked into training")
    }

    /// The fitter has to actually fit: a cleanly separable signal must be recovered, or a null result from
    /// the clock model would be indistinguishable from a broken optimiser.
    func testLogisticFitRecoversASeparableSignal() {
        var X: [[Double]] = [], y: [Bool] = []
        for i in 0..<400 {
            let v = Double(i) / 400.0
            X.append([v]); y.append(v > 0.5)
        }
        let w = Ablation.logisticFit(X: X, y: y)
        XCTAssertGreaterThan(w[1], 1.0, "the coefficient must be positive and substantial")
        XCTAssertLessThan(Ablation.sigmoid(Ablation.dot(w, [0.1])), 0.2)
        XCTAssertGreaterThan(Ablation.sigmoid(Ablation.dot(w, [0.9])), 0.8)
    }

    /// The threshold is tuned on the training folds, which matters because REM is a minority class: a
    /// fixed 0.5 systematically under-predicts it, and unequally across models with different calibration.
    func testThresholdTuningBeatsAFixedHalfOnAMinorityClass() {
        // 10 % positives whose scores never reach 0.5 — a fixed cut scores 0, a tuned cut recovers them.
        var scores: [Double] = [], truth: [Bool] = []
        for i in 0..<100 {
            let pos = i < 10
            scores.append(pos ? 0.40 : 0.05); truth.append(pos)
        }
        let thr = Ablation.bestF1Threshold(scores: scores, truth: truth)
        XCTAssertLessThanOrEqual(thr, 0.40)
        XCTAssertEqual(binaryF1(ref: truth, pred: scores.map { $0 >= 0.5 }), 0.0, accuracy: 1e-12)
        XCTAssertEqual(binaryF1(ref: truth, pred: scores.map { $0 >= thr }), 1.0, accuracy: 1e-12)
    }

    func testLinearSolveMatchesAKnownSystem() {
        // [[2,1],[1,3]] x = [5,10] → x = [1,3].
        let x = Ablation.solve([[2, 1], [1, 3]], [5, 10])!
        XCTAssertEqual(x[0], 1.0, accuracy: 1e-9)
        XCTAssertEqual(x[1], 3.0, accuracy: 1e-9)
        XCTAssertNil(Ablation.solve([[1, 2], [2, 4]], [1, 2]), "a singular system returns nil, not NaNs")
    }
}

final class VariantsTests: XCTestCase {

    /// Each variant must differ from the shipped recipe in exactly the fields its name claims. A variant
    /// that quietly moved a second constant could not be attributed, which is the entire point of measuring
    /// #348's components one at a time.
    func testEachVariantIsASingleNamedChange() {
        let s = RecipeConfig.shipped

        // #987 is a two-sided comparison: this repository's main carries it, upstream's does not, and the
        // variant offers whichever row the branch is NOT on. Both directions are asserted so the test does
        // not have to know which branch it is compiled on.
        var c = Variants.pr987.config
        let shippedRow = s.transition["awake"]!
        XCTAssertTrue(shippedRow == Variants.awakeRowPre987 || shippedRow == Variants.awakeRowPR987,
                      "the shipped awake row is neither side of #987 — RecipeConfig.shipped is stale")
        XCTAssertEqual(c.transition["awake"]!,
                       shippedRow == Variants.awakeRowPR987 ? Variants.awakeRowPre987 : Variants.awakeRowPR987,
                       "the #987 variant must offer the row the branch is NOT on")
        c.transition = s.transition
        XCTAssertEqual(c, s, "#987 must change nothing but the awake transition row")

        var p = Variants.p348Priors.config
        XCTAssertEqual(p.priorDeep, log(0.15), accuracy: 1e-12)
        XCTAssertEqual(p.priorAwake, log(0.34), accuracy: 1e-12)
        p.priorDeep = s.priorDeep; p.priorAwake = s.priorAwake
        XCTAssertEqual(p, s)

        var m = Variants.p348Motion.config
        m.jerkFloorMoveMult = s.jerkFloorMoveMult; m.jerkFloorGateMult = s.jerkFloorGateMult
        m.motionGateBoost = s.motionGateBoost
        XCTAssertEqual(m, s)

        var d = Variants.p348DeepGate.config
        d.deepGateThresh = s.deepGateThresh
        XCTAssertEqual(d, s)

        var z = Variants.p348Deadzone.config
        z.awakeDeadzone = s.awakeDeadzone
        XCTAssertEqual(z, s)

        var o = Variants.p348OtherRows.config
        XCTAssertEqual(o.transition["awake"]!, s.transition["awake"]!, "the awake row is #987's, not this one's")
        o.transition = s.transition
        XCTAssertEqual(o, s)

        var g = Variants.preNine30Guard.config
        XCTAssertEqual(g.remLatencyMode, .preNine30FractionStep)
        g.remLatencyMode = s.remLatencyMode
        XCTAssertEqual(g, s, "the provenance variant must change nothing but the guard's shape")
    }

    /// The shipped mode is the graded one, and the pre-#930 step must actually reach the lattice — a
    /// provenance variant that staged identically to the incumbent would explain nothing about the gap it
    /// is there to explain.
    func testPreNine30GuardActuallyChangesTheHypnogram() {
        XCTAssertEqual(RecipeConfig.shipped.remLatencyMode, .gradedFromOnset)
        var differed = false
        for n in PortValidation.corpus().prefix(6) {
            let a = V2Recipe.stageSession(start: n.start, end: n.end, grav: n.grav, hr: n.hr,
                                          rr: n.rr, resp: n.resp, cfg: .shipped)
            let b = V2Recipe.stageSession(start: n.start, end: n.end, grav: n.grav, hr: n.hr,
                                          rr: n.rr, resp: n.resp, cfg: Variants.preNine30Guard.config)
            XCTAssertFalse(a.isEmpty)
            if epochLabels(a, start: n.start, end: n.end) != epochLabels(b, start: n.start, end: n.end) {
                differed = true
                break
            }
        }
        XCTAssertTrue(differed, "the pre-#930 guard staged identically on every night — mode is not wired")
    }

    /// The shipped dead-zone is off, and `dz` must then be the identity — that is what makes
    /// `RecipeConfig.shipped` able to reproduce an emission the shipped file writes without any dead-zone
    /// at all.
    func testDeadzoneIsTheIdentityWhenDisabled() {
        XCTAssertEqual(RecipeConfig.shipped.awakeDeadzone, 0.0)
        for z in [-3.0, -0.1, 0.0, 0.29, 5.0] {
            XCTAssertEqual(V2Recipe.dz(z, 0.0), z, accuracy: 1e-12)
        }
        XCTAssertEqual(V2Recipe.dz(0.2, 0.3), 0.0, accuracy: 1e-12)
        XCTAssertEqual(V2Recipe.dz(0.5, 0.3), 0.2, accuracy: 1e-12)
        XCTAssertEqual(V2Recipe.dz(-0.5, 0.3), -0.2, accuracy: 1e-12)
    }

    /// Transition rows must stay probability distributions, in every variant. A row that no longer sums to
    /// 1 would silently reweight the whole lattice rather than express the change its name claims.
    func testEveryVariantsTransitionRowsSumToOne() {
        for v in Variants.all {
            for (from, row) in v.config.transition {
                XCTAssertEqual(row.values.reduce(0, +), 1.0, accuracy: 1e-9,
                               "\(v.name): row \(from) does not sum to 1")
            }
        }
    }

    /// `#348 entire` must be the union of the components, not an independently typed eighth build.
    func testEntire348IsTheUnionOfItsComponents() {
        let all = Variants.p348All.config
        XCTAssertEqual(all.priorDeep, Variants.p348Priors.config.priorDeep)
        XCTAssertEqual(all.priorAwake, Variants.p348Priors.config.priorAwake)
        XCTAssertEqual(all.jerkFloorMoveMult, Variants.p348Motion.config.jerkFloorMoveMult)
        XCTAssertEqual(all.motionGateBoost, Variants.p348Motion.config.motionGateBoost)
        XCTAssertEqual(all.deepZhv, Variants.p348Emissions.config.deepZhv)
        XCTAssertEqual(all.awakeZhr, Variants.p348Emissions.config.awakeZhr)
        XCTAssertEqual(all.deepGateThresh, Variants.p348DeepGate.config.deepGateThresh)
        XCTAssertEqual(all.awakeDeadzone, Variants.p348Deadzone.config.awakeDeadzone)
        XCTAssertEqual(all.transition["light"]!, Variants.p348OtherRows.config.transition["light"]!)
        XCTAssertEqual(all.transition["awake"]!, Variants.awakeRowPR987,
                       "#348's awake row is the one #987 later restored")
    }
}
