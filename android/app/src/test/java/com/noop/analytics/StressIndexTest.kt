package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Swift-parity twin of StressIndexTests.swift, Baevsky Stress Index golden value + monotonicity + gates.
 */
class StressIndexTest {

    @Test
    fun goldenStressIndexHandComputed() {
        // 22 beats that all survive cleaning; in seconds span [0.70, 0.86] (MxDMn 0.16), bins at 0.05 s into
        // 4 bins with counts [3, 5, 13, 1]: modal bin index 2 (count 13), Mo = 0.825, AMo = 13/22 =
        // 59.0909..%, SI = 59.0909.. / (2*0.825*0.16) = 223.829201101928...
        val rr = listOf(700.0, 720.0, 740.0, 760.0, 780.0, 800.0, 820.0, 840.0, 860.0, 800.0, 800.0,
            800.0, 800.0, 820.0, 780.0, 800.0, 810.0, 790.0, 800.0, 800.0, 805.0, 795.0)
        val comp = StressIndex.componentsRaw(rr)
        assertNotNull(comp)
        assertEquals(0.16, comp!!.mxDMnSec, 1e-9)
        assertEquals(0.825, comp.moSec, 1e-9)
        assertEquals(59.09090909090909, comp.aMoPercent, 1e-9)
        assertEquals(223.82920110192836, comp.si, 1e-9)
        assertEquals(223.82920110192836, StressIndex.stressIndexRaw(rr)!!, 1e-9)
    }

    @Test
    fun tighterHistogramRaisesSI() {
        val broad = (0 until 30).map { 700.0 + (it % 11) * 18.0 }
        val rigid = (0 until 30).map { if (it % 6 == 0) 810.0 else 800.0 }
        val siBroad = StressIndex.stressIndexRaw(broad)
        val siRigid = StressIndex.stressIndexRaw(rigid)
        assertNotNull(siBroad)
        assertNotNull(siRigid)
        assertTrue("a rigid, tightly-clustered rhythm has a higher Stress Index", siRigid!! > siBroad!!)
    }

    @Test
    fun tooFewBeatsReturnsNull() {
        val rr = List(StressIndex.MIN_BEATS - 1) { 800.0 }
        assertNull(StressIndex.stressIndexRaw(rr))
    }

    @Test
    fun degenerateRangeReturnsNull() {
        val rr = List(30) { 800.0 }
        assertNull(StressIndex.stressIndexRaw(rr))
    }

    @Test
    fun rrIntervalOverloadMatchesRaw() {
        val raw = listOf(700.0, 720.0, 740.0, 760.0, 780.0, 800.0, 820.0, 840.0, 860.0, 800.0, 800.0,
            800.0, 800.0, 820.0, 780.0, 800.0, 810.0, 790.0, 800.0, 800.0, 805.0, 795.0)
        val rr = raw.mapIndexed { i, v -> RrInterval(deviceId = "d", ts = 1000L + i, rrMs = v.toInt()) }
        assertEquals(StressIndex.stressIndexRaw(raw)!!, StressIndex.stressIndex(rr)!!, 1e-9)
    }

    @Test
    fun mostlyRejectedSpotCaptureReturnsNull() {
        // A varied 22-beat capture that alone yields a reading, padded with out-of-range (>2000 ms) beats
        // so >35% are rejected — too noisy to label as stress (#585 spot-honesty gate).
        val valid = listOf(700.0, 720.0, 740.0, 760.0, 780.0, 800.0, 820.0, 840.0, 860.0, 800.0, 800.0,
            800.0, 800.0, 820.0, 780.0, 800.0, 810.0, 790.0, 800.0, 800.0, 805.0, 795.0)
        assertNotNull("baseline: the valid beats alone yield a reading", StressIndex.componentsRaw(valid))
        assertNull("39% rejected (14/36) is too noisy", StressIndex.componentsRaw(valid + List(14) { 2500.0 }))
        assertNotNull("24% rejected (7/29) still reads", StressIndex.componentsRaw(valid + List(7) { 2500.0 }))
    }
}
