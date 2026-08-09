package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1169 — the primary-session mean resting-HR definition. The Android twin of the macOS
 * `PrimarySessionRestingHRTests`; same fixtures, same numbers (cross-platform parity).
 */
class PrimarySessionRestingHRTest {
    private fun s(durationSec: Double, bpm: List<Int>) = PrimarySessionRestingHR.Session(durationSec, bpm)

    /** A shorter, lower-HR nap must NOT replace the longer main night (the half the shipped `.min()` gets
     *  wrong). Longest session wins, order-independent. */
    @Test fun napDoesNotReplaceTheLongerMainNight() {
        val mainNight = s(8 * 3600.0, List(480) { 64 })
        val nap = s(40 * 60.0, List(40) { 50 })
        assertEquals(64.0, PrimarySessionRestingHR.meanHR(listOf(nap, mainNight))!!, 1e-9)
        assertEquals(64.0, PrimarySessionRestingHR.meanHR(listOf(mainNight, nap))!!, 1e-9)
    }

    /** The SAMPLE mean is unweighted, so irregular cadence weights by COUNT, not wall-time. */
    @Test fun sampleMeanIsUnweightedByCadence() {
        val bpm = List(90) { 60 } + List(10) { 40 }
        assertEquals(58.0, PrimarySessionRestingHR.meanHR(listOf(s(8 * 3600.0, bpm)))!!, 1e-9)
    }

    /** Spikes, dropouts and 0s outside 30..220 are excluded; the mean is over the valid samples only. */
    @Test fun invalidSamplesAreExcluded() {
        val bpm = List(40) { 60 } + listOf(0, 300, -5, 250)
        assertEquals(60.0, PrimarySessionRestingHR.meanHR(listOf(s(8 * 3600.0, bpm)))!!, 1e-9)
    }

    /** Below the coverage floor -> null rather than a noisy value; an all-invalid session is null too. */
    @Test fun insufficientCoverageReturnsNull() {
        assertNull(PrimarySessionRestingHR.meanHR(listOf(s(3600.0, List(5) { 60 }))))
        assertNull(PrimarySessionRestingHR.meanHR(listOf(s(3600.0, List(100) { 0 }))))
    }

    /** A constant-HR session returns exactly that value. */
    @Test fun constantHRExact() {
        assertEquals(58.0, PrimarySessionRestingHR.meanHR(listOf(s(3600.0, List(100) { 58 })))!!, 1e-9)
    }

    /** No sessions -> null. */
    @Test fun noSessionsReturnsNull() {
        assertNull(PrimarySessionRestingHR.meanHR(emptyList()))
    }

    /** Equal-duration sessions resolve to the FIRST (the documented tie rule). Locked so the selection
     *  can't silently diverge from the macOS twin under a tie — the two stdlibs must agree here. */
    @Test fun equalDurationTieSelectsFirst() {
        val a = s(6 * 3600.0, List(100) { 60 })
        val b = s(6 * 3600.0, List(100) { 50 })
        assertEquals(60.0, PrimarySessionRestingHR.meanHR(listOf(a, b))!!, 1e-9)
        assertEquals(50.0, PrimarySessionRestingHR.meanHR(listOf(b, a))!!, 1e-9)
    }

    /** The coverage threshold is a parameter, so the validation phase can tune it. */
    @Test fun coverageThresholdIsParameterised() {
        val bpm = List(12) { 62 }
        assertNull(PrimarySessionRestingHR.meanHR(listOf(s(3600.0, bpm)), minValidSamples = 20))
        assertEquals(62.0, PrimarySessionRestingHR.meanHR(listOf(s(3600.0, bpm)), minValidSamples = 10)!!, 1e-9)
    }
}
