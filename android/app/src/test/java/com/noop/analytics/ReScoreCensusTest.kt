package com.noop.analytics

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2013: "scored N nights" cannot distinguish a day the pass never produced from a day it produced and
 * something downstream lost. The reported case looked exactly like the second and could have been the
 * first, and no line in a shared log separated them.
 */
class ReScoreCensusTest {

    private fun day(d: String, strain: Double?) =
        IntelligenceEngine.Computed(day = d, recovery = 50.0, strain = strain, sleepMin = 400.0, hrv = 40.0, rhr = 55)

    /**
     * The case that motivated this: every night scored, but Effort short of the night count. That says
     * the pass produced nothing for those days, so the loss is upstream of persistence.
     */
    @Test
    fun `a metric short of the night count is visible`() {
        val line = IntelligenceEngine.reScoreCensusLine(
            listOf(day("2026-08-29", 9.9), day("2026-08-30", null), day("2026-08-31", null)),
        )
        assertTrue(line, line.contains("3 night(s)"))
        assertTrue(line, line.contains("effort=1"))
        assertTrue(line, line.contains("charge=3"))
    }

    /** The span is named, because a window that quietly shrank is the other way days go missing. */
    @Test
    fun `the census names the day span`() {
        val line = IntelligenceEngine.reScoreCensusLine(
            listOf(day("2026-09-09", 1.0), day("2026-08-26", 2.0), day("2026-09-01", 3.0)),
        )
        assertTrue(line, line.contains("2026-08-26..2026-09-09"))
    }

    /** A pass that produced everything reads as complete, so a healthy log is not noisy to scan. */
    @Test
    fun `a complete pass reports every metric at the night count`() {
        val line = IntelligenceEngine.reScoreCensusLine(listOf(day("2026-09-01", 1.0), day("2026-09-02", 2.0)))
        listOf("charge=2", "effort=2", "sleep=2", "hrv=2", "rhr=2").forEach {
            assertTrue(line, line.contains(it))
        }
    }

    /** An empty pass says so rather than printing an empty span. */
    @Test
    fun `an empty pass is stated, not rendered as a blank range`() {
        val line = IntelligenceEngine.reScoreCensusLine(emptyList())
        assertTrue(line, line.contains("0 night(s)"))
        assertTrue(line, !line.contains(".."))
    }
}
