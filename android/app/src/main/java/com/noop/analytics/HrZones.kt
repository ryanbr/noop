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
    /** "tanaka" (age formula), "manual" (caller override), or "custom" (personalized boundaries). */
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

    /**
     * Sensible editable BPM range for personalized zone starts. The analytics API accepts any
     * positive finite values; the app UIs use this range to keep steppers practical.
     */
    val customBPMRange: IntRange = 30..250

    /** Tanaka (2001) age-predicted max HR: 208 − 0.7 × age (gender-independent). */
    fun tanakaMaxHR(age: Double): Double = 208.0 - 0.7 * age

    /**
     * Build the 5-zone set from age (Tanaka) or a manual [maxHROverride].
     *
     * @param age age in years (used only when [maxHROverride] is null).
     * @param maxHROverride explicit HRmax (bpm); when provided, `source == "manual"`.
     */
    fun zones(age: Double, maxHROverride: Double? = null, customLowerBounds: List<Double>? = null): HrZoneSet {
        val maxHR: Double
        val source: String
        if (maxHROverride != null) {
            maxHR = maxHROverride
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age)
            source = "tanaka"
        }
        return zones(maxHR, source, customLowerBounds)
    }

    /**
     * Build the 5-zone set directly from a known max HR, optionally replacing the conventional
     * percentage edges with five personalized inclusive lower bounds in BPM. Invalid custom input
     * falls back to the conventional model, so malformed restored preferences can never create gaps.
     */
    fun zones(maxHR: Double, source: String = "manual", customLowerBounds: List<Double>? = null): HrZoneSet {
        val custom = customLowerBounds?.let(::validCustomLowerBounds)
        val built = ArrayList<HrZone>(5)
        for (i in 0 until 5) {
            val lower = custom?.get(i) ?: (zoneEdges[i] * maxHR)
            val upper = custom?.let { if (i < 4) it[i + 1] else maxOf(maxHR, it[i]) } ?: (zoneEdges[i + 1] * maxHR)
            val loPct = if (maxHR > 0) lower / maxHR else 0.0
            val hiPct = if (maxHR > 0) upper / maxHR else 0.0
            built.add(
                HrZone(
                    number = i + 1,
                    lower = lower,
                    upper = upper,
                    lowerPct = loPct,
                    upperPct = hiPct,
                )
            )
        }
        return HrZoneSet(zones = built, maxHR = maxHR, source = if (custom == null) source else "custom")
    }

    /**
     * The conventional five inclusive lower bounds, rounded up to whole BPM for an editor. Rounding
     * up preserves the existing integer-sample classification (e.g. a 93.5 edge starts at 94 bpm).
     */
    fun defaultLowerBounds(maxHR: Double): List<Int> = zoneEdges.take(5).map { kotlin.math.ceil(it * maxHR).toInt() }

    /**
     * Return a valid five-boundary custom model, or null unless values are positive, finite, and
     * strictly increasing. Kept public so persistence layers can reject hand-edited backup values
     * using the exact same invariant as the analytics engine.
     */
    fun validCustomLowerBounds(values: List<Double>): List<Double>? {
        if (values.size != 5 || !values.all { it.isFinite() && it > 0 }) return null
        for (i in 1 until values.size) if (values[i] <= values[i - 1]) return null
        return values
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
    private var custom: List<Double>? = null
    private var set: HrZoneSet? = null

    /**
     * The effective zone set for [maxHR] and optional [customLowerBounds], rebuilt only when an input
     * differs from the last call — so the 1 Hz coach path reuses it, and personalized zones (#531) are
     * honoured instead of the maxHR-only default.
     */
    fun zones(maxHR: Double, customLowerBounds: List<Double>? = null): HrZoneSet {
        set?.let { if (maxHR == this.maxHR && customLowerBounds == custom) return it }
        return HrZones.zones(maxHR = maxHR, customLowerBounds = customLowerBounds).also {
            this.maxHR = maxHR; custom = customLowerBounds; set = it
        }
    }
}
