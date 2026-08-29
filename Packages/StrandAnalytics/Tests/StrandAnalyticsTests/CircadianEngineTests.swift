import XCTest
@testable import StrandAnalytics

final class CircadianEngineTests: XCTestCase {

    /// Build a 24-point hourly profile from a known cosine: mesor + amp·cos(2π(h − acro)/24).
    private func profile(mesor: Double, amp: Double, acrophase: Double) -> [CircadianEngine.ActivityBin] {
        (0..<24).map { h in
            let v = mesor + amp * cos(2.0 * Double.pi * (Double(h) - acrophase) / 24.0)
            return CircadianEngine.ActivityBin(hour: Double(h), activity: v)
        }
    }

    // MARK: - Cosinor recovers a known acrophase + amplitude (pure-math determinism)

    func testCosinorRecoversInjectedParameters() {
        let fit = CircadianEngine.cosinor(profile(mesor: 50, amp: 30, acrophase: 15))!
        XCTAssertEqual(fit.mesor, 50, accuracy: 1e-6)
        XCTAssertEqual(fit.amplitude, 30, accuracy: 1e-6)
        XCTAssertEqual(fit.acrophaseHours, 15, accuracy: 1e-6)
    }

    func testCosinorAcrophaseWrapsIntoDay() {
        let fit = CircadianEngine.cosinor(profile(mesor: 10, amp: 5, acrophase: 23))!
        XCTAssertEqual(fit.acrophaseHours, 23, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(fit.acrophaseHours, 0)
        XCTAssertLessThan(fit.acrophaseHours, 24)
    }

    func testCosinorRejectsTooFewPoints() {
        XCTAssertNil(CircadianEngine.cosinor([.init(hour: 1, activity: 1), .init(hour: 2, activity: 2)]))
    }

    // MARK: - Phase estimate confidence

    func testStrongRhythmEnoughDaysIsSolid() {
        let bins = profile(mesor: 50, amp: 30, acrophase: 15)
        let est = CircadianEngine.estimatePhase(bins: bins, daysObserved: 20, habitualWakeHour: 7)!
        XCTAssertEqual(est.confidence, .solid)
        // Acrophase 15:00 → derived temp-min ≈ 15 − 12 = 03:00.
        XCTAssertEqual(est.tempMinHour, 3, accuracy: 1e-6)
    }

    func testThinDataIsWideOrUnreadable() {
        let bins = profile(mesor: 50, amp: 30, acrophase: 15)
        let est = CircadianEngine.estimatePhase(bins: bins, daysObserved: 4, habitualWakeHour: 7)!
        XCTAssertEqual(est.confidence, .unreadable)
        XCTAssertTrue(est.note.lowercased().contains("hard to read"))
    }

    func testArrhythmicProfileIsUnreadable() {
        // Near-flat activity (amplitude ≈ 0) → arrhythmic → unreadable even with many days.
        let bins = profile(mesor: 50, amp: 0.5, acrophase: 15)
        let est = CircadianEngine.estimatePhase(bins: bins, daysObserved: 30, habitualWakeHour: 7)!
        XCTAssertEqual(est.confidence, .unreadable)
    }

    func testObservedTempMinOverridesDerived() {
        let bins = profile(mesor: 50, amp: 30, acrophase: 15)
        let est = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: 20, habitualWakeHour: 7, observedTempMinHour: 4.5)!
        XCTAssertEqual(est.tempMinHour, 4.5, accuracy: 1e-9)
    }

    // MARK: - Jet-lag / shift planner: direction + light rule + no supplements

    func testEastwardAdvancePlanUsesMorningLight() {
        // +3 h required = advance the clock earlier (eastward).
        let plan = CircadianEngine.planShift(shiftHours: 3, currentSleepHour: 23, currentWakeHour: 7)
        XCTAssertEqual(plan.direction, .advance)
        XCTAssertEqual(plan.estimatedDays, 3)            // 3 h at ≤1 h/day
        XCTAssertEqual(plan.days.count, 3)
        // Final day: window pulled 3 h earlier → sleep 20:00, wake 04:00.
        let last = plan.days.last!
        XCTAssertEqual(last.targetSleepHour, 20, accuracy: 1e-9)
        XCTAssertEqual(last.targetWakeHour, 4, accuracy: 1e-9)
        // Morning light begins at the new wake.
        XCTAssertEqual(last.brightLightStartHour, 4, accuracy: 1e-9)
        XCTAssertTrue(last.guidance.contains("bright light early"))
    }

