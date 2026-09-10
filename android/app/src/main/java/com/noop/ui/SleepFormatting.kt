package com.noop.ui

import androidx.compose.ui.graphics.Color
import com.noop.analytics.SleepDebt
import com.noop.analytics.SleepDebtLedger
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

// MARK: - Formatting helpers (mirror SleepView.swift)

internal fun pct(minutes: Double, total: Double): Int =
    if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0

internal fun pctValue(v: Double?): String = v?.let { "${it.roundToInt()}%" } ?: "—"

/** "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries. */
internal fun vsTypical(latest: Double?, typical: Double?, suffix: String, decimals: Int = 0): String {
    if (latest == null || typical == null || typical == 0.0) return "vs typical - "
    val diff = latest - typical
    val sign = if (diff >= 0) "+" else "−"
    val mag = abs(diff)
    val num = if (decimals == 0) "${mag.roundToInt()}" else String.format(java.util.Locale.US, "%.${decimals}f", mag)
    return "$sign$num$suffix vs typical"
}

/** #1946: a carried prior-day value is stamped "Carried · <date>" instead of "vs typical", so it is
 *  never passed off as tonight's read. Falls through to [vsTypical] when the value is today's own
 *  (or there is no value). Mirror EXACTLY in Swift. */
internal fun tileCaption(
    latestDay: String?, latest: Double?, typical: Double?,
    suffix: String, decimals: Int = 0,
): String {
    Metric.carriedMetricCaption(latestDay, latest)?.let { caption ->
        // Resolve the DisplayText.Resource here so tileCaption stays String-returning for the
        // SparkTile call sites. uiString reads the process Application resources, so this is
        // locale-aware without being a @Composable.
        return when (caption) {
            is DisplayText.Resource -> uiString(caption.id, *caption.args.toTypedArray())
            is DisplayText.Dynamic -> caption.value
        }
    }
    return vsTypical(latest, typical, suffix, decimals)
}

internal fun debtCaption(debt: Double?): String {
    if (debt == null) return "vs need"
    return if (debt < SleepDebt.ON_TARGET_BAND_MIN) "On target" else "Below need"
}

internal fun debtColor(debt: Double?): Color = when {
    debt == null -> Palette.textPrimary
    debt < SleepDebt.ON_TARGET_BAND_MIN -> Palette.statusPositive
    debt < 60.0 -> Palette.statusWarning
    else -> Palette.statusCritical
}

// MARK: - Sleep-debt ledger formatting (mirror SleepView.swift)

/**
 * "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate. Reads
 * "On target" inside the deadband so a few stray minutes don't show as debt.
 */
internal fun debtHeadline(ledger: SleepDebtLedger): String =
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) "On target"
    else "≈${durationText(ledger.magnitudeMin)}"

/** Short tag beside the headline: the recurrence never creates a positive surplus. */
internal fun debtTag(ledger: SleepDebtLedger): String = when {
    ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN -> "balanced"
    ledger.isDebt -> "sleep debt"
    else -> "balanced"
}

/** Plain-English read of the actionable addition to the next night's target. */
internal fun debtRead(ledger: SleepDebtLedger): String {
    val nights = ledger.nightCount
    val span = "the last $nights night${if (nights == 1) "" else "s"}"
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) {
        return "You've met your current sleep target across $span. No extra debt needs carrying into tonight."
    }
    val mag = durationText(ledger.magnitudeMin)
    return if (ledger.isDebt) {
        "Aim for about $mag beyond your base need tonight. Meeting that target clears the displayed sleep debt."
    } else {
        "You're carrying about $mag of surplus over $span. You've slept past your need on balance. Nicely ahead."
    }
}

/**
 * Color the balance by size: within-band → positive green, modest debt →
 * warning, heavier debt → critical.
 */
internal fun debtBalanceColor(ledger: SleepDebtLedger): Color = when {
    ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN || !ledger.isDebt -> Palette.statusPositive
    ledger.magnitudeMin < 180.0 -> Palette.statusWarning
    else -> Palette.statusCritical
}

/** Signed "+1h 20m" / "−2h 10m" / "0m" balance string. */
internal fun debtSigned(minutes: Double): String {
    if (abs(minutes) < 1.0) return "0m"
    val sign = if (minutes >= 0.0) "+" else "−"
    return "$sign${durationText(abs(minutes))}"
}

internal fun durationText(minutes: Double): String {
    val m = max(0, minutes.roundToInt())
    return if (m < 60) "${m}m" else "${m / 60}h ${m % 60}m"
}

internal fun List<Double>.sleepAverageOrNull(): Double? =
    if (isEmpty()) null else sum() / size
