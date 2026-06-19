package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * Kotlin parity for StrandAnalytics/LabBookProjectionTests.swift — SAME fixtures, SAME
 * results. The same Lab Book readings must produce byte-identical daily projections and
 * windowed pairs on both platforms (the project's standard Swift/Kotlin parity footgun).
 */
class LabBookProjectionTest {

    private fun r(key: String, day: String, value: Double, takenAt: Double) =
        LabReading(markerKey = key, day = day, value = value, takenAtEpoch = takenAt)

    // MARK: - daily fold: latest-per-day

    @Test
    fun project_latestPerDay() {
        val readings = listOf(
            r("ldl", "2026-01-10", 3.4, 1_736_500_000.0),
            r("ldl", "2026-01-10", 3.0, 1_736_590_000.0), // later same day
            r("ldl", "2026-03-10", 2.8, 1_741_600_000.0),
        )
        val proj = LabBookProjection.project(readings, DailyFold.LATEST)
        assertEquals(
            listOf(
                ProjectedPoint("ldl", "2026-01-10", 3.0),
                ProjectedPoint("ldl", "2026-03-10", 2.8),
            ),
            proj,
        )
    }

    // MARK: - daily fold: mean-per-day

    @Test
    fun project_meanPerDay() {
        val readings = listOf(
            r("bp_systolic", "2026-02-01", 120.0, 1_738_400_000.0),
            r("bp_systolic", "2026-02-01", 130.0, 1_738_410_000.0), // same day → mean 125
            r("bp_systolic", "2026-02-02", 118.0, 1_738_490_000.0),
        )
        val proj = LabBookProjection.project(readings, DailyFold.MEAN)
        assertEquals(
            listOf(
                ProjectedPoint("bp_systolic", "2026-02-01", 125.0),
                ProjectedPoint("bp_systolic", "2026-02-02", 118.0),
            ),
            proj,
        )
    }

    // MARK: - deterministic ordering across markers

    @Test
    fun project_sortsByMarkerThenDay() {
        val readings = listOf(
            r("hdl", "2026-03-10", 1.4, 3.0),
            r("ldl", "2026-01-10", 3.4, 1.0),
            r("hdl", "2026-01-10", 1.2, 2.0),
        )
        val proj = LabBookProjection.project(readings, DailyFold.LATEST)
        assertEquals(
            listOf("hdl@2026-01-10", "hdl@2026-03-10", "ldl@2026-01-10"),
            proj.map { "${it.markerKey}@${it.day}" },
        )
    }

    // MARK: - BP pair: two distinct keys project independently

    @Test
    fun bpPair_projectsTwoKeys() {
        val readings = listOf(
            r(LabBookProjection.BP_SYSTOLIC_KEY, "2026-02-01", 122.0, 1.0),
            r(LabBookProjection.BP_DIASTOLIC_KEY, "2026-02-01", 78.0, 1.0),
        )
        val proj = LabBookProjection.project(readings, DailyFold.LATEST)
        assertEquals(
            listOf(
                ProjectedPoint("bp_diastolic", "2026-02-01", 78.0),
                ProjectedPoint("bp_systolic", "2026-02-01", 122.0),
            ),
            proj,
        )
    }

    // MARK: - windowed pairing (trailing window, inclusive of D)

    @Test
    fun windowedPair_trailingMean() {
        val marker = listOf("2026-01-15" to 3.1)
        val wearable = listOf(
            "2026-01-10" to 60.0, // OUTSIDE the 3-day window
            "2026-01-13" to 50.0,
            "2026-01-14" to 52.0,
            "2026-01-15" to 54.0,
        )
        val pairs = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 3)
        assertEquals(1, pairs.size)
        assertEquals("2026-01-15", pairs[0].day)
        assertEquals(3.1, pairs[0].markerValue, 1e-9)
        assertEquals((50.0 + 52.0 + 54.0) / 3.0, pairs[0].wearableMean, 1e-9) // 52.0
        assertEquals(3, pairs[0].wearableN)
    }

    @Test
    fun windowedPair_dropsNoCoverageDay() {
        val marker = listOf(
            "2026-01-15" to 3.1, // covered
            "2026-06-01" to 2.9, // no wearable anywhere near → dropped
        )
        val wearable = listOf(
            "2026-01-14" to 52.0,
            "2026-01-15" to 54.0,
        )
        val pairs = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 14)
        assertEquals(listOf("2026-01-15"), pairs.map { it.day })
    }

    @Test
    fun windowedPair_windowWidths() {
        val marker = listOf("2026-02-01" to 100.0)
        val wearable = listOf(
            "2026-01-05" to 10.0, // 27 days back → only in width 30
            "2026-01-20" to 20.0, // 12 days back → in 14 and 30
            "2026-01-29" to 30.0, //  3 days back → in 7, 14, 30
            "2026-02-01" to 40.0, //  same day    → all widths
        )
        val w7 = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 7)
        assertEquals((30.0 + 40.0) / 2.0, w7[0].wearableMean, 1e-9) // 35
        assertEquals(2, w7[0].wearableN)

        val w14 = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 14)
        assertEquals((20.0 + 30.0 + 40.0) / 3.0, w14[0].wearableMean, 1e-9) // 30
        assertEquals(3, w14[0].wearableN)

        val w30 = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 30)
        assertEquals((10.0 + 20.0 + 30.0 + 40.0) / 4.0, w30[0].wearableMean, 1e-9) // 25
        assertEquals(4, w30[0].wearableN)
    }

    // MARK: - pairs feed a Pearson computation unchanged (x = marker, y = wearable)

    @Test
    fun correlationInput_feedsPearson() {
        val marker = listOf(
            "2026-01-01" to 1.0,
            "2026-01-08" to 2.0,
            "2026-01-15" to 3.0,
            "2026-01-22" to 4.0,
        )
        val wearable = listOf(
            "2026-01-01" to 10.0,
            "2026-01-08" to 20.0,
            "2026-01-15" to 30.0,
            "2026-01-22" to 40.0,
        )
        val pairs = LabBookProjection.pairMarkerToWearable(marker, wearable, windowDays = 1)
        assertEquals(4, pairs.size)
        val xy = LabBookProjection.correlationInput(pairs)
        val (r, n) = pearson(xy)!!
        assertEquals(4, n)
        assertEquals(1.0, r, 1e-9) // perfect positive line y = 10x
    }

    // MARK: - day arithmetic parity (UTC-calendar shiftDay across a month boundary)

    @Test
    fun shiftDay_crossesMonthBoundary() {
        assertEquals("2026-01-31", LabBookProjection.shiftDay("2026-02-03", -3))
        assertEquals("2026-02-03", LabBookProjection.shiftDay("2026-02-03", 0))
        assertTrue(LabBookProjection.shiftDay("not-a-date", -1) == null)
    }

    /** Local Pearson (r, n) — only to confirm correlationInput produces a clean line; the
     *  real Pearson math parity is covered elsewhere. Mirrors the engine's formula. */
    private fun pearson(xy: List<Pair<Double, Double>>): Pair<Double, Int>? {
        val nn = xy.size
        if (nn < 3) return null
        val nD = nn.toDouble()
        var sumX = 0.0
        var sumY = 0.0
        for (p in xy) { sumX += p.first; sumY += p.second }
        val meanX = sumX / nD
        val meanY = sumY / nD
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for (p in xy) {
            val dx = p.first - meanX
            val dy = p.second - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        if (sxx <= 0.0 || syy <= 0.0) return null
        var r = sxy / (sqrt(sxx) * sqrt(syy))
        if (r > 1.0) r = 1.0
        if (r < -1.0) r = -1.0
        return r to nn
    }
}
