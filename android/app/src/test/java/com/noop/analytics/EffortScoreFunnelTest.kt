package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The Effort score's funnel line — the trace [StrainScorer] had none of.
 *
 * Every other engine emits one: WorkoutDetector, SleepStager, and both analytics engines. The number on
 * the Today hero ring emitted nothing, so a log could not separate "measured, and the day was genuinely
 * calm" from "could not measure". A reader looking for the second finds `workout detect`, which answers a
 * different question, and that confusion has already produced one wrong diagnosis from a real capture.
 */
class EffortScoreFunnelTest {

    @Test
    fun `a calm day reports the zero it measured`() {
        assertEquals(
            "effort score day=2026-08-31 hr=39339 enough=true hrMax=185.0(provided) rhr=58.0" +
                " reserve=127.0 method=edwards trimp=0.0 strain=0.0 zones=n/a",
            StrainScorer.scoreFunnelLine(
                day = "2026-08-31", hrSamples = 39339, enough = true,
                maxHR = 185.0, maxHRProvided = true, restingHR = 58.0,
                method = StrainScorer.Method.EDWARDS, trimp = 0.0, strain = 0.0,
            ),
        )
    }

    /**
     * The distinction the ring cannot show. A refusal and a genuine zero both render as "0"; only the
     * line says which happened, and n/a is what makes the refusal legible.
     */
    @Test
    fun `a refusal is not a zero`() {
        val line = StrainScorer.scoreFunnelLine(
            day = "2026-08-31", hrSamples = 12, enough = false,
            maxHR = 185.0, maxHRProvided = false, restingHR = 58.0,
            method = StrainScorer.Method.EDWARDS, trimp = null, strain = null,
        )
        assertEquals(
            "effort score day=2026-08-31 hr=12 enough=false hrMax=185.0(default) rhr=58.0" +
                " reserve=127.0 method=edwards trimp=n/a strain=n/a zones=n/a",
            line,
        )
    }

    /**
     * The hook must cost nothing when nobody is watching. A scoring pass re-scores many days, so a line
     * built unconditionally would be built for every one of them on every pass; `diag` defaults to null
     * and the string is only assembled when a sink is supplied.
     */
    @Test
    fun `no diag sink means no line and no behaviour change`() {
        val hr = (0 until 5).map { HrSample(deviceId = "d", ts = 1_700_000_000L + it * 60L, bpm = 60) }
        val emitted = ArrayList<String>()
        // Too little data either way, so the scores match; the point is that one emits and one does not.
        assertNull(StrainScorer.strain(hr))
        assertNull(StrainScorer.strain(hr, diag = { emitted.add(it) }, day = "2026-08-31"))
        assertEquals(1, emitted.size)
        assertEquals(true, emitted[0].startsWith("effort score day=2026-08-31 "))
    }

    // ---- Per-zone minutes (#2438) ----

    /** Shared with the Swift twin: bpm values straddling every Edwards threshold from both sides. */
    private val zoneProbe = listOf(60, 60, 60, 119, 120, 131, 132, 143, 144, 155, 156, 167, 168)

    private fun probeSamples() = zoneProbe.mapIndexed { i, bpm ->
        HrSample(deviceId = "d", ts = 1_700_000_000L + i * 60L, bpm = bpm)
    }

    /**
     * Every threshold pinned from both sides: 119 against 120, 131 against 132, and so on. A shift of one
     * zone in either direction moves at least two buckets, and an off-by-one index would empty z0.
     */
    @Test
    fun `zone minutes bucket every boundary from both sides`() {
        val hr = probeSamples()
        val durations = StrainScorer.sampleDurationsMinutes(hr)
        assertEquals(
            listOf(4.0, 2.0, 2.0, 2.0, 2.0, 1.0),
            StrainScorer.zoneMinutes(hr, 60.0, 120.0, durations),
        )
    }

    /**
     * The buckets partition exactly the duration TRIMP integrates over, so a reader can check the two
     * against each other. Credited time, not wall-clock wear: dropouts are clamped before they get here.
     */
    @Test
    fun `zone minutes partition the credited duration`() {
        val hr = probeSamples()
        val durations = StrainScorer.sampleDurationsMinutes(hr)
        assertEquals(durations.sum(), StrainScorer.zoneMinutes(hr, 60.0, 120.0, durations).sum(), 1e-9)
    }

    /**
     * z0 is the whole point: Edwards scores sub-50 %HRR time as zero, so a day spent entirely below
     * zone 1 has TRIMP 0 and was indistinguishable from an unworn day in every line NOOP emitted before.
     */
    @Test
    fun `time below zone one is visible even though it scores zero`() {
        val hr = (0 until 10).map { HrSample(deviceId = "d", ts = 1_700_000_000L + it * 60L, bpm = 70) }
        val durations = StrainScorer.sampleDurationsMinutes(hr)
        val zones = StrainScorer.zoneMinutes(hr, 60.0, 120.0, durations)
        assertEquals(0.0, StrainScorer.edwardsTRIMP(hr, 60.0, 120.0, durations), 1e-9)
        assertEquals(10.0, zones[0], 1e-9)
        assertEquals(listOf(0.0, 0.0, 0.0, 0.0, 0.0), zones.drop(1))
    }

    /** The rendered field, byte for byte against the Swift twin. */
    @Test
    fun `the line carries six zone fields`() {
        assertEquals(
            "effort score day=2026-08-31 hr=13 enough=true hrMax=180.0(provided) rhr=60.0" +
                " reserve=120.0 method=edwards trimp=26.0 strain=40.0" +
                " z0=4.0 z1=2.0 z2=2.0 z3=2.0 z4=2.0 z5=1.0",
            StrainScorer.scoreFunnelLine(
                day = "2026-08-31", hrSamples = 13, enough = true,
                maxHR = 180.0, maxHRProvided = true, restingHR = 60.0,
                method = StrainScorer.Method.EDWARDS, trimp = 26.0, strain = 40.0,
                zoneMinutes = listOf(4.0, 2.0, 2.0, 2.0, 2.0, 1.0),
            ),
        )
    }

    /**
     * A malformed list is refused rather than rendered short. Six zeros would read as a real day spent
     * entirely below zone 1, which is a measurement this line must never invent.
     */
    @Test
    fun `a wrong length list renders as not available`() {
        val line = StrainScorer.scoreFunnelLine(
            day = "2026-08-31", hrSamples = 13, enough = true,
            maxHR = 180.0, maxHRProvided = true, restingHR = 60.0,
            method = StrainScorer.Method.EDWARDS, trimp = 26.0, strain = 40.0,
            zoneMinutes = listOf(1.0, 2.0),
        )
        assertEquals(true, line.endsWith(" zones=n/a"))
    }
}
