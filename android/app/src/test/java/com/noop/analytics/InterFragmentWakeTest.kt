package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * (#777) Out-of-bed time BETWEEN bridged main-night fragments must count as awake (WASO), not vanish.
 * Mirror of the Swift InterFragmentWakeTests — same numbers, same expectations.
 */
class InterFragmentWakeTest {

    @Test fun emptyOrSingleSpanHasNoGap() {
        assertEquals(0L, SleepStageTotals.interFragmentWakeSeconds(emptyList()))
        assertEquals(0L, SleepStageTotals.interFragmentWakeSeconds(listOf(0L to 100L)))
    }

    @Test fun sumsPositiveGapsBetweenOrderedSpans() {
        // [0,100] then [400,500] then [700,900] → gaps 300 + 200 = 500.
        val spans = listOf(0L to 100L, 400L to 500L, 700L to 900L)
        assertEquals(500L, SleepStageTotals.interFragmentWakeSeconds(spans))
    }

    @Test fun ignoresContiguousAndOverlappingSpans() {
        // Contiguous (end==start) and overlapping pairs contribute no positive gap.
        assertEquals(0L, SleepStageTotals.interFragmentWakeSeconds(listOf(0L to 100L, 100L to 200L)))
        assertEquals(0L, SleepStageTotals.interFragmentWakeSeconds(listOf(0L to 200L, 150L to 300L)))
    }

    @Test fun ordersByStartBeforeMeasuring() {
        // Same two fragments passed out of order yield the same single 300s gap.
        assertEquals(300L, SleepStageTotals.interFragmentWakeSeconds(listOf(400L to 500L, 0L to 100L)))
    }

    @Test fun extraAwakeRaisesAwakeAndLowersEfficiency() {
        // One fragment: 8 awake + 392 asleep (light 120, deep 152, rem 120) → eff = 392/400 = 0.98.
        val stages = """{"awake":8,"light":120,"deep":152,"rem":120}"""
        val base = SleepStageTotals.dailyAggregate(listOf(stages))!!
        assertEquals(0.98, base.efficiency, 1e-9)
        // Add a 20-min (1200s) out-of-bed gap as awake: asleep unchanged (392), in-bed = 400 + 20 = 420,
        // efficiency = 392/420 = 0.9333…; total sleep stays 392.
        val withGap = SleepStageTotals.dailyAggregate(listOf(stages), extraAwakeSec = 1200.0)!!
        assertEquals(392.0, withGap.totalSleepMin, 1e-9)
        assertEquals(392.0 / 420.0, withGap.efficiency, 1e-9)
        assertNotNull(withGap)
    }

    @Test fun bridgedBiphasicNightCountsTheOutOfBedGapAsAwake() {
        // Two fragments of ONE night split by a 20-min walk. Fragment A onset=0, in-bed=200min;
        // fragment B onset = 200min + 20min gap. dailyAggregateHonoringEdits should fold the 20-min gap
        // into awake, dropping efficiency below the no-gap sum.
        val aStart = 1_700_000_000L
        val aStages = """{"awake":10,"light":60,"deep":80,"rem":50}""" // in-bed 200, asleep 190
        val bStart = aStart + (200L + 20L) * 60L                       // 20-min out-of-bed gap
        val bStages = """{"awake":10,"light":60,"deep":70,"rem":60}""" // in-bed 200, asleep 190
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(aStart to aStages, bStart to bStages),
            edited = emptyMap(),
            onsetByStart = mapOf(aStart to aStart, bStart to bStart),
            offsetSec = 0L,
        )
        assertNotNull(r)
        // Asleep = 190 + 190 = 380. In-bed = 200 + 200 + 20 (gap) = 420. eff = 380/420.
        assertEquals(380.0, r!!.sleep.totalSleepMin, 1e-9)
        assertEquals(380.0 / 420.0, r.sleep.efficiency, 1e-9)
    }
}
