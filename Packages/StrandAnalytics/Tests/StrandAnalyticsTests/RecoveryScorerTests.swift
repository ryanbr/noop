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

    func testRestingHRLowestRollingMean() {
        // Two 5-min blocks: first averages 60, second averages 50 → resting = 50.
        var hr: [HRSample] = []
        let start = 1000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }        // 0..299 s
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 50)) }  // 300..599 s
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 50)
    }

    func testRestingHRNilWhenNoSamples() {
        XCTAssertNil(RecoveryScorer.restingHR([], start: 0, end: 1000))
    }

    // MARK: - #686: artifact hardening of the resting-HR floor

    func testRestingHRRejectsSingleSampleArtifactBin() {
        // A dense, well-populated bin at 55 bpm, then a SECOND 5-min bin holding exactly ONE
        // artifact beat at 30 bpm. The old min-of-bin-means took the lone-sample bin (30) as the
        // floor; with #686 a single-sample bin can't WIN, so the floor is the real 55.
        var hr: [HRSample] = []
        let start = 1000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 55)) }   // bin 0: 300 samples @55
        hr.append(HRSample(ts: start + 300, bpm: 30))                       // bin 1: ONE sample @30
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 55, "a single-sample artifact bin must not win the resting floor")
    }

    func testRestingHRRejectsSubPhysiologicalDropoutBin() {
        // Two FULLY-populated bins: a real 52 bpm bin and a dropout bin whose 300 samples all read
        // an implausible 10 bpm (decode-zero / dropout run). It clears the sample-count bar but is
        // sub-physiological, so #686 bars it from the floor → resting reads the real 52.
        var hr: [HRSample] = []
        let start = 2000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 52)) }         // real bin
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 10)) }   // dropout bin
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 52, "a sub-physiological dropout bin must not win the resting floor")
    }

    func testRestingHRKeepsGenuineLowFloor() {
        // A REAL sustained dip (a full 5-min bin at 45 bpm) is plausible AND well-populated, so it
        // still wins — the hardening must not flatten genuine athletic resting HRs.
        var hr: [HRSample] = []
        let start = 3000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 45)) }
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 45, "a genuine sustained low bin must still win the floor")
    }

    func testRestingHRFallsBackWhenNoBinQualifies() {
        // A wholly sparse window: every bin holds a single sample (none clears the count bar).
        // Rather than return nil on data present, fall back to the legacy lowest-bin-mean (here 48).
        let start = 4000
        let hr = [HRSample(ts: start + 10, bpm: 58),
                  HRSample(ts: start + 320, bpm: 48)]   // two bins, one sample each
        let r = RecoveryScorer.restingHR(hr, start: start, end: start + 600)
        XCTAssertEqual(r, 48, "with no qualifying bin, fall back to the lowest bin mean (never nil on data)")
    }

    // MARK: - Recovery Index: recoveryIndexSlope(_:start:end:)

    /// Build a synthetic in-bed HR series with a constant slope (bpm/hour) from `startBpm`,
    /// sampled every 30 s (a low-cadence strap) over `hours`. Returns the series plus its
    /// [start, end] window.
    private func slopeSeries(startBpm: Double, slopePerHour: Double, hours: Double,
                            originTs: Int = 10_000) -> (hr: [HRSample], start: Int, end: Int) {
        var hr: [HRSample] = []
        let totalSeconds = Int(hours * 3600)
        var t = 0
        while t < totalSeconds {
            let bpm = startBpm + slopePerHour * (Double(t) / 3600.0)
            hr.append(HRSample(ts: originTs + t, bpm: Int(bpm.rounded())))
            t += 30
        }
        return (hr, originTs, originTs + totalSeconds)
    }

    func testRecoveryIndexSlopeNilWhenNoSamples() {
        XCTAssertNil(RecoveryScorer.recoveryIndexSlope([], start: 0, end: 1000))
    }

    func testRecoveryIndexSlopeNilWhenTooFewBins() {
        // Only 2 five-minute bins (10 minutes) of data — below recoveryIndexMinBins — too
        // little of the night to fit a trend; must return nil, never a fabricated slope.
        var hr: [HRSample] = []
        let start = 5000
        for i in 0..<300 { hr.append(HRSample(ts: start + i, bpm: 60)) }
        for i in 0..<300 { hr.append(HRSample(ts: start + 300 + i, bpm: 55)) }
        XCTAssertNil(RecoveryScorer.recoveryIndexSlope(hr, start: start, end: start + 600))
    }

    func testRecoveryIndexSlopeRecoversMultipleDistinctInjectedSlopes() {
        // Derived-signal rule: recover MULTIPLE distinct injected slopes, not one matched case.
        // Four full-night (6 h) synthetic series: flat, mild decline, steep decline, rising.
        let flat = slopeSeries(startBpm: 62, slopePerHour: 0.0, hours: 6)
        let mild = slopeSeries(startBpm: 62, slopePerHour: -1.0, hours: 6)
        let steep = slopeSeries(startBpm: 68, slopePerHour: -4.0, hours: 6)
        let rising = slopeSeries(startBpm: 55, slopePerHour: 2.0, hours: 6)

        let flatSlope = RecoveryScorer.recoveryIndexSlope(flat.hr, start: flat.start, end: flat.end)
        let mildSlope = RecoveryScorer.recoveryIndexSlope(mild.hr, start: mild.start, end: mild.end)
        let steepSlope = RecoveryScorer.recoveryIndexSlope(steep.hr, start: steep.start, end: steep.end)
        let risingSlope = RecoveryScorer.recoveryIndexSlope(rising.hr, start: rising.start, end: rising.end)

        XCTAssertNotNil(flatSlope); XCTAssertNotNil(mildSlope)
        XCTAssertNotNil(steepSlope); XCTAssertNotNil(risingSlope)

        // Each recovered slope is close to its OWN injected value (within integer-bpm rounding
        // noise from the synthetic series), not just relatively ordered.
        XCTAssertEqual(flatSlope!, 0.0, accuracy: 0.3)
        XCTAssertEqual(mildSlope!, -1.0, accuracy: 0.3)
        XCTAssertEqual(steepSlope!, -4.0, accuracy: 0.3)
        XCTAssertEqual(risingSlope!, 2.0, accuracy: 0.3)

        // And strictly ordered steep-decline < mild-decline < flat < rising.
        XCTAssertLessThan(steepSlope!, mildSlope!)
        XCTAssertLessThan(mildSlope!, flatSlope!)
        XCTAssertLessThan(flatSlope!, risingSlope!)
    }

    // MARK: - Window endpoint: the closed [start, end] window has a closed FINAL bin

    // Both `restingHR` and `recoveryIndexSlope` prefilter ts ∈ [start, end], so a sample sitting
    // exactly ON `end` is admitted. With bins shaped [t, t+300) and a loop that stops at `end`, an
    // ALIGNED end (end - start a multiple of the bin width) left that admitted sample in no bin at
    // all: it was counted as data and then silently ignored. The final bin is therefore closed at
    // `end`. The paired non-aligned cases pin the behaviour that was already correct, so the fix
    // cannot be mistaken for a change to trailing partial bins.

    func testRestingHRAlignedEndpointSampleReachesABin() {
        // Issue #39's minimal case: start = 0, end = 300 (exactly one bin wide), five samples on
        // the endpoint. They pass the prefilter, so they must also populate the final bin — and
        // five is exactly restingHRMinBinSamples, so the bin qualifies for the floor. This case
        // already returned 60 before the fix, but only because NO bin held anything and the
        // all-sample fallback stepped in; it now flows through the bin path like any other
        // window. testRestingHREndpointSampleLandsInFinalBinOnly is where the fallback cannot
        // hide the dropped sample.
        let hr = (0..<5).map { _ in HRSample(ts: 300, bpm: 60) }
        XCTAssertEqual(RecoveryScorer.restingHR(hr, start: 0, end: 300), 60,
                       "a sample exactly on an aligned end must belong to the final bin")
    }

    func testRestingHRNonAlignedEndpointSampleReachesABin() {
        // Paired non-aligned case: end = 450 falls mid-bin, so the endpoint sample was always
        // inside the trailing partial bin. Same answer, before and after the fix.
        let hr = (0..<5).map { _ in HRSample(ts: 450, bpm: 60) }
        XCTAssertEqual(RecoveryScorer.restingHR(hr, start: 0, end: 450), 60,
                       "a sample on a non-aligned end stays in the trailing partial bin")
    }

    func testRestingHREndpointSampleLandsInFinalBinOnly() {
        // The endpoint must join the LAST bin, not leak into earlier ones: a dense 70 bpm first
        // bin plus five endpoint beats at 40 gives a floor of 40 (the endpoint bin), while the
        // 70 bpm bin is untouched. A rule that admitted ts == end into every bin would drag the
        // first bin's mean down instead.
        var hr: [HRSample] = (0..<300).map { HRSample(ts: $0, bpm: 70) }
        hr.append(contentsOf: (0..<5).map { _ in HRSample(ts: 600, bpm: 40) })
        XCTAssertEqual(RecoveryScorer.restingHR(hr, start: 0, end: 600), 40,
                       "the endpoint sample belongs to the final bin only")
    }

    func testRestingHRDegenerateZeroLengthWindow() {
        // start == end: the single instant is one closed bin. Five samples clear the count bar,
        // so the floor is their mean — the same number the all-sample fallback produced before.
        let hr = (0..<5).map { _ in HRSample(ts: 1000, bpm: 58) }
        XCTAssertEqual(RecoveryScorer.restingHR(hr, start: 1000, end: 1000), 58)
    }

    func testRecoveryIndexSlopeAlignedEndpointCompletesTheBinGate() throws {
        // Issue #39's second case: six samples over an aligned 30-minute window, the last exactly
        // on `end`. Dropping it left five bins — one short of recoveryIndexMinBins — so the gate
        // turned a complete window into nil. With the final bin closed there are six bins and a
        // slope. Expected value from the Swift oracle in Tools-free standalone form (see the
        // Kotlin twin, which pins the same literal).
        let hr = [HRSample(ts: 0, bpm: 66), HRSample(ts: 300, bpm: 64),
                  HRSample(ts: 600, bpm: 62), HRSample(ts: 900, bpm: 60),
                  HRSample(ts: 1200, bpm: 58), HRSample(ts: 1800, bpm: 54)]
        let slope = try XCTUnwrap(RecoveryScorer.recoveryIndexSlope(hr, start: 0, end: 1800),
                                  "an admitted endpoint sample must count toward the bin gate")
        XCTAssertEqual(slope, -27.428571428571423, accuracy: 1e-9)
    }

    func testRecoveryIndexSlopeStillNilWithOnlyFiveBins() {
        // The gate itself is unchanged: the same window without the endpoint sample has five
        // bins and must stay nil. Closing the final bin adds no bin where there is no sample.
        let hr = [HRSample(ts: 0, bpm: 66), HRSample(ts: 300, bpm: 64),
                  HRSample(ts: 600, bpm: 62), HRSample(ts: 900, bpm: 60),
                  HRSample(ts: 1200, bpm: 58)]
        XCTAssertNil(RecoveryScorer.recoveryIndexSlope(hr, start: 0, end: 1800))
    }

    func testRecoveryIndexSlopeNonAlignedEndpointCompletesTheBinGate() throws {
        // Paired non-aligned case: end = 1750 sits mid-bin, so the endpoint sample was already in
        // the trailing partial bin and the gate was already satisfied. Pinned so the fix is
        // visibly confined to the aligned case.
        let hr = [HRSample(ts: 0, bpm: 66), HRSample(ts: 300, bpm: 64),
                  HRSample(ts: 600, bpm: 62), HRSample(ts: 900, bpm: 60),
                  HRSample(ts: 1200, bpm: 58), HRSample(ts: 1750, bpm: 54)]
        let slope = try XCTUnwrap(RecoveryScorer.recoveryIndexSlope(hr, start: 0, end: 1750))
        XCTAssertEqual(slope, -27.428571428571423, accuracy: 1e-9)
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
