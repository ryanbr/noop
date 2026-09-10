import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the daily-steps derivation in AnalyticsEngine.analyzeDay: cumulative-counter
/// delta summation, u16 wraparound, sub-2-sample and cross-day filtering, and nil-when-no-movement.
/// No DB; pure-function test. step_motion_counter@57 is a CUMULATIVE u16 counter, so the daily total
/// is the sum of positive consecutive deltas (APPROXIMATE — @57 semantics unverified vs the app).
/// Mirrors the Android StepsAnalyticsTest vectors value-for-value.
final class StepsDailyTests: XCTestCase {

    private let profile = UserProfile()

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z = 1767355200).
    private let dayUtc = "2026-01-02"
    private let noonUtc = 1_767_355_200

    private func step(_ tsOffsetSec: Int, _ counter: Int) -> StepSample {
        StepSample(ts: noonUtc + tsOffsetSec, counter: counter)
    }

    private func stepsFor(_ samples: [StepSample]) -> Int? {
        AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: profile).daily.steps
    }

    func testSumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        let s = [step(0, 100), step(60, 150), step(120, 220)]
        XCTAssertEqual(stepsFor(s), 120)
    }

    func testHandlesU16Wraparound() {
        // 65500 -> 30 wraps: (30 - 65500) & 0xFFFF => 66 real steps (a small in-range increment, NOT a
        // huge negative); then 30 -> 90 => 60. Both deltas are < the 512 guard so both count.
        let s = [step(0, 65_500), step(60, 30), step(120, 90)]
        XCTAssertEqual(stepsFor(s), 66 + 60)
    }

    func testFewerThanTwoSamplesIsNil() {
        XCTAssertNil(stepsFor([]))
        XCTAssertNil(stepsFor([step(0, 500)]))
    }

    func testNoForwardMovementIsNil() {
        // Flat counter across the day => no positive delta => nil (not 0).
        let s = [step(0, 1_000), step(60, 1_000), step(120, 1_000)]
        XCTAssertNil(stepsFor(s))
    }

    func testDropsBigGapDeltaAsBoundary() {
        // 100 -> 1000 is a 900-tick jump (a sync-gap/disconnect boundary, not real 1 Hz steps), and
        // 1000 -> 50 wrap-corrects to 64586. Both are >= the 512 guard, so both are dropped — the day
        // has no in-range increment left, so the total is nil (not an inflated number).
        let s = [step(0, 100), step(60, 1_000), step(120, 50)]
        XCTAssertNil(stepsFor(s))
    }

    func testJumpGuardDropsGapButKeepsRealSteps() {
        // 100 -> 300 (=200 real) ; 300 -> 1200 is a 900-tick GAP (>= 512) and is dropped ; 1200 -> 1500
        // (=300 real). Only the two in-range increments count => 200 + 300 = 500, the gap doesn't inflate.
        let s = [step(0, 100), step(60, 300), step(3_600, 1_200), step(3_675, 1_500)]
        XCTAssertEqual(stepsFor(s), 500)
    }

    func testOldSummingOfRawByteOvercountsVsWrapAwareDiff() {
        // THE BUG (#132/#276/#316). A realistic ascending cumulative counter sampled at 1 Hz. The OLD
        // code summed the raw running total (here, byte @57 alone summed) — exploding the count; the NEW
        // wrap-aware diff sums only the per-record increments and yields a sane number.
        let counters = [100, 102, 102, 105, 106, 106, 109, 111, 113, 115]
        let samples = counters.enumerated().map { step($0.offset, $0.element) }
        // NEW behaviour: sum of wrap-aware deltas == last - first (all small increments, none >= 512).
        let sane = counters.last! - counters.first!  // 75
        XCTAssertEqual(stepsFor(samples), sane)
        // OLD behaviour (summing the cumulative counter itself) would be vastly larger — prove the gap.
        let oldOvercount = counters.reduce(0, +)  // 1373
        XCTAssertGreaterThan(oldOvercount, sane * 10)
    }

    func testIgnoresSamplesOutsideTheTargetDay() {
        // One sample 36h before the day (in the analytics window but a different UTC day)
        // must be excluded.
        let s = [step(-36 * 3_600, 5_000), step(0, 100), step(60, 300)]
        XCTAssertEqual(stepsFor(s), 200)  // only the in-day 100 -> 300 delta counts
    }

    func testDayStepsOverrideCountsFullCalendarDay() {
        // The night-window `steps` only sees the early part of the day; the full calendar-day
        // stream `daySteps` also carries the late-evening samples. When daySteps is supplied
        // the daily total must come from it, so late-day movement is NOT dropped (the past-day
        // undercount fix).
        let nightWindow = [step(0, 100), step(60, 300)]  // early only
        let fullDay = [
            step(0, 100), step(60, 300),     // morning: 200
            step(10 * 3_600, 700),           // evening samples only in the full-day stream
            step(11 * 3_600, 1_100),
        ]
        let total = AnalyticsEngine.analyzeDay(
            day: dayUtc, steps: nightWindow, daySteps: fullDay, profile: profile).daily.steps
        // deltas over the full day: 100->300=200, 300->700=400, 700->1100=400 => 1000 (all < 512 guard).
        XCTAssertEqual(total, 1_000)
    }

    func testDayStepsNilFallsBackToWindowSteps() {
        // No calendar-day stream supplied (pure-function callers / old tests) -> total falls
        // back to the night-window `steps` exactly as before.
        let s = [step(0, 100), step(60, 150), step(120, 220)]  // 50 + 70 = 120
        XCTAssertEqual(AnalyticsEngine.analyzeDay(day: dayUtc, steps: s, profile: profile).daily.steps,
                       120)
    }

    // MARK: - Step-scale calibration (#139)

    private func stepsFor(_ samples: [StepSample], ticksPerStep: Double) -> Int? {
        AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples,
                                   profile: UserProfile(stepTicksPerStep: ticksPerStep)).daily.steps
    }

    func testTicksPerStepTwoHalvesTheTotal() {
        // 120 raw ticks at 2.0 ticks/step => 60 steps.
        let s = [step(0, 100), step(60, 150), step(120, 220)]
        XCTAssertEqual(stepsFor(s, ticksPerStep: 2.0), 60)
    }

    func testTicksPerStepHalvingRoundsToNearest() {
        // 121 raw ticks at 2.0 => 60.5, rounded to nearest => 61.
        let s = [step(0, 100), step(60, 150), step(120, 221)]
        XCTAssertEqual(stepsFor(s, ticksPerStep: 2.0), 61)
    }

    func testTicksPerStepDefaultIsRawPassThrough() {
        // Default 1.0 (and an explicit 1.0) must leave the total untouched — no behavior
        // change until the user calibrates.
        let s = [step(0, 100), step(60, 150), step(120, 220)]
        XCTAssertEqual(stepsFor(s), 120)
        XCTAssertEqual(stepsFor(s, ticksPerStep: 1.0), 120)
    }

    func testTicksPerStepClampsAtFloor() {
        // A divisor below the 0.5 floor clamps: it can at most double the total, never
        // explode it. 120 / 0.5 = 240 even when the profile says 0.1.
        let s = [step(0, 100), step(60, 150), step(120, 220)]
        XCTAssertEqual(stepsFor(s, ticksPerStep: 0.1), 240)
    }
}
