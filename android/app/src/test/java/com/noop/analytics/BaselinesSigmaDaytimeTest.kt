package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import kotlin.math.max

/**
 * Kotlin twin of the sigma() + daytime-config additions in BaselinesTests.swift (PR #413).
 * Pure-function tests; no DB.
 */
class BaselinesSigmaDaytimeTest {

    /**
     * sigma() is a pure extraction of deviation()'s internal conversion — must match it exactly
     * and stay internally consistent (deviation at baseline + sigma is z == 1.0).
     */
    @Test
    fun sigmaMatchesDeviationsInternalConversion() {
        val s = Baselines.foldHistory(List(14) { 50.0 }, Baselines.hrvCfg)
        val sigma = Baselines.sigma(s)
        assertEquals(max(1.253 * s.spread, 1e-9), sigma, 1e-9)
        val dev = Baselines.deviation(s.baseline + sigma, s)
        assertEquals(1.0, dev.z, 1e-6)
    }

    /**
     * The new daytime_hr / daytime_rmssd configs exist, are reachable via both the map and the
     * convenience accessor, and are distinct from the nightly resting_hr/hrv configs they sit
     * alongside (different bounds/floor — daytime HR runs warmer than nocturnal RHR).
     */
    @Test
    fun daytimeConfigsExistAndAreDistinctFromNightlyConfigs() {
        assertEquals(Baselines.daytimeHRCfg, Baselines.metricCfg["daytime_hr"])
        assertEquals(Baselines.daytimeRMSSDCfg, Baselines.metricCfg["daytime_rmssd"])
        assertNotEquals(Baselines.daytimeHRCfg, Baselines.restingHRCfg)
        assertNotEquals(Baselines.daytimeRMSSDCfg, Baselines.hrvCfg)
    }

    /** The stored skin-temp deviation rounds ties AWAY from zero like Swift's Double.rounded(): a −0.125 °C
     *  delta (an exact binary tie at 2 dp) stores −0.13, where Math.round would store −0.12. */
    @Test
    fun roundedDelta2dpRoundsNegativeTiesAwayFromZero() {
        val s = Baselines.foldHistory(List(14) { 34.0 }, Baselines.metricCfg.getValue("skin_temp"))
        assertEquals(34.0, s.baseline, 0.0)
        assertEquals(-0.13, Baselines.roundedDelta2dp(33.875, s), 0.0)
        assertEquals(0.13, Baselines.roundedDelta2dp(34.125, s), 0.0)
        assertEquals(-0.12, Math.round(-0.125 * 100.0) / 100.0, 0.0)   // the divergence being pinned
    }
}
