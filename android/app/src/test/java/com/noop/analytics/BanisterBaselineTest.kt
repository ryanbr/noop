package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1624: Banister's axis has to start where Edwards' does.
 *
 * The reported symptom was "the new exponential effort score flattens all scores" — a desk day rising
 * from ~0 to 10+ while a hard ride barely moved. The cause was structural, not observational: Edwards
 * pays nothing below 50% HRR so a sedentary day is exactly 0, while Banister pays at every intensity, so
 * sixteen waking hours of doing nothing accumulated real TRIMP. On the shipped constants a 24 h day held
 * at 5% HRR scored 0 under Edwards and 45 under Banister — the usable range squashed into the top half.
 */
class BanisterBaselineTest {
    private val rest = 50.0
    private val max = 190.0
    private var clock = 0L

    /** [minutes] of samples held at a fixed fraction of HR reserve, one sample per second. */
    private fun dayAt(hrrFraction: Double, minutes: Int): List<com.noop.data.HrSample> {
        val bpm = (rest + hrrFraction * (max - rest)).toInt()
        return (0 until minutes * 60).map {
            com.noop.data.HrSample(deviceId = "t", ts = clock++, bpm = bpm)
        }
    }

    private fun score(hr: List<com.noop.data.HrSample>, method: StrainScorer.Method): Double? =
        StrainScorer.strain(hr = hr, maxHR = max, restingHR = rest, method = method, sex = "male")

    @Test
    fun `a sedentary day scores zero under BOTH methods`() {
        // The invariant #1545 claimed and did not have: mapping the maximum to 100 puts the two on one
        // axis only if they also agree at the bottom.
        for (frac in listOf(0.0, 0.05, 0.10)) {
            clock = 0L
            val hr = dayAt(frac, 24 * 60)
            val ed = score(hr, StrainScorer.Method.EDWARDS) ?: 0.0
            val ba = score(hr, StrainScorer.Method.BANISTER) ?: 0.0
            assertEquals("edwards @ $frac", 0.0, ed, 0.01)
            assertEquals("banister @ $frac", 0.0, ba, 0.01)
        }
    }

    @Test
    fun `Banister still pays for work Edwards zeroes - the reason it exists`() {
        // The whole point of the recipe: intermittent effort that averages below Edwards' 50% HRR floor.
        // A baseline subtraction that erased this would have fixed the axis by removing the feature.
        clock = 0L
        val hr = dayAt(0.35, 90) + dayAt(0.05, 24 * 60 - 90)
        val ed = score(hr, StrainScorer.Method.EDWARDS) ?: 0.0
        val ba = score(hr, StrainScorer.Method.BANISTER) ?: 0.0
        assertEquals("edwards pays nothing below its floor", 0.0, ed, 0.01)
        assertTrue("banister must still pay: was $ba", ba > 1.0)
    }

    @Test
    fun `a harder day always outscores an easier one`() {
        clock = 0L
        val easy = score(dayAt(0.20, 24 * 60), StrainScorer.Method.BANISTER) ?: 0.0
        clock = 0L
        val hard = score(dayAt(0.60, 24 * 60), StrainScorer.Method.BANISTER) ?: 0.0
        assertTrue("monotonic: easy=$easy hard=$hard", hard > easy)
    }

    @Test
    fun `the baseline is subtracted from the ceiling too, so the top still reaches 100`() {
        // Anchoring only the bottom would trade one mismatched end for the other.
        clock = 0L
        val full = score(dayAt(1.0, 24 * 60), StrainScorer.Method.BANISTER) ?: 0.0
        assertEquals(StrainScorer.maxStrain, full, 0.5)
    }
}
