package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift StepsEstimateEngineTests — same numbers, same expectations. */
class StepsEstimateEngineTest {

    private fun g(ts: Long, x: Double, y: Double, z: Double) = GravitySample("t", ts, x, y, z)
    private fun p(motion: Double, steps: Double) = StepsEstimateEngine.CalibrationPoint(motion, steps)

    @Test fun motionIntensitySumsDeltas() {
        val grav = listOf(g(0, 0.0, 0.0, 1.0), g(1, 0.3, 0.0, 1.0), g(2, 0.3, 0.4, 1.0)) // 0.3 + 0.4
        assertEquals(0.7, StepsEstimateEngine.dayMotionIntensity(grav), 1e-9)
    }

    @Test fun motionIntensityEmptyAndSingle() {
        assertEquals(0.0, StepsEstimateEngine.dayMotionIntensity(emptyList()), 1e-9)
        assertEquals(0.0, StepsEstimateEngine.dayMotionIntensity(listOf(g(0, 0.0, 0.0, 1.0))), 1e-9)
    }

    @Test fun calibrateFitsMedianRatio() {
        // ratios 100,100,110,90,100 → median 100
        val pts = listOf(p(10.0, 1000.0), p(20.0, 2000.0), p(10.0, 1100.0), p(10.0, 900.0), p(10.0, 1000.0))
        val cal = StepsEstimateEngine.calibrate(pts)
        assertTrue(cal != null)
        assertEquals(100.0, cal!!.coefficient, 1e-9)
        assertTrue(!cal.manual)
        assertEquals(5, cal.sampleDays)
        assertTrue(cal.confidence > 0)
    }

    @Test fun calibrateNullBelowMinDays() {
        assertNull(StepsEstimateEngine.calibrate(listOf(p(10.0, 1000.0), p(10.0, 1000.0))))
    }

    @Test fun calibrateSkipsNearStillAndZeroStepDays() {
        val pts = listOf(p(0.2, 5000.0), p(10.0, 0.0), p(10.0, 1000.0), p(20.0, 2000.0), p(15.0, 1500.0))
        val cal = StepsEstimateEngine.calibrate(pts)
        assertTrue(cal != null)
        assertEquals(100.0, cal!!.coefficient, 1e-9)
        assertEquals(3, cal.sampleDays)
    }

    @Test fun calibrateMotionWeightedHighActivityDayDrivesFit() {
        // #682: three near-still days read ratio 50 (motion 1, steps 50); one busy day reads ratio 100
        // (motion 100, steps 10000). PLAIN median of [50,50,50,100] = 50 (low days win by count); the
        // motion-weighted median lets the busy day's 100 units of motion outvote the still days → k = 100.
        val pts = listOf(p(1.0, 50.0), p(1.0, 50.0), p(1.0, 50.0), p(100.0, 10000.0))
        val cal = StepsEstimateEngine.calibrate(pts)
        assertTrue(cal != null)
        assertEquals(100.0, cal!!.coefficient, 1e-9) // weighted → busy day wins (plain median = 50)
        assertEquals(4, cal.sampleDays)
    }

    @Test fun weightedMedianReducesToPlainMedianAtEqualWeights() {
        assertEquals(105.0, StepsEstimateEngine.weightedMedian(listOf(90.0, 100.0, 110.0, 130.0), listOf(5.0, 5.0, 5.0, 5.0)), 1e-9)
        assertEquals(2.0, StepsEstimateEngine.weightedMedian(listOf(3.0, 1.0, 2.0), listOf(7.0, 7.0, 7.0)), 1e-9)
    }

    @Test fun weightedMedianFallsBackOnDegenerateWeights() {
        assertEquals(2.0, StepsEstimateEngine.weightedMedian(listOf(1.0, 2.0, 3.0), emptyList()), 1e-9)
        assertEquals(2.0, StepsEstimateEngine.weightedMedian(listOf(1.0, 2.0, 3.0), listOf(0.0, 0.0, 0.0)), 1e-9)
        assertEquals(0.0, StepsEstimateEngine.weightedMedian(emptyList(), emptyList()), 1e-9)
    }

    @Test fun manualOverrideWinsFullConfidence() {
        val cal = StepsEstimateEngine.calibrate(emptyList(), manualOverride = 123.0)
        assertTrue(cal != null)
        assertEquals(123.0, cal!!.coefficient, 1e-9)
        assertTrue(cal.manual)
        assertEquals(1.0, cal.confidence, 1e-9)
    }

    @Test fun tightFitMoreConfidentThanScattered() {
        val tight = (0 until 14).map { p(10.0, 1000.0) }
        val scattered = (0 until 14).map { i -> p(10.0, (500 + (i % 2) * 1500).toDouble()) }
        val ct = StepsEstimateEngine.calibrate(tight)!!
        val cs = StepsEstimateEngine.calibrate(scattered)!!
        assertTrue(ct.confidence > cs.confidence)
        assertEquals(1.0, ct.confidence, 1e-9)
    }

    @Test fun estimateAppliesCoefficient() {
        val cal = StepsEstimateEngine.Calibration(100.0, 5, 0.8, false)
        assertEquals(8700, StepsEstimateEngine.estimate(87.0, cal))
    }

