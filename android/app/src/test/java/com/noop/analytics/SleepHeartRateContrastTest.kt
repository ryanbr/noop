package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SleepHeartRateContrastTest {
    private fun filled(value: Double, count: Int): List<Double?> = List(count) { value }

    @Test
    fun lowerSleepHRProducesPositiveReduction() {
        val r = SleepHeartRateContrast.evaluate(filled(70.0, 40), filled(56.0, 40))!!
        assertEquals(70.0, r.wakeMeanBpm, 1e-12)
        assertEquals(56.0, r.sleepMeanBpm, 1e-12)
        assertEquals(-14.0, r.sleepMinusWakeBpm, 1e-12)
        assertEquals(20.0, r.sleepReductionPercent, 1e-12)   // 100*(70-56)/70
        assertEquals(1.0, r.wakeCoverage, 1e-12)
        assertEquals(1.0, r.sleepCoverage, 1e-12)
    }

    @Test
    fun higherSleepHRProducesNegativeReductionWithoutClassification() {
        val r = SleepHeartRateContrast.evaluate(filled(60.0, 40), filled(66.0, 40))!!
        assertEquals(6.0, r.sleepMinusWakeBpm, 1e-12)
        assertEquals(-10.0, r.sleepReductionPercent, 1e-12)  // 100*(60-66)/60
    }

    @Test
    fun minimumValidSampleGateAppliesIndependentlyToBothWindows() {
        val wake = filled(65.0, 30)
        val sleep = filled(55.0, 29) + listOf<Double?>(null)
        assertNull(SleepHeartRateContrast.evaluate(wake, sleep))
        assertNotNull(SleepHeartRateContrast.evaluate(filled(65.0, 30), filled(55.0, 30)))
    }

    @Test
    fun missingAndInvalidEpochsAreExcludedAndReduceCoverage() {
        val wake = filled(60.0, 30) + List(5) { null } + List(5) { 10.0 }
        val r = SleepHeartRateContrast.evaluate(wake, filled(50.0, 40))!!
        assertEquals(30, r.wakeValidSamples)
        assertEquals(40, r.wakeTotalSamples)
        assertEquals(0.75, r.wakeCoverage, 1e-12)
        assertEquals(60.0, r.wakeMeanBpm, 1e-12)             // out-of-range 10s never entered the mean
    }

    @Test
    fun unequalWindowLengthsAreAllowedAndCoverageIsPerWindow() {
        val r = SleepHeartRateContrast.evaluate(filled(70.0, 60), filled(58.0, 30))!!
        assertEquals(60, r.wakeTotalSamples)
        assertEquals(30, r.sleepTotalSamples)
        assertEquals(1.0, r.wakeCoverage, 1e-12)
        assertEquals(1.0, r.sleepCoverage, 1e-12)
    }

    @Test
    fun validityRangeEdgesAreIncluded() {
        val wake = List(15) { 30.0 } + List(15) { 220.0 } + listOf<Double?>(29.9, 220.1)
        val r = SleepHeartRateContrast.evaluate(wake, filled(60.0, 30))!!
        assertEquals(30, r.wakeValidSamples)                 // the two out-of-range edges excluded
        assertEquals(125.0, r.wakeMeanBpm, 1e-12)            // (30*15 + 220*15)/30
    }

    @Test
    fun emptyAndInvalidConfigurationFailClosed() {
        assertNull(SleepHeartRateContrast.evaluate(emptyList(), filled(60.0, 30)))
        assertNull(SleepHeartRateContrast.evaluate(filled(60.0, 30), emptyList()))
        assertNull(SleepHeartRateContrast.evaluate(filled(60.0, 30), filled(60.0, 30), minimumValidSamples = 0))
        assertNull(SleepHeartRateContrast.evaluate(filled(Double.NaN, 40), filled(60.0, 40)))
    }
}
