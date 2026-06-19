import XCTest
@testable import StrandAnalytics

/// DoseResponseEngine — per-user dose slope shrunk toward a population prior. The oracle for
/// the Android DoseResponseEngineTest; keep the two in lockstep (same fixtures, same numbers).
final class DoseResponseEngineTests: XCTestCase {

    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    // The documented alcohol→Charge prior used throughout (mirror of DoseResponsePriors).
    private let alcoholPrior = -5.0

    // MARK: - n_user = 0 returns the prior exactly

    func testNoDataReturnsPrior() {
        // Doses logged, but NO next-day outcome exists for any of them → 0 usable pairs.
        let doses: [String: Int] = [ymd(2026, 6, 1): 2, ymd(2026, 6, 2): 1]
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: [:])!
        XCTAssertEqual(r.nUser, 0)
        XCTAssertEqual(r.weight, 0, accuracy: 1e-12)
        XCTAssertNil(r.userSlope)
        XCTAssertEqual(r.perUnit, alcoholPrior, accuracy: 1e-12)   // pure prior
        XCTAssertTrue(r.priorDominated)
        XCTAssertFalse(r.contradictsPrior)
        XCTAssertEqual(r.confidence, .calibrating)
        XCTAssertEqual(r.outcome, "Charge")
    }

    // MARK: - shrinkage weight w = n/(n+k) is exact at the boundary n = k

    func testShrinkageWeightAtBoundary() {
        // Plant exactly 8 pairs with a clean personal slope of -2 (outcome = 80 - 2*dose), so
        // n_user = k = 8 ⇒ w = 0.5, and perUnit = 0.5*(-2) + 0.5*(-5) = -3.5 (inside clamp).
        var doses: [String: Int] = [:]
        var outcome: [String: Double] = [:]
        // 8 anchor days, each the 10th of a distinct month so D+1 never collides with a dose day.
        for (i, month) in [1, 2, 3, 4, 5, 6, 7, 8].enumerated() {
            let dose = i % 4                       // doses 0,1,2,3,0,1,2,3
            let day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 80.0 - 2.0 * Double(dose)   // D+1 = 80 - 2·dose
        }
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: outcome)!
        XCTAssertEqual(r.nUser, 8)
        XCTAssertEqual(r.weight, 0.5, accuracy: 1e-12)             // 8 / (8 + 8)
        XCTAssertEqual(r.userSlope!, -2.0, accuracy: 1e-9)        // clean OLS slope
        XCTAssertEqual(r.perUnit, -3.5, accuracy: 1e-9)           // 0.5·(−2) + 0.5·(−5)
        XCTAssertEqual(r.confidence, .building)                   // 5 ≤ 8 < 12
    }

    // MARK: - large n_user recovers ≈ the personal slope

    func testLargeNRecoversPersonalSlope() {
        // 40 clean pairs with personal slope -3 (outcome = 90 - 3*dose). w = 40/48 = 0.8333…,
        // perUnit = w·(-3) + (1-w)·(-5) = -3.333..., dominated by the personal fit.
        var doses: [String: Int] = [:]
        var outcome: [String: Double] = [:]
        // 40 anchors: months won't span 40, so use day-of-month within a few wide-gapped months,
        // spacing anchors 3 days apart so D+1 outcomes never collide with a later dose day.
        var count = 0
        for month in [1, 4, 7, 10] {           // 4 months
            for k in 0..<10 {                  // 10 per month
                let dom = 1 + k * 3            // 1,4,7,...,28 — D+1 = dom+1 never a dose day
                let dose = count % 4
                let day = ymd(2026, month, dom)
                doses[day] = dose
                outcome[ymd(2026, month, dom + 1)] = 90.0 - 3.0 * Double(dose)
                count += 1
            }
        }
        XCTAssertEqual(count, 40)
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: outcome)!
        XCTAssertEqual(r.nUser, 40)
        XCTAssertEqual(r.userSlope!, -3.0, accuracy: 1e-9)
        let w = 40.0 / 48.0
        XCTAssertEqual(r.weight, w, accuracy: 1e-12)
        XCTAssertEqual(r.perUnit, w * (-3.0) + (1.0 - w) * (-5.0), accuracy: 1e-9)
        XCTAssertFalse(r.priorDominated)             // n ≥ minDoseDays
        XCTAssertFalse(r.contradictsPrior)           // same sign as prior (both negative)
        XCTAssertEqual(r.confidence, .solid)         // n ≥ 12
    }

    // MARK: - a personal slope that contradicts the prior flips the copy state

    func testPersonalSlopeContradictsPriorOverGate() {
        // Personal slope POSITIVE (outcome = 60 + 2*dose): your drink-nights show NO dip. With
        // n_user ≥ minDoseDays the person overrides the population → contradictsPrior = true.
        var doses: [String: Int] = [:]
        var outcome: [String: Double] = [:]
        for (i, month) in [1, 2, 3, 4, 5, 6].enumerated() {   // 6 pairs ≥ gate (5)
            let dose = i % 4
            let day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 60.0 + 2.0 * Double(dose)   // POSITIVE slope
        }
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: outcome)!
        XCTAssertEqual(r.nUser, 6)
        XCTAssertGreaterThan(r.userSlope!, 0)        // personal slope is positive
        XCTAssertFalse(r.priorDominated)             // n ≥ gate
        XCTAssertTrue(r.contradictsPrior)            // sign disagrees with the negative prior
    }

    // MARK: - below the gate stays prior-dominated even with a contrary slope

    func testBelowGateStaysPriorDominated() {
        // Only 3 pairs (< minDoseDays) with a positive slope. Still priorDominated, NOT flagged
        // contradicts (we don't let 3 nights overrule the prior).
        var doses: [String: Int] = [:]
        var outcome: [String: Double] = [:]
        for (i, month) in [1, 2, 3].enumerated() {
            let dose = i        // 0,1,2 → spread for a fit
            let day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 60.0 + 5.0 * Double(dose)
        }
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: outcome)!
        XCTAssertEqual(r.nUser, 3)
        XCTAssertTrue(r.priorDominated)
        XCTAssertFalse(r.contradictsPrior)
        XCTAssertEqual(r.confidence, .calibrating)
    }

    // MARK: - clamp keeps a runaway personal slope inside the prior's range

    func testPerUnitIsClampedToPriorRange() {
        // A wildly steep personal slope (-40/drink) with enough n to dominate would push perUnit
        // below the alcohol clampLow of -15; the result must clamp at -15.
        var doses: [String: Int] = [:]
        var outcome: [String: Double] = [:]
        for k in 0..<40 {
            let dose = k % 4
            // Space anchors so D+1 never collides: anchor every 2 days across wide months.
            let month = 1 + (k / 10) * 3        // 1,4,7,10
            let dom = 1 + (k % 10) * 3
            let day = ymd(2026, month, dom)
            doses[day] = dose
            outcome[ymd(2026, month, dom + 1)] = 100.0 - 40.0 * Double(dose)
        }
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: doses, outcomeByDay: outcome)!
        XCTAssertEqual(r.perUnit, -15.0, accuracy: 1e-9)   // clamped at the prior's low bound
    }

    // MARK: - curve points use the shrunk slope from a 0 anchor

    func testCurvePoints() {
        // No data → pure prior of -5; curve is 0, -5, -10, -15 for dose 0..3.
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: [:], outcomeByDay: [:])!
        XCTAssertEqual(r.curve.map { $0.dose }, [0, 1, 2, 3])
        XCTAssertEqual(r.curve.map { $0.outcomeDelta }, [0, -5, -10, -15])
    }

    // MARK: - delta() composes incremental units (for the Damage Forecast)

    func testDeltaComposesUnits() {
        let r = DoseResponseEngine.estimate(behavior: .alcohol,
                                            doseByDay: [:], outcomeByDay: [:])!  // perUnit = -5
        XCTAssertEqual(r.delta(fromDose: 1, toDose: 2), -5, accuracy: 1e-12)
        XCTAssertEqual(r.delta(fromDose: 0, toDose: 3), -15, accuracy: 1e-12)
        XCTAssertEqual(r.delta(fromDose: 2, toDose: 2), 0, accuracy: 1e-12)
    }

    // MARK: - no documented prior → nil

    func testNoPriorOutcomeReturnsNil() {
        // Alcohol has a prior on "Charge" but not on "RHR" → nil.
        XCTAssertNil(DoseResponseEngine.estimate(behavior: .alcohol, outcome: "RHR",
                                                 doseByDay: [:], outcomeByDay: [:]))
    }

    // MARK: - caffeine default outcome is HRV with its own prior

    func testCaffeineDefaultsToHRV() {
        let r = DoseResponseEngine.estimate(behavior: .caffeine,
                                            doseByDay: [:], outcomeByDay: [:])!
        XCTAssertEqual(r.outcome, "HRV")
        XCTAssertEqual(r.perUnit, -4.0, accuracy: 1e-12)   // the documented caffeine→HRV prior
    }
}
