import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The Lift Log's training metrics. Pure arithmetic, so every figure the user is shown can be
/// checked here against a number worked out by hand.
final class LiftMetricsTests: XCTestCase {

    private var ord = 0

    /// A working set. Defaults chosen so a test only states what it is actually about.
    private func set(_ exercise: String = "Bench press",
                     weight: Double? = 100, reps: Int? = 5, rpe: Double? = nil,
                     warmup: Bool = false,
                     start: Int? = nil, end: Int? = nil, rest: Int? = nil,
                     primary: LiftMuscle? = .chest,
                     secondary: [LiftMuscle] = []) -> LiftSetRow {
        ord += 1
        return LiftSetRow(id: UUID().uuidString, deviceId: "dev", sessionId: "s",
                          ord: ord, exercise: exercise,
                          primaryMuscle: primary, secondaryMuscles: secondary,
                          setIndex: ord, weightKg: weight, reps: reps, rpe: rpe,
                          isWarmup: warmup, startTs: start, endTs: end, restSec: rest, note: nil)
    }

    // MARK: - Volume load

    func testVolumeIsWeightTimesRepsSummed() {
        let v = LiftMetrics.volumeLoadKg([set(weight: 100, reps: 5), set(weight: 80, reps: 10)])
        XCTAssertEqual(v!, 100 * 5 + 80 * 10, accuracy: 0.001)   // 1300
    }

    func testWarmUpsAreExcludedFromVolume() {
        let v = LiftMetrics.volumeLoadKg([set(weight: 100, reps: 5),
                                          set(weight: 40, reps: 10, warmup: true)])
        XCTAssertEqual(v!, 500, accuracy: 0.001,
                       "the literature counts working sets; a warm-up would flatter every session")
    }

    func testASetMissingWeightOrRepsContributesNothingRatherThanAGuess() {
        XCTAssertNil(LiftMetrics.volumeLoadKg([set(weight: nil, reps: 5)]))
        XCTAssertNil(LiftMetrics.volumeLoadKg([set(weight: 100, reps: nil)]))
        XCTAssertNil(LiftMetrics.volumeLoadKg([]))
    }

    func testBodyweightWorkLoggedWithNoWeightIsNotCountedAsVolume() {
        // Pull-ups logged as reps only: real training, but no tonnage figure is honest for it.
        XCTAssertNil(LiftMetrics.volumeLoadKg([set("Pull-up", weight: nil, reps: 12)]))
    }

    // MARK: - Session load (Foster sRPE-TL)

    func testSessionLoadIsRpeTimesMinutes() {
        XCTAssertEqual(LiftMetrics.sessionLoad(sessionRpe: 7, durationSec: 3600)!, 420, accuracy: 0.001)
        XCTAssertEqual(LiftMetrics.sessionLoad(sessionRpe: 8, durationSec: 1800)!, 240, accuracy: 0.001)
    }

    func testAnUnratedSessionHasNoLoadRatherThanZero() {
        XCTAssertNil(LiftMetrics.sessionLoad(sessionRpe: nil, durationSec: 3600),
                     "a skipped rating must never read as an effortless session")
        XCTAssertNil(LiftMetrics.sessionLoad(sessionRpe: 7, durationSec: 0))
    }

    // MARK: - Work versus rest

    func testWorkAndRestAreSummedFromTheTaps() {
        let wr = LiftMetrics.workRest([
            set(start: 100, end: 140, rest: 120),      // 40s work, 120s rest
            set(start: 260, end: 290, rest: 90),       // 30s work, 90s rest
        ])
        XCTAssertEqual(wr.workSec, 70)
        XCTAssertEqual(wr.restSec, 210)
        XCTAssertEqual(wr.restToWorkRatio!, 3.0, accuracy: 0.001)
    }

    func testWarmUpTimeCountsAsWorkEvenThoughItIsNotVolume() {
        let wr = LiftMetrics.workRest([set(warmup: true, start: 0, end: 60, rest: 30)])
        XCTAssertEqual(wr.workSec, 60, "a warm-up is still time under load")
    }

