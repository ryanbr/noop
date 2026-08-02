package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Test

/**
 * #977 — the RSA respiratory-rate path must not splice across dropped beats. Twin of the Swift
 * `RespRateGapAwareTests`: the same vectors in the same order, because the two platforms must reach the
 * same rate from the same rows.
 *
 * `respRateFromRR` rebuilds beat times by cumulatively summing RR, which cannot represent a stretch where
 * no beats arrived: a 30-45 s dropout is stitched shut and the two sides become adjacent on the beat-time
 * axis, so the tachogram gets a discontinuity the peak-picker reads as a breath.
 *
 * The signal is `ts`, and only `ts`: these beats were lost before storage, so they were never in the list
 * to be marked, and `cleanRRGapAware` — which takes a List<Double> and has no clock — cannot see them.
 *
 * Every vector here is synthetic and says so. Inventing a "real capture" for a timing bug would be worse
 * than useless: the property under test is the relationship between `ts` and the RR sum, which a
 * fabricated capture would assert by construction.
 */
class RespRateGapAwareTest {

    /**
     * ~15 breaths/min of RSA on ~900 ms beats, with `ts` advancing consistently with the intervals.
     * [gapAfter] inserts a wall-clock jump of [gapS] after that beat index WITHOUT adding beats —
     * exactly what a dropout looks like in the store.
     */
    private fun series(beats: Int, gapAfter: Int? = null, gapS: Int = 40): List<RrInterval> {
        val rows = mutableListOf<RrInterval>()
        var t = 1_000_000L
        var carryMs = 0.0
        for (i in 0 until beats) {
            val rr = 900.0 + 60.0 * sin(2.0 * PI * i * 0.9 / 4.0)
            carryMs += rr
            if (gapAfter != null && i == gapAfter) t += gapS
            rows.add(RrInterval(deviceId = "t", ts = t, rrMs = rr.roundToInt()))
            if (carryMs >= 1000) { val whole = (carryMs / 1000).toInt(); t += whole; carryMs -= whole * 1000.0 }
        }
        return rows
    }

    /** A contiguous night is untouched — the regression guard: change nothing when clock and beats agree. */
    @Test fun contiguousNightStillProducesARate() {
        // 330 beats at ~0.9 s is ~297 s, ONE ~5-min window. Sized deliberately: with two windows a splice
        // in the first would leave the second to carry the median and the test would pass regardless.
        val rate = SleepStager.respRateFromRR(series(330), 0L, 2_000_000L)
        assertFalse("a clean series must still yield a rate", rate.isNaN())
        assertTrue("expected a plausible breathing rate, got $rate", rate in 6.0..24.0)
    }

    /** Same beat VALUES, a 40 s hole punched in the middle: the only difference is `ts`. */
    @Test fun aSplicedWindowIsNotMeasured() {
        val clean = series(330)
        val spliced = series(330, gapAfter = 165)
        assertEquals("the fixture must differ only in ts", clean.map { it.rrMs }, spliced.map { it.rrMs })
        assertTrue(SleepStager.respRateFromRR(spliced, 0L, 2_000_000L).isNaN())
    }

    /** One second of disagreement is `ts` quantisation, not a dropout. */
    @Test fun secondLevelJitterIsNotTreatedAsAGap() {
        assertFalse(SleepStager.respRateFromRR(series(330, gapAfter = 165, gapS = 1), 0L, 2_000_000L).isNaN())
    }

    /** The row filter keeps exactly what `rangeFilter` keeps — the equivalence the fix relies on. */
    @Test fun rowFilterMatchesRangeFilter() {
        val raw = listOf(250.0, 300.0, 900.0, 1500.0, 2000.0, 2001.0, 45.0)
        assertEquals(
            HrvAnalyzer.rangeFilter(raw),
            raw.filter { it >= HrvAnalyzer.RR_MIN_MS && it <= HrvAnalyzer.RR_MAX_MS },
        )
    }
}
