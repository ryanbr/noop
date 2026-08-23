package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1545: why a day produced no workout, counted at each gate the detector actually applies.
 *
 * The `effort bout` line explains a bout that EXISTS, so it is silent on the harder report — a strap log
 * with 37 days and zero detected workouts, where every gate looks equally plausible from outside. These
 * tests pin that the funnel separates the causes rather than just confirming the zero.
 *
 * Byte-parity twin of Swift `DetectionFunnelTests`.
 */
class DetectionFunnelTest {

    private val dev = "t"
    private fun hrs(n: Int, bpm: Int, from: Int = 0) =
        (from until from + n).map { HrSample(dev, it.toLong(), bpm) }

    /** Motion that genuinely varies — a constant vector has zero intensity and detects nothing. */
    private fun moving(n: Int, from: Int = 0) = (from until from + n).map {
        GravitySample(dev, it.toLong(), x = if (it % 2 == 0) 0.9 else 0.5, y = 0.1, z = 0.1)
    }

    /** Motion that is present but perfectly still — samples exist, intensity never clears the gate. */
    private fun still(n: Int) = (0 until n).map {
        GravitySample(dev, it.toLong(), x = 0.9, y = 0.1, z = 0.1)
    }

    private fun funnelOf(
        hr: List<HrSample>, grav: List<GravitySample>,
        restingHR: Double? = 60.0, maxHR: Double? = 190.0,
    ): WorkoutDetector.DetectionFunnel {
        var f: WorkoutDetector.DetectionFunnel? = null
        WorkoutDetector.detect(hr = hr, gravity = grav, restingHR = restingHR, maxHR = maxHR,
                               age = 30.0, funnel = { f = it })
        assertNotNull("the funnel must be reported on every exit", f)
        return f!!
    }

    /**
     * The reporter's case: a day that yields nothing, and the funnel says WHICH gate ate it.
     *
     * Here the body is still — motion rows exist in quantity, none clear the intensity threshold. That is
     * the WHOOP 4.0 coarse-motion suspicion (#345/#28) and it must be distinguishable from a quiet heart.
     */
    @Test
    fun aStillDayNamesMotionAsTheGateThatAteIt() {
        val f = funnelOf(hrs(3600, 150), still(3600))
        assertEquals(0, f.kept)
        assertTrue("motion rows were present: $f", f.motionSamples > 0)
        assertEquals("no sample cleared the motion gate", 0, f.motionPassed)
        assertEquals(0, f.active)
        // HR was never even consulted, so the HR counters must stay clean rather than implicating it.
        assertEquals(0, f.hrMissing)
        assertEquals(0, f.hrTooLow)
    }

    /**
     * The opposite cause, which a bout count of zero reports identically: plenty of motion, but the heart
     * never cleared resting + 15. Blaming the sensor here would send someone chasing the wrong fault.
     */
    @Test
    fun aMovingButUnexertedDayNamesHRAsTheGateThatAteIt() {
        val f = funnelOf(hrs(3600, 62), moving(3600))       // floor = 60 + 15 = 75
        assertEquals(0, f.kept)
        assertTrue("motion cleared its gate: $f", f.motionPassed > 0)
        assertTrue("HR is what rejected them: $f", f.hrTooLow > 0)
        assertEquals("not a sensor gap", 0, f.hrMissing)
        assertEquals(0, f.active)
    }

    /** A sensor dropout is a third cause again: motion is there, HR simply is not. */
    @Test
    fun aMissingHrStreamIsNotConfusedWithALowHeartRate() {
        val f = funnelOf(hrs(60, 150), moving(3600))         // HR only for the first minute
        assertTrue("HR gaps must be counted as gaps: $f", f.hrMissing > 0)
        assertEquals("nothing was rejected for being too low", 0, f.hrTooLow)
    }

    /** Real work, but under the five-minute bar — the funnel must say "short", not blame a sensor. */
    @Test
    fun aShortEffortIsNamedAsShort() {
        // Two minutes of qualifying work inside an otherwise resting hour.
        val hr = hrs(600, 60) + hrs(120, 150, from = 600) + hrs(2880, 60, from = 720)
        val f = funnelOf(hr, moving(3600))
        assertEquals(0, f.kept)
        assertTrue("a run was formed: $f", f.runs > 0)
        assertTrue("and rejected for duration: $f", f.droppedShort > 0)
    }

    /** The happy path still reports, and reports a survivor — the funnel is not a failure-only line. */
    @Test
    fun aRealWorkoutIsCountedAsKept() {
        val hr = hrs(600, 60) + hrs(2400, 150, from = 600) + hrs(600, 60, from = 3000)
        val f = funnelOf(hr, moving(3600))
        assertTrue("expected a detected bout: $f", f.kept > 0)
        assertTrue(f.active > 0)
        assertEquals(f.hrSamples, 3600)
    }

    /** The thresholds the day was judged against are reported, not left for the reader to guess. */
    @Test
    fun itReportsTheBarTheDayHadToClear() {
        val f = funnelOf(hrs(3600, 62), moving(3600))
        assertEquals(60.0, f.restingHR!!, 1e-9)
        assertEquals(75.0, f.hrFloor!!, 1e-9)   // resting + hrMarginBPM (15)
    }

    /** An empty day still reports — the early return must not skip the funnel. */
    @Test
    fun aDayWithNoDataStillReports() {
        val f = funnelOf(emptyList(), emptyList())
        assertEquals(0, f.hrSamples)
        assertEquals(0, f.motionSamples)
        assertEquals(0, f.kept)
    }

    /** The exact bytes. Compared between two users' logs and across platforms, so the shape is contract. */
    @Test
    fun theLineIsExactlyThis() {
        val f = WorkoutDetector.DetectionFunnel(
            hrSamples = 34137, motionSamples = 34136, restingHR = 59.0, hrFloor = 74.0,
            motionPassed = 1203, hrMissing = 12, hrTooLow = 1103, active = 88,
            runs = 6, bridged = 4, droppedShort = 4, droppedNoHR = 0, droppedLowIntensity = 0, kept = 0,
        )
        assertEquals(
            "effort detect day=2026-08-24 hr=34137 motion=34136 restHR=59 floor=74 " +
                "motionOK=1203 hrMissing=12 hrTooLow=1103 active=88 runs=6 bridged=4 " +
                "short=4 noHR=0 lowIntensity=0 kept=0",
            WorkoutDetector.detectionFunnelLine("2026-08-24", f),
        )
    }
}
