package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the daily-steps derivation in AnalyticsEngine.analyzeDay: cumulative-counter
 * delta summation, u16 wraparound, sub-2-sample and cross-day filtering, and null-when-no-movement.
 * No DB; pure-function test. step_motion_counter@57 is a CUMULATIVE u16 counter, so the daily total
 * is the sum of positive consecutive deltas (APPROXIMATE — @57 semantics unverified vs the app).
 */
class StepsAnalyticsTest {

    private val profile = UserProfile()

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z = 1767355200).
    private val dayUtc = "2026-01-02"
    private val noonUtc = 1_767_355_200L

    private fun step(tsOffsetSec: Long, counter: Int) =
        StepSample(deviceId = "my-whoop", ts = noonUtc + tsOffsetSec, counter = counter)

    private fun stepsFor(samples: List<StepSample>): Int? =
        AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = profile).daily.steps

    @Test
    fun sumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(120, stepsFor(s))
    }

    @Test
    fun handlesU16Wraparound() {
        // 65500 -> 30 wraps: (30 - 65500) and 0xFFFF => 66 real steps (a small in-range increment, NOT a
        // huge negative); then 30 -> 90 => 60. Both deltas are < the 512 guard so both count.
        val s = listOf(step(0, 65_500), step(60, 30), step(120, 90))
        assertEquals(66 + 60, stepsFor(s))
    }

    @Test
    fun fewerThanTwoSamplesIsNull() {
        assertNull(stepsFor(emptyList()))
        assertNull(stepsFor(listOf(step(0, 500))))
    }

    @Test
    fun noForwardMovementIsNull() {
        // Flat counter across the day => no positive delta => null (not 0).
        val s = listOf(step(0, 1_000), step(60, 1_000), step(120, 1_000))
        assertNull(stepsFor(s))
    }

    @Test
    fun dropsBigGapDeltaAsBoundary() {
        // 100 -> 1000 is a 900-tick jump (a sync-gap/disconnect boundary, not real 1 Hz steps), and
        // 1000 -> 50 wrap-corrects to 64586. Both are >= the 512 guard, so both are dropped — the day
        // has no in-range increment left, so the total is null (not an inflated number).
        val s = listOf(step(0, 100), step(60, 1_000), step(120, 50))
        assertNull(stepsFor(s))
    }

    @Test
    fun jumpGuardDropsGapButKeepsRealSteps() {
        // 100 -> 300 (=200 real) ; 300 -> 1200 is a 900-tick GAP (>= 512) and is dropped ; 1200 -> 1500
        // (=300 real). Only the two in-range increments count => 200 + 300 = 500, the gap doesn't inflate.
        val s = listOf(step(0, 100), step(60, 300), step(3_600, 1_200), step(3_675, 1_500))
        assertEquals(500, stepsFor(s))
    }

    @Test
    fun oldSummingOfRawByteOvercountsVsWrapAwareDiff() {
        // THE BUG (#132/#276/#316). A realistic ascending cumulative counter sampled at 1 Hz. The OLD
        // code summed the raw running total (byte @57 alone summed) — exploding the count; the NEW
        // wrap-aware diff sums only the per-record increments and yields a sane number.
        val counters = listOf(100, 102, 102, 105, 106, 106, 109, 111, 113, 115)
        val samples = counters.mapIndexed { i, c -> step(i.toLong(), c) }
        // NEW behaviour: sum of wrap-aware deltas == last - first (all small increments, none >= 512).
        val sane = counters.last() - counters.first() // 75
        assertEquals(sane, stepsFor(samples))
        // OLD behaviour (summing the cumulative counter itself) would be vastly larger — prove the gap.
        val oldOvercount = counters.sum()
        org.junit.Assert.assertTrue(oldOvercount > sane * 10)
    }

    @Test
    fun ignoresSamplesOutsideTheTargetDay() {
        // One sample 36h before the day (in the analytics window but a different UTC day) must be excluded.
        val s = listOf(step(-36 * 3_600, 5_000), step(0, 100), step(60, 300))
        assertEquals(200, stepsFor(s)) // only the in-day 100 -> 300 delta counts
    }

    @Test
    fun daySteps_overrideCountsFullCalendarDay() {
        // The night-window `steps` only sees the early part of the day; the full calendar-day stream
        // `daySteps` also carries the late-evening samples. When daySteps is supplied the daily total
        // must come from it, so late-day movement is NOT dropped (the past-day undercount fix).
        val nightWindow = listOf(step(0, 100), step(60, 300)) // early only
        val fullDay = listOf(
            step(0, 100), step(60, 300),       // morning: 200
            step(10 * 3_600, 700),             // evening samples present only in the full-day stream
            step(11 * 3_600, 1_100),
        )
        val total = AnalyticsEngine.analyzeDay(
            day = dayUtc, steps = nightWindow, daySteps = fullDay, profile = profile,
        ).daily.steps
        // deltas over the full day: 100->300=200, 300->700=400, 700->1100=400 => 1000 (all < 512 guard).
        assertEquals(1_000, total)
    }

    @Test
    fun daySteps_nullFallsBackToWindowSteps() {
        // No calendar-day stream supplied (pure-function callers / old tests) -> total falls back to
        // the night-window `steps` exactly as before.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220)) // 50 + 70 = 120
        assertEquals(120, AnalyticsEngine.analyzeDay(day = dayUtc, steps = s, profile = profile).daily.steps)
    }

    // MARK: - Step-scale calibration (#139). Mirrors the Swift StepsDailyTests vectors.

    private fun stepsFor(samples: List<StepSample>, ticksPerStep: Double): Int? =
        AnalyticsEngine.analyzeDay(
            day = dayUtc, steps = samples, profile = UserProfile(stepTicksPerStep = ticksPerStep),
        ).daily.steps

    @Test
    fun ticksPerStepTwoHalvesTheTotal() {
        // 120 raw ticks at 2.0 ticks/step => 60 steps.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(60, stepsFor(s, ticksPerStep = 2.0))
    }

    @Test
    fun ticksPerStepHalvingRoundsToNearest() {
        // 121 raw ticks at 2.0 => 60.5, rounded to nearest => 61.
        val s = listOf(step(0, 100), step(60, 150), step(120, 221))
        assertEquals(61, stepsFor(s, ticksPerStep = 2.0))
    }

    @Test
    fun ticksPerStepDefaultIsRawPassThrough() {
        // Default 1.0 (and an explicit 1.0) must leave the total untouched — no behavior
        // change until the user calibrates.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(120, stepsFor(s))
        assertEquals(120, stepsFor(s, ticksPerStep = 1.0))
    }

    @Test
    fun ticksPerStepClampsAtFloor() {
        // A divisor below the 0.5 floor clamps: it can at most double the total, never
        // explode it. 120 / 0.5 = 240 even when the profile says 0.1.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(240, stepsFor(s, ticksPerStep = 0.1))
    }
}
