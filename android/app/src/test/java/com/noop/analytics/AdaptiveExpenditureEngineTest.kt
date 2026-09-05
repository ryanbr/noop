package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TDEE by energy balance — the ORACLE for the Swift twin `AdaptiveExpenditureEngineTests`.
 *
 * The identity is `expenditure = intake - stored-energy change`. Everything interesting here is about
 * refusing to answer: the method is only meaningful over weeks, and most installs will never have enough
 * logged intake to reach it.
 */
class AdaptiveExpenditureEngineTest {

    /** A synthetic history: `days` long, intake every `logEvery` days, weight every `weighEvery`. */
    private fun history(
        days: Int,
        intake: Double = 2_400.0,
        startKg: Double = 80.0,
        kgPerDay: Double = 0.0,
        logEvery: Int = 1,
        weighEvery: Int = 3,
    ): List<AdaptiveExpenditureDay> = (0 until days).map { i ->
        AdaptiveExpenditureDay(
            day = dayKey(i),
            caloriesIn = if (i % logEvery == 0) intake else null,
            weightKg = if (i % weighEvery == 0) startKg + kgPerDay * i else null,
        )
    }

    /** Sequential "yyyy-MM-dd" keys from 2026-01-01, so the engine's own date maths is exercised. */
    private fun dayKey(offset: Int): String {
        val epochDay = java.time.LocalDate.of(2026, 1, 1).toEpochDay() + offset
        return java.time.LocalDate.ofEpochDay(epochDay).toString()
    }

    /** Weight flat ⇒ expenditure equals intake. The simplest reading of the identity. */
    @Test
    fun `a stable weight puts expenditure at intake`() {
        val est = AdaptiveExpenditureEngine.estimate(history(days = 30))!!
        assertEquals(2_400.0, est.estimatedDailyKcal, 1.0)
        assertEquals(0.0, est.weightSlopeKgPerDay, 1e-9)
    }

    /**
     * Losing weight ⇒ expenditure EXCEEDED intake, so the estimate is ABOVE what was eaten. The sign is
     * the classic error in this formula, so both directions are pinned rather than one.
     */
    @Test
    fun `losing weight puts expenditure above intake`() {
        val est = AdaptiveExpenditureEngine.estimate(history(days = 30, kgPerDay = -0.05))!!
        // 0.05 kg/day * 7700 = 385 kcal/day of stored energy released.
        assertEquals(2_400.0 + 385.0, est.estimatedDailyKcal, 2.0)
        assertTrue(est.estimatedDailyKcal > est.meanIntakeKcal)
    }

    /** And the mirror: gaining weight means expenditure fell SHORT of intake. */
    @Test
    fun `gaining weight puts expenditure below intake`() {
        val est = AdaptiveExpenditureEngine.estimate(history(days = 30, kgPerDay = 0.05))!!
        assertEquals(2_400.0 - 385.0, est.estimatedDailyKcal, 2.0)
        assertTrue(est.estimatedDailyKcal < est.meanIntakeKcal)
    }

    /** Under three weeks the method is not meaningful, so it declines rather than answering. */
    @Test
    fun `a short history yields nothing`() {
        assertNull(AdaptiveExpenditureEngine.estimate(history(days = 20)))
    }

    /**
     * The gate that matters most in practice: someone logs hard for a fortnight of a long window and
     * stops. The days they skip are not a random sample of their eating, so a mean over them would read
     * as a large false deficit.
     */
    @Test
    fun `sparse intake logging yields nothing`() {
        assertNull(AdaptiveExpenditureEngine.estimate(history(days = 40, logEvery = 3)))
    }

    /** Weight is the other half of the identity; too few readings cannot establish a trend. */
    @Test
    fun `too few weigh-ins yields nothing`() {
        assertNull(AdaptiveExpenditureEngine.estimate(history(days = 30, weighEvery = 10)))
    }

    /** The output is a RANGE, and the estimate must sit inside it. */
    @Test
    fun `the estimate is bracketed by its interval`() {
        val est = AdaptiveExpenditureEngine.estimate(history(days = 30))!!
        assertTrue(est.lowerKcal < est.estimatedDailyKcal)
        assertTrue(est.upperKcal > est.estimatedDailyKcal)
    }

    /** Confidence rises with the window, coverage and number of weigh-ins — never with the value itself. */
    @Test
    fun `confidence reflects coverage not the answer`() {
        val full = AdaptiveExpenditureEngine.estimate(history(days = 35, weighEvery = 2))!!
        assertEquals(AdaptiveExpenditureConfidence.HIGH, full.confidence)
        val thin = AdaptiveExpenditureEngine.estimate(history(days = 22, weighEvery = 3))!!
        assertTrue(thin.confidence != AdaptiveExpenditureConfidence.HIGH)
    }

    /**
     * The window must hold exactly the days it claims. `dayCount` is inclusive, so a strict `<` in the
     * recency filter drops the oldest day while still reporting the full window — losing a day of data
     * and understating coverage, both silently. Every other case here logs every day, so a one-day loss
     * crosses no gate and nothing else would notice.
     */
    @Test
    fun `a fully logged window keeps every day it reports`() {
        val est = AdaptiveExpenditureEngine.estimate(history(days = 30))!!
        assertEquals(30, est.windowDays)
        assertEquals(est.windowDays, est.intakeDays)
    }

    /**
     * A duplicated day must not buy confidence. Coverage is "share of the window that was logged", so it
     * cannot exceed 1 — but a caller that merged its two sparse series badly could pass a day twice, and
     * an unclamped ratio above 1 both shrinks the interval and lifts the confidence, making the answer
     * look more certain than its data. That is the one direction this engine must never err in.
     */
    @Test
    fun `duplicated days cannot buy a narrower interval or higher confidence`() {
        val clean = history(days = 30)
        val duped = clean + clean          // every day twice
        val a = AdaptiveExpenditureEngine.estimate(clean)!!
        val b = AdaptiveExpenditureEngine.estimate(duped)!!
        val widthA = a.upperKcal - a.lowerKcal
        val widthB = b.upperKcal - b.lowerKcal
        assertEquals("a duplicate must not narrow the interval", widthA, widthB, 1e-6)
        assertEquals("nor raise the confidence", a.confidence, b.confidence)
        assertTrue("and the interval still brackets", b.lowerKcal < b.estimatedDailyKcal)
        assertTrue(b.upperKcal > b.estimatedDailyKcal)
    }

    /** A bad day key must not be read as 1970 and stretch the window by twenty thousand days. */
    @Test
    fun `an unparseable day key is refused not treated as 1970`() {
        assertNull(AdaptiveExpenditureEngine.dayCount("not-a-day", "2026-01-01"))
        assertNull(AdaptiveExpenditureEngine.dayCount("2026-01-01", ""))
    }

    /** Readings that all share one day cannot yield a slope; dividing by zero variance must return null. */
    @Test
    fun `a single-day weight cluster has no slope`() {
        assertNull(AdaptiveExpenditureEngine.leastSquaresSlope(listOf(3 to 80.0, 3 to 80.5, 3 to 79.5)))
    }
}
