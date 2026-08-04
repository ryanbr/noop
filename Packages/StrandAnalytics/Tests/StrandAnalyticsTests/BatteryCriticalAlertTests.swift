import XCTest
@testable import StrandAnalytics

/// The escalation alerts: the CRITICAL SoC crossing and the BEDTIME night-guard, plus the ~10% cutoff
/// model they both rest on.
///
/// The fixture below is a REAL measured discharge from a WHOOP 5.0 running R22 deep-data + high-rate
/// IMU capture — the run that lost the user a night of biometrics. Times are PDT; the strap's last HR
/// sample of the session landed at 13:27, i.e. ~27 min after the final 10.9% reading and with no
/// reading below 10.9% ever banked. That 27 min is the ground truth the cutoff model is scored against.
final class BatteryCriticalAlertTests: XCTestCase {

    // MARK: - The real discharge fixture

    /// Arbitrary epoch anchor; only deltas matter to the fit.
    private static let base = 1_700_000_000
    /// Seconds after `base` for 13:27, when the strap actually went dark (27 min past the 10.9% read).
    private static let deathOffset = 6420

    /// The ten real readings, `(seconds after 11:40, SoC%)`.
    private static let realTail: [(ts: Int, soc: Double)] = [
        (0,    13.1),  // 11:40
        (120,  12.9),  // 11:42
        (660,  12.6),  // 11:51
        (1020, 12.4),  // 11:57
        (1620, 12.1),  // 12:07
        (2160, 11.9),  // 12:16
        (2760, 11.6),  // 12:26
        (3060, 11.4),  // 12:31
        (4080, 11.1),  // 12:48
        (4800, 10.9),  // 13:00
    ].map { (base + $0.0, $0.1) }

    /// The tail as the estimator really saw it: `LiveState` seeds the SoC buffer from the persisted
    /// battery table on connect (#7) and caps it at 400 readings (~53 h at the strap's ~8 min cadence),
    /// so the fit window in production spans the whole discharge from the last near-full charge — NOT
    /// just the 80 minutes of tail above. Reconstructed here at the measured 1.65 %/h from 95% down to
    /// the 13.1% the tail opens on, ~8 min apart, which is what makes `source == .measured` reachable.
    private static func realFullDischarge() -> [(ts: Int, soc: Double)] {
        let rate = 1.65
        let leadSeconds = Int((95.0 - 13.1) / rate * 3600)  // ~49.6 h
        var out: [(ts: Int, soc: Double)] = []
        for elapsed in stride(from: 0, to: leadSeconds, by: 480) {
            out.append((base - leadSeconds + elapsed, 95.0 - rate * Double(elapsed) / 3600.0))
        }
        return out + realTail
    }

    // MARK: - A3 / A4: what the estimator actually says about this run

    func testRealDischargeFitsMeasuredSlopeAtRoughly1Point65PctPerHour() {
        let e = BatteryEstimator.estimate(samples: Self.realFullDischarge(),
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)
        let est = try! XCTUnwrap(e)
        XCTAssertEqual(est.source, .measured, "the seeded full-discharge buffer must beat the rated fallback")
        XCTAssertEqual(est.currentSoc, 10.9, accuracy: 0.001)
        // Recovered slope = currentSoc / remainingHours.
        XCTAssertEqual(est.currentSoc / est.remainingHours, 1.65, accuracy: 0.02)
    }

    /// A4, the headline number: `estimate` divides the FULL SoC by the rate, so it reports time-to-0%.
    /// At 10.9% and 1.65 %/h that is ~6.6 h of runway — but the strap died 27 min later. ~6 h of the
    /// estimate is charge the hardware never actually spends.
    func testRawEstimateOverstatesRunwayByTheWholeCutoffBand() {
        let est = try! XCTUnwrap(BatteryEstimator.estimate(samples: Self.realFullDischarge(),
                                                           ratedHours: BatteryEstimator.ratedLifeHoursWhoop5))
        XCTAssertEqual(est.remainingHours, 6.6, accuracy: 0.15, "time-to-0%, not time-to-death")
        let usable = BatteryEstimator.usableRemainingHours(est)
        let overstatementHours = est.remainingHours - usable
        XCTAssertEqual(overstatementHours, 6.06, accuracy: 0.15, "cutoff / rate = 10 / 1.65")
    }

