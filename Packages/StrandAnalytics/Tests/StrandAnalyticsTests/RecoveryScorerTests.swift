import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class RecoveryScorerTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and σ (Gaussian).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        // spread is internal abs-dev units; deviation() multiplies by 1.253 → σ.
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    func testRecoveryAtBaselineNearPopulationMean() {
        // HRV at baseline, RHR at baseline, no resp, sleepPerf at center → Z≈0 → ~58%.
        let r = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil,
            sleepPerf: RecoveryScorer.sleepPerfCenter)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 57.93, accuracy: 0.5)
    }

    func testRecoveryHigherWhenHRVAboveAndRHRBelow() {
        let good = RecoveryScorer.recovery(
            hrv: 65, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.90)!
        let bad = RecoveryScorer.recovery(
            hrv: 40, rhr: 62, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6.265),
            rhrBaseline: baseline(mean: 55, sigma: 2.506),
            respBaseline: nil,
            sleepPerf: 0.70)!
        XCTAssertGreaterThan(good, bad)
        XCTAssertGreaterThan(good, 90)   // matches Python golden ~97
        XCTAssertLessThan(bad, 15)       // matches Python golden ~7
    }

    func testRecoveryClampedToRange() {
        let r = RecoveryScorer.recovery(
            hrv: 200, rhr: 30, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 5),
            rhrBaseline: baseline(mean: 55, sigma: 2),
            respBaseline: nil,
            sleepPerf: 1.0)!
        XCTAssertLessThanOrEqual(r, 100.0)
        XCTAssertGreaterThanOrEqual(r, 0.0)
    }

    func testColdStartReturnsNil() {
        let coldHRV = BaselineState(baseline: 50, spread: 5, nValid: 2,
                                    nightsSinceUpdate: 0, status: .calibrating)
        let r = RecoveryScorer.recovery(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: coldHRV, rhrBaseline: nil, respBaseline: nil, sleepPerf: 0.9)
        XCTAssertNil(r)
    }

    func testRespTermDropAndRenormalize() {
        // With resp present vs nil but everything else equal at baseline, the score
        // stays near population mean either way (no driver pushes Z off zero).
        let withResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: 100,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        let withoutResp = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 100, sigma: 5),
            sleepPerf: RecoveryScorer.sleepPerfCenter)!
        XCTAssertEqual(withResp, withoutResp, accuracy: 1e-6)
    }

    func testRespAboveBaselineLowersAndBelowRaisesRecovery() {
        // Pins the resp-into-recovery wiring direction (mirrors the Android BaselineSeedingTest
        // addition): with HRV/RHR pinned at baseline, a nightly respiratory rate above the resp
        // baseline must LOWER recovery and one below it must RAISE it. A nil resp renormalizes
        // to the no-resp score (testRespTermDropAndRenormalize already pins that).
        func score(_ resp: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 50, rhr: 55, resp: resp,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: baseline(mean: 14.5, sigma: 1),
                sleepPerf: 0.9)!
        }
        let neutral = score(nil)
        let elevated = score(17.5)
        let lowered = score(12.0)
        XCTAssertLessThan(elevated, neutral, "resp above baseline must lower recovery")
        XCTAssertGreaterThan(lowered, neutral, "resp below baseline must raise recovery")
    }

    func testSkinTempNilLeavesScoreIdenticalToBefore() {
        // The no-skin-temp path must be byte-identical to the pre-redesign score:
        // when skinTempDev is nil the term drops and the weights renormalize.
        func score(_ dev: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 55, rhr: 52, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: 0.9,
                skinTempDev: dev)!
        }
        // Default argument (nil) and explicit nil agree, and both equal the no-skin-temp score.
        let implicitNil = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil,
            sleepPerf: 0.9)!
        XCTAssertEqual(score(nil), implicitNil, accuracy: 1e-9)
    }

    func testSkinTempDeviationLowersChargeSymmetrically() {
        // A symmetric penalty: ANY drift from baseline (hot OR cold) lowers Charge, and a
        // larger |deviation| lowers it more. Baseline drivers are pinned ABOVE-center
        // (positive composite z) so the penalty has a visible direction to push against.
        func score(_ dev: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 55, rhr: 52, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: 0.9,
                skinTempDev: dev)!
        }
        let neutral = score(nil)
        let zeroDev = score(0.0)
        let warm = score(1.0)
        let cold = score(-1.0)
        let bigWarm = score(2.0)
        // A present zero-deviation term adds no penalty itself, but participates in the
        // renormalization (extra weight at z=0), so an above-center composite is pulled
        // slightly toward the logistic center — strictly below the no-term score.
        XCTAssertLessThan(zeroDev, neutral)
        // A real deviation penalizes further, below the zero-deviation case…
        XCTAssertLessThan(warm, zeroDev, "warm deviation must lower Charge")
        XCTAssertLessThan(cold, zeroDev, "cold deviation must lower Charge")
        // …symmetrically (±1 °C cost the same)…
        XCTAssertEqual(warm, cold, accuracy: 1e-9)
        // …and a larger deviation lowers it more.
        XCTAssertLessThan(bigWarm, warm)
    }

    func testBandThresholds() {
        XCTAssertEqual(RecoveryScorer.band(20), "red")
        XCTAssertEqual(RecoveryScorer.band(33.9), "red")
        XCTAssertEqual(RecoveryScorer.band(34), "yellow")
        XCTAssertEqual(RecoveryScorer.band(50), "yellow")
        XCTAssertEqual(RecoveryScorer.band(66.9), "yellow")
        XCTAssertEqual(RecoveryScorer.band(67), "green")
        XCTAssertEqual(RecoveryScorer.band(90), "green")
    }

    // MARK: - Recovery Index / Activity-Balance folded into recovery(...)

    func testRecoveryIndexAndActivityBalanceDefaultNilByteIdenticalToBefore() {
        // Both new terms default to nil; the score must be EXACTLY the same whether the caller
        // omits them (every pre-existing call site in the app) or supplies nil explicitly —
        // proving the addition is non-breaking for every caller that does not yet supply the
        // two new signals. Covers BOTH overloads (BaselineState convenience + raw DriverBaseline).
        let omitted = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: 14.0,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 14.5, sigma: 1),
            sleepPerf: 0.9,
            skinTempDev: 0.4)!
        let explicitNil = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: 14.0,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 14.5, sigma: 1),
            sleepPerf: 0.9,
            skinTempDev: 0.4,
            recoveryIndexSlope: nil,
            effortBaseline: nil,
            priorDayEffort: nil)!
        XCTAssertEqual(omitted, explicitNil, accuracy: 1e-9)

        let hrvB = RecoveryScorer.DriverBaseline(mean: 50, spread: 6 / 1.253)
        let rhrB = RecoveryScorer.DriverBaseline(mean: 55, spread: 3 / 1.253)
        let rawOmitted = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil,
            sleepPerf: 0.9, skinTempDev: 0.4)!
        let rawExplicitNil = RecoveryScorer.recovery(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil,
            sleepPerf: 0.9, skinTempDev: 0.4, hrvBaselineUsable: true,
            recoveryIndexSlope: nil, effortBaseline: nil, priorDayEffort: nil)!
        XCTAssertEqual(rawOmitted, rawExplicitNil, accuracy: 1e-9)
    }

    func testRecoveryIndexSteeperDeclineRaisesChargeMoreThanFlatOrRising() {
        // Pin HRV/RHR/sleep at neutral so the ONLY thing moving is the slope term.
        func score(_ slope: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 50, rhr: 55, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: RecoveryScorer.sleepPerfCenter,
                recoveryIndexSlope: slope)!
        }
        let flat = score(0.0)
        let mildDecline = score(-1.0)
        let steepDecline = score(-4.0)
        let rising = score(2.0)

        // Multiple distinct slopes recovered in the expected order (derived-signal rule): a
        // steeper decline raises the Charge contribution more than a flat or rising night.
        XCTAssertGreaterThan(steepDecline, mildDecline)
        XCTAssertGreaterThan(mildDecline, flat)
        XCTAssertGreaterThan(flat, rising)
    }

    func testActivityBalanceHighEffortYesterdayLowersChargeVsRestDay() {
        // Baseline drivers pinned ABOVE-center (positive composite z), same rigor as the
        // skin-temp precedent test, so the effort term's renormalization dilution has a
        // direction to push against.
        func score(_ effort: Double?) -> Double {
            RecoveryScorer.recovery(
                hrv: 58, rhr: 50, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: 0.92,
                effortBaseline: baseline(mean: 40, sigma: 15),
                priorDayEffort: effort)!
        }
        let neutral = score(nil)
        let atBaseline = score(40.0)     // exactly typical -> present term, z=0, dilutes toward center
        let restDay = score(10.0)        // well below normal -> supports recovery further
        let hardDay = score(65.0)        // above normal -> pulls recovery down
        let veryHardDay = score(90.0)    // far above normal -> pulls down more

        XCTAssertLessThan(atBaseline, neutral,
            "a present at-baseline effort term still dilutes an above-center composite toward the logistic center")
        XCTAssertGreaterThan(restDay, atBaseline, "a lighter-than-normal day supports recovery vs a typical day")
        XCTAssertGreaterThan(atBaseline, hardDay, "a harder-than-normal day pulls recovery down vs a typical day")
        // Multiple distinct levels recovered in strictly the expected monotonic order
        // (derived-signal rule): more effort yesterday -> lower Charge contribution.
        XCTAssertGreaterThan(restDay, hardDay)
        XCTAssertGreaterThan(hardDay, veryHardDay)
    }

    func testActivityBalanceDropsTermUnlessBothValueAndBaselineArePresent() {
        func score(effort: Double?, effortBaseline base: BaselineState?) -> Double {
            RecoveryScorer.recovery(
                hrv: 50, rhr: 55, resp: nil,
                hrvBaseline: baseline(mean: 50, sigma: 6),
                rhrBaseline: baseline(mean: 55, sigma: 3),
                respBaseline: nil,
                sleepPerf: RecoveryScorer.sleepPerfCenter,
                effortBaseline: base,
                priorDayEffort: effort)!
        }
        let neither = score(effort: nil, effortBaseline: nil)
        let valueOnly = score(effort: 80.0, effortBaseline: nil)
        let baselineOnly = score(effort: nil, effortBaseline: baseline(mean: 40, sigma: 15))
        let both = score(effort: 80.0, effortBaseline: baseline(mean: 40, sigma: 15))

        XCTAssertEqual(neither, valueOnly, accuracy: 1e-9, "a value with no baseline must drop the term")
        XCTAssertEqual(neither, baselineOnly, accuracy: 1e-9, "a baseline with no value must drop the term")
        XCTAssertNotEqual(both, neither, "supplying BOTH must actually change the score")
    }
}
