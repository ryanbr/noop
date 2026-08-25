package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the collapsed skipped-day line (#1121). Swift twin: `SleepSkipSummaryTests`. The two must emit
 * byte-identical strings, so these expectations are spelled out rather than pattern-matched.
 */
class SleepSkipSummaryTest {

    @Test
    fun `nothing skipped stays silent`() {
        assertNull(skippedSleepDaysLine(emptyList(), 200))
    }

    @Test
    fun `one day`() {
        assertEquals(
            "sleep SKIPPED 1 day(s) — need ≥200 hrSamples: hrSamples=97 on 1 day(s): 2026-08-25",
            skippedSleepDaysLine(listOf("2026-08-25" to 97), 200),
        )
    }

    @Test
    fun `groups by count ascending and sorts days`() {
        assertEquals(
            "sleep SKIPPED 3 day(s) — need ≥200 hrSamples: " +
                "hrSamples=0 on 2 day(s): 2026-08-05, 2026-08-07; " +
                "hrSamples=97 on 1 day(s): 2026-08-25",
            skippedSleepDaysLine(
                listOf("2026-08-07" to 0, "2026-08-25" to 97, "2026-08-05" to 0), 200,
            ),
        )
    }

    @Test
    fun `every day is listed`() {
        // Lossless on purpose: a range would hide a gap, and a gap in which days lack raw HR is exactly
        // the thing an investigation is looking for.
        val days = (5..9).map { "2026-08-%02d".format(it) to 0 }
        val line = skippedSleepDaysLine(days, 200)!!
        days.forEach { assertTrue("missing ${it.first}", line.contains(it.first)) }
    }

    @Test
    fun `the collector emits once per pass and resets`() {
        val out = mutableListOf<String>()
        val c = SleepSkipCollector()
        c.add("2026-08-05", 0)
        c.add("2026-08-06", 0)
        c.emit(200) { out += it }
        assertEquals(1, out.size)
        c.reset()
        c.emit(200) { out += it }   // a pass that skipped nothing must add no line
        assertEquals(1, out.size)
    }
}
