package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the resting-HR strap-log line (#691). NOOP's restingHr is the deep-sleep mean HR; the line carries it
 * beside the lowest 5-min bin (floor, what NOOP reported until it read ~6 bpm under WHOOP's) and the whole
 * in-bed mean a "sleeping HR" app reports. Mirrors the Swift `IntelligenceRhrFloorMeanTests` so the two
 * platforms log byte-identical lines.
 */
class IntelligenceRhrFloorMeanTest {

    @Test
    fun allThreeStatisticsShipOnOneLine() {
        val bpms = listOf(48, 50, 52, 55, 58, 60, 62)   // mean = 55.0 → "55"
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 53, 48, bpms)
        assertEquals(
            "rhr day=2026-06-12 rhr=53 floor=48 nightMean=55 inBedSamples=7 " +
                "(rhr = deep-sleep mean = NOOP RHR; floor = lowest 5-min bin; mean = whole in-bed span)",
            line,
        )
    }

    @Test
    fun meanRoundsToNearest() {
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-13", 51, 50, listOf(50, 51, 52, 54))
        assertTrue(line, line.contains("rhr=51 floor=50 nightMean=52 inBedSamples=4"))
    }

    @Test
    fun emptyInBedAndMissingFloorReadNil() {
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 47, null, emptyList())
        assertEquals(
            "rhr day=2026-06-12 rhr=47 floor=nil nightMean=nil inBedSamples=0 " +
                "(rhr = deep-sleep mean = NOOP RHR; floor = lowest 5-min bin; mean = whole in-bed span)",
            line,
        )
    }

    @Test
    fun lineCarriesNoEmDash() {
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 50, 48, listOf(48, 60))
        assertFalse(line.contains("—"))
    }
}
