package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins VitalBands — the Health Monitor's personal-baseline banding. Mirrors
 * StrandAnalyticsTests/VitalBandsTests.swift case-for-case with identical numbers, so the
 * two platforms can never band the same vital differently.
 */
class VitalBandsTest {

    private val hrvCfg = Baselines.metricCfg.getValue("hrv")
    private val hrvPop = 40.0..120.0

    @Test
    fun nullValue_isNoData() {
        val r = VitalBands.band(null, listOf(50.0), hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.NO_DATA, r.band)
    }

    // THE MOTIVATING CASE: a personal-normal HRV of 35 ms with the population band at 40-120.
    // Below the trust gate it is still judged against the population, hence out-of-range.
    @Test
    fun lowHrv_below14Nights_populationOutOfRange() {
        val r = VitalBands.band(35.0, List(10) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
        assertEquals(10, r.nights)
    }

    // The fix: at 14 trusted nights the same 35 ms is in-range against the user's OWN baseline.
    @Test
    fun lowHrv_at14Nights_personalInRange() {
        val r = VitalBands.band(35.0, List(14) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.IN_RANGE, r.band)
        assertEquals(VitalBands.Basis.PERSONAL, r.basis)
        assertEquals(14, r.nights)
    }

    @Test
    fun personal_bigDeviation_outOfRange() {
        // Constant 35 → spread floors out; z(70) is far above the 2σ gate.
        val r = VitalBands.band(70.0, List(30) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.PERSONAL, r.basis)
    }

    @Test
    fun personal_justInside2Sigma_inRange() {
        val hist: List<Double?> = List(30) { 35.0 }
        val state = Baselines.foldHistory(hist, hrvCfg)
        // 1.99σ in σ-space (1.253×spread ≈ σ): strictly inside the 2σ gate.
        val edge = state.baseline + 1.99 * 1.253 * state.spread
        assertEquals(VitalBands.Band.IN_RANGE, VitalBands.band(edge, hist, hrvPop, hrvCfg).band)
    }

    @Test
    fun implausibleValue_alwaysOutOfRange_evenWithTrustedBaseline() {
        // hrv cfg bounds 5-250: 300 is implausible regardless of personal spread.
        val r = VitalBands.band(300.0, List(30) { 35.0 }, hrvPop, hrvCfg)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun nullCfg_spo2_staysPopulationOnly() {
        val r = VitalBands.band(93.0, emptyList(), 95.0..100.0, null)
        assertEquals(VitalBands.Band.OUT_OF_RANGE, r.band)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun nullNights_doNotCountTowardTrust() {
        // 13 valid nights then 10 trailing skips → only 13 valid → provisional, still population.
        val hist: List<Double?> = (1..13).map { 35.0 } + List(10) { null }
        val r = VitalBands.band(35.0, hist, hrvPop, hrvCfg)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun staleBaseline_fallsBackToPopulation() {
        // 20 valid nights then 20 missing (> staleDays = 14): status STALE → population.
        val hist: List<Double?> = List(20) { 35.0 } + List(20) { null }
        val r = VitalBands.band(35.0, hist, hrvPop, hrvCfg)
        assertEquals(VitalBands.Basis.POPULATION, r.basis)
    }

    @Test
    fun skinTempHistory_partitionsMixedSemantics() {
        // 34.1/33.8 are absolute °C; 0.2/-0.1 are deviations. Each displayed kind keeps only its own.
        val mixed: List<Double?> = listOf(34.1, 0.2, null, 33.8, -0.1)
        assertEquals(listOf(null, 0.2, null, null, -0.1), VitalBands.skinTempHistory(0.3, mixed))
        assertEquals(listOf(34.1, null, null, 33.8, null), VitalBands.skinTempHistory(34.0, mixed))
    }

    @Test
    fun calendarSeries_padsMissingDays() {
        val rows = listOf<Pair<String, Double?>>("2026-06-01" to 50.0, "2026-06-04" to 52.0)
        assertEquals(listOf(50.0, null, null, 52.0), VitalBands.calendarSeries(rows))
    }

    @Test
    fun calendarSeries_dropsMalformedKeys_emptyIsEmpty() {
        assertEquals(emptyList<Double?>(), VitalBands.calendarSeries(emptyList()))
        val rows = listOf<Pair<String, Double?>>("not-a-date" to 1.0, "2026-06-01" to 50.0)
        assertEquals(listOf(50.0), VitalBands.calendarSeries(rows))
    }
}
