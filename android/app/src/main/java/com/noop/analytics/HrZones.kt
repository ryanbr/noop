package com.noop.analytics

import com.noop.data.HrSample
import kotlin.math.min

/*
 * HrZones.kt — HR-max + 5 heart-rate zones and time-in-zone from an HR stream.
 *
 * Faithful Kotlin port of StrandAnalytics/HRZones.swift (verified on macOS).
 *
 * HR-max uses Tanaka et al. (2001): HRmax = 208 − 0.7 × age (gender-independent),
 * with an optional manual override. The five zones are the conventional %HRmax
 * bands used across consumer wearables:
 *
 *   Zone 1 (50–60% HRmax) — very light / recovery
 *   Zone 2 (60–70% HRmax) — light / fat-burn
 *   Zone 3 (70–80% HRmax) — moderate / aerobic
 *   Zone 4 (80–90% HRmax) — hard / threshold
 *   Zone 5 (90–100% HRmax) — maximum
 *
 * This is the "display" zone model (zones from age, time-in-zone from HrSample);
 * it is independent of the HRR-based strain math in StrainScorer.
 *
 * Named [HrZones] (NOT Zones) to avoid clashing with the existing
 * com.noop.analytics.Zones object in Analytics.kt.
 */

/** A single heart-rate zone defined as a bpm interval [lower, upper). Mirrors Swift `HRZone`. */
data class HrZone(
    /** Zone number 1..5. */
    val number: Int,
    /** Lower bound (bpm), inclusive. */
    val lower: Double,
    /** Upper bound (bpm); exclusive except for the top zone where it is inclusive. */
    val upper: Double,
    /** Fraction-of-HRmax lower bound (e.g. 0.50 for Zone 1). */
    val lowerPct: Double,
    /** Fraction-of-HRmax upper bound (e.g. 0.60 for Zone 1). */
    val upperPct: Double,
)

/**
 * Five HR zones derived from a max HR, plus the max HR itself and its source.
 * Mirrors Swift `HRZoneSet`.
 */
data class HrZoneSet(
    /** The five zones, z1..z5, in ascending order. */
    val zones: List<HrZone>,
    /** Max HR (bpm) the zones were built from. */
    val maxHR: Double,
    /** "tanaka" (age formula) or "manual" (caller override). */
    val source: String,
) {
    /** Return the zone number (1..5) for a bpm value, or 0 when below Zone 1. */
    fun zoneNumber(bpm: Double): Int {
        for (z in zones) {
            // Top zone is inclusive at its upper edge so HRmax itself lands in z5.
            if (z.number == 5) {
                if (bpm >= z.lower) return 5
            } else if (bpm >= z.lower && bpm < z.upper) {
                return z.number
            }
        }
        return 0
    }
}

/**
 * Time spent in each zone (seconds), including below-Zone-1 time as [belowZone1].
 * Mirrors Swift `TimeInZone`.
 */
data class TimeInZone(
    /** Seconds in each of the five zones, indexed z1..z5 (seconds[0] == Zone 1). */
    val seconds: List<Double>,
    /** Seconds spent below Zone 1 (HR under 50% HRmax). */
    val belowZone1: Double,
) {
    /** Total counted seconds (Zone 1..5 plus below-Zone-1). */
    val total: Double get() = seconds.sum() + belowZone1

    /** Seconds in a specific zone (1..5); 0 for out-of-range zone numbers. */
    fun secondsInZone(zone: Int): Double {
        if (zone < 1 || zone > 5) return 0.0
        return seconds[zone - 1]
    }
}

object HrZones {

    /** %HRmax band edges for zones 1..5: [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]. */
    val zoneEdges: List<Double> = listOf(0.50, 0.60, 0.70, 0.80, 0.90, 1.00)

    /** Tanaka (2001) age-predicted max HR: 208 − 0.7 × age (gender-independent). */
    fun tanakaMaxHR(age: Double): Double = 208.0 - 0.7 * age

