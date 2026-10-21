package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import com.noop.R
import com.noop.analytics.PersonalRecords
import com.noop.analytics.PersonalRecordMetric as Metric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

// MARK: - Personal bests card
//
// All-time bests from the user's own daily history (best HRV, lowest resting HR, best Charge, longest
// sleep, ...), each with the day it was set and a NEW tag when it fell in the last week. The selection
// rules live in the pure analytics PersonalRecords (Swift twin in StrandAnalytics); this file only
// formats and renders. Display-only: nothing here feeds a score or a stored value.

/** The record's value in its own unit, e.g. "84 ms", "46 bpm", "7h 52m", "12,480". */
internal fun personalRecordValueText(metric: Metric, value: Double): String = when (metric) {
    Metric.HRV -> String.format(Locale.getDefault(), "%.0f ms", value)
    Metric.RESTING_HR -> String.format(Locale.getDefault(), "%.0f bpm", value)
    Metric.RECOVERY -> String.format(Locale.getDefault(), "%.0f%%", value)
    Metric.STRAIN -> String.format(Locale.getDefault(), "%.1f", value)
    Metric.EFFICIENCY -> String.format(Locale.getDefault(), "%.0f%%", value * 100.0)
    Metric.SLEEP, Metric.DEEP_SLEEP, Metric.REM_SLEEP -> durationText(value)
    Metric.STEPS -> String.format(Locale.getDefault(), "%,.0f", value)
}

/** A `yyyy-MM-dd` key as a medium localized date; the key itself if it does not parse. */
internal fun personalRecordDayText(day: String): String =
    runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)) }
        .getOrDefault(day)

@Composable
private fun Metric.localizedLabel(): String = when (this) {
    Metric.HRV -> uiString(R.string.l10n_personal_records_hrv)
    Metric.RESTING_HR -> uiString(R.string.l10n_personal_records_resting_hr)
    Metric.RECOVERY -> uiString(R.string.l10n_personal_records_charge)
    Metric.STRAIN -> uiString(R.string.l10n_personal_records_strain)
    Metric.SLEEP -> uiString(R.string.l10n_personal_records_sleep)
    Metric.EFFICIENCY -> uiString(R.string.l10n_personal_records_efficiency)
    Metric.DEEP_SLEEP -> uiString(R.string.l10n_personal_records_deep_sleep)
    Metric.REM_SLEEP -> uiString(R.string.l10n_personal_records_rem_sleep)
    Metric.STEPS -> uiString(R.string.l10n_personal_records_steps)
}

/** The score family a metric belongs to, so each row carries its family colour. */
@Composable
private fun Metric.accent(): Color = when (this) {
    Metric.HRV, Metric.RESTING_HR, Metric.RECOVERY -> Palette.chargeColor
    Metric.STRAIN, Metric.STEPS -> Palette.effortColor
    Metric.SLEEP, Metric.EFFICIENCY, Metric.DEEP_SLEEP, Metric.REM_SLEEP -> Palette.restColor
}

@Composable
internal fun PersonalRecordsCard(records: List<PersonalRecords.Record>) {
    NoopCard(padding = Metrics.cardPadding, tint = Palette.gold) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            Column {
                Overline(uiString(R.string.l10n_personal_records_overline))
                Text(uiString(R.string.l10n_personal_records_title), style = NoopType.headline, color = Palette.textPrimary)
            }
            if (records.isEmpty()) {
                Text(uiString(R.string.l10n_personal_records_empty), style = NoopType.footnote, color = Palette.textSecondary)
                return@Column
            }
            records.forEach { r -> PersonalRecordRow(r) }
            Text(uiString(R.string.l10n_personal_records_footnote), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun PersonalRecordRow(r: PersonalRecords.Record) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceInset)
            .padding(horizontal = Metrics.space14, vertical = Metrics.space8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                Text(r.metric.localizedLabel(), style = NoopType.subhead, color = r.metric.accent())
                if (r.isNew) Overline(uiString(R.string.l10n_personal_records_new_badge), color = Palette.gold)
            }
            Text(personalRecordDayText(r.day), style = NoopType.footnote, color = Palette.textTertiary)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(personalRecordValueText(r.metric, r.value), style = NoopType.chartValue, color = Palette.textPrimary)
            r.previousBest?.let { prev ->
                Text(
                    uiString(R.string.l10n_personal_records_previous, personalRecordValueText(r.metric, prev)),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}
