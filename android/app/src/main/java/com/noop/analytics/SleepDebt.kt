package com.noop.analytics

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/*
 * SleepDebt.kt — a recency-weighted, capped, asymmetric sleep-debt ledger.
 *
 * Faithful Kotlin mirror of StrandAnalytics/SleepDebt.swift. Keep the window cap,
 * the skip-no-data rule, the three tuning constants, and the recurrence byte-identical
 * to Swift — the two clients must report the same balance for the same nights.
 *
 * Pure, deterministic, DB-free. Given a chronological series of per-night total
 * sleep (minutes) and a personal sleep need (hours), it walks the recent nights
 * oldest → newest and folds each night's (slept − need) into a running balance with
 * three principled properties — recency weighting, a cap, and accrual/repay asymmetry —
 * then reports the net balance plus the raw per-night deltas.
 *
 * The recurrence (oldest → newest over the counted, windowed nights, seeded at 0):
 *
 *     contribution = delta < 0 ? delta                          // a DEFICIT accrues in FULL
 *                              : delta * surplusRepayFraction    // a SURPLUS repays only partly
 *     balance      = recencyRetention * balance + contribution  // yesterday's balance DECAYS
 *     balance      = clamp(balance, −cap, +cap)                 // cap = maxBalanceNights * need
 *
 *   where delta = sleptMin − needMin (positive = surplus, negative = deficit).
 *
 * HONEST by construction:
 *   - The per-night [SleepDebtNight.deltaMin] stays the RAW signed (slept − need), so the
 *     UI's diverging per-night bars remain a faithful nightly read. Only the accumulated
 *     [SleepDebtLedger.balanceMin] applies the decay/asymmetry/cap — it is deliberately NOT
 *     the plain Σ of the deltas any more (the model is the point).
 *   - The trailing WINDOW (default 14) still caps how many counted nights are folded in;
 *     decay and window together bound history.
 *   - Nights with no usable sleep total are SKIPPED (no zero-fill), so a gap in wear never
 *     reads as a full night of debt, and decay is applied per COUNTED night (a measurement
 *     gap does not silently "recover" the debt).
 *   - The need value is supplied by the caller ([RestScorer.defaultSleepNeedHours] =
 *     8.0 by default; the caller passes any per-user override — the population-anchored
 *     personalizedNeedHours rather than a self-referential mean). Computation here stays
 *     a pure function of (series, need, window).
 *
 * The three tuning constants ([recencyRetention], [surplusRepayFraction], [maxBalanceNights])
 * are first-cut, defensible defaults that WANT empirical tuning on real wearer histories.
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
    /**
     * Net running balance (minutes): the recency-weighted, asymmetric, capped fold of the per-night
     * deltas (see [SleepDebt.ledger]). Negative = net DEBT, positive = net SURPLUS, 0 = on target.
     * NOT the plain Σ of [nights]`[].deltaMin` — the decay/asymmetry/cap are applied to the
     * accumulation; the raw deltas are kept only for the per-night bars.
     */
    val balanceMin: Double,
    /**
     * Per-night contributions, oldest → newest (skipped nights absent). Each [SleepDebtNight.deltaMin]
     * is the RAW signed (slept − need) — the honest per-night bar/spark — before the balance's
     * decay/asymmetry/cap are applied.
     */
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
     * RECENCY WEIGHTING. Per-night retention of the carried balance: each night the running balance is
     * multiplied by this before the night's contribution is added, so a night's weight decays
     * geometrically (retentionᵏ, k counted nights later). 0.90 ⇒ 10 %/night decay, a ≈ 6.6-night
     * half-life (ln0.5/ln0.90), and ≈ 0.25 weight on the oldest night of a 14-night window. Lower =
     * shorter memory; higher = longer memory (closer to the old flat sum). WANTS empirical tuning.
     * Range (0, 1). Byte-identical to Swift `SleepDebt.recencyRetention`.
     */
    const val RECENCY_RETENTION: Double = 0.90

    /**
     * ASYMMETRY. A surplus (over-need) night repays debt at only this fraction of the weight a deficit
     * night accrues at — you can't fully "bank" catch-up sleep by oversleeping once. 0.5 ⇒ an oversleep
     * night moves the balance half as far as an equal short night. Combined with [RECENCY_RETENTION]
     * (which also quietly repays debt over time), this is the ledger's accrue-fast / repay-slow
     * behaviour. WANTS empirical tuning. Range [0, 1]. Byte-identical to Swift `surplusRepayFraction`.
     */
    const val SURPLUS_REPAY_FRACTION: Double = 0.5

    /**
     * CAP. |balance| is clamped to this many nights of the personal need (cap = value × needMin),
     * applied every step so the running total can't even transiently exceed it. Person-scaled so a
     * longer-sleeping teen's ceiling is proportionally higher. 3 ⇒ "at most ~three full nights behind
     * (or ahead)". Guards the absurd-number failure mode (a sustained deficit's decayed series still
     * converges toward ~10 nights' worth without it). WANTS empirical tuning. Byte-identical to Swift
     * `maxBalanceNights`.
     */
    const val MAX_BALANCE_NIGHTS: Double = 3.0

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
     * The balance folds the windowed nights oldest → newest: each night's carried balance DECAYS by
     * [RECENCY_RETENTION], a DEFICIT adds in full while a SURPLUS adds only [SURPLUS_REPAY_FRACTION]
     * of itself, and |balance| is clamped to [MAX_BALANCE_NIGHTS] × need every step (see the file
     * header for the full rationale). Each [SleepDebtNight.deltaMin] keeps the RAW (slept − need) for
     * the per-night bars. Returns an empty ledger (balance 0, no nights) when no night has data.
     */
    fun ledger(
        series: List<Pair<String, Double?>>,
        needHours: Double = RestScorer.defaultSleepNeedHours,
        window: Int = DEFAULT_WINDOW_NIGHTS,
    ): SleepDebtLedger {
        val needMin = needHours.coerceAtLeast(0.0) * 60.0
        val windowCap = window.coerceAtLeast(1)
        // Person-scaled magnitude ceiling for the running balance (a few nights of need).
        val balanceCap = MAX_BALANCE_NIGHTS * needMin

        // Keep only nights with usable sleep, preserving chronological order, then take the
        // most-recent `windowCap` of them.
        val usable = series.filter { (it.second ?: 0.0) > 0.0 }
        val windowed = usable.takeLast(windowCap)

        val nights = ArrayList<SleepDebtNight>(windowed.size)
        var balance = 0.0
        for ((day, slept) in windowed) {
            val sleptMin = slept ?: 0.0
            val delta = sleptMin - needMin   // RAW signed per-night; kept for the bars
            // Asymmetry: a deficit (delta < 0) accrues in full; a surplus repays only partly.
            val contribution = if (delta < 0.0) delta else delta * SURPLUS_REPAY_FRACTION
            // Recency weighting: yesterday's balance decays before today's contribution lands.
            balance = RECENCY_RETENTION * balance + contribution
            // Cap: clamp every step so the running total never even transiently exceeds it.
            balance = balance.coerceIn(-balanceCap, balanceCap)
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