    func testWestwardDelayPlanUsesEveningLight() {
        // −2 h required = delay the clock later (westward).
        let plan = CircadianEngine.planShift(shiftHours: -2, currentSleepHour: 23, currentWakeHour: 7)
        XCTAssertEqual(plan.direction, .delay)
        XCTAssertEqual(plan.estimatedDays, 2)
        let last = plan.days.last!
        // Window pushed 2 h later → sleep 01:00, wake 09:00.
        XCTAssertEqual(last.targetSleepHour, 1, accuracy: 1e-9)
        XCTAssertEqual(last.targetWakeHour, 9, accuracy: 1e-9)
        XCTAssertTrue(last.guidance.contains("bright light in the evening"))
    }

    func testNoShiftNeededReturnsNonePlan() {
        let plan = CircadianEngine.planShift(shiftHours: 0.2, currentSleepHour: 23, currentWakeHour: 7)
        XCTAssertEqual(plan.direction, .none)
        XCTAssertTrue(plan.days.isEmpty)
    }

    func testPlanNeverMentionsSupplements() {
        let banned = ["melatonin", "supplement", "pill", "drug", "caffeine pill", "medication"]
        for shift in [3.0, -3.0, 6.0, -1.0] {
            let plan = CircadianEngine.planShift(shiftHours: shift, currentSleepHour: 23, currentWakeHour: 7)
            var text = plan.note.lowercased()
            for d in plan.days { text += " " + d.guidance.lowercased() }
            for b in banned { XCTAssertFalse(text.contains(b), "plan mentioned banned \(b)") }
        }
    }

    func testSteppedAtOneHourPerDay() {
        // 6 h shift → 6 stepped days.
        let plan = CircadianEngine.planShift(shiftHours: 6, currentSleepHour: 23, currentWakeHour: 7)
        XCTAssertEqual(plan.estimatedDays, 6)
        XCTAssertEqual(plan.days.count, 6)
    }

    // MARK: - Clock formatting parity helper

    func testClockFormatting() {
        XCTAssertEqual(CircadianEngine.clock(20.0), "20:00")
        XCTAssertEqual(CircadianEngine.clock(23.5), "23:30")
        XCTAssertEqual(CircadianEngine.clock(-1.0), "23:00")   // wraps
        XCTAssertEqual(CircadianEngine.clock(7.25), "07:15")
    }

    // MARK: - #982: what the RELATIVE gate costs, in bpm, at a real HR mesor

    /// The engine is fed mean HEART RATE, not the motion volume its doc used to claim, and
    /// `minRelativeAmplitude` gates on `amplitude / |mesor|`. Against a signal carrying a ~45-75 bpm DC
    /// offset that makes the real bar an ABSOLUTE `0.10 x mesor` bpm — which these pin.
    ///
    /// These USED to pin the relative bar alone, including that the SAME 5 bpm swing was arrhythmic at a
    /// 65 bpm mesor and readable at 45 — the same rhythm judged by the baseline rather than by itself.
    /// `minAbsoluteAmplitudeBpm` removed that split; what remains pinned is that a proportional swing
    /// still passes, a genuinely flat one still fails, and the verdict no longer moves with the mesor.
    private func confidence(mesor: Double, amp: Double) -> CircadianEngine.PhaseConfidence {
        CircadianEngine.estimatePhase(bins: profile(mesor: mesor, amp: amp, acrophase: 16),
                                      daysObserved: CircadianEngine.goodDaysForFit,
                                      habitualWakeHour: 7)!.confidence
    }

    func testAProportionalSwingStillPasses() {
        XCTAssertNotEqual(confidence(mesor: 65, amp: 8), .unreadable)   // 0.123 - clears 0.10
    }

    /// The inconsistency the absolute floor removes: one rhythm, three baselines, one verdict.
    func testTheSameSwingNoLongerDependsOnTheBaseline() {
        XCTAssertNotEqual(confidence(mesor: 45, amp: 5), .unreadable)
        XCTAssertNotEqual(confidence(mesor: 65, amp: 5), .unreadable)
        XCTAssertNotEqual(confidence(mesor: 80, amp: 5), .unreadable)
    }

    /// A genuinely flat rhythm is still refused — the floor widens the gate, it does not remove it.
    func testAFlatRhythmIsStillArrhythmicOnBothMeasures() {
        XCTAssertEqual(confidence(mesor: 45, amp: 4), .unreadable)      // 0.089, 4.0 bpm
        XCTAssertEqual(confidence(mesor: 65, amp: 4), .unreadable)      // 0.062, 4.0 bpm
        XCTAssertEqual(confidence(mesor: 74.7, amp: 3), .unreadable)
    }

