import XCTest
@testable import StrandAnalytics

/// Tests `Calories.estimateDayEnergyFromMET` (#2242) — the whole-day energy estimate from a device's OWN
/// MET stream (the Oura ring's 0x50 record), Oura's documented method with no fitted constant. Pure
/// function; no DB. The Kotlin twin is pinned to this code by oracle (`MetCaloriesOracleTest`, the Swift
/// twin's stdout pasted verbatim); the hand-derived literals here are what stop THIS side drifting.
final class MetCaloriesTests: XCTestCase {

    private typealias M = Calories.MetSample
    private let day0 = 1_755_208_800   // 2026-08-15 00:00 Europe/Paris
    private var day1: Int { day0 + 86_400 }
    /// Revised Harris–Benedict for the default (nonbinary, 70 kg, 170 cm, 30 y) profile:
    /// 267.9775 + 11.322·70 + 394.85·1.70 − 5.0035·30.
    private let defaultBmr = 1581.6575
    /// kcal per excess-MET-minute for the default 70 kg: 0.0175 × 70.
    private let kcalPerMetMin = 1.225

    private func fullDay(_ met: Double) -> [M] { (0..<1440).map { M(ts: day0 + $0 * 60, met: met) } }

    func testEmptyIsAllZero() {
        let r = Calories.estimateDayEnergyFromMET([], profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r, Calories.MetEnergyEstimate(restingKcal: 0, activeKcal: 0,
                                                     observedSeconds: 0, coverageFraction: 0))
    }

