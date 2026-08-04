package com.noop.analytics

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/*
 * SleepDebt.kt — a rolling sleep-debt ledger over the last N nights.
 *
 * Faithful Kotlin mirror of StrandAnalytics/SleepDebt.swift. Keep the window cap,
 * the skip-no-data rule, and the Σ(slept − need) accumulation byte-identical to
 * Swift — the two clients must report the same balance for the same nights.
 *
 * Pure, deterministic, DB-free. Given a chronological series of per-night total
 * sleep (minutes) and a personal sleep need (hours), it accumulates a running
 * balance of (actual − need) per night across a capped trailing window (14 nights
 * by default) and reports the net balance plus the per-night deltas behind it.
 *
 * HONEST by construction:
 *   - A plain debt accumulator — sum of nightly (slept − need) — NOT a physiological
 *     model. A surplus night genuinely offsets a deficit one, like a balance nets
 *     credits and debits.
 *   - The window is capped (default 14) so debt never compounds across months of
 *     history — only the recent fortnight is in scope.
 *   - Nights with no usable sleep total are SKIPPED (no zero-fill), so a gap in wear
 *     never reads as a full night of debt.
 *   - The need value is supplied by the caller ([RestScorer.defaultSleepNeedHours] =
 *     8.0 by default; the caller passes any per-user override). Computation here stays
 *     a pure function of (series, need, window).
 */

/**
 * One night's contribution to the ledger: its day key, minutes slept, and the signed
 * delta against need (positive = surplus, negative = deficit). Mirrors Swift
 * `SleepDebtNight`.
 */
data class SleepDebtNight(
    /** "yyyy-MM-dd" day key for the night (as carried on the DailyMetric). */
    val day: String,
    /** Total sleep for the night (minutes). */
    val sleptMin: Double,
    /** Signed delta vs need (minutes): sleptMin − needMin. Positive = surplus. */
    val deltaMin: Double,
)

/**
 * The rolling sleep-debt ledger over the capped trailing window. Mirrors Swift
 * `SleepDebtLedger`.
 */
data class SleepDebtLedger(
    /** Net running balance (minutes): Σ(slept − need). Negative = net DEBT, positive = net SURPLUS. */
    val balanceMin: Double,
    /** Per-night contributions, oldest → newest (skipped nights absent); the per-night bar/spark. */
    val nights: List<SleepDebtNight>,
    /** Personal sleep need (minutes) the ledger was computed against (for labelling). */
    val needMin: Double,
) {
    /** Number of nights that contributed (nights with usable sleep data). */
    val nightCount: Int get() = nights.size

    /** True when the net balance is a debt (under need overall). */
    val isDebt: Boolean get() = balanceMin < 0.0

    /** Magnitude of the balance in minutes, regardless of sign. */
    val magnitudeMin: Double get() = abs(balanceMin)
}

object SleepDebt {

    /**
     * Cap the ledger at the trailing two weeks — recent enough to be actionable, short
     * enough that one rough patch doesn't read as months of compounding debt.
     */
    const val DEFAULT_WINDOW_NIGHTS: Int = 14

    /**
     * "On target" deadband (minutes): a |balance| under this reads as balanced rather than
     * a debt/surplus, so a few stray minutes don't flip the headline.
     */
    const val ON_TARGET_BAND_MIN: Double = 30.0

    /**
     * Sleep credited toward debt for one day. [mainSleepMin] remains the canonical
     * main-night total used by Rest and the sleep headline; separately-recorded naps
     * add repayment credit without changing that canonical figure. A day with no
     * usable main sleep stays missing, and a malformed negative nap total is ignored.
     *
     * This is deliberately arithmetic rather than a physiological model: callers
     * classify the day's main-night group and pass only asleep minutes from blocks
     * outside that group. Mirrors Swift `SleepDebt.creditedSleepMin` value-for-value.
     */
    fun creditedSleepMin(mainSleepMin: Double?, napSleepMin: Double = 0.0): Double? {
        val main = mainSleepMin?.takeIf { it > 0.0 } ?: return null
        return main + napSleepMin.coerceAtLeast(0.0)
    }

    /**
     * Build the ledger from a chronological `List<Pair<day, totalSleepMin?>>` series.
     *
     * @param series per-night `(day, totalSleepMin)` rows in CHRONOLOGICAL order
     *   (oldest → newest), exactly the order `days` carries. A null or non-positive
     *   `totalSleepMin` marks a night with no usable data and is SKIPPED (never zero-filled).
     * @param needHours personal sleep need (hours) each night is measured against. Defaults
     *   to [RestScorer.defaultSleepNeedHours] (8 h); the caller passes any per-user override.
     * @param window how many of the most-recent COUNTED nights to include. Defaults to
     *   [DEFAULT_WINDOW_NIGHTS] (14). Clamped to ≥ 1.
     *
     * The balance is Σ over the window of (sleptMin − needMin): a surplus night offsets a
     * deficit one. Returns an empty ledger (balance 0, no nights) when no night has data.
     */
    fun ledger(
        series: List<Pair<String, Double?>>,
        needHours: Double = RestScorer.defaultSleepNeedHours,
        window: Int = DEFAULT_WINDOW_NIGHTS,
    ): SleepDebtLedger {
        val needMin = needHours.coerceAtLeast(0.0) * 60.0
        val cap = window.coerceAtLeast(1)

        // Keep only nights with usable sleep, preserving chronological order, then take the
        // most-recent `cap` of them.
        val usable = series.filter { (it.second ?: 0.0) > 0.0 }
        val windowed = usable.takeLast(cap)

        val nights = ArrayList<SleepDebtNight>(windowed.size)
        var balance = 0.0
        for ((day, slept) in windowed) {
            val sleptMin = slept ?: 0.0
            val delta = sleptMin - needMin
            balance += delta
            nights.add(SleepDebtNight(day = day, sleptMin = sleptMin, deltaMin = delta))
        }
        return SleepDebtLedger(balanceMin = round1(balance), nights = nights, needMin = needMin)
    }

    /**
     * Round to 1 decimal place — keeps Σ stable without trailing float noise.
     *
     * Matches Swift `SleepDebt.round1` byte-for-byte: Swift's `Double.rounded()` is
     * `.toNearestOrAwayFromZero` (half-AWAY-from-zero), so a negative half-tie like a
     * −0.05 balance rounds to −0.1, not 0.0. Kotlin's `Double.roundToInt()` rounds half
     * toward +∞ (`floor(x + 0.5)`), which would round that same tie to 0.0 — a real
     * cross-platform divergence on negative half-ties (audit #6). Round each sign away
     * from zero so the two clients report the same balance for the same nights.
     */
    internal fun round1(v: Double): Double {
        val scaled = v * 10.0
        val rounded = if (scaled < 0.0) ceil(scaled - 0.5) else floor(scaled + 0.5)
        return rounded / 10.0
    }
}
