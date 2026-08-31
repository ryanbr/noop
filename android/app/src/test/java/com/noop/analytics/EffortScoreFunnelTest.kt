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
                " reserve=127.0 method=edwards trimp=0.0 strain=0.0",
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
                " reserve=127.0 method=edwards trimp=n/a strain=n/a",
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
}
