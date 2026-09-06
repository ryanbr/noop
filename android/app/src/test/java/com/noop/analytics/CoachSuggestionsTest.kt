package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Byte-identity pin for the contextual Coach suggestion chips. The same inputs MUST produce the
 * same chip strings as the Swift twin
 * `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/CoachSuggestionsTests.swift`.
 * Cross-platform parity is the contract; if you change a chip string here, change it there in the
 * same PR.
 */
class CoachSuggestionsTest {

    private val fallback = CoachSuggestions.fallback

    /** Build a DailyMetric with only the fields the chip logic reads, everything else null. */
    private fun metric(
        day: Int, recovery: Double? = null, hrv: Double? = null,
        sleepMin: Double? = null, strain: Double? = null,
    ): DailyMetric = DailyMetric(
        deviceId = "",
        day = "%04d-01-%02d".format(2026, day),
        totalSleepMin = sleepMin,
        efficiency = null, deepMin = null, remMin = null, lightMin = null, disturbances = null,
        restingHr = null, avgHrv = hrv, recovery = recovery, strain = strain, exerciseCount = null,
        spo2Pct = null, skinTempDevC = null, respRateBpm = null, steps = null, activeKcalEst = null,
        spo2Red = null, spo2Ir = null,
    )

    // MARK: - No-data fallback

    @Test fun nilTodayReturnsFallback() {
        assertEquals(fallback, CoachSuggestions.suggestions(null, emptyList()))
    }

    @Test fun allNullFieldsReturnsFallback() {
        val today = metric(day = 10) // all four signals null
        assertEquals(fallback, CoachSuggestions.suggestions(today, emptyList()))
    }

    // MARK: - Charge bands

    @Test fun lowChargeActiveRecoveryChip() {
        val today = metric(day = 10, recovery = 20.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertEquals("Active recovery only today — what should I do?", chips.first())
        assertEquals("Analyse my sleep", chips.last())
        assertTrue(chips.size in 2..4)
    }

    @Test fun midChargeQualityOverVolumeChip() {
        val today = metric(day = 10, recovery = 50.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertEquals("Quality over volume today — plan my session", chips.first())
    }

    @Test fun highChargeGreenLightChip() {
        val today = metric(day = 10, recovery = 90.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertEquals("Green light — how hard can I push today?", chips.first())
    }

    @Test fun chargeBoundary34IsMidBand() {
        val today = metric(day = 10, recovery = 34.0)
        assertEquals(
            "Quality over volume today — plan my session",
            CoachSuggestions.suggestions(today, emptyList()).first(),
        )
    }

    @Test fun chargeBoundary67IsGreenBand() {
        val today = metric(day = 10, recovery = 67.0)
        assertEquals(
            "Green light — how hard can I push today?",
            CoachSuggestions.suggestions(today, emptyList()).first(),
        )
    }

    // MARK: - HRV trending down

    @Test fun hrvBelowBaselineAddsDownChip() {
        // 30 days of HRV ~60, then today at 45 (< 0.85 * 60 = 51).
        val recent = (1..30).map { metric(day = it, hrv = 60.0) }
        val today = metric(day = 31, recovery = 70.0, hrv = 45.0)
        val chips = CoachSuggestions.suggestions(today, recent)
        assertTrue(chips.contains("Why is my HRV trending down?"))
    }

    @Test fun hrvAtBaselineDoesNotAddDownChip() {
        val recent = (1..30).map { metric(day = it, hrv = 60.0) }
        val today = metric(day = 31, recovery = 70.0, hrv = 60.0)
        val chips = CoachSuggestions.suggestions(today, recent)
        assertFalse(chips.contains("Why is my HRV trending down?"))
    }

    @Test fun hrvBaselineExcludesToday() {
        // Today is in `recent` too; it must be excluded from the baseline so a single low day can
        // still register as "down" against the prior baseline.
        val recent = (1..30).map { metric(day = it, hrv = 60.0) } + metric(day = 31, recovery = 70.0, hrv = 45.0)
        val today = metric(day = 31, recovery = 70.0, hrv = 45.0)
        val chips = CoachSuggestions.suggestions(today, recent)
        assertTrue(chips.contains("Why is my HRV trending down?"))
    }

    // MARK: - Poor sleep

    @Test fun poorSleepAddsRecoverChip() {
        val today = metric(day = 10, recovery = 70.0, sleepMin = 300.0) // 5h
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertTrue(chips.contains("I slept poorly — how do I recover today?"))
    }

    @Test fun sixHoursIsNotPoor() {
        val today = metric(day = 10, recovery = 70.0, sleepMin = 360.0) // exactly 6h
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertFalse(chips.contains("I slept poorly — how do I recover today?"))
    }

    // MARK: - High strain

    @Test fun highStrainAddsLoadedChip() {
        val today = metric(day = 10, recovery = 70.0, strain = 16.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertTrue(chips.contains("Have I done enough today, or push more?"))
    }

    @Test fun strainBelow14DoesNotAddLoadedChip() {
        val today = metric(day = 10, recovery = 70.0, strain = 13.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertFalse(chips.contains("Have I done enough today, or push more?"))
    }

    // MARK: - Cap + stable generic

    @Test fun allSignalsFireCapsAtFour() {
        val recent = (1..30).map { metric(day = it, hrv = 60.0) }
        val today = metric(day = 31, recovery = 20.0, hrv = 40.0, sleepMin = 300.0, strain = 16.0)
        val chips = CoachSuggestions.suggestions(today, recent)
        // charge + hrv + sleep + strain + stable generic = 5 candidates → capped at 4.
        assertEquals(4, chips.size)
        // The stable generic is appended last; with the cap at 4, it is the 4th element (the 5th
        // candidate, the strain chip, is dropped). Charge is first.
        assertEquals("Active recovery only today — what should I do?", chips.first())
        assertEquals("Analyse my sleep", chips.last())
    }

    @Test fun chargeOnlyYieldsChargeAndGeneric() {
        val today = metric(day = 10, recovery = 90.0)
        val chips = CoachSuggestions.suggestions(today, emptyList())
        assertEquals(listOf("Green light — how hard can I push today?", "Analyse my sleep"), chips)
    }

    // MARK: - Byte-identity of the fallback list

    @Test fun fallbackListIsCanonical() {
        assertEquals(
            listOf(
                "How's my recovery trending this week?",
                "What should today's training look like?",
                "Analyse my sleep",
                "Why am I run down?",
            ),
            fallback,
        )
    }
}
