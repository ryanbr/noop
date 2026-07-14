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
}
