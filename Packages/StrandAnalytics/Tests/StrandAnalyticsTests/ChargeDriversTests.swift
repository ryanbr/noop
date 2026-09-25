import XCTest
@testable import StrandAnalytics

/// The Charge driver list + relative skin-temp marker (SHARED CONTRACT). Proves the drivers come from
/// the SAME weighting `recovery(...)` uses, that a missing term yields NO row (never a fake one), that
/// the sign of each driver matches its real direction, and that the skin-temp relative tier banding is
/// honest. Twin of the Android RecoveryScorerChargeDriversTest. No em-dashes.
final class ChargeDriversTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and σ (Gaussian).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    // MARK: - Integer marginal rounding parity (#51)

    func testDriverPointRoundingUsesNearestWithHalfTiesAwayFromZero() {
        func hrvMarginal(hrv: Double, rhr: Double, hrvBaseline: BaselineState,
                         rhrBaseline: BaselineState? = nil) -> (raw: Double, points: Int) {
            let full = RecoveryScorer.recovery(
                hrv: hrv, rhr: rhr, resp: nil,
                hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                respBaseline: nil, sleepPerf: nil)!
            let neutral = RecoveryScorer.recovery(
                hrv: hrvBaseline.baseline, rhr: rhr, resp: nil,
                hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                respBaseline: nil, sleepPerf: nil)!
            let row = RecoveryScorer.chargeDrivers(
                hrv: hrv, rhr: rhr, resp: nil,
                hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                respBaseline: nil, sleepPerf: nil)
                .first { $0.label == "Heart rate variability" }!
            return (full - neutral, row.deltaPoints)
        }

        let negativeBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        let negativeBelowTie = hrvMarginal(
            hrv: 29.991177275907276, rhr: 60.0, hrvBaseline: negativeBaseline)
        let negativeTie = hrvMarginal(
            hrv: 29.99117725828923, rhr: 60.0, hrvBaseline: negativeBaseline)
        let negativeBeyondTie = hrvMarginal(
            hrv: 29.991177240671185, rhr: 60.0, hrvBaseline: negativeBaseline)
        XCTAssertGreaterThan(negativeBelowTie.raw, -0.5)
        XCTAssertEqual(negativeBelowTie.points, 0)
        XCTAssertEqual(negativeTie.raw, -0.5)
        XCTAssertEqual(negativeTie.points, -1)
        XCTAssertLessThan(negativeBeyondTie.raw, -0.5)
        XCTAssertEqual(negativeBeyondTie.points, -1)

        let positiveHRVBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        let positiveRHRBaseline = BaselineState(
            baseline: 60.0, spread: 0.1, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        let positiveBelowTie = hrvMarginal(
            hrv: 33.09890762408082, rhr: 58.541,
            hrvBaseline: positiveHRVBaseline, rhrBaseline: positiveRHRBaseline)
        let positiveTie = hrvMarginal(
            hrv: 33.099135135290354, rhr: 58.541,
            hrvBaseline: positiveHRVBaseline, rhrBaseline: positiveRHRBaseline)
        let positiveBeyondTie = hrvMarginal(
            hrv: 33.09936273466694, rhr: 58.541,
            hrvBaseline: positiveHRVBaseline, rhrBaseline: positiveRHRBaseline)
        XCTAssertLessThan(positiveBelowTie.raw, 0.5)
        XCTAssertEqual(positiveBelowTie.points, 0)
        XCTAssertEqual(positiveTie.raw, 0.5)
        XCTAssertEqual(positiveTie.points, 1)
        XCTAssertGreaterThan(positiveBeyondTie.raw, 0.5)
        XCTAssertEqual(positiveBeyondTie.points, 1)
    }

    func testIssue51NegativeHalfTieUsesDefaultArg8WithoutChangingScoreOrDriverFields() {
        let hrvBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        let scoreBefore = RecoveryScorer.recovery(
            hrv: 29.99117725828923, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)
        let neutralScore = RecoveryScorer.recovery(
            hrv: hrvBaseline.baseline, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)

        // Intentionally omit arg 8 (skinTempDev) to exercise the real default path from #51.
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 29.99117725828923, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)
        let scoreAfter = RecoveryScorer.recovery(
            hrv: 29.99117725828923, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)

        XCTAssertEqual(scoreBefore! - neutralScore!, -0.5)
        XCTAssertEqual(scoreAfter, scoreBefore)
        XCTAssertEqual(drivers, [ChargeDriver(
            label: "Heart rate variability",
            deltaPoints: -1,
            valueText: "30 ms",
            baselineText: "30 ms baseline",
            verdict: "slightly below baseline, limiting recovery")])
    }

    func testVerdictsMatchDisplayedPrecisionAndRoundedPoints() {
        let cases: [(Double, Double, Int, Int, String)] = [
            (51.3, 50.8, 1, 0, "slightly above baseline, supporting recovery"),
            (51.3, 50.8, -1, 0, "slightly above baseline, limiting recovery"),
            (50.8, 51.3, 1, 0, "slightly below baseline, supporting recovery"),
            (50.8, 51.3, -1, 0, "slightly below baseline, limiting recovery"),
            (17, 16, 0, 1, "above baseline, too small to change Charge"),
            (15, 16, 0, 1, "below baseline, too small to change Charge"),
            (51.3, 50.8, 0, 0, "at baseline"),
        ]

        for (value, baseline, points, fractionDigits, expected) in cases {
            XCTAssertEqual(
                RecoveryScorer.baselineVerdict(
                    value: value, baseline: baseline,
                    deltaPoints: points, fractionDigits: fractionDigits),
                expected)
        }
    }

    func testSkinTempVerdictUsesRoundedPointEffect() {
        XCTAssertEqual(
            RecoveryScorer.skinTempVerdict(0.2, deltaPoints: 0),
            "near baseline")
        XCTAssertEqual(
            RecoveryScorer.skinTempVerdict(0.2, deltaPoints: -1),
            "warmer than baseline, limiting recovery")
        XCTAssertEqual(
            RecoveryScorer.skinTempVerdict(-0.2, deltaPoints: -1),
            "cooler than baseline, limiting recovery")
    }

    func testRestingHRRowCannotSayAboveWhenDisplayedValuesMatch() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 50, rhr: 51.3, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6),
            rhrBaseline: baseline(mean: 50.8, sigma: 0.1),
            respBaseline: nil, sleepPerf: nil)
        let rhr = drivers.first { $0.label == "Resting heart rate" }!

        XCTAssertEqual(rhr.valueText, "51 bpm")
        XCTAssertEqual(rhr.baselineText, "51 bpm baseline")
        XCTAssertLessThan(rhr.deltaPoints, 0)
        XCTAssertEqual(rhr.verdict, "slightly above baseline, limiting recovery")
    }

    // MARK: - Presence / omission

    func testColdStartHRVBaselineYieldsNoDrivers() {
        // HRV baseline not usable -> recovery() is nil -> no real contributions to attribute.
        let coldHrv = baseline(mean: 50, sigma: 6, nValid: 1)   // < seed -> .provisional? force calibrating
        let calibrating = BaselineState(baseline: 50, spread: 6 / 1.253, nValid: 1,
                                        nightsSinceUpdate: 0, status: .calibrating)
        _ = coldHrv
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: 15,
            hrvBaseline: calibrating, rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.9, skinTempDev: 0.2)
        XCTAssertTrue(drivers.isEmpty)
    }

    func testMissingTermsOmittedNotFabricated() {
        // No resp, no resp baseline, no skin temp -> those rows must be ABSENT (not zero rows).
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.9, skinTempDev: nil)
        let labels = Set(drivers.map { $0.label })
        XCTAssertTrue(labels.contains("Heart rate variability"))
        XCTAssertTrue(labels.contains("Resting heart rate"))
        XCTAssertTrue(labels.contains("Sleep quality"))
        XCTAssertFalse(labels.contains("Respiratory rate"))     // omitted, not a fake 0 row
        XCTAssertFalse(labels.contains("Skin temperature"))     // omitted, not a fake 0 row
        XCTAssertEqual(drivers.count, 3)
    }

    func testNoRHRBaselineOmitsRHRRow() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: nil,
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: nil)
        XCTAssertFalse(drivers.contains { $0.label == "Resting heart rate" })
        XCTAssertTrue(drivers.contains { $0.label == "Heart rate variability" })
    }

    // MARK: - Sign correctness (the term's real direction)

    func testGoodInputsGivePositiveContributions() {
        // Moderately-good inputs in the real operating range (Charge in the high 70s/low 80s, not a
        // saturated +3sigma-on-everything corner where the logistic is flat and small-weight terms
        // round to 0 points honestly). Each MATERIAL term (HRV 0.55, resting HR 0.20, Rest 0.15)
        // should push Charge UP, so its marginal-vs-neutral contribution is strictly positive.
        // Respiration is a deliberately-minor 0.05-weight term: it can legitimately be worth ~0
        // points, so its verdict must acknowledge when the visible difference is too small to move
        // Charge rather than claim a supporting effect.
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 58, rhr: 53, resp: 15,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.91, skinTempDev: nil)
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        let resp = drivers.first { $0.label == "Respiratory rate" }!
        XCTAssertGreaterThan(hrv.deltaPoints, 0)
        XCTAssertGreaterThan(rhr.deltaPoints, 0)
        XCTAssertGreaterThan(sleep.deltaPoints, 0)
        XCTAssertGreaterThanOrEqual(resp.deltaPoints, 0)   // minor 0.05-weight term; direction below
        XCTAssertTrue(hrv.verdict.contains("supporting recovery"))
        XCTAssertTrue(rhr.verdict.contains("supporting recovery"))
        XCTAssertEqual(
            resp.verdict,
            resp.deltaPoints == 0
                ? "below baseline, too small to change Charge"
                : "below baseline, supporting recovery")
    }

    func testBadInputsGiveNegativeContributions() {
        // HRV below baseline, RHR above, poor sleep -> each should pull Charge DOWN (<0).
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 38, rhr: 66, resp: 19,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.65, skinTempDev: nil)
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        XCTAssertLessThan(hrv.deltaPoints, 0)
        XCTAssertLessThan(rhr.deltaPoints, 0)
        XCTAssertLessThan(sleep.deltaPoints, 0)
        XCTAssertTrue(hrv.verdict.contains("limiting recovery"))
    }

    func testSkinTempDeviationIsAlwaysNonPositive() {
        // Skin temp is a SYMMETRIC penalty: any drift can only lower Charge, so its contribution
        // (full minus without) is <= 0 for both a warm and a cold drift.
        let warm = RecoveryScorer.chargeDrivers(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: 0.8)
        let cold = RecoveryScorer.chargeDrivers(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: -0.8)
        let warmRow = warm.first { $0.label == "Skin temperature" }!
        let coldRow = cold.first { $0.label == "Skin temperature" }!
        XCTAssertLessThanOrEqual(warmRow.deltaPoints, 0)
        XCTAssertLessThanOrEqual(coldRow.deltaPoints, 0)
        XCTAssertTrue(warmRow.valueText.contains("+0.8"))
        XCTAssertTrue(coldRow.valueText.contains("-0.8"))
    }

    // MARK: - Ordering, value text, baseline text

    func testOrderedByMagnitudeBiggestMoverFirst() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 68, rhr: 49, resp: 14,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.95, skinTempDev: 0.4)
        let mags = drivers.map { abs($0.deltaPoints) }
        XCTAssertEqual(mags, mags.sorted(by: >), "drivers must be ordered biggest mover first")
        // HRV is the dominant weight; with a strong HRV signal it should lead.
        XCTAssertEqual(drivers.first?.label, "Heart rate variability")
    }

    func testValueAndBaselineTextShape() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 58, rhr: 61, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 64, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: nil)
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        XCTAssertEqual(rhr.valueText, "61 bpm")
        XCTAssertEqual(rhr.baselineText, "64 bpm baseline")
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        XCTAssertEqual(hrv.valueText, "58 ms")
        XCTAssertEqual(hrv.baselineText, "50 ms baseline")
        // Sleep quality has no learned baseline -> empty baselineText (UI omits the line).
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        XCTAssertEqual(sleep.baselineText, "")
    }

    func testSkinTempAndRespirationFormattingUseSharedPOSIXContract() {
        let expectedSkinText: [(Double, String)] = [
            (-0.35, "-0.4 C vs baseline"),
            (0.35, "+0.4 C vs baseline"),
            (-0.34, "-0.3 C vs baseline"),
            (0.34, "+0.3 C vs baseline"),
            (-0.36, "-0.4 C vs baseline"),
            (0.36, "+0.4 C vs baseline"),
            (-0.0, "-0.0 C vs baseline"),
            (0.0, "+0.0 C vs baseline"),
        ]

        for (deviation, expected) in expectedSkinText {
            let drivers = RecoveryScorer.chargeDrivers(
                hrv: 46, rhr: 58, resp: 14,
                hrvBaseline: baseline(mean: 51, sigma: 6.265),
                rhrBaseline: baseline(mean: 58, sigma: 5.012, nValid: 12),
                respBaseline: baseline(mean: 15, sigma: 1.8795, nValid: 12),
                sleepPerf: 0.9, skinTempDev: deviation)
            let skin = try! XCTUnwrap(drivers.first { $0.label == "Skin temperature" })
            XCTAssertEqual(skin.valueText, expected)
            XCTAssertEqual(skin.baselineText, "")
            XCTAssertLessThanOrEqual(skin.deltaPoints, 0)

            let respiration = try! XCTUnwrap(drivers.first { $0.label == "Respiratory rate" })
            XCTAssertEqual(respiration.valueText, "14.0 br/min")
            XCTAssertEqual(respiration.baselineText, "15.0 br/min baseline")
        }
    }

    func testNoEmDashesInOutput() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: 15,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.9, skinTempDev: 0.3)
        for d in drivers {
            for s in [d.label, d.valueText, d.baselineText, d.verdict] {
                XCTAssertFalse(s.contains("\u{2014}"), "em-dash in: \(s)")
            }
        }
    }

    // MARK: - A5: relative skin-temp tier

    func testSkinTempRelativeNilWhenNoDeviation() {
        XCTAssertNil(RecoveryScorer.skinTempRelative(deviationC: nil))
    }

    func testSkinTempRelativeTiers() {
        let band = RecoveryScorer.skinTempTypicalBandC
        // Within the band -> typical.
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: 0.0)?.tier, .typical)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: band)?.tier, .typical)        // boundary inclusive
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: -band)?.tier, .typical)
        // Beyond the band -> warmer / cooler.
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: band + 0.2)?.tier, .warmer)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: -(band + 0.2))?.tier, .cooler)
    }

    func testSkinTempRelativeCarriesSignedDeviation() {
        let rel = RecoveryScorer.skinTempRelative(deviationC: 0.7)!
        XCTAssertEqual(rel.deviationC, 0.7, accuracy: 1e-9)
        XCTAssertEqual(rel.tier, .warmer)
    }
}
