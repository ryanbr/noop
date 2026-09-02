package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The HR-only spine's funnel line (#1801 follow-up).
 *
 * The path shipped silent. A field log on 11.1.0 then showed `reason=no-motion` with `provided=0` and
 * no way to tell whether the spine had run and found nothing, or never ran — so the report could not
 * be acted on at all. These pin the line that answers it.
 */
class SleepStagerHrOnlyTraceTest {

    private fun hr(from: Int, bpms: List<Int>): List<HrSample> {
        val out = ArrayList<HrSample>()
        bpms.forEachIndexed { i, bpm ->
            val base = (from + i).toLong() * 60L
            repeat(6) { k -> out.add(HrSample("d", base + k * 10L, bpm)) }
        }
        return out
    }

    /** The two numbers that separate a too-tight band from a duration gate eating real runs. */
    @Test
    fun `the line names the derived threshold and the longest candidate`() {
        val line = SleepStagerTrace.hrOnlyLine(
            anchorBpm = 61.0, bandBpm = 64.05, hrP50 = 74.0, hrP90 = 88.0, epochs = 3021, runs = 48, mergedRuns = 12,
            sleepRuns = 7, longestSleepMin = 41, staged = 0, kept = 0, minSleepMin = 60,
        )
        assertEquals(
            "[sleep] hr-only spine anchorBpm=61.0 bandBpm=64.1 hrP50=74.0 hrP90=88.0 " +
                "epochs=3021 runs=48 merged=12 " +
                "sleepRuns=7 longestMin=41 staged=0 kept=0 minSleepMin=60",
            line,
        )
    }

    /** No HR at all still emits, with the anchor absent rather than a fabricated zero. */
    @Test
    fun `an absent anchor prints nil rather than zero`() {
        val line = SleepStagerTrace.hrOnlyLine(
            anchorBpm = null, bandBpm = null, hrP50 = null, hrP90 = null, epochs = 0, runs = 0, mergedRuns = 0,
            sleepRuns = 0, longestSleepMin = 0, staged = 0, kept = 0, minSleepMin = 60,
        )
        assertTrue("must not claim an anchor of 0.0", line.contains("anchorBpm=nil bandBpm=nil"))
    }

    /** The spine emits exactly once per call — that silence was the whole defect. */
    @Test
    fun `every call traces exactly once and names the anchor it used`() {
        val lines = ArrayList<String>()
        SleepStager.hrOnlySessions(hr(1000, List(200) { 120 }), emptyList(), emptyList(),
                                   traceSink = { lines.add(it) })
        assertEquals("exactly one funnel line per call", 1, lines.size)
        assertTrue("must name the anchor it used", lines[0].contains("anchorBpm=120.0"))
    }

    /**
     * A FLAT window is entirely "sleep", and that is by construction rather than a bug.
     *
     * The anchor is a percentile of the SAME window it then classifies, so with a constant heart rate
     * the tenth percentile equals the reading, the band sits 5% above it, and every epoch qualifies.
     * The spine measures a rate against that wearer's own spread; given no spread it cannot separate
     * rest from anything else. Pinned because the first draft of the test above assumed the opposite —
     * that a uniformly high heart rate would be rejected — and asserted `kept=0` on that reasoning.
     */
    @Test
    fun `a flat window is entirely in band because the anchor comes from it`() {
        val lines = ArrayList<String>()
        val kept = SleepStager.hrOnlySessions(hr(1000, List(200) { 120 }), emptyList(), emptyList(),
                                              traceSink = { lines.add(it) })
        assertTrue("a flat window yields one long run, not none", kept.isNotEmpty())
        assertTrue("and the trace says so: ${lines[0]}", lines[0].contains("sleepRuns=1"))
    }

    /**
     * The single-pass epoch count relies on `hrS` being sorted by timestamp, which `hrOnlySessions`
     * guarantees. Pinned because the zero-allocation version trades a set for that assumption, and an
     * unsorted input would silently over-count rather than fail.
     */
    @Test
    fun `distinctEpochs counts buckets in one pass over sorted input`() {
        // 10 epochs x 6 samples, already ts-ordered.
        assertEquals(10, SleepStager.distinctEpochs(hr(1000, List(10) { 60 })))
        assertEquals(1, SleepStager.distinctEpochs(hr(1000, listOf(60))))
        assertEquals(0, SleepStager.distinctEpochs(emptyList()))
    }

    /** `epochs` counts EPOCHS, not samples — the axis every other number is measured on. */
    @Test
    fun `epochs counts epochs not samples`() {
        val lines = ArrayList<String>()
        // 10 epochs x 6 samples = 60 samples.
        SleepStager.hrOnlySessions(hr(1000, List(10) { 120 }), emptyList(), emptyList(),
                                   traceSink = { lines.add(it) })
        assertTrue("expected epochs=10, got: ${lines[0]}", lines[0].contains("epochs=10 "))
    }
}