    func testNoWorkMeansNoRatioRatherThanADivideByZero() {
        XCTAssertNil(LiftMetrics.workRest([]).restToWorkRatio)
        XCTAssertNil(LiftMetrics.workRest([set(start: nil, end: nil, rest: 90)]).restToWorkRatio)
    }

    // MARK: - Estimated 1RM (Epley)

    func testEpleyMatchesTheFormula() {
        // 100 × (1 + 5/30) = 116.67
        XCTAssertEqual(LiftMetrics.estimatedOneRepMaxKg(weightKg: 100, reps: 5)!, 116.6667, accuracy: 0.001)
    }

    func testASingleReturnsTheWeightItself() {
        XCTAssertEqual(LiftMetrics.estimatedOneRepMaxKg(weightKg: 140, reps: 1)!, 140, accuracy: 0.001,
                       "the formula's +3.3% at one rep is an artefact of the fit, not a heavier single")
    }

    func testHighRepSetsGetNoEstimate() {
        XCTAssertNil(LiftMetrics.estimatedOneRepMaxKg(weightKg: 60, reps: 20),
                     "a 20-rep set describes endurance, not a maximum")
        XCTAssertNotNil(LiftMetrics.estimatedOneRepMaxKg(weightKg: 60, reps: 12), "12 is the ceiling")
    }

    func testNoEstimateWithoutBothNumbers() {
        XCTAssertNil(LiftMetrics.estimatedOneRepMaxKg(weightKg: nil, reps: 5))
        XCTAssertNil(LiftMetrics.estimatedOneRepMaxKg(weightKg: 100, reps: nil))
        XCTAssertNil(LiftMetrics.estimatedOneRepMaxKg(weightKg: 0, reps: 5))
    }

    // MARK: - Per exercise

    func testExercisesComeBackInTheOrderTheyWerePerformed() {
        let s = [set("Squat"), set("Bench press"), set("Squat")]
        XCTAssertEqual(LiftMetrics.perExercise(s).map(\.exercise), ["Squat", "Bench press"],
                       "a session reads back in the order it happened, not alphabetically")
    }

