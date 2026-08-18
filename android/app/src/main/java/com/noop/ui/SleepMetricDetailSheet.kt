package com.noop.ui

import com.noop.R
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

// Sleep metric detail bottom sheet.
// Extracted from SleepScreen.kt (behavioral no-op; pure UI code-motion).

// MARK: - Sleep metric detail sheet

@Composable
internal fun SleepMetricDetailSheetContent(vm: AppViewModel, key: String) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var range by remember { mutableStateOf(SleepMetricRange.MONTH) }
    val spec = remember(key) { sleepMetricSpec(key) }
    val allPoints = remember(days, key) { buildSleepMetricPoints(days, key) }
    val filteredPoints = remember(allPoints, range) { filterSleepMetricPoints(allPoints, range) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = Metrics.space24, vertical = Metrics.space8),
        verticalArrangement = Arrangement.spacedBy(Metrics.space16),
    ) {
        if (allPoints.size < 2) {
            Text(uiString(R.string.l10n_sleep_screen_not_enough_history_yet_0e2f93b6), style = NoopType.headline, color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_sleep_screen_this_metric_needs_at_least_two_2de1d37a),
                style = NoopType.subhead, color = Palette.textSecondary,
            )
            Spacer(Modifier.height(Metrics.space16))
        } else if (filteredPoints.size < 2) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep")
                    Text(spec.title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            SegmentedPillControl(
                items = SleepMetricRange.entries,
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
            Text(uiString(R.string.l10n_sleep_screen_not_enough_history_in_this_range_7e2fd640), style = NoopType.subhead, color = Palette.textSecondary)
            Spacer(Modifier.height(Metrics.space16))
        } else {
            val values = filteredPoints.map { it.second }
            val dates = filteredPoints.map { it.first }
            val latest = filteredPoints.last()
            val minV = values.minOrNull() ?: 0.0
            val maxV = values.maxOrNull() ?: 0.0
            val avgV = values.average()

            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep · ${filteredPoints.size} nights")
                    Text(spec.title, style = NoopType.title2, color = Palette.textPrimary)
                    Text(uiString(R.string.l10n_sleep_screen_as_of_latest_first_726f20bb, latest.first), style = NoopType.footnote, color = Palette.textTertiary)
                }
                Text(
                    uiString(R.string.l10n_sleep_screen_spec_format_latest_second_spec_unit_18433019, spec.format(latest.second), spec.unit).trim(),
                    style = NoopType.chartValue,
                    color = spec.color,
                )
            }
            SegmentedPillControl(
                items = SleepMetricRange.entries,
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
            Row(
                modifier = Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space4),
            ) {
                Column(
                    modifier = Modifier.height(Metrics.chartHeight),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(uiString(R.string.l10n_sleep_screen_spec_format_maxv_spec_unit_65091104, spec.format(maxV), spec.unit).trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_sleep_screen_spec_format_avgv_spec_unit_46bf7fdc, spec.format(avgV), spec.unit).trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_sleep_screen_spec_format_minv_spec_unit_e69978f4, spec.format(minV), spec.unit).trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                LineChart(
                    values = values,
                    modifier = Modifier.weight(1f).height(Metrics.chartHeight)
                        .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_spec_title_trend_chart_3085ac6e, spec.title) },
                    color = spec.color,
                    fill = true,
                    selectionEnabled = true,
                    selectionLabels = filteredPoints.map { shortDayLabel(it.first) },   // #691: hover shows date + value
                )
            }
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(dates.first(), dates.getOrNull(dates.lastIndex / 2), dates.last()).forEach { d ->
                    Text(
                        d?.let { runCatching { LocalDate.parse(it).format(DateTimeFormatter.ofPattern("d MMM", Locale.US)) }.getOrDefault(it) }.orEmpty(),
                        style = NoopType.footnote, color = Palette.textTertiary,
                        modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            SleepHairline()
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf("Min" to minV, "Avg" to avgV, "Max" to maxV).forEach { (lbl, v) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(lbl, color = Palette.textTertiary)
                        Text(
                            uiString(R.string.l10n_sleep_screen_spec_format_v_spec_unit_7a7f630c, spec.format(v), spec.unit).trim(),
                            style = NoopType.captionNumber, color = Palette.textPrimary,
                        )
                    }
                }
            }
            Spacer(Modifier.height(Metrics.space8))
        }
    }
}