    /**
     * Build the 5-zone set from age (Tanaka) or a manual [maxHROverride].
     *
     * @param age age in years (used only when [maxHROverride] is null).
     * @param maxHROverride explicit HRmax (bpm); when provided, `source == "manual"`.
     */
    fun zones(age: Double, maxHROverride: Double? = null): HrZoneSet {
        val maxHR: Double
        val source: String
        if (maxHROverride != null) {
            maxHR = maxHROverride
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age)
            source = "tanaka"
        }
        return zones(maxHR, source)
    }

    /** Build the 5-zone set directly from a known max HR. */
    fun zones(maxHR: Double, source: String = "manual"): HrZoneSet {
        val built = ArrayList<HrZone>(5)
        for (i in 0 until 5) {
            val loPct = zoneEdges[i]
            val hiPct = zoneEdges[i + 1]
            built.add(
                HrZone(
                    number = i + 1,
                    lower = loPct * maxHR,
                    upper = hiPct * maxHR,
                    lowerPct = loPct,
                    upperPct = hiPct,
                )
            )
        }
        return HrZoneSet(zones = built, maxHR = maxHR, source = source)
    }

    /**
     * Compute time-in-zone (seconds) from a time-ordered HR stream.
     *
     * Each sample is credited with the duration until the next sample (the
     * "hold until next reading" convention). The final sample is credited with
     * the median inter-sample interval (so a constant-rate stream is fully
     * accounted for). Samples are sorted defensively by ts.
     *
     * @param hr time-ordered (or unordered) HR samples.
     * @param zoneSet the zone definitions to bucket against.
     */
    fun timeInZone(hr: List<HrSample>, zoneSet: HrZoneSet): TimeInZone {
        val sorted = hr.sortedBy { it.ts }
        val zoneSeconds = DoubleArray(5)
        var below = 0.0

        if (sorted.isEmpty()) {
            return TimeInZone(seconds = zoneSeconds.toList(), belowZone1 = 0.0)
        }

        // Tail sample gets the median inter-sample gap so the series is fully counted.
        val tailDuration = medianInterval(sorted)

        for (i in sorted.indices) {
            val dur: Double = if (i < sorted.size - 1) {
                val gap = (sorted[i + 1].ts - sorted[i].ts).toDouble()
                // Guard against zero/negative or pathological gaps; cap at the median
                // so a single huge wall-clock gap doesn't blow up one bucket.
                if (gap > 0) min(gap, tailDuration) else tailDuration
            } else {
                tailDuration
            }
            val z = zoneSet.zoneNumber(sorted[i].bpm.toDouble())
            if (z >= 1) {
                zoneSeconds[z - 1] += dur
            } else {
                below += dur
            }
        }
        return TimeInZone(seconds = zoneSeconds.toList(), belowZone1 = below)
    }

    /**
     * Median spacing between consecutive timestamps, restricted to plausible
     * (0, 300 s) gaps. Falls back to 1.0 s when no plausible gap exists.
     */
    internal fun medianInterval(sorted: List<HrSample>): Double {
        if (sorted.size < 2) return 1.0
        val gaps = ArrayList<Double>()
        for (i in 1 until sorted.size) {
            val g = (sorted[i].ts - sorted[i - 1].ts).toDouble()
            if (g > 0 && g < 300) gaps.add(g)
        }
        if (gaps.isEmpty()) return 1.0
        gaps.sort()
        return maxOf(gaps[gaps.size / 2], 1.0)
    }
}

/**
 * Single-entry memo for [HrZones.zones]. The zone set is a pure function of maxHR (the [HrZones.zoneEdges]
 * are constant), and maxHR changes only when the user edits their profile — orders of magnitude less often
 * than [com.noop.ui.AppViewModel.coachZone] runs, which is every ~1 Hz live-HR sample while zone coaching
 * is active. Rebuilds the 5-zone set only when maxHR changes, so a streaming tick reuses it instead of
 * allocating six objects a second. Not thread-safe by design: touched only from the single coachZone call
 * on the live-state collector.
 */
internal class HrZoneSetCache {
    private var maxHR = Double.NaN
    private var set: HrZoneSet? = null

    /** The `manual`-source zone set for [maxHR], rebuilt only when [maxHR] differs from the last call. */
    fun zones(maxHR: Double): HrZoneSet {
        set?.let { if (maxHR == this.maxHR) return it }
        return HrZones.zones(maxHR = maxHR).also { this.maxHR = maxHR; set = it }
    }
}
