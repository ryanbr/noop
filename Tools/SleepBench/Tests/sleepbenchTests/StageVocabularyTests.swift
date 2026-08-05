import StrandAnalytics
import XCTest

@testable import sleepbench

/// #979 fixed eleven segment comparisons in the app but left this harness comparing bare `"wake"`
/// literals, so a hypnogram spelling wake `"awake"` — Oura's phase table, generic wearable JSON, or a
/// stage-edited night's `stagelock` rows — had every wake epoch scored as SLEEP. That biases wake
/// DOWN and sleep UP in exactly the metrics the project has repeatedly re-measured and got wrong signs
/// on: wake-minute error, wake over-call, and sleep/wake kappa against the strap band.
///
/// Every test here scores the SAME night written two ways and demands the two agree. No database, no
/// health data, no `--db` argument.
final class StageVocabularyTests: XCTestCase {

    private func run(_ stage: String, _ n: Int) -> [String] { [String](repeating: stage, count: n) }

    /// One night, two spellings: 40 epochs wake, 100 light, 20 deep, 20 rem, then 20 more wake.
    private var deviceSpelling: [String] {
        run("wake", 40) + run("light", 100) + run("deep", 20) + run("rem", 20) + run("wake", 20)
    }
    private var importSpelling: [String] {
        run("awake", 40) + run("light", 100) + run("deep", 20) + run("rem", 20) + run("awake", 20)
    }

    // MARK: - The vocabulary itself

    /// The harness classifies by "everything that is not wake is sleep", which is sound only while the
    /// scored vocabulary is these four. A fifth label must break this test, not land in the sleep bucket.
    func testStageOrderIsTheClosedScoredSet() {
        XCTAssertEqual(stageOrder, ["wake", "light", "deep", "rem"])
        XCTAssertFalse(stageOrder.contains("awake"), "\"awake\" is an input spelling, never a scored class")
        for s in stageOrder { XCTAssertEqual(bucketLabel(s), s, "\(s) must be its own bucket") }
    }

    func testIsWakeAcceptsBothSpellingsAndRejectsSleepStages() {
        for w in ["wake", "awake", "Awake", "  WAKE "] { XCTAssertTrue(isWake(w), "\(w) should read as wake") }
        for s in ["light", "deep", "rem"] { XCTAssertFalse(isWake(s)) }
    }

    /// The harness bucket must agree with the shared predicate — one rule, not two.
    func testBucketLabelAgreesWithTheSharedPredicate() {
        for s in ["wake", "awake", "Awake", "light", "deep", "rem", "restless"] {
            XCTAssertEqual(bucketLabel(s) == "wake", SleepStageVocabulary.isWake(s), "disagreement on \(s)")
        }
        XCTAssertEqual(bucketLabel("awake"), "wake")
        XCTAssertEqual(bucketLabel("restless"), "restless", "an unknown label stays visible, not coerced")
    }

    // MARK: - The two spellings must score identically

    func testWakeMinutesAreIdenticalAcrossSpellings() {
        XCTAssertEqual(wakeMinutes(importSpelling), wakeMinutes(deviceSpelling), accuracy: 1e-9)
        // 60 wake epochs x 30 s = 30 min. The pre-fix harness returned 0 for the "awake" spelling.
        XCTAssertEqual(wakeMinutes(importSpelling), 30.0, accuracy: 1e-9)
    }

    func testSleepMinutesAreIdenticalAcrossSpellings() {
        XCTAssertEqual(sleepMinutes(importSpelling), sleepMinutes(deviceSpelling), accuracy: 1e-9)
        // 140 sleep epochs x 30 s = 70 min. Pre-fix, all 200 epochs (100 min) counted as sleep.
        XCTAssertEqual(sleepMinutes(importSpelling), 70.0, accuracy: 1e-9)
    }

    func testToSleepWakeIsIdenticalAcrossSpellings() {
        XCTAssertEqual(toSleepWake(importSpelling), toSleepWake(deviceSpelling))
        // Pre-fix this mapped every "awake" epoch to "sleep", producing a reference that claims the wearer
        // never woke — which is what section C's sleep/wake kappa was then scored against.
        XCTAssertEqual(toSleepWake(importSpelling).filter { $0 == "wake" }.count, 60)
    }

    func testOnsetAndFinalWakeAreIdenticalAcrossSpellings() {
        let imported = onsetAndFinalWake(importSpelling), device = onsetAndFinalWake(deviceSpelling)
        XCTAssertEqual(imported.onset, device.onset)
        XCTAssertEqual(imported.final, device.final)
        // Onset is the first sleep epoch (40), final wake the last (179). Pre-fix onset landed on index 0 —
        // the first "awake" epoch — collapsing the whole 20 min sleep latency to zero.
        XCTAssertEqual(imported.onset, 40)
        XCTAssertEqual(imported.final, 179)
    }