    /// The absolute floor's own boundary, isolated: at a 74.7 bpm mesor the relative test cannot pass
    /// either value, so only `minAbsoluteAmplitudeBpm` decides. Expressed RELATIVE to the constant, with a
    /// 0.1 bpm margin rather than the exact value — the cosinor recovers amplitude to ~1e-9, and sitting
    /// exactly on `>=` would pin float recovery rather than the threshold.
    func testTheAbsoluteFloorIsWhereItSays() {
        let floor = CircadianEngine.minAbsoluteAmplitudeBpm
        XCTAssertNotEqual(confidence(mesor: 74.7, amp: floor + 0.1), .unreadable)
        XCTAssertEqual(confidence(mesor: 74.7, amp: floor - 0.1), .unreadable)
    }

    /// The widening must not hand a thinner fit a FIRMER label. A rhythm admitted only by the absolute
    /// floor caps at `.wide`, which withholds `chronotype` — that names a category off an acrophase a
    /// small swing pins loosely. A proportional rhythm still reaches `.solid`.
    func testAnAbsoluteOnlyRhythmIsReadableButNotSolid() {
        XCTAssertEqual(confidence(mesor: 74.7, amp: 5.5), .wide)    // 0.073 - floor only
        XCTAssertEqual(confidence(mesor: 65, amp: 8), .solid)       // 0.123 - proportional
        let wide = CircadianEngine.estimatePhase(bins: profile(mesor: 74.7, amp: 5.5, acrophase: 16),
                                                 daysObserved: CircadianEngine.goodDaysForFit,
                                                 habitualWakeHour: 7)!
        XCTAssertNil(CircadianEngine.chronotype(wide), "a floor-only fit must not name a chronotype")
    }

    /// The measured wearer this change exists for: 5.5 bpm on a 74.7 bpm mesor, refused at 7.3% against
    /// the 10% bar while its acrophase implied a textbook CBTmin near 04:06.
    func testTheMeasuredWearerIsNoLongerSilenced() {
        XCTAssertNotEqual(confidence(mesor: 74.7, amp: 5.5), .unreadable)
    }

    // MARK: - chronotype lean (absolute phase, not schedule-relative)

    /// The boundaries and the circular case, asserted from this side too so the agreement is pinned on
    /// both platforms rather than only in the Kotlin oracle. `late-evening-wrap` is the row that matters:
    /// 23:30 is five hours BEFORE the 04:30 anchor, so it is a strong MORNING lean — a naive
    /// `23.5 > 5.5` bucket would call it evening.
    func testChronotypeBucketsAbsolutePhaseCircularly() {
        XCTAssertEqual(CircadianEngine.chronotypeAnchorHour, 4.5, accuracy: 0,
                       "the anchor is derived from the engine's own constants, not hardcoded")
        let cases: [(Double, CircadianEngine.Chronotype)] = [
            (4.5, .intermediate), (3.5, .intermediate), (3.49, .morning),
            (5.5, .intermediate), (5.51, .evening),
            (23.5, .morning), (0.0, .morning), (12.0, .evening),
            (16.5, .evening), (16.4, .evening), (16.6, .morning),
            (28.5, .intermediate), (-1.0, .morning),
        ]
        for (hour, expected) in cases {
            XCTAssertEqual(CircadianEngine.chronotype(tempMinHour: hour), expected,
                           "tempMinHour \(hour)")
        }
    }

    /// A NAMED category reads as a fact about the person rather than a reading of the week, so it waits
    /// for the strongest tier — unlike the continuous offset the card already shows at `.wide`.
    func testChronotypeIsNamedOnlyForASolidFit() {
        func estimate(_ confidence: CircadianEngine.PhaseConfidence) -> CircadianEngine.PhaseEstimate {
            CircadianEngine.PhaseEstimate(tempMinHour: 23.5, acrophaseHours: 11.5,
                                          offsetVsScheduleMinutes: 0, confidence: confidence, note: "")
        }
        XCTAssertEqual(CircadianEngine.chronotype(estimate(.solid)), .morning)
        XCTAssertNil(CircadianEngine.chronotype(estimate(.wide)),
                     "a thin fit must not name a chronotype")
        XCTAssertNil(CircadianEngine.chronotype(estimate(.unreadable)))
    }