    @Test fun estimateNullBelowMinMotion() {
        val cal = StepsEstimateEngine.Calibration(100.0, 5, 0.8, false)
        assertNull(StepsEstimateEngine.estimate(0.5, cal))
    }

    @Test fun estimateClampsAbsurd() {
        val cal = StepsEstimateEngine.Calibration(1_000_000.0, 5, 0.1, false)
        assertEquals(StepsEstimateEngine.MAX_DAILY_STEPS, StepsEstimateEngine.estimate(100.0, cal))
    }

    // calibration status (#589 — explain a blank tile instead of going silent)

    @Test fun statusNeedsMoreDaysCountsUsableDays() {
        // Two usable overlapping days (< MIN_CALIBRATION_DAYS 3) → NeedsMoreDays(have=2). A near-still day
        // and a zero-step day don't count toward `have`.
        val pts = listOf(p(0.2, 5000.0), p(10.0, 0.0), p(10.0, 1000.0), p(20.0, 2000.0))
        val status = StepsEstimateEngine.status(pts)
        assertTrue(status is StepsEstimateEngine.CalibrationStatus.NeedsMoreDays)
        status as StepsEstimateEngine.CalibrationStatus.NeedsMoreDays
        assertEquals(2, status.have)
        assertEquals(3, status.need)
        assertTrue(!status.canEstimate)
        assertEquals("Need 1 more day where your phone also counted steps", status.headline)
    }

    @Test fun statusCalibratedOnceEnoughDays() {
        val pts = (0 until 3).map { p(10.0, 1000.0) }
        val status = StepsEstimateEngine.status(pts)
        assertTrue(status is StepsEstimateEngine.CalibrationStatus.Calibrated)
        status as StepsEstimateEngine.CalibrationStatus.Calibrated
        assertEquals(100.0, status.coefficient, 1e-9)
        assertEquals(3, status.sampleDays)
        assertTrue(status.confidence > 0)
        assertTrue(status.canEstimate)
        assertEquals("Estimated from 3 days your phone also counted", status.headline)
    }

    @Test fun statusManualOverrideWinsEvenWithNoDays() {
        val status = StepsEstimateEngine.status(emptyList(), manualOverride = 42.0)
        assertTrue(status is StepsEstimateEngine.CalibrationStatus.Manual)
        status as StepsEstimateEngine.CalibrationStatus.Manual
        assertEquals(42.0, status.coefficient, 1e-9)
        assertEquals(0, status.sampleDays)
        assertTrue(status.canEstimate)
        assertEquals("Calibrated by hand", status.headline)
    }

    // calibration STATUS surfaced on the tile (#760/#792 - k / days / confidence self-explain). Mirrors Swift.

    @Test fun confidenceTierThresholds() {
        assertEquals(StepsEstimateEngine.ConfidenceTier.LOW, StepsEstimateEngine.ConfidenceTier.from(0.0))
        assertEquals(StepsEstimateEngine.ConfidenceTier.LOW, StepsEstimateEngine.ConfidenceTier.from(0.33))
        assertEquals(StepsEstimateEngine.ConfidenceTier.MEDIUM, StepsEstimateEngine.ConfidenceTier.from(0.34))
        assertEquals(StepsEstimateEngine.ConfidenceTier.MEDIUM, StepsEstimateEngine.ConfidenceTier.from(0.66))
        assertEquals(StepsEstimateEngine.ConfidenceTier.HIGH, StepsEstimateEngine.ConfidenceTier.from(0.67))
        assertEquals(StepsEstimateEngine.ConfidenceTier.HIGH, StepsEstimateEngine.ConfidenceTier.from(1.0))
    }

    @Test fun statusDetailCalibratedSurfacesKDaysAndConfidence() {
        val status = StepsEstimateEngine.CalibrationStatus.Calibrated(
            coefficient = 12.34, sampleDays = 6, confidence = 0.2,
        )
        assertEquals(StepsEstimateEngine.ConfidenceTier.LOW, status.confidenceTier)
        assertEquals(12.34, status.coefficientOrNull, 1e-9)
        assertEquals("k=12.3 from 6 days, low confidence", status.detail)
        val one = StepsEstimateEngine.CalibrationStatus.Calibrated(
            coefficient = 5.0, sampleDays = 1, confidence = 0.8,
        )
        assertEquals(StepsEstimateEngine.ConfidenceTier.HIGH, one.confidenceTier)
        assertEquals("k=5.0 from 1 day, high confidence", one.detail)
    }

    @Test fun statusDetailManualAndNeedsMoreDays() {
        val manual = StepsEstimateEngine.CalibrationStatus.Manual(coefficient = 9.5, sampleDays = 0)
        assertEquals(StepsEstimateEngine.ConfidenceTier.HIGH, manual.confidenceTier)
        assertEquals(9.5, manual.coefficientOrNull, 1e-9)
        assertEquals("manual k=9.5", manual.detail)
        val needs = StepsEstimateEngine.CalibrationStatus.NeedsMoreDays(have = 1, need = 3)
        assertEquals(StepsEstimateEngine.ConfidenceTier.LOW, needs.confidenceTier)
        assertNull(needs.coefficientOrNull)
        assertEquals("calibrating: 1/3 days", needs.detail)
        val over = StepsEstimateEngine.CalibrationStatus.NeedsMoreDays(have = 9, need = 3)
        assertEquals("calibrating: 3/3 days", over.detail)
    }
}
