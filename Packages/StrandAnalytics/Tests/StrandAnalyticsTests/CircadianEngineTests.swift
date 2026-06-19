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
}
