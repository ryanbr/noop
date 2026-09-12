package com.noop.analytics

import com.noop.data.DailyMetric
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Heart-rate variability.
 *
 * Ported verbatim from `AppModel.rmssd` in the hardware-verified Swift reference
 * (`Strand/App/AppModel.swift`). RMSSD = root-mean-square of successive R-R
 * interval differences (milliseconds in, milliseconds out).
 */
object Hrv {
    /**
     * Root mean square of successive differences over a list of R-R intervals (ms).
     *
     * Returns 0.0 when fewer than two intervals are available (matching the Swift
     * guard `rr.count >= 2`).
     */
    fun rmssd(rr: List<Int>): Double {
        if (rr.size < 2) return 0.0
        var sum = 0.0
        var n = 0
        for (i in 1 until rr.size) {
            val d = (rr[i] - rr[i - 1]).toDouble()
            sum += d * d
            n += 1
        }
        return if (n > 0) sqrt(sum / n.toDouble()) else 0.0
    }
}

/**
 * Heart-rate training zones.
 *
 * Ported from the zone ladder in `AppModel.coachZone` (`Strand/App/AppModel.swift`):
 * pct >= 0.9 → 5, >= 0.8 → 4, >= 0.7 → 3, >= 0.6 → 2, else 1.
 */
object Zones {
    /**
     * Zone (1..5) for a heart rate given an estimated maximum heart rate.
     *
     * Mirrors the Swift `pct = hr / maxHR` ladder. If [hrMax] is non-positive the
     * percentage is undefined, so we fall back to the lowest zone.
     */
    fun zone(hr: Int, hrMax: Int): Int {
        if (hrMax <= 0) return 1
        val pct = hr.toDouble() / hrMax.toDouble()
        return when {
            pct >= 0.9 -> 5
            pct >= 0.8 -> 4
            pct >= 0.7 -> 3
            pct >= 0.6 -> 2
            else -> 1
        }
    }

    /**
     * Tanaka maximum-heart-rate estimate: round(208 - 0.7 * age).
     */
    fun hrMaxTanaka(age: Int): Int = (208.0 - 0.7 * age).roundToInt()
}

/**
 * Illness / strain early-warning.
 *
 * Ported from `AppModel.evaluateIllness` (`Strand/App/AppModel.swift`). Compares the
 * last ~2 days against a ~28-day baseline ending 3 days ago across resting HR, HRV,
 * skin-temperature deviation and respiration. Two or more anomalies surface a banner;
 * the classic early-illness signature is RHR up + HRV down + skin-temp up.
 *
 * The Swift method also gates on a user toggle (`behavior.illnessWatch`); that toggle
 * is a UI concern, so this pure function omits it. Callers decide whether to run it.
 */
object IllnessWatch {
    /**
     * Evaluate the [days] history (oldest -> newest). Returns a human-readable banner
     * message when 2+ anomaly flags fire, otherwise null.
     *
     * Requires at least 14 days of history (matching `days.count >= 14`).
     */
    fun evaluate(days: List<DailyMetric>): String? {
        if (days.size < 14) return null

        val recent = days.takeLast(2)
        // ~28 days ending 3 days ago: take the last 31, drop the most recent 3.
        val base = days.takeLast(31).dropLast(3)
        // Whether a signal's window is fit to accuse the recent one (#2130). The Swift twin folds this
        // SAME window through `Baselines.foldHistory` and refuses the signal unless the state is usable;
        // here it was a plain mean, which is happy with ONE value and gated nothing.
        //
        // Folding rather than counting is the point: it is the statistic Charge is scored against, so
        // the banner and the score can no longer hold two different baselines for one metric.
        //
        // Values rather than a helper because a named local function is a declaration the parity ledger
        // counts, and this file is inside its scan.
        val rhrBaseUsable = Baselines.metricCfg["resting_hr"]?.let { cfg ->
            Baselines.foldHistory(base.map { it.restingHr?.toDouble() }, cfg).usable
        } == true
        val hrvBaseUsable = Baselines.metricCfg["hrv"]?.let { cfg ->
            Baselines.foldHistory(base.map { it.avgHrv }, cfg).usable
        } == true

        fun mean(vals: List<Double>): Double? =
            if (vals.isEmpty()) null else vals.sum() / vals.size.toDouble()

        fun rm(selector: (DailyMetric) -> Double?): Double? =
            mean(recent.mapNotNull(selector))

        fun bm(selector: (DailyMetric) -> Double?): Double? =
            mean(base.mapNotNull(selector))

        val flags = mutableListOf<String>()

        run {
            val r = rm { it.restingHr?.toDouble() }
            val b = bm { it.restingHr?.toDouble() }
            if (r != null && b != null && rhrBaseUsable && r >= b + 5) {
                flags.add("resting HR +${(r - b).roundToInt()} bpm")
            }
        }

        run {
            // The sparsest of the four: the over-count gate withholds whole nights (#1118), so HRV is
            // the likeliest to have been resting on a cold-start baseline.
            val r = rm { it.avgHrv }
            val b = bm { it.avgHrv }
            if (r != null && b != null && b > 0 && hrvBaseUsable && r <= b * 0.80) {
                flags.add("HRV −${((1 - r / b) * 100).roundToInt()}%")
            }
        }

        run {
            val r = rm { it.skinTempDevC }
            if (r != null && r >= 0.6) {
                flags.add("skin temp +${formatOneDp(r)}°C")
            }
        }

        run {
            // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate
            // (WHOOP5 BLE-only). The field carries no source flag, so gate conservatively for BOTH:
            //  - require enough valid baseline nights for a stable baseline mean (RSA history can be sparse),
            //  - only compare physiologically plausible sleeping-RR values (~8-25 bpm), rejecting RSA outliers,
            //  - use a wider +2.5 bpm margin so one noisy night (averaged over the 2 recent days) can't fire,
            //    while a sustained genuine rise (both recent nights up) still does.
            val respBase = base.mapNotNull { it.respRateBpm }
            val r = rm { it.respRateBpm }
            val b = bm { it.respRateBpm }
            val plausible = { v: Double -> v in 8.0..25.0 }
            if (r != null && b != null && respBase.size >= 10 &&
                plausible(r) && plausible(b) && r >= b + 2.5
            ) {
                flags.add("respiration up")
            }
        }

        return if (flags.size >= 2) {
            "Your body looks strained - " + flags.joinToString(", ") +
                ". Consider taking it easy."
        } else {
            null
        }
    }

    /** Format a double to one decimal place (locale-independent), matching "%.1f". */
    private fun formatOneDp(value: Double): String {
        val scaled = (value * 10.0).roundToInt()
        val whole = scaled / 10
        val frac = kotlin.math.abs(scaled % 10)
        return "$whole.$frac"
    }
}
