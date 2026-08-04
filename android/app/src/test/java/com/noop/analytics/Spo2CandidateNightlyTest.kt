package com.noop.analytics

import com.noop.data.V18AuxRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #112 / #103 — the nightly gated mean of the 5/MG SpO2 candidate byte.
 *
 * Byte-parity twin of the Swift `Spo2CandidateNightlyTests`: same fixtures, same expected values.
 *
 * This exists to make a volunteer's contribution checkable. The candidate cannot be promoted while two
 * straps disagree about it, and breaking that tie means a third wearer comparing their nightly figure
 * against the one the WHOOP app reports. Reading it off a scrolling chart is not an instrument; one
 * number is. These pin what that number counts and — more importantly — what it refuses to count.
 */
class Spo2CandidateNightlyTest {

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    private fun aux(ts: Long, v: Long?) = V18AuxRow(ts = ts, auxByte82 = v)

    @Test fun meanAndSampleCountOverTheSession() {
        val r = AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), listOf(aux(1100, 94), aux(1200, 96), aux(1300, 95)))
        assertEquals(95, r?.first)
        assertEquals(3, r?.second)
    }

    /** The count is not decoration: 3 readings and 3000 are different evidence. */
    @Test fun sampleCountTravelsWithTheMean() {
        val many = (0 until 50).map { aux(1000L + it, 93L) }
        assertEquals(50, AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(900, 600)), many)?.second)
    }

    /**
     * Out-of-band values are DIAGNOSTIC CODES and SATURATION SENTINELS, not low blood oxygen. Averaging
     * them in would produce a number that is not a percentage of anything — the most damaging thing this
     * helper could do, because the result would still look plausible.
     */
    @Test fun subSeventyAndSentinelValuesAreExcluded() {
        val r = AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)),
            listOf(aux(1100, 94), aux(1150, 3), aux(1200, 0), aux(1250, 0x80), aux(1300, 96)))
        assertEquals(95, r?.first)
        assertEquals(2, r?.second)
    }

    @Test fun daytimeSamplesOutsideTheSessionAreExcluded() {
        val r = AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), listOf(aux(500, 99), aux(1100, 94), aux(5000, 88)))
        assertEquals(1, r?.second)
        assertEquals(94, r?.first)
    }

    @Test fun nullWhenNothingInBandFallsInsideASession() {
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 600)), listOf(aux(1100, 5))))
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 600)), listOf(aux(9999, 95))))
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(emptyList(), listOf(aux(1100, 95))))
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(listOf(session(1000, 600)), emptyList()))
    }

    /** A record with no @82 at all is not a zero reading. */
    @Test fun missingBytesAreSkippedNotCountedAsZero() {
        val r = AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), listOf(aux(1100, null), aux(1200, 96)))
        assertEquals(96, r?.first)
        assertEquals(1, r?.second)
    }

    /** Boundaries are inclusive, matching the decoder's own 70..100 emit gate exactly. */
    @Test fun bandBoundariesMatchTheDecoderGate() {
        assertEquals(2, AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), listOf(aux(1100, 70), aux(1200, 100)))?.second)
        assertNull(AnalyticsEngine.nightlySpo2CandidateMean(
            listOf(session(1000, 600)), listOf(aux(1100, 69), aux(1200, 101))))
    }
}