    func testBestSetIsRankedByEstimatedOneRepMaxNotRawWeight() {
        // 100×5 → 116.7 ; 90×10 → 120.0. The lighter set is the better one.
        let summaries = LiftMetrics.perExercise([set(weight: 100, reps: 5), set(weight: 90, reps: 10)])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].bestWeightKg!, 90, accuracy: 0.001)
        XCTAssertEqual(summaries[0].bestReps, 10)
        XCTAssertEqual(summaries[0].bestEstimatedOneRepMaxKg!, 120, accuracy: 0.001)
    }

    func testBestSetFallsBackToHeaviestWhenNoSetSupportsAnEstimate() {
        let summaries = LiftMetrics.perExercise([set(weight: 60, reps: 20), set(weight: 70, reps: 25)])
        XCTAssertEqual(summaries[0].bestWeightKg!, 70, accuracy: 0.001)
        XCTAssertNil(summaries[0].bestEstimatedOneRepMaxKg, "still no 1RM claim from a 25-rep set")
    }

    func testWorkingAndWarmUpSetsAreCountedSeparately() {
        let summaries = LiftMetrics.perExercise([
            set(warmup: true), set(warmup: true), set(), set(), set(),
        ])
        XCTAssertEqual(summaries[0].workingSets, 3)
        XCTAssertEqual(summaries[0].warmupSets, 2)
    }

    // MARK: - RPE profile

    func testRpeProfileAveragesOnlyRatedWorkingSets() {
        let p = LiftMetrics.rpeProfile([set(rpe: 7), set(rpe: 9), set(rpe: nil)])
        XCTAssertEqual(p.mean!, 8.0, accuracy: 0.001)
        XCTAssertEqual(p.ratedSets, 2)
        XCTAssertEqual(p.unratedSets, 1, "an unrated set is surfaced, so a thin mean is visibly thin")
    }

    func testHardSetsAreCountedAtOrAboveTheThreshold() {
        let p = LiftMetrics.rpeProfile([set(rpe: 7.5), set(rpe: 8), set(rpe: 9.5)])
        XCTAssertEqual(p.setsAtOrAboveThreshold, 2, "at the threshold counts, not just above it")
    }

    func testAWarmUpNeverEntersTheRpeProfile() {
        let p = LiftMetrics.rpeProfile([set(rpe: 3, warmup: true), set(rpe: 9)])
        XCTAssertEqual(p.mean!, 9.0, accuracy: 0.001)
        XCTAssertEqual(p.ratedSets, 1)
    }

    func testNothingRatedMeansNoMean() {
        XCTAssertNil(LiftMetrics.rpeProfile([set(rpe: nil), set(rpe: nil)]).mean)
    }

    // MARK: - Sets per muscle

    func testDirectSetsCountOnceAndIndirectSetsCountHalf() {
        let s = [set(primary: .chest, secondary: [.triceps, .frontDelts])]
        let c = LiftMetrics.muscleCounts(s)
        XCTAssertEqual(c.fractional[.chest]!, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.fractional[.triceps]!, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.fractional[.frontDelts]!, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.direct[.chest], 1)
        XCTAssertEqual(c.indirect[.triceps], 1)
    }

    func testTheCreditsMatchThePublishedMethod() {
        // Pinned deliberately: these constants and the reference doses were derived under the SAME
        // operationalisation, so changing one without the other silently invalidates the comparison.
        XCTAssertEqual(LiftMuscle.directSetCredit, 1.0)
        XCTAssertEqual(LiftMuscle.indirectSetCredit, 0.5)
    }

    func testAMuscleIsNeverCreditedTwiceForOneSet() {
        // A malformed row listing the primary among its secondaries must not double-count.
        let s = [set(primary: .chest, secondary: [.chest, .triceps])]
        let c = LiftMetrics.muscleCounts(s)
        XCTAssertEqual(c.fractional[.chest]!, 1.0, accuracy: 0.001)
        XCTAssertNil(c.indirect[.chest])
    }

    func testWarmUpsDoNotCountTowardAnyMuscle() {
        let c = LiftMetrics.muscleCounts([set(warmup: true, primary: .chest, secondary: [.triceps])])
        XCTAssertTrue(c.fractional.isEmpty)
    }

    func testSetCountsAreNotFilteredByRpe() {
        // Load-bearing: the reference doses come from UNFILTERED working-set counts. Filtering to
        // "hard" sets would compare a smaller number against a scale built from a larger one.
        let c = LiftMetrics.muscleCounts([set(rpe: 5), set(rpe: nil), set(rpe: 10)])
        XCTAssertEqual(c.fractional[.chest]!, 3.0, accuracy: 0.001,
                       "an easy set and an unrated set still count toward the dose")
    }

    func testAnUnclassifiedExerciseClaimsNoMuscle() {
        let s = [set(primary: nil, secondary: [])]
        XCTAssertTrue(LiftMetrics.muscleCounts(s).fractional.isEmpty)
        XCTAssertNotNil(LiftMetrics.volumeLoadKg(s), "but it still counts toward volume")
    }

    // MARK: - The reference band

    func testTheBandIsAFractionOfTheMinimumEffectiveDoseAndClamps() {
        XCTAssertEqual(LiftMetrics.ReferenceDose.fractionOfHypertrophyMinimum(2), 0.5, accuracy: 0.001)
        XCTAssertEqual(LiftMetrics.ReferenceDose.fractionOfHypertrophyMinimum(4), 1.0, accuracy: 0.001)
        XCTAssertEqual(LiftMetrics.ReferenceDose.fractionOfHypertrophyMinimum(20), 1.0, accuracy: 0.001,
                       "9 sets is not '225% complete' — past the minimum the evidence just thins out")
        XCTAssertEqual(LiftMetrics.ReferenceDose.fractionOfHypertrophyMinimum(0), 0.0, accuracy: 0.001)
    }

    func testTheReferenceDosesAreTheOnesTheCreditsWereDerivedUnder() {
        XCTAssertEqual(LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek, 4.0)
        XCTAssertEqual(LiftMetrics.ReferenceDose.strengthMinimumSetsPerWeek, 1.0)
        XCTAssertEqual(LiftMetrics.ReferenceDose.strengthPlateauSetsPerWeek, 4.0)
    }
}