    /// The schedule-relative offset CANNOT name a chronotype, which is why this buckets the absolute
    /// phase instead. A consistent 03:00-11:00 sleeper is well aligned with their OWN schedule — offset
    /// ~0 — while being strongly evening-type by the clock.
    func testConsistentLateSleeperIsEveningTypeDespiteAZeroScheduleOffset() {
        let alignedButLate = CircadianEngine.PhaseEstimate(
            tempMinHour: 8.0, acrophaseHours: 20.0, offsetVsScheduleMinutes: 0,
            confidence: .solid, note: "")
        XCTAssertEqual(CircadianEngine.chronotype(alignedButLate), .evening)
    }

    /// The same table the Kotlin oracle pins, asserted from this side too. `typical` says the model is
    /// sane: a 04:30 temperature minimum and an 8 h night put the ideal window at 23:00-07:00. The wrap
    /// rows matter because the ideal bedtime routinely lands on the PREVIOUS day.
    func testIdealSleepWindowPlacesTheWindowOnTheRing() {
        let cases: [(Double, Double, (Double, Double)?)] = [
            (4.5, 8.0, (23.0, 7.0)), (4.5, 5.0, (2.0, 7.0)), (4.5, 10.0, (21.0, 7.0)),
            (7.0, 8.0, (1.5, 9.5)), (2.0, 8.0, (20.5, 4.5)),
            (1.0, 8.0, (19.5, 3.5)), (23.0, 8.0, (17.5, 1.5)),
            (4.5, 0.0, nil), (4.5, -1.0, nil), (4.5, 24.0, nil),
        ]
        for (tempMin, duration, expected) in cases {
            let w = CircadianEngine.idealSleepWindow(tempMinHour: tempMin, durationHours: duration)
            if let expected {
                XCTAssertEqual(w?.bedHour ?? -1, expected.0, accuracy: 1e-12, "bed for \(tempMin)/\(duration)")
                XCTAssertEqual(w?.wakeHour ?? -1, expected.1, accuracy: 1e-12, "wake for \(tempMin)/\(duration)")
            } else {
                XCTAssertNil(w, "an impossible duration cannot be placed on the ring: \(duration)")
            }
        }
    }

    /// The ideal arc takes the night's OWN length, so the dial compares PHASE alone — which keeps a sleep
    /// DEBT from rendering as a body-clock problem.
    func testIdealWindowSharesTheWakeAnchorAcrossDurations() {
        let short = CircadianEngine.idealSleepWindow(tempMinHour: 4.5, durationHours: 5)
        let long = CircadianEngine.idealSleepWindow(tempMinHour: 4.5, durationHours: 10)
        XCTAssertEqual(short?.wakeHour, long?.wakeHour)
        XCTAssertNotEqual(short?.bedHour, long?.bedHour)
    }

    /// The dial's caption quantity. `wrap-late` earns its place: a 23:00 temperature minimum puts the
    /// ideal wake at 01:30, so waking at 02:30 is one hour LATE, not twenty-three hours early.
    func testSleepWindowOffsetHours() {
        let cases: [(Double, Double, Double)] = [
            (4.5, 7.0, 0.0), (4.5, 8.0, 1.0), (4.5, 6.0, -1.0),
            (23.0, 2.5, 1.0), (1.0, 23.0, -4.5), (4.5, 19.0, 12.0),
        ]
        for (tempMin, wake, expected) in cases {
            XCTAssertEqual(CircadianEngine.sleepWindowOffsetHours(tempMinHour: tempMin, actualWakeHour: wake),
                           expected, accuracy: 1e-12, "tempMin \(tempMin) wake \(wake)")
        }
    }

    /// The dial's caption and the card's existing headline measure DIFFERENT things: a consistent late
    /// sleeper is well-aligned with their own schedule while sleeping hours from what their clock wants.
    func testWindowOffsetAndScheduleOffsetAreDifferentQuantities() {
        let windowOffset = CircadianEngine.sleepWindowOffsetHours(tempMinHour: 8.0, actualWakeHour: 6.5)
        XCTAssertEqual(windowOffset, -4.0, accuracy: 1e-12)
        let scheduleAligned = CircadianEngine.PhaseEstimate(
            tempMinHour: 8.0, acrophaseHours: 20.0, offsetVsScheduleMinutes: 0,
            confidence: .solid, note: "")
        XCTAssertEqual(scheduleAligned.offsetVsScheduleMinutes, 0)
        XCTAssertGreaterThan(abs(windowOffset), 1.0)
    }
}
