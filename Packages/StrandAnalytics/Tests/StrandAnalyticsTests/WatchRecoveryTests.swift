import XCTest
@testable import StrandAnalytics

/// Tests for `WatchRecovery`, the honesty-critical recovery-from-daily-aggregate engine behind
/// "Apple Watch as a device". The watch gives sparse daily SDNN + resting HR rather than the
/// strap's dense RR stream, so these fixtures pin the BEHAVIOUR (at-baseline ≈ mid, high-HRV /
/// low-RHR → high, thin history / missing today → nil + calibrating) regardless of the exact
/// logistic constants, which are inherited unchanged from `RecoveryScorer` (the strap Charge
/// engine) so watch recovery and strap recovery sit on the same scale.
final class WatchRecoveryTests: XCTestCase {

    // A person whose HRV today equals their baseline and RHR equals baseline → mid recovery,
    // solid confidence (14 nights of history clears the trusted gate).
    func testAtBaselineGivesMidRecoverySolid() {
        let hist = Array(repeating: 45.0, count: 14)            // 14 nights of SDNN
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 60)
        XCTAssertEqual(out.confidence, .solid)
    }

    // HRV well above baseline + RHR below baseline → high recovery.
    func testHighHRVLowRHRGivesHighRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 70.0, todayRHR: 46,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThan(out.recovery!, 65)
    }

    // HRV well below baseline + RHR above baseline → low recovery (the symmetric case;
    // a bad night must read low, not get floored at mid).
    func testLowHRVHighRHRGivesLowRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 22.0, todayRHR: 62,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertLessThan(out.recovery!, 40)
    }

    // Too little history → calibrating, nil recovery (never a fabricated number).
    func testInsufficientHistoryCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: [45, 46], rhrHistory: [52, 51])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History just under the week gate → still calibrating (the gate is exactly minBaselineNights).
    func testHistoryJustBelowGateCalibrates() {
        let n = WatchRecovery.minBaselineNights - 1
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: n),
                                        rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History at the week gate (and usable baseline) → scores, no longer calibrating.
    func testHistoryAtGateScores() {
        let n = WatchRecovery.minBaselineNights
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: n),
                                        rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNotNil(out.recovery)
        XCTAssertNotEqual(out.confidence, .calibrating)
    }

    // Missing today's HRV → calibrating, nil (we never score off RHR alone).
    func testMissingTodayCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: nil, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: 14),
                                        rhrHistory: Array(repeating: 52.0, count: 14))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Missing today's RHR (but HRV present + baseline usable) → still scores off HRV alone,
    // honestly, rather than nil-ing out. RHR is an optional term.
    func testMissingTodayRHRStillScoresFromHRV() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        // At-baseline HRV with the RHR term dropped should still land near the mid band.
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 70)
    }

    // MARK: - Week gate counts ACCEPTED nights, not raw entries (fork issue #62)

    // Seven RAW history entries of which only four are physiologically valid must NOT clear the
    // week gate: `minBaselineNights` means nights the baseline ACCEPTED (`nValid`), so the rejected
    // -1 / 0 / 999 readings can't buy a score a week early.
    func testSevenRawNightsWithFourValidCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: [45, 46, 47, 48, -1, 0, 999], rhrHistory: [])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Seven raw entries of which only three are valid: below the baseline's own seed gate too.
    func testSevenRawNightsWithThreeValidCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: [45, 46, 47, -1, 0, 999, 1000], rhrHistory: [])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Six raw entries, all six valid → still one accepted night short of the gate.
    func testSixRawNightsWithSixValidCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: [45, 46, 47, 48, 45, 46], rhrHistory: [])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Nine raw entries of which exactly seven are valid → the gate is met by accepted nights.
    func testNineRawNightsWithSevenValidScores() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: [45, 46, 47, 48, 45, 46, 47, -1, 999],
                                        rhrHistory: [])
        XCTAssertNotNil(out.recovery)
        XCTAssertNotEqual(out.confidence, .calibrating)
    }

    // MARK: - RHR term needs a USABLE RHR baseline (fork issue #61)

    // An empty RHR history yields `foldHistory`'s synthetic midpoint baseline (75 bpm), which must
    // never score today's reading: with no usable RHR baseline the result is the documented
    // HRV-only path, exactly as if today's RHR were missing.
    func testEmptyRHRHistoryScoresLikeMissingRHR() {
        let hist = Array(repeating: 45.0, count: 7)
        let withRHR = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                            sdnnHistory: hist, rhrHistory: [])
        let hrvOnly = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                            sdnnHistory: hist, rhrHistory: [])
        XCTAssertNotNil(withRHR.recovery)
        XCTAssertNotNil(hrvOnly.recovery)
        XCTAssertEqual(withRHR.recovery!, hrvOnly.recovery!, accuracy: 1e-12)
        // The same literal the Kotlin twin pins, so the oracle guards BOTH directions: a Swift-side
        // drift would break here rather than silently diverging from Android.
        XCTAssertEqual(withRHR.recovery!, 57.932425214874954, accuracy: 1e-12)
    }

    // An RHR history that is entirely out of physiological range accepts no night at all, so its
    // baseline is the same synthetic midpoint — likewise dropped.
    func testUnusableRHRHistoryScoresLikeMissingRHR() {
        let hist = Array(repeating: 45.0, count: 7)
        let junk = Array(repeating: 300.0, count: 7)   // above restingHRCfg.maxVal (120)
        let withRHR = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                            sdnnHistory: hist, rhrHistory: junk)
        let hrvOnly = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                            sdnnHistory: hist, rhrHistory: junk)
        XCTAssertNotNil(withRHR.recovery)
        XCTAssertEqual(withRHR.recovery!, hrvOnly.recovery!, accuracy: 1e-12)
    }

    // Once the RHR baseline IS usable (≥ Baselines.minNightsSeed accepted nights) the term returns:
    // a resting HR above baseline must pull the score below the HRV-only number.
    func testUsableRHRHistoryStillContributes() {
        let hist = Array(repeating: 45.0, count: 7)
        let rhrHist = Array(repeating: 52.0, count: 4)   // exactly the seed gate → provisional
        let withRHR = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 62,
                                            sdnnHistory: hist, rhrHistory: rhrHist)
        let hrvOnly = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                            sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(withRHR.recovery)
        XCTAssertNotNil(hrvOnly.recovery)
        XCTAssertLessThan(withRHR.recovery!, hrvOnly.recovery! - 1.0)
    }

    // Watch recovery is on the SAME scale as strap recovery: feeding identical at-baseline inputs
    // to RecoveryScorer directly (HRV + RHR terms only) reproduces WatchRecovery's number.
    func testSameScaleAsStrapRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 58.0, todayRHR: 50,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        let hrvBase = Baselines.foldHistory(hist.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHist.map { Optional($0) }, cfg: Baselines.restingHRCfg)
        let strap = RecoveryScorer.recovery(hrv: 58.0, rhr: 50.0, resp: nil,
                                            hrvBaseline: hrvBase, rhrBaseline: rhrBase,
                                            respBaseline: nil, sleepPerf: nil)
        XCTAssertNotNil(out.recovery)
        XCTAssertNotNil(strap)
        XCTAssertEqual(out.recovery!, strap!, accuracy: 0.0001)
    }
}
