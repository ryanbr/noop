package com.noop.analytics

import java.util.Locale
import kotlin.math.roundToLong

/**
 * Estimate a strap's remaining runtime from its battery state-of-charge (SoC) history — the "~X days left"
 * the WHOOP app and WHOOP's API never give you (#713). NOOP already banks a SoC time-series from the strap
 * over BLE (the `battery` table), so NO manual logging is needed: we fit the recent DISCHARGE slope and
 * divide the current charge by it, falling back to the device's typical full-charge life when the discharge
 * data is too short to trust. The measured slope already reflects the user's real usage (HR-broadcast,
 * strain, …), so no hand-tuned multipliers are needed — the curve IS the personalisation.
 *
 * APPROXIMATE: battery drain is non-linear (faster near full/empty) and usage-dependent, and the strap
 * reports SoC sparsely — an honest estimate, not a guarantee. Byte-for-byte twin of the Swift BatteryEstimator.
 */
object BatteryEstimator {

    /** Typical full-charge life (hours) per generation — the cold-start fallback before enough of the user's
     *  OWN discharge is seen. WHOOP 4.0 ≈ 4.5 days, 5.0/MG ≈ 12 days (#713). The caller maps its strap to one. */
    const val ratedLifeHoursWhoop4 = 108.0
    const val ratedLifeHoursWhoop5 = 288.0

    /** A discharge run must span at least this long AND drop at least this much before its measured slope is
     *  trusted over the rated fallback — short/noisy spans give wild rates. */
    const val minSpanHours = 2.0
    const val minDropPct = 2.0

    /** A SoC rise beyond this (%) between consecutive readings marks a CHARGE — the discharge run restarts. */
    const val chargeStepPct = 1.0

    enum class Source { MEASURED, RATED }

    data class Estimate(
        /** Estimated hours of runtime left at the latest reading. */
        val remainingHours: Double,
        val source: Source,
        /** The latest SoC the estimate is anchored to (%). */
        val currentSoc: Double,
    )

    /**
     * Estimate remaining runtime. [readings] = (unix-seconds, SoC%) pairs in any order (the caller drops
     * nil-SoC rows and maps the `battery` series); [ratedLifeHours] = the strap's typical life (the
     * `ratedLifeHours…` constants). null only when there isn't a single reading. Mirrors Swift.
     */
    fun estimate(readings: List<Pair<Long, Double>>, ratedLifeHours: Double): Estimate? {
        val r = readings.sortedBy { it.first }
        val last = r.lastOrNull() ?: return null
        val current = last.second

        // The trailing discharge run: everything after the most recent CHARGE step (SoC rising > chargeStepPct).
        var startIdx = 0
        if (r.size >= 2) {
            for (i in r.size - 1 downTo 1) {
                if (r[i].second > r[i - 1].second + chargeStepPct) { startIdx = i; break }
            }
        }
        val seg = r.subList(startIdx, r.size)

        val measuredRate: Double? = run {
            if (seg.size < 2) return@run null
            val first = seg.first(); val lastSeg = seg.last()
            val spanH = (lastSeg.first - first.first) / 3600.0
            val drop = first.second - lastSeg.second
            if (spanH < minSpanHours || drop < minDropPct) return@run null
            val rate = drop / spanH                  // %/h over the run
            if (rate > 0) rate else null
        }

        val rate = measuredRate ?: (100.0 / maxOf(ratedLifeHours, 1.0))
        val remaining = maxOf(0.0, current) / rate
        val clamped = minOf(remaining, ratedLifeHours * 1.5)   // a fresh full charge can't exceed ~1.5× rated
        return Estimate(clamped, if (measuredRate != null) Source.MEASURED else Source.RATED, current)
    }

    /** Hours under 48 h ("~14 h"), days above ("~4.8 days") — #713's display rule. Unit-only; UI adds copy. */
    fun label(hours: Double): String =
        if (hours < 48) "~${hours.roundToLong()} h"
        else "~${String.format(Locale.US, "%.1f", hours / 24)} days"
}