    /// The cutoff model scored against ground truth: the strap went dark 27 min after the 10.9% read.
    func testCutoffAwareRunwayMatchesTheObservedTimeOfDeath() {
        let est = try! XCTUnwrap(BatteryEstimator.estimate(samples: Self.realFullDischarge(),
                                                           ratedHours: BatteryEstimator.ratedLifeHoursWhoop5))
        let usableMinutes = BatteryEstimator.usableRemainingHours(est) * 60
        let observedMinutes = Double(Self.deathOffset - 4800) / 60  // 13:27 − 13:00 = 27 min
        XCTAssertEqual(observedMinutes, 27, accuracy: 0.001)
        XCTAssertEqual(usableMinutes, observedMinutes, accuracy: 10,
                       "cutoff-aware runway should land within ~10 min of the real time of death")
    }

    func testUsableRunwayIsZeroAtOrBelowTheCutoff() {
        XCTAssertEqual(BatteryEstimator.usableRemainingHours(remainingHours: 6.0, currentSoc: 10.0), 0)
        XCTAssertEqual(BatteryEstimator.usableRemainingHours(remainingHours: 5.0, currentSoc: 8.0), 0)
        XCTAssertEqual(BatteryEstimator.usableRemainingHours(remainingHours: 0, currentSoc: 50), 0)
        XCTAssertEqual(BatteryEstimator.usableRemainingHours(remainingHours: 10, currentSoc: 0), 0)
    }

    func testUsableRunwayIsUnaffectedWellAboveTheCutoff() {
        // 90% with 100 h to 0% → 100 × 80/90 = 88.9 h to the cutoff. Real but not dramatic up high.
        XCTAssertEqual(BatteryEstimator.usableRemainingHours(remainingHours: 100, currentSoc: 90),
                       88.89, accuracy: 0.01)
    }

    /// A3's latent second bug, isolated: on a WHOOP 5.0's 288 h rated fallback the predictive alert's
    /// 24 h line sits at 8.3% SoC — BELOW the ~10% cutoff, so it is unreachable. A strap on the rated
    /// path can therefore never warn before it dies. (The reference device's persisted
    /// `batteryRuntimeAlerted = true` proves it was on the `.measured` path in practice.)
    func testRatedFallbackOnWhoop5PutsThePredictiveAlertBelowTheHardwareCutoff() {
        let ratedRate = 100.0 / BatteryEstimator.ratedLifeHoursWhoop5
        let socAtAlertLine = BatteryEstimator.runtimeAlertHours * ratedRate
        XCTAssertEqual(socAtAlertLine, 8.33, accuracy: 0.01)
        XCTAssertLessThan(socAtAlertLine, BatteryEstimator.cutoffSocPct,
                          "rated-path predictive alert is unreachable before the strap dies")
    }

    /// The same trap reached the honest way: a buffer holding ONLY the 80-minute tail spans 1.33 h,
    /// short of `minSpanHours` (2.0), so the fit is rejected and the estimate falls back to rated —
    /// reporting ~31 h of life on a strap with ~30 min left, and firing nothing.
    func testShortBufferFallsBackToRatedAndThePredictiveAlertStaysSilent() {
        let est = try! XCTUnwrap(BatteryEstimator.estimate(samples: Self.realTail,
                                                           ratedHours: BatteryEstimator.ratedLifeHoursWhoop5))
        XCTAssertEqual(est.source, .rated)
        XCTAssertEqual(est.remainingHours, 31.4, accuracy: 0.2)
        XCTAssertFalse(BatteryEstimator.runtimeAlert(remainingHours: est.remainingHours,
                                                     charging: false, alerted: false).fire,
                       "31 h estimate is above the 24 h line — no predictive alert, ~30 min before death")
    }

    // MARK: - B1: the critical SoC alert

    /// The alert the incident needed: replay the real curve (SoC reaches the policy rounded, as
    /// `AppModel` passes `Int(pct.rounded())`) and exactly one critical alert must fire — at 12.4% /
    /// 11:57, which is 90 minutes of warning before the 13:27 death.
    func testRealCurveFiresExactlyOneCriticalAlertWithNinetyMinutesOfWarning() {
        var alerted = false
        var firedAt: [Int] = []
        for r in Self.realTail {
            let out = BatteryEstimator.criticalAlert(pct: Int(r.soc.rounded()),
                                                     charging: false, alerted: alerted)
            if out.fire { firedAt.append(r.ts) }
            alerted = out.newAlerted
        }
        XCTAssertEqual(firedAt.count, 1, "exactly once per discharge cycle")
        let warningMinutes = Double(Self.base + Self.deathOffset - firedAt[0]) / 60
        XCTAssertEqual(warningMinutes, 90, accuracy: 0.001)
    }

