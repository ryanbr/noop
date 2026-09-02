package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What anchors the HR-only sleep band, and why it is not the median (#1801).
 *
 * The windows here are synthetic sinusoids with KNOWN sleep hours. They cannot show that staging is
 * accurate on a real night — nothing offline can — but they do measure the one property that decides
 * whether this spine is usable at all: how much of a window it calls sleep.
 */
class SleepStagerHrOnlyAnchorTest {

    /** `aH` hours awake around `aC`+/-`aA` bpm, then `nH` hours asleep around `nC`+/-`nA`. */
    private fun window(aC: Int, aA: Int, aH: Int, nC: Int, nA: Int, nH: Int): List<HrSample> {
        val t0 = 1_788_300_000L
        val hr = ArrayList<HrSample>()
        var i = 0
        while (i < aH * 3600) { hr.add(HrSample("d", t0 + i, aC + (Math.sin(i / 500.0) * aA).toInt())); i++ }
        var j = 0
        while (j < nH * 3600) {
            hr.add(HrSample("d", t0 + aH * 3600L + j, nC + (Math.sin(j / 900.0) * nA).toInt())); j++
        }
        return hr
    }

    private fun sleepHours(hr: List<HrSample>, baseline: Double): Double =
        SleepStager.hrOnlySleepRuns(hr, baseline)
            .filter { it.stage == "sleep" }.sumOf { it.end - it.start } / 3600.0

    /** Nearest-rank, so the anchor is always a bpm the wearer actually recorded. */
    @Test
    fun `the anchor is the tenth percentile by nearest rank`() {
        val hr = (1..100).map { HrSample("d", 1_788_300_000L + it, it) }
        assertEquals(0.10, SleepStager.hrOnlyAnchorPercentile, 1e-9)
        // (100-1)*0.10 = 9.9 -> index 9 -> the 10th smallest, bpm 10.
        assertEquals(10.0, SleepStager.hrOnlyBaseline(hr)!!, 1e-9)
    }

    /**
     * The percentile index, pinned against the Swift twin's OWN output across the sizes where a
     * nearest-rank rule can disagree — n below 1/p, and either side of an exact boundary. Every value
     * below is stdout from `hrOnlyBaseline` compiled standalone, not read off the Kotlin.
     */
    @Test
    fun `the percentile index matches the Swift twin`() {
        val cases = listOf(
            1 to 1.0, 2 to 1.0, 3 to 1.0, 7 to 1.0, 10 to 1.0,
            11 to 2.0, 99 to 10.0, 100 to 10.0, 101 to 11.0, 1000 to 100.0,
        )
        for ((n, expected) in cases) {
            val hr = (1..n).map { HrSample("d", 1_788_300_000L + it, it) }
            assertEquals("n=$n", expected, SleepStager.hrOnlyBaseline(hr)!!, 1e-9)
        }
    }

    /**
     * One sort, three reads. The anchor and the trace's spread come from the SAME sorted axis, so a
     * refactor that sorts per percentile - ~160k samples three times per scored day across a 21-day
     * rescore - shows up here as a disagreement rather than only as a slower pass.
     */
    @Test
    fun `the shared percentile helper agrees with the anchor`() {
        val hr = (1..100).map { HrSample("d", 1_788_300_000L + it, it) }
        val sorted = hr.map { it.bpm.toDouble() }.sorted()
        assertEquals(
            SleepStager.hrOnlyBaseline(hr)!!,
            SleepStager.percentileOfSorted(sorted, SleepStager.hrOnlyAnchorPercentile)!!,
            1e-9,
        )
        assertEquals(50.0, SleepStager.percentileOfSorted(sorted, 0.50)!!, 1e-9)
        assertEquals(90.0, SleepStager.percentileOfSorted(sorted, 0.90)!!, 1e-9)
        assertTrue(SleepStager.percentileOfSorted(emptyList(), 0.5) == null)
    }

    /**
     * The regression this file exists for. The first draft anchored on [SleepStager.hrBaseline], the
     * window MEDIAN — which admits over half of any window by definition, because a median splits the
     * samples in half and the band then adds 5% on top. On a field-shaped day that called 14.4 h sleep
     * against a truth of 8. The percentile anchor must stay far below it.
     */
    @Test
    fun `the median anchor over-detects and the percentile anchor does not`() {
        val hr = window(74, 11, 16, 64, 5, 8)   // 24 h, 8 h of it asleep
        val median = sleepHours(hr, SleepStager.hrBaseline(hr)!!)
        val percentile = sleepHours(hr, SleepStager.hrOnlyBaseline(hr)!!)
        assertTrue("median anchor should over-detect badly, was $median", median > 13.0)
        assertTrue("percentile anchor should land near the truth of 8, was $percentile",
            percentile in 7.0..9.5)
        assertTrue("percentile must be far tighter than median", percentile < median - 4.0)
    }

    /**
     * The chosen corner errs toward UNDER-detection, deliberately: a missed night leaves "No data",
     * which is the state this feature improves on, while an invented night puts a wrong Rest on screen.
     * Two nights inside one 54 h window are under-read rather than over-read.
     */
    @Test
    fun `a long multi-night window is under-read rather than over-read`() {
        val hr = window(78, 12, 38, 60, 6, 16)   // 54 h, 16 h of it asleep
        val h = sleepHours(hr, SleepStager.hrOnlyBaseline(hr)!!)
        assertTrue("must not exceed the truth of 16 h, was $h", h <= 16.0)
        assertTrue("must still find a real night, was $h", h >= 6.0)
    }

    /** A flat sleeper — a small awake/asleep separation — is under-read, never inflated. */
    @Test
    fun `a flat sleeper is under-read never inflated`() {
        val hr = window(70, 6, 16, 58, 3, 8)
        val h = sleepHours(hr, SleepStager.hrOnlyBaseline(hr)!!)
        assertTrue("must not exceed the truth of 8 h, was $h", h <= 8.5)
    }

    /**
     * The detector's tolerance is its OWN constant, not the confirmation gate's. Equal today; this
     * pins that a future change to one cannot silently move the other.
     */
    @Test
    fun `the detector band is a separate constant from the confirmation gate`() {
        assertEquals(1.05, SleepStager.hrOnlyBandMult, 1e-9)
        assertEquals(1.05, SleepStager.hrSleepBandMult, 1e-9)
    }
}
