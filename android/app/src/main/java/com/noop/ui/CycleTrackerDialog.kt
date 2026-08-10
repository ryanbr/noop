package com.noop.ui

import android.app.DatePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import com.noop.analytics.CyclePhaseEngine
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Calendar
import java.util.Locale

/** Local-only cycle-day-1 logger and editable history. It never presents fertility or safe-day claims. */
@Composable
fun CycleTrackerDialog(
    result: CyclePhaseEngine.Result,
    starts: List<String>,
    onLog: (String) -> Unit,
    onDelete: (String) -> Unit,
    onDeleteAll: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    var selectedDay by remember { mutableStateOf(LocalDate.now()) }
    var confirmingDeleteAll by remember { mutableStateOf(false) }
    val selectedKey = selectedDay.toString()
    val alreadyLogged = selectedKey in starts

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(com.noop.R.string.cycle_tracker_title), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = Metrics.dialogScrollableMaxHeight).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                Text(uiString(com.noop.R.string.cycle_tracker_current_estimate).uppercase(Locale.getDefault()), style = NoopType.overline, color = Palette.textTertiary)
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    Text(cycleTrackerPhase(result.phase), style = NoopType.headline, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    cycleTrackerDay(result)?.let { Text(it, style = NoopType.bodyNumber, color = Palette.textSecondary) }
                }
                Text(result.note, style = NoopType.subhead, color = Palette.textSecondary)
                result.nextPeriodWindow?.let {
                    Text(
                        uiString(com.noop.R.string.cycle_tracker_likely_window, cycleTrackerPrettyDay(it.earliestDay), cycleTrackerPrettyDay(it.latestDay)),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }

                HorizontalDivider(color = Palette.hairline)
                Text(uiString(com.noop.R.string.cycle_tracker_log_heading).uppercase(Locale.getDefault()), style = NoopType.overline, color = Palette.textTertiary)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(Metrics.cornerSm))
                        .background(Palette.surfaceInset)
                        .clickable {
                            DatePickerDialog(
                                context,
                                { _, year, month, day -> selectedDay = LocalDate.of(year, month + 1, day) },
                                selectedDay.year,
                                selectedDay.monthValue - 1,
                                selectedDay.dayOfMonth,
                            ).apply { datePicker.maxDate = System.currentTimeMillis() }.show()
                        }
                        .padding(Metrics.space12),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = Palette.restColor, modifier = Modifier.size(Metrics.iconSmall))
                    Text(selectedDay.format(cycleTrackerDateFormatter()), style = NoopType.body, color = Palette.textPrimary)
                }
                TextButton(onClick = { onLog(selectedKey) }, enabled = !alreadyLogged) {
                    Text(if (alreadyLogged) uiString(com.noop.R.string.cycle_tracker_already_logged) else uiString(com.noop.R.string.cycle_tracker_log_action), color = if (alreadyLogged) Palette.textTertiary else Palette.restColor)
                }
                Text(
                    uiString(com.noop.R.string.cycle_tracker_anchor_help),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                HorizontalDivider(color = Palette.hairline)
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(uiString(com.noop.R.string.cycle_tracker_logged_starts).uppercase(Locale.getDefault()), style = NoopType.overline, color = Palette.textTertiary)
                    Spacer(Modifier.weight(1f))
                    if (starts.isNotEmpty()) {
                        TextButton(onClick = { confirmingDeleteAll = true }) {
                            Text(uiString(com.noop.R.string.cycle_tracker_delete_all), color = Palette.statusCritical)
                        }
                    }
                }
                if (starts.isEmpty()) {
                    Text(uiString(com.noop.R.string.cycle_tracker_empty), style = NoopType.subhead, color = Palette.textSecondary)
                } else {
                    starts.asReversed().forEachIndexed { index, day ->
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(cycleTrackerPrettyDay(day), style = NoopType.bodyNumber, color = Palette.textPrimary)
                            Spacer(Modifier.weight(1f))
                            TextButton(onClick = { onDelete(day) }) {
                                Icon(Icons.Filled.Delete, contentDescription = uiString(com.noop.R.string.cycle_tracker_delete_day, cycleTrackerPrettyDay(day)), tint = Palette.statusCritical)
                            }
                        }
                        if (index < starts.lastIndex) HorizontalDivider(color = Palette.hairline)
                    }
                }

                HorizontalDivider(color = Palette.hairline)
                Text(CyclePhaseEngine.awarenessLine, style = NoopType.footnote, color = Palette.textTertiary)
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8), verticalAlignment = Alignment.Top) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(Metrics.iconTiny))
                    Text(uiString(com.noop.R.string.cycle_tracker_privacy), style = NoopType.footnote, color = Palette.textTertiary)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(uiString(com.noop.R.string.cycle_tracker_done), color = Palette.restColor) } },
    )

    if (confirmingDeleteAll) {
        AlertDialog(
            onDismissRequest = { confirmingDeleteAll = false },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(com.noop.R.string.cycle_tracker_delete_title), style = NoopType.title2, color = Palette.textPrimary) },
            text = { Text(uiString(com.noop.R.string.cycle_tracker_delete_message), style = NoopType.body, color = Palette.textSecondary) },
            confirmButton = {
                TextButton(onClick = { confirmingDeleteAll = false; onDeleteAll() }) {
                    Text(uiString(com.noop.R.string.cycle_tracker_delete_all), color = Palette.statusCritical)
                }
            },
            dismissButton = { TextButton(onClick = { confirmingDeleteAll = false }) { Text(uiString(com.noop.R.string.cycle_tracker_cancel), color = Palette.textSecondary) } },
        )
    }
}