    /// The threshold is chosen against the cutoff, and the cutoff is what makes the conventional
    /// choices wrong: on this hardware a 5% critical alert can never fire, and even 10% is a coin flip
    /// (nothing below 10.9% was ever banked on the real run).
    func testConventionalCriticalThresholdsAreUnreachableOnThisHardware() {
        let lowestObserved = Self.realTail.map(\.soc).min()!
        XCTAssertEqual(lowestObserved, 10.9, accuracy: 0.001)
        for deadThreshold in [5, 8, 10] {
            XCTAssertFalse(Self.realTail.contains { Int($0.soc.rounded()) <= deadThreshold },
                           "\(deadThreshold)% is never reported before the strap dies")
        }
        // 12 is reported, and clears the 15% alert by a genuine 3 pp rather than jitter.
        XCTAssertTrue(Self.realTail.contains { Int($0.soc.rounded()) <= BatteryEstimator.criticalSocPct })
        XCTAssertEqual(BatteryEstimator.criticalSocPct, 12)
    }

    /// Latch independence — the actual bug. The critical gate is its OWN parameter (and, at the call
    /// site, its own persisted key), so a 15% alert that has already fired and latched cannot silence
    /// it. On the incident `behavior.batteryLowAlerted` was true for the whole final descent.
    func testCriticalGateIsIndependentOfAnAlreadyLatchedLowAlert() {
        // Whatever the low alert's gate is doing, a fresh critical gate at 12% fires.
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 12, charging: false, alerted: false).fire)
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 11, charging: nil, alerted: false).fire)
    }

    func testFiresAtThresholdAndArms() {
        let r = BatteryEstimator.criticalAlert(pct: 12, charging: false, alerted: false)
        XCTAssertTrue(r.fire)
        XCTAssertTrue(r.newAlerted)
    }

    func testAboveThresholdNoFire() {
        let r = BatteryEstimator.criticalAlert(pct: 13, charging: false, alerted: false)
        XCTAssertFalse(r.fire)
        XCTAssertFalse(r.newAlerted)
    }

    func testJitterInsideBandCannotRefire() {
        var alerted = BatteryEstimator.criticalAlert(pct: 12, charging: nil, alerted: false).newAlerted
        XCTAssertTrue(alerted)
        for pct in [11, 13, 12, 14, 11] {
            let r = BatteryEstimator.criticalAlert(pct: pct, charging: nil, alerted: alerted)
            XCTAssertFalse(r.fire, "re-fired at \(pct)% inside the hysteresis band")
            alerted = r.newAlerted
        }
    }

    func testRearmsOnGenuineRecoveryThenFiresNextCycle() {
        var alerted = BatteryEstimator.criticalAlert(pct: 11, charging: nil, alerted: false).newAlerted
        let recovered = BatteryEstimator.criticalAlert(pct: 25, charging: nil, alerted: alerted)
        XCTAssertFalse(recovered.fire)
        XCTAssertFalse(recovered.newAlerted, "25% is the re-arm line (inclusive)")
        alerted = recovered.newAlerted
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 12, charging: nil, alerted: alerted).fire)
    }

    func testRearmBoundaryIsInclusive() {
        XCTAssertFalse(BatteryEstimator.criticalAlert(pct: 25, charging: nil, alerted: true).newAlerted)
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 24, charging: nil, alerted: true).newAlerted)
    }

    func testConfirmedChargingSuppressesButUnknownFires() {
        XCTAssertFalse(BatteryEstimator.criticalAlert(pct: 8, charging: true, alerted: false).fire)
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 8, charging: nil, alerted: false).fire)
    }

    func testChargingSuppressionDoesNotArmGate() {
        let plugged = BatteryEstimator.criticalAlert(pct: 11, charging: true, alerted: false)
        XCTAssertFalse(plugged.newAlerted)
        XCTAssertTrue(BatteryEstimator.criticalAlert(pct: 11, charging: false,
                                                     alerted: plugged.newAlerted).fire)
    }

    // MARK: - typicalSleepHours

    func testTypicalSleepHoursIsTheMedianAndIgnoresJunkNights() {
        // A dead-strap 0.3 h night and an all-nighter must not drag the budget.
        let nights = [7.9, 8.1, 0.3, 7.6, 8.4, 7.8, 8.0, 2.0]
        let median = try! XCTUnwrap(BatteryEstimator.typicalSleepHours(nightlyHours: nights))
        XCTAssertEqual(median, 7.85, accuracy: 0.001)
    }

    func testTypicalSleepHoursColdStart() {
        XCTAssertNil(BatteryEstimator.typicalSleepHours(nightlyHours: []))
        XCTAssertNil(BatteryEstimator.typicalSleepHours(nightlyHours: [8, 8, 8]))
        XCTAssertNil(BatteryEstimator.typicalSleepHours(nightlyHours: Array(repeating: 0, count: 20)),
                     "zero-length nights are not history")
        XCTAssertNotNil(BatteryEstimator.typicalSleepHours(nightlyHours: Array(repeating: 8, count: 7)))
    }

    // MARK: - B2: the bedtime night-guard

    /// 03:30 midsleep on an 8 h night → 23:30 bedtime, computed circularly (naively it is negative).
    private let midsleep0330 = 3 * 3600 + 1800
    private let sleep8h = 8.0
    private func atClock(_ h: Int, _ m: Int = 0) -> Int { h * 3600 + m * 60 }

    func testFiresBeforeBedWhenTheStrapWontClearTheNight() {
        // 22:00, 1.5 h to a 23:30 bedtime → needs 1.5 + 8 + 1 = 10.5 h; has 5 h.
        let r = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                              typicalSleepHours: sleep8h, usableRemainingHours: 5,
                                              charging: false, alerted: false)
        XCTAssertTrue(r.fire)
        XCTAssertTrue(r.newAlerted)
        let runway = try! XCTUnwrap(r.runway)
        XCTAssertEqual(runway.hoursUntilBedtime, 1.5, accuracy: 0.001, "bedtime wrapped midnight correctly")
        XCTAssertEqual(runway.requiredHours, 10.5, accuracy: 0.001)
        XCTAssertEqual(runway.shortfallHours, 5.5, accuracy: 0.001)
    }

    func testStaysSilentWhenTheStrapClearsTheNight() {
        let r = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                              typicalSleepHours: sleep8h, usableRemainingHours: 12,
                                              charging: false, alerted: false)
        XCTAssertFalse(r.fire)
        XCTAssertEqual(try! XCTUnwrap(r.runway).shortfallHours, 0)
    }

    /// The requirement is anchored to the wait until bedtime, not a flat night: firing 3 h out demands
    /// 3 h more runtime than firing at bedtime. Same battery, same night, different answer.
    func testRequirementScalesWithTheWaitUntilBedtime() {
        let early = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(20, 30), habitualMidsleepSec: midsleep0330,
                                                  typicalSleepHours: sleep8h, usableRemainingHours: 10.5,
                                                  charging: false, alerted: false)
        XCTAssertEqual(try! XCTUnwrap(early.runway).requiredHours, 12.0, accuracy: 0.001)
        XCTAssertTrue(early.fire, "3 h out, 10.5 h of runway does not cover the wait plus the night")
        let atBed = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(23, 30), habitualMidsleepSec: midsleep0330,
                                                  typicalSleepHours: sleep8h, usableRemainingHours: 10.5,
                                                  charging: false, alerted: false)
        XCTAssertEqual(try! XCTUnwrap(atBed.runway).requiredHours, 9.0, accuracy: 0.001)
        XCTAssertFalse(atBed.fire)
    }

    func testOutsideTheWindowIsSilentAndRearms() {
        // 18:00 — 5.5 h before bed, window not open yet. A latched gate re-arms here.
        let early = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(18), habitualMidsleepSec: midsleep0330,
                                                  typicalSleepHours: sleep8h, usableRemainingHours: 0.5,
                                                  charging: false, alerted: true)
        XCTAssertFalse(early.fire)
        XCTAssertFalse(early.newAlerted)
        XCTAssertNil(early.runway)
        // 23:45 — bedtime has passed, `hoursUntilBedtime` wraps to ~23.75. Silent, and re-armed for
        // tomorrow: this is what makes the night-guard once-per-NIGHT rather than once-per-discharge.
        let late = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(23, 45), habitualMidsleepSec: midsleep0330,
                                                 typicalSleepHours: sleep8h, usableRemainingHours: 0.5,
                                                 charging: false, alerted: true)
        XCTAssertFalse(late.fire)
        XCTAssertFalse(late.newAlerted)
    }

    func testFiresOncePerNightThenAgainTheFollowingNight() {
        var alerted = false
        // Tonight's window: fires once, then holds across every later reading in the window.
        for clock in [atClock(21), atClock(21, 30), atClock(22), atClock(23)] {
            let r = BatteryEstimator.bedtimeAlert(nowSecOfDay: clock, habitualMidsleepSec: midsleep0330,
                                                  typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                  charging: false, alerted: alerted)
            XCTAssertEqual(r.fire, clock == atClock(21), "exactly one alert per night")
            alerted = r.newAlerted
        }
        XCTAssertTrue(alerted)
        // Next morning: outside the window → re-armed, WITHOUT needing a charge to do it.
        alerted = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(9), habitualMidsleepSec: midsleep0330,
                                                typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                charging: false, alerted: alerted).newAlerted
        XCTAssertFalse(alerted)
        // Tomorrow night: speaks again.
        XCTAssertTrue(BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(21), habitualMidsleepSec: midsleep0330,
                                                    typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                    charging: false, alerted: alerted).fire)
    }

    /// Cold start: no learned bedtime → no alert and no fabricated bedtime.
    func testColdStartNeverFiresAndInventsNoBedtime() {
        let noMidsleep = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: nil,
                                                       typicalSleepHours: sleep8h, usableRemainingHours: 0.1,
                                                       charging: false, alerted: false)
        XCTAssertFalse(noMidsleep.fire)
        XCTAssertNil(noMidsleep.runway)
        let noDuration = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                                       typicalSleepHours: nil, usableRemainingHours: 0.1,
                                                       charging: false, alerted: false)
        XCTAssertFalse(noDuration.fire)
        XCTAssertNil(noDuration.runway)
        // Cold start must not silently consume a latched gate either.
        XCTAssertTrue(BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: nil,
                                                    typicalSleepHours: nil, usableRemainingHours: 0.1,
                                                    charging: false, alerted: true).newAlerted)
    }

    func testNoEstimateIsSilent() {
        let r = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                              typicalSleepHours: sleep8h, usableRemainingHours: nil,
                                              charging: false, alerted: false)
        XCTAssertFalse(r.fire)
        XCTAssertNil(r.runway)
    }

    func testConfirmedChargingSuppressesButUnknownFiresAndGateSurvives() {
        let plugged = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                                    typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                    charging: true, alerted: false)
        XCTAssertFalse(plugged.fire)
        XCTAssertFalse(plugged.newAlerted, "charging suppression must not consume the gate")
        // Unplugged, still in the window → it fires.
        XCTAssertTrue(BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                                    typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                    charging: false, alerted: plugged.newAlerted).fire)
        // Unknown charge bit (the strap only reports it every ~8 min) still fires.
        XCTAssertTrue(BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                                    typicalSleepHours: sleep8h, usableRemainingHours: 2,
                                                    charging: nil, alerted: false).fire)
    }

    /// A late sleeper: 05:00 midsleep, 7 h night → 01:30 bedtime, so the window opens at 22:30 and
    /// spans midnight. Nothing here may key off a fixed clock band.
    func testLateSleeperWindowSpansMidnight() {
        let midsleep0500 = 5 * 3600
        let inWindow = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(0, 30), habitualMidsleepSec: midsleep0500,
                                                     typicalSleepHours: 7, usableRemainingHours: 1,
                                                     charging: false, alerted: false)
        XCTAssertTrue(inWindow.fire)
        XCTAssertEqual(try! XCTUnwrap(inWindow.runway).hoursUntilBedtime, 1.0, accuracy: 0.001)
        // 21:00 is still outside a 01:30 bedtime's 3 h window.
        XCTAssertFalse(BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(21), habitualMidsleepSec: midsleep0500,
                                                     typicalSleepHours: 7, usableRemainingHours: 1,
                                                     charging: false, alerted: false).fire)
    }

    /// End to end on the real fixture: at the 13.1% reading the strap has ~32 min of usable runway. If
    /// that reading had landed in the pre-bed window, the night-guard would have caught what both
    /// latched alerts missed.
    func testNightGuardCatchesTheRealIncidentRunway() {
        let est = try! XCTUnwrap(BatteryEstimator.estimate(samples: Self.realFullDischarge(),
                                                           ratedHours: BatteryEstimator.ratedLifeHoursWhoop5))
        let r = BatteryEstimator.bedtimeAlert(nowSecOfDay: atClock(22), habitualMidsleepSec: midsleep0330,
                                              typicalSleepHours: sleep8h,
                                              usableRemainingHours: BatteryEstimator.usableRemainingHours(est),
                                              charging: false, alerted: false)
        XCTAssertTrue(r.fire)
        XCTAssertEqual(try! XCTUnwrap(r.runway).shortfallHours, 9.95, accuracy: 0.15)
    }
}
