import XCTest
@testable import StrandAnalytics

/// #979 — both spellings of the wake stage occur in stored hypnograms, and five segment comparisons
/// only recognised one of them.
///
/// The damaging shape is `stage != "wake"`, used to mean "asleep": an imported `"awake"` segment fell
/// through it and was counted as SLEEP, inflating the efficiency figure. The mirror shape,
/// `stage == "wake"`, under-counted wake time and made the #987 wake refinement skip those segments.
///
/// Twin of the Kotlin `SleepStageVocabularyTest`; same cases in the same order.
final class SleepStageVocabularyTests: XCTestCase {

    /// Both spellings are wake. This is the whole point.
    func testBothSpellingsAreWake() {
        XCTAssertTrue(SleepStageVocabulary.isWake("wake"))
        XCTAssertTrue(SleepStageVocabulary.isWake("awake"))
    }

    /// Sleep stages are not wake — the predicate must not swallow the rest of the vocabulary.
    func testSleepStagesAreNotWake() {
        for s in ["deep", "light", "rem"] {
            XCTAssertFalse(SleepStageVocabulary.isWake(s), "\(s) must not read as wake")
        }
    }

    /// Imported JSON is not guaranteed tidy; casing and padding must not decide a sleep score.
    func testCasingAndWhitespaceAreFolded() {
        XCTAssertTrue(SleepStageVocabulary.isWake("Awake"))
        XCTAssertTrue(SleepStageVocabulary.isWake("  WAKE "))
        XCTAssertTrue(SleepStageVocabulary.isWake("\tAwAkE"))
        XCTAssertTrue(SleepStageVocabulary.isWake("\nwake\n"))
        XCTAssertTrue(SleepStageVocabulary.isWake("\rawake\r"))
    }

    /// An absent or unknown stage is NOT wake, which preserves the existing behaviour of the callers
    /// that treat "anything that is not wake" as asleep. Widening that would be a separate change.
    func testUnknownAndEmptyAreNotWake() {
        XCTAssertFalse(SleepStageVocabulary.isWake(""))
        XCTAssertFalse(SleepStageVocabulary.isWake("   "))
        XCTAssertFalse(SleepStageVocabulary.isWake("restless"))
    }

    /// The regression itself, in the shape the importers use: a night of `awake` + `deep` must count
    /// only the `deep` span as asleep. Before the fix the `awake` span fell through `!= "wake"` and was
    /// added to the asleep total, so this asserted 2x the true value.
    func testAwakeSegmentIsNotCountedAsAsleep() {
        let segs: [(stage: String, seconds: Int)] = [("awake", 1800), ("deep", 1800)]
        let asleep = segs.filter { !SleepStageVocabulary.isWake($0.stage) }.reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(asleep, 1800)
    }

    /// And the mirror shape: wake time must include the `awake` span, which `== "wake"` dropped.
    func testWakeTotalIncludesBothSpellings() {
        let segs: [(stage: String, seconds: Int)] = [("wake", 600), ("awake", 300), ("rem", 1200)]
        let wake = segs.filter { SleepStageVocabulary.isWake($0.stage) }.reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(wake, 900)
    }

    /// `canonicalStage` folds BOTH wake spellings onto the segment vocabulary's `"wake"`, and only
    /// tidies (trims, lowercases) everything else. Swift-only cases below this line: the Kotlin twin of
    /// this rule is the UI's `canonicalStage`, which folds the same alias set toward `"awake"` because
    /// its consumers key the minutes/colour vocabulary — same rule, that vocabulary's spelling.
    func testCanonicalStageFoldsWakeSpellings() {
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("wake"), "wake")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("awake"), "wake")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("  AWAKE\t"), "wake")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("Wake"), "wake")
    }

    /// Non-wake labels are tidied, not renamed — the canonicaliser must not invent vocabulary.
    func testCanonicalStagePassesOtherLabelsThroughTidied() {
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("deep"), "deep")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("  Light "), "light")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("REM"), "rem")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage("restless"), "restless")
        XCTAssertEqual(SleepStageVocabulary.canonicalStage(""), "")
    }

    /// The two APIs must never disagree about what wake is: for every label, folding to "wake" and
    /// satisfying the predicate are the same fact.
    func testCanonicalStageAgreesWithIsWake() {
        for label in ["wake", "awake", "Awake", " WAKE ", "deep", "light", "rem", "restless", ""] {
            XCTAssertEqual(SleepStageVocabulary.canonicalStage(label) == "wake",
                           SleepStageVocabulary.isWake(label),
                           "canonicalStage and isWake disagree on \(label)")
        }
    }

    /// INTEGRATION, not the predicate. The tests above pass whether or not the five call sites were
    /// actually changed — they exercise the rule, not its users. This one exercises a real caller, so
    /// it is the test that fails if a site is reverted.
    ///
    /// The same night as `SleepStagerTests.testHypnogramMetricsAASM`, with the WASO segment spelled
    /// `awake`. `tst` is computed from a POSITIVE list (`light || deep || rem`) so it is immune either
    /// way at 1080 s; WASO and the disturbance count are not, and read 0 before the fix.
    func testWasoAndDisturbancesCountAnAwakeSegment() {
        let stages = [
            StageSegment(start: 0, end: 60, stage: "wake"),      // pre-onset, clipped out of WASO
            StageSegment(start: 60, end: 600, stage: "light"),
            StageSegment(start: 600, end: 900, stage: "deep"),
            StageSegment(start: 900, end: 960, stage: "awake"),  // the other spelling — 60 s of WASO
            StageSegment(start: 960, end: 1200, stage: "rem"),
        ]
        let session = SleepSession(start: 0, end: 1200, efficiency: 0.95,
                                   stages: stages, restingHR: 50, avgHRV: 60)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.tstS, 1080, accuracy: 1e-9, "sleep total must be unaffected either way")
        XCTAssertEqual(m.wasoS, 60, accuracy: 1e-9, "an awake segment is wake after sleep onset")
        XCTAssertEqual(m.disturbances, 1, "and counts as one disturbance")
    }
}
