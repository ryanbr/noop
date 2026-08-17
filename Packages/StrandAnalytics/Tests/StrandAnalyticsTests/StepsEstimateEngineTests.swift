import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StepsEstimateEngineTests: XCTestCase {

    // MARK: motion intensity

    func testMotionIntensitySumsDeltas() {
        // Three samples: deltas of magnitude 0.3 then 0.4 → total 0.7.
        let grav = [
            GravitySample(ts: 0, x: 0, y: 0, z: 1),
            GravitySample(ts: 1, x: 0.3, y: 0, z: 1),   // Δ = 0.3
            GravitySample(ts: 2, x: 0.3, y: 0.4, z: 1), // Δ = 0.4
        ]
        XCTAssertEqual(StepsEstimateEngine.dayMotionIntensity(grav), 0.7, accuracy: 1e-9)
    }

    func testMotionIntensityEmptyAndSingle() {
        XCTAssertEqual(StepsEstimateEngine.dayMotionIntensity([]), 0)
        XCTAssertEqual(StepsEstimateEngine.dayMotionIntensity([GravitySample(ts: 0, x: 0, y: 0, z: 1)]), 0)
    }

    // MARK: calibration

    func testCalibrateFitsMedianRatio() {
        // steps/motion ratios: 100, 100, 110, 90, 100 → median 100.
        let pts = [(10.0, 1000.0), (20.0, 2000.0), (10.0, 1100.0), (10.0, 900.0), (10.0, 1000.0)]
            .map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }
        let cal = StepsEstimateEngine.calibrate(pts)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.coefficient, 100, accuracy: 1e-9)
        XCTAssertFalse(cal!.manual)
        XCTAssertEqual(cal!.sampleDays, 5)
        XCTAssertGreaterThan(cal!.confidence, 0)
    }

    func testCalibrateNilBelowMinDays() {
        let pts = [(10.0, 1000.0), (10.0, 1000.0)]   // only 2 < minCalibrationDays(3)
            .map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }
        XCTAssertNil(StepsEstimateEngine.calibrate(pts))
    }

    func testCalibrateSkipsNearStillAndZeroStepDays() {
        // Two near-still days (motion < minMotionForFit) + two zero-step days should NOT count toward the fit;
        // only the 3 real days remain, all ratio 100.
        let pts = [
            (0.2, 5000.0),   // below minMotionForFit → skipped
            (10.0, 0.0),     // zero steps → skipped
            (10.0, 1000.0), (20.0, 2000.0), (15.0, 1500.0),
        ].map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }
        let cal = StepsEstimateEngine.calibrate(pts)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.coefficient, 100, accuracy: 1e-9)
        XCTAssertEqual(cal!.sampleDays, 3)
    }

    func testCalibrateMotionWeightedHighActivityDayDrivesFit() {
        // #682: three near-still low-activity days all read ratio 50 (motion 1, steps 50); one busy day reads
        // ratio 100 (motion 100, steps 10000). The PLAIN median of [50,50,50,100] would be 50 — the low days
        // win by COUNT. The motion-weighted median lets the busy day's 100 units of motion outvote the 3 units
        // from the still days (half-mass 51.5 lands inside the busy day), so k = 100.
        let pts = [
            (1.0, 50.0), (1.0, 50.0), (1.0, 50.0),   // ratio 50, weight 1 each
            (100.0, 10000.0),                        // ratio 100, weight 100
        ].map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }
        let cal = StepsEstimateEngine.calibrate(pts)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.coefficient, 100, accuracy: 1e-9)   // weighted → busy day wins (plain median = 50)
        XCTAssertEqual(cal!.sampleDays, 4)
    }

    func testWeightedMedianReducesToPlainMedianAtEqualWeights() {
        // Equal weights must reproduce the old even-count midpoint average exactly (byte-identical fits).
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([90, 100, 110, 130], weights: [5, 5, 5, 5]),
                       105, accuracy: 1e-9)                       // plain median = (100+110)/2
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([3, 1, 2], weights: [7, 7, 7]),
                       2, accuracy: 1e-9)                         // odd count, order-independent
    }

    func testWeightedMedianFallsBackOnDegenerateWeights() {
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 2, 3], weights: []), 2, accuracy: 1e-9)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 2, 3], weights: [0, 0, 0]), 2, accuracy: 1e-9)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([], weights: []), 0, accuracy: 1e-9)
    }

    func testManualOverrideWinsWithFullConfidence() {
        let cal = StepsEstimateEngine.calibrate([], manualOverride: 123)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.coefficient, 123)
        XCTAssertTrue(cal!.manual)
        XCTAssertEqual(cal!.confidence, 1.0)
    }

    func testTightFitMoreConfidentThanScattered() {
        let tight = (0..<14).map { _ in StepsEstimateEngine.CalibrationPoint(motion: 10, steps: 1000) }
        let scattered = (0..<14).map { i in
            StepsEstimateEngine.CalibrationPoint(motion: 10, steps: Double(500 + (i % 2) * 1500))
        }
        let ct = StepsEstimateEngine.calibrate(tight)!
        let cs = StepsEstimateEngine.calibrate(scattered)!
        XCTAssertGreaterThan(ct.confidence, cs.confidence)
        XCTAssertEqual(ct.confidence, 1.0, accuracy: 1e-9)   // 14 days, zero spread
    }

    // MARK: estimate

    func testEstimateAppliesCoefficient() {
        let cal = StepsEstimateEngine.Calibration(coefficient: 100, sampleDays: 5, confidence: 0.8, manual: false)
        XCTAssertEqual(StepsEstimateEngine.estimate(motion: 87, calibration: cal), 8700)
    }

    func testEstimateNilBelowMinMotion() {
        let cal = StepsEstimateEngine.Calibration(coefficient: 100, sampleDays: 5, confidence: 0.8, manual: false)
        XCTAssertNil(StepsEstimateEngine.estimate(motion: 0.5, calibration: cal))
    }

    func testEstimateClampsAbsurd() {
        let cal = StepsEstimateEngine.Calibration(coefficient: 1_000_000, sampleDays: 5, confidence: 0.1, manual: false)
        XCTAssertEqual(StepsEstimateEngine.estimate(motion: 100, calibration: cal), StepsEstimateEngine.maxDailySteps)
    }

    // MARK: calibration status (#589 — explain a blank tile instead of going silent)

    func testStatusNeedsMoreDaysCountsUsableDays() {
        // Two usable overlapping days (< minCalibrationDays 3) → needsMoreDays with have=2, message says
        // "Need 1 more day". A near-still day and a zero-step day don't count toward `have`.
        let pts = [
            (0.2, 5000.0),     // below minMotionForFit → not usable
            (10.0, 0.0),       // zero steps → not usable
            (10.0, 1000.0), (20.0, 2000.0),
        ].map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }
        let status = StepsEstimateEngine.status(pts)
        XCTAssertEqual(status, .needsMoreDays(have: 2, need: 3))
        XCTAssertFalse(status.canEstimate)
        XCTAssertEqual(status.headline, "Need 1 more day where your phone also counted steps")
    }

    func testStatusHeadlineNoPhoneSourceIsActionableNotAFrozenCountdown() {
        // #589 follow-up: ZERO usable days (no day had both strap motion and a phone step count) — the case a
        // WHOOP 4.0 user with no phone step source connected hits. A "Need 3 more days" countdown would never
        // advance, so the headline must say what actually unblocks it. Verified via an empty set and via a set
        // whose only days are unusable (below-motion / zero-step), both of which yield have=0.
        for pts in [[StepsEstimateEngine.CalibrationPoint](),
                    [(0.2, 5000.0), (10.0, 0.0)].map { StepsEstimateEngine.CalibrationPoint(motion: $0.0, steps: $0.1) }] {
            let status = StepsEstimateEngine.status(pts)
            XCTAssertEqual(status, .needsMoreDays(have: 0, need: 3))
            XCTAssertEqual(status.headline, "Connect your phone's step count to estimate steps")
        }
    }

    func testStatusCalibratedOnceEnoughDays() {
        let pts = (0..<3).map { _ in StepsEstimateEngine.CalibrationPoint(motion: 10, steps: 1000) }
        let status = StepsEstimateEngine.status(pts)
        guard case let .calibrated(coefficient, sampleDays, confidence) = status else {
            return XCTFail("3 usable days must report .calibrated, got \(status)")
        }
        XCTAssertEqual(coefficient, 100, accuracy: 1e-9)
        XCTAssertEqual(sampleDays, 3)
        XCTAssertGreaterThan(confidence, 0)
        XCTAssertTrue(status.canEstimate)
        XCTAssertEqual(status.headline, "Estimated from 3 days your phone also counted")
    }

    func testStatusManualOverrideWinsEvenWithNoDays() {
        // A hand-set coefficient reports .manual regardless of how few overlapping days exist (the whole
        // point of the manual path — a user with no phone history can still get an estimate).
        let status = StepsEstimateEngine.status([], manualOverride: 42)
        XCTAssertEqual(status, .manual(coefficient: 42, sampleDays: 0))
        XCTAssertTrue(status.canEstimate)
        XCTAssertEqual(status.headline, "Calibrated by hand")
    }

    // MARK: calibration STATUS surfaced on the tile (#760/#792 - k / days / confidence self-explain)

    func testConfidenceTierThresholds() {
        // < 0.34 low, < 0.67 medium, else high. The boundaries are inclusive at the lower tier's top.
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.0), .low)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.33), .low)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.34), .medium)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.66), .medium)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.67), .high)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(1.0), .high)
    }

    func testStatusDetailCalibratedSurfacesKDaysAndConfidence() {
        // A low-confidence calibrated fit must SAY so (the frozen-estimate complaint #760/#792): the detail
        // names k, the day count, and the confidence tier.
        let status = StepsEstimateEngine.CalibrationStatus.calibrated(
            coefficient: 12.34, sampleDays: 6, confidence: 0.2)
        XCTAssertEqual(status.confidenceTier, .low)
        XCTAssertEqual(status.coefficient, 12.34)
        XCTAssertEqual(status.detail, "k=12.3 from 6 days, low confidence")
        // Singular day grammar.
        let one = StepsEstimateEngine.CalibrationStatus.calibrated(
            coefficient: 5.0, sampleDays: 1, confidence: 0.8)
        XCTAssertEqual(one.confidenceTier, .high)
        XCTAssertEqual(one.detail, "k=5.0 from 1 day, high confidence")
    }

    func testStatusDetailManualAndNeedsMoreDays() {
        let manual = StepsEstimateEngine.CalibrationStatus.manual(coefficient: 9.5, sampleDays: 0)
        XCTAssertEqual(manual.confidenceTier, .high)
        XCTAssertEqual(manual.coefficient, 9.5)
        XCTAssertEqual(manual.detail, "manual k=9.5")
        let needs = StepsEstimateEngine.CalibrationStatus.needsMoreDays(have: 1, need: 3)
        XCTAssertEqual(needs.confidenceTier, .low)
        XCTAssertNil(needs.coefficient)
        XCTAssertEqual(needs.detail, "calibrating: 1/3 days")
        // `have` is clamped to `need` in the fraction so it never reads more than the requirement.
        let over = StepsEstimateEngine.CalibrationStatus.needsMoreDays(have: 9, need: 3)
        XCTAssertEqual(over.detail, "calibrating: 3/3 days")
    }

    // MARK: #693 — apple-health steps + strap motion over the calibration window

    /// A day's still-with-walking-bursts gravity at 1 Hz: `bursts` short active windows separated by stillness,
    /// so `dayMotionIntensity` returns a positive, day-distinct motion volume (the strap-side input the engine
    /// pairs with the phone step count).
    private func walkingGravity(start: Int, bursts: Int) -> [GravitySample] {
        var out: [GravitySample] = []
        var t = start
        for b in 0..<bursts {
            // a 60 s active burst (oscillating gravity → real deltas) then 540 s still
            for i in 0..<60 {
                let phase = Double(i % 2) * 0.5
                out.append(GravitySample(ts: t, x: phase, y: 0, z: 1.0)); t += 1
            }
            for _ in 0..<540 { out.append(GravitySample(ts: t, x: 0, y: 0, z: 1.0)); t += 1 }
            _ = b
        }
        return out
    }

    /// #693 regression (iOS/Mac): steps calibration must advance once the phone has counted steps on
    /// >= minCalibrationDays days that ALSO have strap motion. The live bug was a wrong DATA SOURCE in
    /// IntelligenceEngine — the phone reference was read from `dailyMetrics` (always empty for steps;
    /// Apple-Health writes the count into `appleDaily.steps`, an `Int?`), so `refStepsByDay` stayed empty
    /// and the fit never had any points → "Need 3 more days" forever. This pins the calibration-point
    /// ASSEMBLY the fixed read feeds: building `CalibrationPoint`s from an apple-steps source (`Int?`) keyed
    /// by day + per-day `dayMotionIntensity` over >= 3 overlapping days yields a non-nil Calibration and a
    /// status that is NOT `needsMoreDays`.
    func testCalibrationFromAppleStepsAndStrapMotionAdvances() {
        // Five days, each with a real phone step count (the `appleDaily.steps` Int? source) AND strap motion.
        // (Day 4 carries a nil step count — the gap the engine's `if let s = r.steps` filter must skip; it
        //  contributes motion but no calibration point, exactly like a day the phone didn't count.)
        let daySecs = 86_400
        let appleSteps: [(day: String, steps: Int?)] = [
            ("2026-06-15", 8000),
            ("2026-06-16", 11000),
            ("2026-06-17", 6000),
            ("2026-06-18", nil),      // phone didn't count this day → no reference, must be skipped
            ("2026-06-19", 9000),
        ]
        // Per-day strap motion, distinct volumes (more bursts on busier days), keyed by the same day string.
        var motionByDay: [String: Double] = [:]
        for (i, e) in appleSteps.enumerated() {
            let grav = walkingGravity(start: 1_750_000_000 + i * daySecs, bursts: 6 + i)
            let m = StepsEstimateEngine.dayMotionIntensity(grav)
            XCTAssertGreaterThan(m, StepsEstimateEngine.minMotionForFit, "each active day must clear the fit floor")
            motionByDay[e.day] = m
        }

        // Build reference steps from the apple-steps source the SAME way the fixed engine does:
        // `for r in appleRows { if let s = r.steps, s > 0 { refStepsByDay[r.day] = Double(s) } }`.
        var refStepsByDay: [String: Double] = [:]
        for e in appleSteps { if let s = e.steps, s > 0 { refStepsByDay[e.day] = Double(s) } }
        XCTAssertEqual(refStepsByDay.count, 4, "the nil-step day must not enter the reference set")

        // Pair into calibration points exactly as the engine's `calPoints` does (motion + reference step).
        let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
            guard let s = refStepsByDay[day] else { return nil }
            return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
        }
        XCTAssertEqual(calPoints.count, 4, "4 overlapping (motion + phone-step) days, the nil day dropped")

        // The fix's payoff: a real fit now exists, and the status is NOT stuck on needsMoreDays.
        let cal = StepsEstimateEngine.calibrate(calPoints)
        XCTAssertNotNil(cal, "4 usable overlapping days must fit a coefficient (the #693 regression)")
        XCTAssertGreaterThan(cal!.coefficient, 0)
        XCTAssertGreaterThanOrEqual(cal!.sampleDays, StepsEstimateEngine.minCalibrationDays)

        let status = StepsEstimateEngine.status(calPoints)
        if case .needsMoreDays = status {
            XCTFail("calibration must have advanced past needsMoreDays, got \(status)")
        }
        XCTAssertTrue(status.canEstimate)
    }
}