    func testRestingDayIsBmrOverFullCoverage() {
        let r = Calories.estimateDayEnergyFromMET(fullDay(0.9), profile: UserProfile(),
                                                  dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.restingKcal, defaultBmr, accuracy: 1e-9)
        XCTAssertEqual(r.activeKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(r.observedSeconds, 86_400, accuracy: 1e-12)
        XCTAssertEqual(r.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.totalKcal, defaultBmr, accuracy: 1e-9)
    }

    func testBoutIsExcessOverThresholdAtTheMetRateForWeight() {
        // 30 min at 4.0 MET → (4 − 1.5) × 0.0175 × 70 kg × 30 — Oura's rule at the MET definition.
        var day = fullDay(0.9)
        for i in 600..<630 { day[i] = M(ts: day0 + i * 60, met: 4.0) }
        let r = Calories.estimateDayEnergyFromMET(day, profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.activeKcal, 2.5 * kcalPerMetMin * 30.0, accuracy: 1e-9)
        XCTAssertEqual(r.activeKcal, 91.875, accuracy: 1e-9)   // the oracle line
        XCTAssertEqual(r.restingKcal, defaultBmr, accuracy: 1e-9)
    }

    func testThresholdIsTheZeroOfTheActiveTerm() {
        // 1.4 is rest; 1.5 is "active" but its excess over the threshold is zero; 1.6 contributes 0.1.
        let r = Calories.estimateDayEnergyFromMET([M(ts: day0, met: 1.4), M(ts: day0 + 60, met: 1.5),
                                                   M(ts: day0 + 120, met: 1.6)],
                                                  profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.activeKcal, 0.1 * kcalPerMetMin, accuracy: 1e-9)
        XCTAssertEqual(r.observedSeconds, 180, accuracy: 1e-12)   // all three minutes covered
    }

    func testActiveScalesWithWeightOnly() {
        // Same minutes, twice the weight → twice the active term; resting follows Harris–Benedict instead.
        let bout = [M(ts: day0, met: 5.0)]
        let a = Calories.estimateDayEnergyFromMET(bout, profile: UserProfile(weightKg: 50), dayStart: day0, dayEnd: day1)
        let b = Calories.estimateDayEnergyFromMET(bout, profile: UserProfile(weightKg: 100), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(b.activeKcal, 2 * a.activeKcal, accuracy: 1e-9)
        XCTAssertEqual(a.activeKcal, 3.5 * 0.0175 * 50.0, accuracy: 1e-9)
    }

    func testCoverageIsOverTheDayWindowPassed() {
        // 60 % of a 24 h day.
        let sixty: [M] = (0..<864).map { M(ts: day0 + $0 * 60, met: 1.0) }
        let full = Calories.estimateDayEnergyFromMET(sixty, profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(full.coverageFraction, 0.6, accuracy: 1e-12)
        XCTAssertEqual(full.restingKcal, defaultBmr * 0.6, accuracy: 1e-9)
        // The same samples against a 6 h elapsed window (today, mid-morning) read as fully covered.
        let partial: [M] = (0..<360).map { M(ts: day0 + $0 * 60, met: 1.0) }
        let today = Calories.estimateDayEnergyFromMET(partial, profile: UserProfile(),
                                                      dayStart: day0, dayEnd: day0 + 6 * 3600)
        XCTAssertEqual(today.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(today.observedSeconds, 21_600, accuracy: 1e-12)
    }

    func testMissingMinutesAreUnknownNotRest() {
        // A one-hour hole reduces resting energy by exactly one hour's BMR and adds no activity.
        var day = fullDay(1.0)
        day.removeSubrange(300..<360)
        let r = Calories.estimateDayEnergyFromMET(day, profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.restingKcal, defaultBmr * (1380.0 / 1440.0), accuracy: 1e-9)
        XCTAssertEqual(r.activeKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(r.coverageFraction, 1380.0 / 1440.0, accuracy: 1e-12)
    }

    func testSecPerSampleScalesBothTerms() {
        // 720 × 120 s at rest plus one 120 s sample at 3.0 MET = a full day, 2 MET·min × 2 minutes active.
        var twoMin: [M] = (0..<720).map { M(ts: day0 + $0 * 120, met: 1.0, secPerSample: 120) }
        twoMin[300] = M(ts: day0 + 300 * 120, met: 3.0, secPerSample: 120)
        let r = Calories.estimateDayEnergyFromMET(twoMin, profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.observedSeconds, 86_400, accuracy: 1e-12)
        XCTAssertEqual(r.activeKcal, 1.5 * kcalPerMetMin * 2.0, accuracy: 1e-9)
    }

    func testDuplicateTsCountsOnceAndLowerMetWins() {
        let r = Calories.estimateDayEnergyFromMET([M(ts: day0, met: 5.0), M(ts: day0, met: 2.0)],
                                                  profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.observedSeconds, 60, accuracy: 1e-12)
        XCTAssertEqual(r.activeKcal, 0.5 * kcalPerMetMin, accuracy: 1e-9)
    }

    /// 2026-09-17, first hardware day: 157 of 1,035 stored rows were the same minute re-served under a
    /// fresh per-session `0x13` anchor, 3–4 s off the first copy, and the day read +8 %. A sample that
    /// starts inside the interval already counted is that minute again: skipped, the first copy wins.
    func testOverlappingReserveIsTheSameMinuteAndCountsOnce() {
        let r = Calories.estimateDayEnergyFromMET(
            [M(ts: day0, met: 4.0), M(ts: day0 + 3, met: 4.0), M(ts: day0 + 60, met: 0.9),
             M(ts: day0 + 64, met: 9.0), M(ts: day0 + 120, met: 4.0)],
            profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.observedSeconds, 180)                       // three minutes, not five
        XCTAssertEqual(r.activeKcal, 2 * 2.5 * kcalPerMetMin, accuracy: 1e-9)   // the 9.0 twin is dropped
    }

    /// The first-starting copy wins even when the twin starts a second earlier than a LATER minute's own
    /// sample would — overlap is judged against the interval just counted, so a 57-s-late twin of minute
    /// 0 loses to minute 0, and minute 2 (which does not overlap minute 0) is kept.
    func testOverlapIsAgainstTheCountedIntervalNotTheGrid() {
        let r = Calories.estimateDayEnergyFromMET(
            [M(ts: day0, met: 1.0), M(ts: day0 + 57, met: 5.0), M(ts: day0 + 120, met: 1.0)],
            profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.observedSeconds, 120)
        XCTAssertEqual(r.activeKcal, 0, accuracy: 1e-12)
    }

    func testWindowIsHalfOpenAndOutsideSamplesAreIgnored() {
        let r = Calories.estimateDayEnergyFromMET(
            [M(ts: day0 - 60, met: 9.0), M(ts: day0, met: 2.0), M(ts: day1 - 60, met: 2.0), M(ts: day1, met: 9.0)],
            profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(r.observedSeconds, 120, accuracy: 1e-12)
        XCTAssertEqual(r.activeKcal, 2 * 0.5 * kcalPerMetMin, accuracy: 1e-9)
    }

    func testProfileFallbacksMatchTheHrPath() {
        // A zeroed profile falls back to 70 kg / 170 cm / 30 y exactly as `estimateDayEnergy` does.
        let zeroed = UserProfile(weightKg: 0, heightCm: 0, age: 0, sex: "male")
        let r = Calories.estimateDayEnergyFromMET(fullDay(1.0), profile: zeroed, dayStart: day0, dayEnd: day1)
        // Explicitly typed, term by term: the untyped literal chain made the CI toolchain's type-checker
        // give up ("unable to type-check this expression in reasonable time").
        let weightTerm: Double = 13.397 * 70.0
        let heightTerm: Double = 479.9 * 1.7
        let ageTerm: Double = 5.677 * 30.0
        let maleBmr: Double = 88.362 + weightTerm + heightTerm - ageTerm
        XCTAssertEqual(r.restingKcal, maleBmr, accuracy: 1e-9)
    }

    func testBadEpochRowsAreDroppedAndZeroLengthDayIsEmpty() {
        let bad = Calories.estimateDayEnergyFromMET(
            [M(ts: day0, met: 4.0, secPerSample: 0), M(ts: day0 + 60, met: 4.0, secPerSample: -60),
             M(ts: day0 + 120, met: 4.0)],
            profile: UserProfile(), dayStart: day0, dayEnd: day1)
        XCTAssertEqual(bad.observedSeconds, 60, accuracy: 1e-12)
        let zero = Calories.estimateDayEnergyFromMET(fullDay(2.0), profile: UserProfile(),
                                                     dayStart: day0, dayEnd: day0)
        XCTAssertEqual(zero.coverageFraction, 0, accuracy: 1e-12)
        XCTAssertEqual(zero.totalKcal, 0, accuracy: 1e-12)
    }

    func testCoverageClampsAtTheDaySpan() {
        let r = Calories.estimateDayEnergyFromMET((0..<1500).map { M(ts: day0 + $0 * 60, met: 1.0) },
                                                  profile: UserProfile(),
                                                  dayStart: day0, dayEnd: day0 + 1500 * 60 - 3600)
        XCTAssertEqual(r.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.observedSeconds, 86_400, accuracy: 1e-12)
    }
}
