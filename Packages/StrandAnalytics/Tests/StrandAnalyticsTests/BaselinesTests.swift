import XCTest
@testable import StrandAnalytics

final class BaselinesTests: XCTestCase {

    func testFirstNightSeeds() {
        let s = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 1)
        XCTAssertEqual(s.status, .calibrating)
    }

    func testColdStartStatusProgression() {
        // 3 nights → calibrating; 4 → provisional; 14 → trusted.
        var s = Baselines.foldHistory(Array(repeating: 50.0, count: 3), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .calibrating)
        XCTAssertFalse(s.usable)

        s = Baselines.foldHistory(Array(repeating: 50.0, count: 4), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .provisional)
        XCTAssertTrue(s.usable)

        s = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .trusted)
        XCTAssertTrue(s.trusted)
    }

    func testMissingNightSkipAndHold() {
        let seed = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        let after = Baselines.update(seed, value: nil, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.baseline, seed.baseline, accuracy: 1e-9)
        XCTAssertEqual(after.spread, seed.spread, accuracy: 1e-9)
        XCTAssertEqual(after.nValid, seed.nValid)            // not incremented
        XCTAssertEqual(after.nightsSinceUpdate, 1)
    }

    func testConstantSeriesConvergesToValue() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 30), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-6)     // EWMA of constant = constant
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
    }

    func testHardOutlierRejected() {
        // Establish a stable baseline, then feed a huge outlier (>5σ).
        var values = Array(repeating: 50.0, count: 10)
        let stable = Baselines.foldHistory(values, cfg: Baselines.hrvCfg)
        values.append(200.0)  // way out (within physiological max 250, but >5*spread)
        let after = Baselines.foldHistory(values, cfg: Baselines.hrvCfg)
        // Baseline should barely move (outlier was rejected, not folded).
        XCTAssertEqual(after.baseline, stable.baseline, accuracy: 1.0)
    }

    func testOutOfRangeValueSkipped() {
        let seed = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        // 300 > hrv max 250 → skip-and-hold.
        let after = Baselines.update(seed, value: 300, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.nValid, seed.nValid)
        XCTAssertEqual(after.nightsSinceUpdate, 1)
    }

    func testDeviationDirectionAndZero() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.hrvCfg)
        let atBaseline = Baselines.deviation(50.0, state: s)
        XCTAssertEqual(atBaseline.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(atBaseline.delta, 0.0, accuracy: 1e-6)
        XCTAssertTrue(atBaseline.inNormalRange)

        let above = Baselines.deviation(70.0, state: s)
        XCTAssertGreaterThan(above.z, 0)
        XCTAssertEqual(above.delta, 20.0, accuracy: 1e-6)

        let below = Baselines.deviation(30.0, state: s)
        XCTAssertLessThan(below.z, 0)
    }

    func testRollingMeanSD() {
        // Trailing mean/SD over a small known set: [40, 50, 60] → mean 50, sample SD 10.
        let s = Baselines.rollingMeanSD([40, 50, 60], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        // spread is stored as SD/1.253, so deviation() recovers σ = SD = 10.
        let dev = Baselines.deviation(60.0, state: s)
        XCTAssertEqual(dev.z, 1.0, accuracy: 1e-6)  // (60-50)/10
    }

    func testRollingMeanSDWindowTruncates() {
        // 35 values; window 30 keeps the last 30. Last 30 are all 50 → mean 50.
        var vals: [Double?] = Array(repeating: 100.0, count: 5)
        vals.append(contentsOf: Array(repeating: 50.0, count: 30))
        let s = Baselines.rollingMeanSD(vals, cfg: Baselines.hrvCfg, window: 30)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 30)
    }

    func testRollingMeanSDDropsOutOfRangeAndNil() {
        let s = Baselines.rollingMeanSD([nil, 50, 300, 50, 50], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.nValid, 3)  // nil + 300(>250) dropped
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
    }

    func testEmptyHistoryCalibrating() {
        let s = Baselines.rollingMeanSD([], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .calibrating)
        XCTAssertEqual(s.nValid, 0)
    }

    // MARK: - Early-life anti-anchoring (Reddit HRV report)

    /// Three artificially-high seed nights then a run of genuine lower nights must converge toward
    /// reality QUICKLY (days, not the ~2-3 weeks the old halfLifeB=14 EWMA took) — and crucially the
    /// genuine lower nights must NOT be rejected as hard outliers while the spread is still tight.
    func testEarlyHighSeedConvergesQuickly() {
        // 3 high cold-start nights (~90ms) then the user's true ~54ms.
        var vals: [Double?] = [90, 92, 88]
        vals.append(contentsOf: Array(repeating: 54.0, count: 7)) // ~1 week of real nights
        let s = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)

        // The baseline must have tracked most of the way down to 54 within a week.
        XCTAssertLessThan(s.baseline, 65.0,
                          "early-high seed should converge near the true value within ~1 week, got \(s.baseline)")
        // A true 54ms night should now read as roughly in-range, NOT a Charge-crushing extreme z.
        let dev = Baselines.deviation(54.0, state: s)
        XCTAssertLessThan(abs(dev.z), 2.0,
                          "a real night near the converged baseline shouldn't read as an extreme outlier, z=\(dev.z)")
    }

    /// The OLD behaviour (for contrast): without the early-life fix, the same sequence would reject
    /// the lower nights and stay anchored high. Here we assert the FIX — the lower nights are folded,
    /// so the baseline moves well below the seed (it would barely move if they were rejected).
    func testGenuineLowerNightsNotRejectedDuringSeed() {
        let seedHigh = Baselines.foldHistory(Array(repeating: 90.0, count: 4), cfg: Baselines.hrvCfg)
        var vals: [Double?] = Array(repeating: 90.0, count: 4)
        vals.append(contentsOf: Array(repeating: 55.0, count: 5))
        let after = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertLessThan(after.baseline, seedHigh.baseline - 15.0,
                          "lower nights must be folded (baseline drops), not rejected as outliers")
    }

    /// A genuinely settled, stable baseline must still reject a wild one-off outlier (the gate isn't
    /// disabled forever — only suspended during early life / floor-tight spread).
    func testHardOutlierStillRejectedOnceSettled() {
        // Enough varied nights to get past earlyAdaptNights AND lift spread off the floor.
        var vals: [Double?] = []
        for i in 0..<14 { vals.append(50.0 + Double(i % 3)) } // 50/51/52 jitter, ~stable
        let stable = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertGreaterThanOrEqual(stable.nValid, Baselines.earlyAdaptNights)
        vals.append(220.0) // wild outlier
        let after = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.baseline, stable.baseline, accuracy: 2.0,
                       "a settled baseline should still reject a wild outlier")
    }

    /// Constant input is unchanged by the early-life path (EWMA of a constant is the constant, and
    /// the faster early half-life can't move a center that's already at the value).
    func testEarlyPathNoOpOnConstantSeries() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 30), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-6)
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
    }

    // MARK: - Manual recalibration epoch (noop.hrvBaselineEpoch)

    /// Day-keyed fold with a recalibration epoch must DROP every night before the epoch and re-seed
    /// from the first on-or-after night — so a high early baseline resets to the recent reality.
    func testRecalibrateEpochReseedsFromEpoch() {
        // Pre-recalibration: 6 high nights; post: 6 lower nights. Epoch = start of 2026-06-15.
        let days = ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
                    "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20"]
        let vals: [Double?] = [90, 91, 89, 90, 92, 88,  54, 55, 53, 54, 56, 54]

        // Epoch at 2026-06-15T00:00:00Z.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = cal.date(from: comps)!.timeIntervalSince1970

        let recalibrated = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: epoch)
        // Only the 6 post-epoch (~54ms) nights contribute → baseline is the lower value, not anchored high.
        XCTAssertEqual(recalibrated.nValid, 6)
        XCTAssertEqual(recalibrated.baseline, 54.0, accuracy: 2.0)

        // Sanity: with NO epoch the high pre-nights still anchor it well above the recalibrated value.
        let notRecalibrated = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 0)
        XCTAssertGreaterThan(notRecalibrated.baseline, recalibrated.baseline + 10.0)
    }

    /// epoch <= 0 is byte-identical to the plain foldHistory (no recalibration).
    func testRecalibrateEpochZeroIsNoOp() {
        let days = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"]
        let vals: [Double?] = [60, 61, 59, 62]
        let withZero = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 0)
        let plain = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertEqual(withZero.baseline, plain.baseline, accuracy: 1e-9)
        XCTAssertEqual(withZero.nValid, plain.nValid)
    }

    /// An epoch AFTER every night drops them all → calibrating cold-start (re-learns from scratch).
    func testRecalibrateEpochAfterAllNightsResetsToColdStart() {
        let days = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"]
        let vals: [Double?] = [60, 61, 59, 62]
        // Far-future epoch.
        let s = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 4_000_000_000)
        XCTAssertEqual(s.nValid, 0)
        XCTAssertEqual(s.status, .calibrating)
    }

    // MARK: - #201: HRV window switch re-folds instead of restarting calibration

    /// #201: switching the HRV window re-scores the recent nights under the new window and folds the
    /// baseline from them WITHOUT re-anchoring the epoch. An established user (≥ minNightsSeed valid
    /// nights) therefore keeps a usable baseline centered on the new (here lower, deep-window) values
    /// immediately — not a multi-night calibrating reset. Contrast the epoch-reset path
    /// (testRecalibrateEpochAfterAllNightsResetsToColdStart), the old window-switch behaviour that dropped
    /// every night to cold-start and read as "the deep-sleep setting is broken" (#195).
    func testWindowSwitchRefoldStaysUsableWithoutEpochReset() {
        // 21 recent nights, all re-scored under the new deep window → the lower deep-only value.
        let days = (1...21).map { String(format: "2026-06-%02d", $0) }
        let deepVals: [Double?] = Array(repeating: 48.0, count: 21)

        // #201 path: fold with no recalibration epoch → usable, centered on the new deep value.
        let refolded = Baselines.foldHistory(deepVals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 0)
        XCTAssertTrue(refolded.usable)
        XCTAssertEqual(refolded.baseline, 48.0, accuracy: 2.0)

        // Old behaviour: re-anchoring the epoch to "now" (after every re-scored night) drops them all →
        // calibrating cold-start.
        let reset = Baselines.foldHistory(deepVals, dayKeys: days, cfg: Baselines.hrvCfg,
                                          baselineEpoch: 4_000_000_000)
        XCTAssertFalse(reset.usable)
        XCTAssertEqual(reset.status, .calibrating)
    }

    // MARK: - "Recalibrate Charge baseline" reset helper (noop.hrvBaselineEpoch + noop.recoveryBaselineEpoch)

    /// An isolated UserDefaults suite so these tests never touch the real app domain.
    private func makeDefaults(_ fn: String = #function) -> UserDefaults {
        let suite = "BaselinesTests.\(fn)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)   // start clean
        return d
    }

    /// recalibrateRecoveryBaselines must move BOTH the HRV and the recovery epoch to `now` — the whole
    /// Charge build-up restarts, not just HRV. Before the reset both read 0 (no recalibration).
    func testRecalibrateMovesBothEpochs() {
        let d = makeDefaults()
        XCTAssertEqual(Baselines.hrvBaselineEpoch(d), 0, accuracy: 1e-9)
        XCTAssertEqual(Baselines.recoveryBaselineEpoch(d), 0, accuracy: 1e-9)

        let now = 1_750_000_000.0
        Baselines.recalibrateRecoveryBaselines(now: now, defaults: d)

        XCTAssertEqual(Baselines.hrvBaselineEpoch(d), now, accuracy: 1e-9)
        XCTAssertEqual(Baselines.recoveryBaselineEpoch(d), now, accuracy: 1e-9)
    }

    /// End-to-end: a poisoned baseline (a bad high first week, then real lower nights) re-anchors to the
    /// recent reality once the reset moves the epoch — and the SAME stored history is folded both times
    /// (nothing is deleted; only the anchor day moves).
    func testRecalibrateReAnchorsNextComputationWithoutDeletingHistory() {
        let d = makeDefaults()
        // A "bad first week" worn sick (high HRV artefact), then six honest lower nights.
        let days = ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
                    "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20"]
        let vals: [Double?] = [90, 91, 89, 90, 92, 88,  54, 55, 53, 54, 56, 54]

        // Before any reset the early high week anchors the baseline well above the real ~54ms.
        let before = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg,
                                           baselineEpoch: Baselines.hrvBaselineEpoch(d))
        XCTAssertGreaterThan(before.baseline, 70.0)

        // User taps "Recalibrate Charge baseline" at the start of 2026-06-15.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let resetInstant = cal.date(from: comps)!.timeIntervalSince1970
        Baselines.recalibrateRecoveryBaselines(now: resetInstant, defaults: d)

        // The next computation folds the IDENTICAL history (nothing deleted) but honours the new epoch,
        // dropping the pre-reset nights and re-seeding from tonight onward.
        let after = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg,
                                          baselineEpoch: Baselines.hrvBaselineEpoch(d))
        XCTAssertEqual(after.nValid, 6)                     // only the 6 post-reset nights contribute
        XCTAssertEqual(after.baseline, 54.0, accuracy: 2.0) // re-anchored to the real value
        XCTAssertLessThan(after.baseline, before.baseline - 10.0)
    }

    /// Reset at "now" with only pre-now history drops every night → an honest calibrating cold-start,
    /// which is exactly what lets Today show the building/calibrating state again.
    func testRecalibrateNowYieldsCalibratingWhenNoNewerNights() {
        let d = makeDefaults()
        let days = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04", "2026-06-05"]
        let vals: [Double?] = [60, 61, 59, 62, 60]
        // Anchor strictly AFTER the last night so all are dropped.
        var comps = DateComponents(); comps.year = 2026; comps.month = 6; comps.day = 6
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        Baselines.recalibrateRecoveryBaselines(now: cal.date(from: comps)!.timeIntervalSince1970, defaults: d)

        let after = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg,
                                          baselineEpoch: Baselines.recoveryBaselineEpoch(d))
        XCTAssertEqual(after.nValid, 0)
        XCTAssertEqual(after.status, .calibrating)
    }

    // MARK: - "strain" MetricCfg (RecoveryScorer Activity-Balance / previous-day-Effort term)

    func testStrainCfgRegisteredWithEffortScaleBounds() {
        // Bounds match StrainScorer.maxStrain's 0-100 output scale, keyed "strain" to match the
        // existing internal metric-key convention (StrainScorer: "Internal metric key stays strain").
        XCTAssertEqual(Baselines.metricCfg["strain"]!, Baselines.strainCfg)
        XCTAssertEqual(Baselines.strainCfg.minVal, 0.0, accuracy: 1e-9)
        XCTAssertEqual(Baselines.strainCfg.maxVal, 100.0, accuracy: 1e-9)
    }

    func testStrainCfgIsBaselineRelativeOverDailyEffort() {
        // A week of moderate days then a rest day: the baseline tracks the moderate norm, and
        // the rest day reads as a clear BELOW-baseline (positive, "lighter than usual") deviation.
        let moderateWeek: [Double?] = [38, 42, 40, 36, 44, 39, 41]
        let s = Baselines.foldHistory(moderateWeek, cfg: Baselines.strainCfg)
        XCTAssertTrue(s.usable)
        XCTAssertEqual(s.baseline, 40.0, accuracy: 5.0)

        let restDay = Baselines.deviation(10.0, state: s)
        XCTAssertLessThan(restDay.z, 0, "a much-lighter-than-normal day must read BELOW the effort baseline")

        let hardDay = Baselines.deviation(85.0, state: s)
        XCTAssertGreaterThan(hardDay.z, 0, "a much-harder-than-normal day must read ABOVE the effort baseline")
    }

    // MARK: - sigma() + daytime configs (DaytimeStress baseline-relative mode)

    /// `sigma(_:)` is a pure extraction of `deviation()`'s internal conversion — must match it
    /// exactly and stay internally consistent (deviation at baseline + sigma is z == 1.0).
    func testSigmaMatchesDeviationsInternalConversion() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.hrvCfg)
        let sigma = Baselines.sigma(s)
        XCTAssertEqual(sigma, max(1.253 * s.spread, 1e-9), accuracy: 1e-9)
        let dev = Baselines.deviation(s.baseline + sigma, state: s)
        XCTAssertEqual(dev.z, 1.0, accuracy: 1e-6)
    }

    /// The new daytime_hr / daytime_rmssd configs exist, are reachable via both the dictionary
    /// and the convenience accessor, and are distinct from the nightly resting_hr/hrv configs
    /// they sit alongside (different bounds/floor — daytime HR runs warmer than nocturnal RHR).
    func testDaytimeConfigsExistAndAreDistinctFromNightlyConfigs() {
        XCTAssertEqual(Baselines.metricCfg["daytime_hr"], Baselines.daytimeHRCfg)
        XCTAssertEqual(Baselines.metricCfg["daytime_rmssd"], Baselines.daytimeRMSSDCfg)
        XCTAssertNotEqual(Baselines.daytimeHRCfg, Baselines.restingHRCfg)
        XCTAssertNotEqual(Baselines.daytimeRMSSDCfg, Baselines.hrvCfg)
    }
}
