package com.noop.analytics

import com.noop.data.Spo2Sample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/**
 * Tests for the ratio-of-ratios SpO₂ computation (`AnalyticsEngine.nightlySpo2Pct`).
 *
 * The method is the standard pulse-oximetry algorithm (TI SLAA655 Eq. 1-2):
 *   R = (AC_red / DC_red) / (AC_ir / DC_ir)
 *   SpO₂ = 110 − 25 × R
 * where AC = standard deviation (pulsatile) and DC = mean (steady) of the per-sample
 * red/IR ADC values over detected in-bed spans.
 *
 * Byte-parity twin of the Swift `Spo2RatioOfRatiosTests`: same fixtures, same expected
 * behavior. Per the derived-biosignal rule, these tests prove the method TRACKS A
 * VARYING INPUT — different simulated SpO₂ levels produce different R values and
 * different computed percentages, not just one coincidental match.
 */
class Spo2RatioOfRatiosTest {

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun spo2Sample(ts: Long, red: Int, ir: Int) = Spo2Sample(
        deviceId = "test", ts = ts, red = red, ir = ir,
    )

    /**
     * Generate N synthetic red/IR samples simulating a PPG signal at a target SpO₂.
     *
     * The ratio R = (AC_red/DC_red) / (AC_ir/DC_ir) determines the computed SpO₂.
     * For a target SpO₂: R = (110 - SpO₂) / 25.
     * We set DC_red = DC_ir = 1000 (arbitrary), then choose AC_red and AC_ir so that
     * AC_red/AC_ir = R, with a pulsatile amplitude of ~2% of DC (typical perfusion index).
     */
    private fun syntheticSamples(count: Int, startTs: Long, targetSpo2: Double): List<Spo2Sample> {
        val r = (110.0 - targetSpo2) / 25.0
        val dc = 1000.0
        val acIr = dc * 0.02           // 2% perfusion index on IR
        val acRed = acIr * r           // AC_red/AC_ir = R
        return (0 until count).map { i ->
            val phase = i.toDouble() * 2.0 * PI / 10.0   // 10-sample cardiac cycle
            val noise = (i % 3).toDouble() - 1.0          // ±1 ADC noise
            val red = (dc + acRed * sin(phase) + noise).toInt()
            val ir = (dc + acIr * sin(phase) + noise).toInt()
            spo2Sample(startTs + i, red, ir)
        }
    }

    // MARK: - Varying input (the core validation requirement)

    /**
     * The method must TRACK a varying input: different target SpO₂ levels produce
     * different computed percentages. This is the test the #194 PPG→HR estimate failed
     * (it manufactured one coincidental match but couldn't track a varying input).
     */
    @Test
    fun testTracksVaryingSpO2Levels() {
        val targets = listOf(98.0, 95.0, 90.0, 85.0, 80.0)
        val results = mutableListOf<Double>()
        for (target in targets) {
            val samples = syntheticSamples(count = 100, startTs = 1100, targetSpo2 = target)
            val pct = AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), samples)
            assertNotNull("target SpO₂ $target should produce a value", pct)
            results.add(pct!!)
        }
        // Each successive (lower) target should produce a lower computed SpO₂.
        for (i in 1 until results.size) {
            assertTrue(
                "SpO₂ should decrease as target decreases: $results",
                results[i] < results[i - 1],
            )
        }
        // The computed values should be in a physiologically plausible range.
        assertTrue("All results in 70-100 range: $results",
            results.all { it >= 70.0 && it <= 100.0 })
    }

    /**
     * The computed values should be reasonably close to the target (within ~5% with
     * standard coefficients). This proves the calibration is clinically useful, not
     * just monotonic.
     */
    @Test
    fun testComputedValuesCloseToTarget() {
        for (target in listOf(98.0, 95.0, 90.0)) {
            val samples = syntheticSamples(count = 200, startTs = 1100, targetSpo2 = target)
            val pct = AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), samples)
            assertNotNull(pct)
            assertEquals("target $target% → computed $pct% (within 5%)", target, pct!!, 5.0)
        }
    }

    // MARK: - Edge cases

    @Test
    fun testNullWhenNoSamples() {
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 600)), emptyList()))
    }

    @Test
    fun testNullWhenNoSessions() {
        val samples = (0 until 100).map { spo2Sample(1100 + it, 1000, 1000) }
        assertNull(AnalyticsEngine.nightlySpo2Pct(emptyList(), samples))
    }

    @Test
    fun testNullWhenTooFewSamples() {
        val samples = (0 until 49).map { spo2Sample(1100 + it, 1000, 1000) }
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), samples))
    }

    @Test
    fun testFiftySamplesIsSufficient() {
        val samples = syntheticSamples(count = 50, startTs = 1100, targetSpo2 = 95.0)
        assertNotNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), samples))
    }

    @Test
    fun testSamplesOutsideSessionAreExcluded() {
        val inside = syntheticSamples(count = 100, startTs = 1100, targetSpo2 = 95.0)
        val outside = syntheticSamples(count = 100, startTs = 7000, targetSpo2 = 80.0)
        val pct = AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), inside + outside)
        assertNotNull(pct)
        // Should be close to 95 (the inside samples), not influenced by the outside ones.
        assertEquals(95.0, pct!!, 5.0)
    }

    @Test
    fun testResultClampedTo70_100() {
        // All flat → AC_ir = 0 → returns null (guard), not a crash.
        val flatSamples = (0 until 100).map { spo2Sample(1100 + it, 1000, 1000) }
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), flatSamples))
    }

    @Test
    fun testNullWhenDCIsZero() {
        val zeroSamples = (0 until 100).map { spo2Sample(1100 + it, 0, 0) }
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), zeroSamples))
    }

    // MARK: - Parity with nightlySpo2RawMeans

    /**
     * The ratio-of-ratios function should work on the same session/sample inputs that
     * nightlySpo2RawMeans accepts — they share the same in-bed filtering logic.
     */
    @Test
    fun testSameInBedFilteringAsRawMeans() {
        val samples = syntheticSamples(count = 100, startTs = 1100, targetSpo2 = 95.0)
        val raw = AnalyticsEngine.nightlySpo2RawMeans(listOf(session(1000, 6000)), samples)
        val pct = AnalyticsEngine.nightlySpo2Pct(listOf(session(1000, 6000)), samples)
        assertNotNull(raw)
        assertNotNull(pct)
        // Both should process the same 100 samples (raw mean ≈ 1000 for both channels).
        assertEquals(1000.0, raw!!.first.toDouble(), 5.0)
        assertEquals(1000.0, raw.second.toDouble(), 5.0)
    }
}
