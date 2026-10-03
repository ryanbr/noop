package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.ui.graphics.Color
import com.noop.R
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
    if (latest == null || typical == null || typical == 0.0) return uiString(R.string.l10n_sleep_formatting_vs_typical_2d0865ea)
    val diff = latest - typical
    val sign = if (diff >= 0) "+" else "−"
    val mag = abs(diff)
    val num = if (decimals == 0) "${mag.roundToInt()}" else String.format(java.util.Locale.US, "%.${decimals}f", mag)
    return uiString(R.string.l10n_sleep_formatting_vs_typical_b07f374b, sign, num, suffix)
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

internal fun debtCaption(debt: Double?): String = uiString(debtCaptionRes(debt))

/** The resource behind [debtCaption], kept apart so the 10-minute boundary stays testable on the JVM. */
@StringRes
internal fun debtCaptionRes(debt: Double?): Int = when {
    debt == null -> R.string.l10n_sleep_formatting_vs_need_6d942bfe
    debt < SleepDebt.ON_TARGET_BAND_MIN -> R.string.l10n_sleep_formatting_on_target_412a8343
    else -> R.string.l10n_sleep_formatting_below_need_85eb30c0
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
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) uiString(R.string.l10n_sleep_formatting_on_target_412a8343)
    else "≈${durationText(ledger.magnitudeMin)}"

/** Short tag beside the headline: the recurrence never creates a positive surplus. */
internal fun debtTag(ledger: SleepDebtLedger): String = when {
    ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN -> uiString(R.string.l10n_sleep_formatting_balanced_6217e69f)
    ledger.isDebt -> uiString(R.string.l10n_sleep_formatting_sleep_debt_cbdd4bd3)
    else -> uiString(R.string.l10n_sleep_formatting_balanced_6217e69f)
}

/** Plain-English read of the actionable addition to the next night's target. */
internal fun debtRead(ledger: SleepDebtLedger): String {
    val nights = ledger.nightCount
    val span = uiPlural(R.plurals.l10n_sleep_formatting_the_last_nights, nights, nights)
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) {
        return uiString(R.string.l10n_sleep_formatting_you_ve_met_your_current_sleep_1206a442, span)
    }
    val mag = durationText(ledger.magnitudeMin)
    return if (ledger.isDebt) {
        uiString(R.string.l10n_sleep_formatting_aim_for_about_beyond_your_base_601117a6, mag)
    } else {
        uiString(R.string.l10n_sleep_formatting_you_re_carrying_about_of_surplus_a8522bd4, mag, span)
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