    func testStagePercentagesAndBiasAreIdenticalAcrossSpellings() {
        let imported = stagePercentages(importSpelling), device = stagePercentages(deviceSpelling)
        for s in stageOrder { XCTAssertEqual(imported[s]!, device[s]!, accuracy: 1e-9, "stage \(s)") }
        XCTAssertEqual(imported["wake"]!, 30.0, accuracy: 1e-9)   // 60 of 200 epochs
        // Pre-fix, "awake" opened a fifth key no caller reads while "wake" stayed 0 — so a night the human
        // scored 30% awake read as a 30 pp UNDER-call of wake against any replay that got it right.
        XCTAssertNil(imported["awake"])

        // A recipe scored against the two spellings of the same reference must get the same bias.
        let pred = run("wake", 60) + run("light", 140)
        let bImported = stageBias(ref: importSpelling, pred: pred)
        let bDevice = stageBias(ref: deviceSpelling, pred: pred)
        for s in stageOrder { XCTAssertEqual(bImported[s]!, bDevice[s]!, accuracy: 1e-9, "bias \(s)") }
        XCTAssertEqual(bImported["wake"]!, 0.0, accuracy: 1e-9, "same wake fraction ⇒ zero bias")
    }

    func testFirstRemLatencyIsIdenticalAcrossSpellings() {
        XCTAssertEqual(firstRemLatencyMinutes(importSpelling)!,
                       firstRemLatencyMinutes(deviceSpelling)!, accuracy: 1e-9)
        // Onset at epoch 40, REM at 160 ⇒ 120 epochs x 30 s = 60 min. Pre-fix the "awake" spelling put
        // onset at epoch 0 and reported 80 min.
        XCTAssertEqual(firstRemLatencyMinutes(importSpelling)!, 60.0, accuracy: 1e-9)
    }

    // MARK: - Agreement scoring

    /// The nastiest pre-fix failure mode: an `"awake"` reference epoch matched no class in `stageOrder`,
    /// so `Confusion.add` dropped it. The epochs did not go to the wrong cell — they left the matrix,
    /// silently shrinking the denominator under every accuracy and kappa in the run.
    func testConfusionKeepsEveryEpochRegardlessOfSpelling() {
        let pred = deviceSpelling
        let imported = confusion(ref: importSpelling, pred: pred)
        let device = confusion(ref: deviceSpelling, pred: pred)
        XCTAssertEqual(imported.total, 200, "no epoch may be dropped for spelling wake \"awake\"")
        XCTAssertEqual(imported.total, device.total)
        XCTAssertEqual(imported.m, device.m)
        XCTAssertEqual(imported.accuracy, 1.0, accuracy: 1e-9)
    }

    /// Section C's kappa is computed on the 2-class collapse, so the fold decides it outright.
    func testSleepWakeKappaIsIdenticalAcrossSpellings() {
        let pred = toSleepWake(deviceSpelling)
        let imported = confusion(ref: toSleepWake(importSpelling), pred: pred, classes: ["wake", "sleep"])
        let device = confusion(ref: toSleepWake(deviceSpelling), pred: pred, classes: ["wake", "sleep"])
        XCTAssertEqual(imported.kappa, device.kappa, accuracy: 1e-9)
        XCTAssertEqual(imported.kappa, 1.0, accuracy: 1e-9, "a hypnogram scored against itself is perfect")
    }

    // MARK: - The load path

    /// The fold has to happen on the way in from `StageSegment`, not only in the predicates — this is the
    /// shape the harness actually reads out of `stagesJSON`.
    func testEpochLabelsFoldImportSpelledSegments() {
        let start = 1_700_000_000
        let imported = [
            StageSegment(start: start, end: start + 1800, stage: "awake"),
            StageSegment(start: start + 1800, end: start + 3600, stage: "light"),
            StageSegment(start: start + 3600, end: start + 5400, stage: "rem"),
        ]
        let device = imported.map {
            StageSegment(start: $0.start, end: $0.end, stage: $0.stage == "awake" ? "wake" : $0.stage)
        }
        let li = epochLabels(imported, start: start, end: start + 5400)
        let ld = epochLabels(device, start: start, end: start + 5400)
        XCTAssertEqual(li, ld)
        XCTAssertFalse(li.contains("awake"), "expansion must emit one spelling per class")
        XCTAssertEqual(wakeMinutes(li), 30.0, accuracy: 1e-9)
        XCTAssertEqual(firstRemLatencyMinutes(li)!, 30.0, accuracy: 1e-9)
    }

    /// A JSON round-trip through the exact `[{start,end,stage}]` shape an import writes, pinning that the
    /// decode path the harness uses carries the alias all the way to a scored metric.
    func testImportSpelledStagesJSONDecodesToTheSameMetrics() throws {
        let start = 1_700_000_000
        let json = """
        [{"start":\(start),"end":\(start + 1800),"stage":"awake"},
         {"start":\(start + 1800),"end":\(start + 5400),"stage":"light"}]
        """
        let segs = try JSONDecoder().decode([StageSegment].self, from: Data(json.utf8))
        XCTAssertEqual(segs.first?.stage, "awake", "the decoder itself must not silently rewrite the label")
        let labels = epochLabels(segs, start: start, end: start + 5400)
        XCTAssertEqual(wakeMinutes(labels), 30.0, accuracy: 1e-9)
        XCTAssertEqual(sleepMinutes(labels), 60.0, accuracy: 1e-9)
    }
}
