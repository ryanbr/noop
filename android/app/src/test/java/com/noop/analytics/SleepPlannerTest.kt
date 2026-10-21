package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the display-only [SleepPlanner]. Same cases as the Swift SleepPlannerTests; the oracle block
 * holds lines printed by the Swift implementation (swiftc over SleepPlanner.swift, 144 input
 * combinations, all identical to this twin) so a drift in either direction fails here.
 */
class SleepPlannerTest {

    private fun n(day: String, min: Double?, eff: Double?) = SleepPlannerNight(day, min, eff)

    private fun line(p: SleepPlan): String =
        "${p.tonightNeedMin} ${p.napCreditMin} ${String.format(java.util.Locale.US, "%.6f", p.efficiencyUsed)} " +
            p.tiers.joinToString(" ") { "${it.sleepTargetMin}/${it.timeInBedMin}/${it.bedtimeMinuteOfDay}" }

    @Test fun noPlanUnderThreeConsecutiveNights() {
        val rows = listOf(n("2026-10-17", 420.0, 0.9), n("2026-10-19", 430.0, 0.9), n("2026-10-20", 440.0, 0.9))
        assertNull(SleepPlanner.plan(rows, 480.0, 0.0, 0.0, 420))
    }

    @Test fun consecutiveRunIgnoresEmptyRowsAndDuplicates() {
        val rows = listOf(
            "2026-10-16" to 400.0, "2026-10-17" to null, "2026-10-18" to 410.0,
            "2026-10-19" to 420.0, "2026-10-19" to 30.0, "2026-10-20" to 430.0, "2026-10-21" to null,
        )
        assertEquals(3, SleepPlanner.consecutiveNights(rows))
    }

    @Test fun consecutiveRunCrossesMonthAndLeapDay() {
        assertEquals(3, SleepPlanner.consecutiveNights(listOf("2024-02-28" to 400.0, "2024-02-29" to 400.0, "2024-03-01" to 400.0)))
        assertEquals(0, SleepPlanner.epochDay("1970-01-01"))
        assertEquals(20_746, SleepPlanner.epochDay("2026-10-20"))
        assertNull(SleepPlanner.epochDay("2026-13-01"))
    }

    @Test fun malformedDayEndsTheRun() {
        assertEquals(1, SleepPlanner.consecutiveNights(listOf("2026-10-18" to 400.0, "bad" to 400.0, "2026-10-20" to 400.0)))
    }

    @Test fun tiersWithEfficiencyAndBedtimeWrap() {
        val rows = listOf(n("2026-10-18", 420.0, 90.0), n("2026-10-19", 400.0, 0.88), n("2026-10-20", 450.0, 0.92))
        val plan = SleepPlanner.plan(rows, 480.0, 40.0, 0.0, 390)
        assertNotNull(plan)
        plan!!
        assertEquals(520, plan.tonightNeedMin)
        assertEquals(0.9, plan.efficiencyUsed, 1e-12)
        assertEquals(listOf(364, 442, 520), plan.tiers.map { it.sleepTargetMin })
        assertEquals(listOf(404, 491, 578), plan.tiers.map { it.timeInBedMin })
        assertEquals(listOf(1426, 1339, 1252), plan.tiers.map { it.bedtimeMinuteOfDay })
    }

    @Test fun napsOnlyRepayDebt() {
        val rows = listOf(n("2026-10-18", 420.0, null), n("2026-10-19", 400.0, null), n("2026-10-20", 450.0, null))
        val plan = SleepPlanner.plan(rows, 480.0, 30.0, 90.0, 420)!!
        assertEquals(30, plan.napCreditMin)
        assertEquals(480, plan.tonightNeedMin)
        assertEquals(1.0, plan.efficiencyUsed, 0.0)
        assertEquals(480, plan.tiers.last().timeInBedMin)
    }

    @Test fun efficiencyMedianAndClamp() {
        assertEquals(0.9, SleepPlanner.typicalEfficiency(listOf(0.8, null, 0.9, 95.0, 0.0))!!, 1e-12)
        assertEquals(0.5, SleepPlanner.typicalEfficiency(listOf(0.2, 0.3))!!, 1e-12)
        assertNull(SleepPlanner.typicalEfficiency(listOf(null, 0.0)))
    }

    @Test fun roundingIsHalfAwayFromZero() {
        assertEquals(511, SleepPlanner.roundHalfAway(510.5))
        assertEquals(-511, SleepPlanner.roundHalfAway(-510.5))
        assertEquals(0, SleepPlanner.roundHalfAway(0.49999999999999994))
    }

    // Swift oracle: base debt nap wake -> line, efficiencies [0.82, 91, effs[base % 5]].
    @Test fun matchesSwiftOracle() {
        val effs = listOf(null, 0.82, 91.0, 0.87, 0.95)
        fun run(b: Double, d: Double, nap: Double, w: Int): String {
            val rows = listOf(
                n("2026-10-18", 400.0, effs[1]), n("2026-10-19", 410.0, effs[2]), n("2026-10-20", 420.0, effs[b.toInt() % 5]),
            )
            return line(SleepPlanner.plan(rows, b, d, nap, w)!!)
        }
        assertEquals("420 0 0.865000 294/340/1100 357/413/1027 420/486/954", run(420.0, -5.0, 0.0, 0))
        assertEquals("480 0 0.865000 336/388/1052 408/472/968 480/555/885", run(480.0, -5.0, 0.0, 0))
        assertEquals("511 0 0.865000 357/413/7 434/502/1358 511/590/1270", run(510.5, -5.0, 0.0, 420))
        assertEquals("511 95 0.865000 357/413/1026 434/502/937 511/590/849", run(510.5, 95.0, 200.0, 1439))
    }
}
