package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests HrZones.timeInZone — time-in-zone accumulation from an HR stream.
 * Pure-function tests; no DB. Kotlin twin of the StrandAnalytics HRZonesTests.
 */
class HrZonesTest {

    @Test
    fun timeInZone_capsHugePositiveGap() {
        // Regression (#366): three 1 Hz zone-1 samples (median gap 1 s), then one sample an HOUR
        // later. The 3600 s gap before the last sample must be capped at the median (1 s) — as the
        // comment promises — not credited in full, so one wear gap / sparse stretch can't blow up a
        // bucket.
        val zs = HrZones.zones(maxHR = 200.0)
        val hr = listOf(
            HrSample(deviceId = "t", ts = 0L, bpm = 110),
            HrSample(deviceId = "t", ts = 1L, bpm = 110),
            HrSample(deviceId = "t", ts = 2L, bpm = 110),
            HrSample(deviceId = "t", ts = 3602L, bpm = 110),
        )
        val tiz = HrZones.timeInZone(hr, zs)
        assertTrue(
            "a huge inter-sample gap must be capped at the median, not credited in full",
            tiz.total < 10.0,
        )
        assertEquals(tiz.total, tiz.secondsInZone(1), 1e-9) // all of it is zone 1
    }

    // --- HrZoneSetCache: coachZone runs ~1 Hz but the zone set only changes when maxHR does. ---

    /** The same maxHR reuses the exact zone-set instance (identity, not just equality) across ticks. */
    @Test fun hrZoneSetCache_reusesSetWhileMaxHrUnchanged() {
        val cache = HrZoneSetCache()
        val first = cache.zones(190.0)
        repeat(1_000) { assertSame(first, cache.zones(190.0)) }
        assertEquals(190.0, first.maxHR, 0.0)
    }

    /** A changed maxHR rebuilds. Single-entry by design (coachZone's maxHR is stable), so returning to a
     *  previous value rebuilds again rather than restoring an older instance. */
    @Test fun hrZoneSetCache_rebuildsWhenMaxHrChanges() {
        val cache = HrZoneSetCache()
        val a = cache.zones(190.0)
        val b = cache.zones(180.0)
        assertNotSame(a, b)
        assertEquals(180.0, b.maxHR, 0.0)
        val a2 = cache.zones(190.0)
        assertNotSame(a, a2)               // single-entry: not restored, rebuilt
        assertEquals(a, a2)                // but value-equal — same pure output for the same maxHR
    }

    @Test
    fun customBpmBoundariesReplacePercentageEdges() {
        val zs = HrZones.zones(
            maxHR = 200.0,
            customLowerBounds = listOf(95.0, 118.0, 142.0, 168.0, 184.0),
        )
        assertEquals("custom", zs.source)
        assertEquals(listOf(95.0, 118.0, 142.0, 168.0, 184.0), zs.zones.map { it.lower })
        assertEquals(1, zs.zoneNumber(117.0))
        assertEquals(2, zs.zoneNumber(118.0))
        assertEquals(4, zs.zoneNumber(168.0))
        assertEquals(5, zs.zoneNumber(184.0))
        assertEquals(5, zs.zoneNumber(230.0))
    }

    @Test
    fun invalidCustomBoundariesFallBackToDefaults() {
        val zs = HrZones.zones(
            maxHR = 200.0,
            customLowerBounds = listOf(100.0, 120.0, 120.0, 160.0, 180.0),
        )
        assertEquals("manual", zs.source)
        assertEquals(listOf(100.0, 120.0, 140.0, 160.0, 180.0), zs.zones.map { it.lower })
    }

    @Test
    fun defaultEditorBoundsPreserveIntegerClassification() {
        assertEquals(listOf(94, 113, 131, 150, 169), HrZones.defaultLowerBounds(187.0))
    }
}