/** Compact Today entry point for the local period-start tracker. Awareness only; never fertility advice. */
@Composable
fun MenstrualCycleHomeCard(
    enabled: Boolean,
    result: CyclePhaseEngine.Result?,
    starts: List<String>,
    onSetUp: () -> Unit,
    onOpen: () -> Unit,
    onLogToday: () -> Unit,
) {
    val today = LocalDate.now().toString()
    val todayLogged = today in starts

    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                Icon(
                    Icons.Filled.CalendarMonth,
                    contentDescription = null,
                    tint = Palette.restColor,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Column {
                    Text(uiString(com.noop.R.string.cycle_home_title), style = NoopType.headline, color = Palette.textPrimary)
                    Text(uiString(com.noop.R.string.cycle_home_private), style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (enabled) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    Text(
                        result?.let { cycleTrackerPhase(it.phase) }
                            ?: uiString(com.noop.R.string.cycle_home_learning),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    result?.let(::cycleTrackerDay)?.let {
                        Text(it, style = NoopType.bodyNumber, color = Palette.textSecondary)
                    }
                }
            } else {
                Text(
                    uiString(com.noop.R.string.cycle_home_description),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }

            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(uiString(com.noop.R.string.cycle_home_latest), style = NoopType.subhead, color = Palette.textSecondary)
                Spacer(Modifier.weight(1f))
                Text(
                    starts.lastOrNull()?.let(::cycleTrackerPrettyDay)
                        ?: uiString(com.noop.R.string.cycle_tracker_empty),
                    style = NoopType.bodyNumber,
                    color = if (starts.isEmpty()) Palette.textTertiary else Palette.textPrimary,
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                TextButton(onClick = if (enabled) onOpen else onSetUp) {
                    Text(
                        uiString(if (enabled) com.noop.R.string.cycle_home_open else com.noop.R.string.cycle_home_setup),
                        color = Palette.restColor,
                    )
                }
                if (enabled) {
                    TextButton(onClick = onLogToday, enabled = !todayLogged) {
                        Text(
                            uiString(if (todayLogged) com.noop.R.string.cycle_home_logged_today else com.noop.R.string.cycle_home_log_today),
                            color = if (todayLogged) Palette.textTertiary else Palette.restColor,
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8), verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(Metrics.iconTiny))
                Text(uiString(com.noop.R.string.cycle_tracker_privacy), style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

private fun cycleTrackerPhase(phase: CyclePhaseEngine.Phase): String = when (phase) {
    CyclePhaseEngine.Phase.FOLLICULAR -> uiString(com.noop.R.string.cycle_phase_follicular)
    CyclePhaseEngine.Phase.PERI_OVULATORY -> uiString(com.noop.R.string.cycle_phase_mid_cycle)
    CyclePhaseEngine.Phase.LUTEAL -> uiString(com.noop.R.string.cycle_phase_luteal)
    CyclePhaseEngine.Phase.UNKNOWN -> uiString(com.noop.R.string.cycle_phase_unclear)
    CyclePhaseEngine.Phase.LEARNING -> uiString(com.noop.R.string.cycle_phase_learning)
}

private fun cycleTrackerDay(result: CyclePhaseEngine.Result): String? {
    val lo = result.cycleDayLow ?: return null
    val hi = result.cycleDayHigh ?: return null
    return if (lo == hi) uiString(com.noop.R.string.cycle_tracker_day_single, lo)
    else uiString(com.noop.R.string.cycle_tracker_day_range, lo, hi)
}

private fun cycleTrackerPrettyDay(day: String): String = runCatching {
    LocalDate.parse(day).format(cycleTrackerDateFormatter())
}.getOrDefault(day)

private fun cycleTrackerDateFormatter(): DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault())
