package com.noop.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import com.noop.R
import com.noop.data.WeightEntry
import com.noop.data.WeightHistory
import com.noop.data.WeightHistoryStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
fun WeightHistoryScreen(vm: AppViewModel) {
    val store = remember(vm) { WeightHistoryStore(vm.repo) }
    WeightHistoryContent(store)
}

@Composable
internal fun WeightHistoryContent(store: WeightHistoryStore) {
    val scope = rememberCoroutineScope()
    val system = UnitPrefs.system(LocalContext.current)
    val today = LocalDate.now()
    var history by remember { mutableStateOf<List<WeightEntry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var range by rememberSaveable { mutableIntStateOf(90) }
    var showEditor by rememberSaveable { mutableStateOf(false) }
    var editingDay by rememberSaveable { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<WeightEntry?>(null) }
    val visible = remember(history, range, today) {
        history.filter { range == 0 || it.day >= today.minusDays(range.toLong() - 1).toString() }
    }
    val dateFormat = remember { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM) }
    fun dateLabel(day: String) = LocalDate.parse(day).format(dateFormat)

    suspend fun load() {
        history = withContext(Dispatchers.IO) { store.history(today.toString()) }
    }
    fun change(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                withContext(Dispatchers.IO) { action() }
                showEditor = false
                deleting = null
                try { load() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { error = R.string.weight_load_error }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                error = R.string.weight_change_error
            } finally { busy = false }
        }
    }
    LaunchedEffect(reload) {
        loading = true
        error = null
        try { load() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = R.string.weight_load_error }
        finally { loading = false }
    }

    LazyScreenScaffold(
        title = uiString(R.string.weight_history_title),
        trailing = {
            NoopButton(uiString(R.string.weight_add), leadingIcon = Icons.Filled.Add, enabled = !busy) {
                editingDay = null
                showEditor = true
            }
        },
    ) {
        if (error != null) item {
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Text(uiString(error!!), style = NoopType.body, color = Palette.statusCritical)
                    TextButton(onClick = { reload++ }, enabled = !busy) {
                        Text(uiString(R.string.l10n_add_device_wizard_try_again_042c862e))
                    }
                }
            }
        }
        if (loading) item { LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = Palette.accent) }
        item {
            SegmentedPillControl(
                items = listOf(30, 90, 0), selection = range, onSelect = { range = it },
                label = { if (it == 0) uiString(R.string.timeline_all) else uiString(R.string.weight_days, it) },
            )
        }
        item {
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    if (visible.isEmpty()) {
                        Text(uiString(R.string.today_no_data), style = NoopType.title2, color = Palette.textPrimary)
                        Text(uiString(R.string.weight_empty), style = NoopType.body, color = Palette.textSecondary)
                    } else {
                        val latest = visible.last()
                        Text(UnitFormatter.massFromKilograms(latest.kilograms, system), style = NoopType.title1.copy(fontFeatureSettings = "tnum"), color = Palette.textPrimary)
                        Text(dateLabel(latest.day), style = NoopType.caption, color = Palette.textSecondary)
                        if (visible.size > 1) {
                            val values = visible.map { if (system == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(it.kilograms) else it.kilograms }
                            val low = values.min()
                            val high = values.max()
                            val padding = maxOf(1.0, (high - low) * 0.1)
                            LineChart(
                                values = values,
                                yDomain = maxOf(0.0, low - padding)..(high + padding),
                                timestamps = visible.map { LocalDate.parse(it.day).atStartOfDay().toEpochSecond(ZoneOffset.UTC) },
                                selectionLabels = visible.map { dateLabel(it.day) },
                                selectionEnabled = true, showsPoints = true, fill = false,
                                formatValue = { value -> UnitFormatter.massFromKilograms(
                                    if (system == UnitSystem.IMPERIAL) value / UnitFormatter.kgToPounds(1.0) else value, system) },
                                modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            )
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(dateLabel(visible.first().day), style = NoopType.caption, color = Palette.textSecondary)
                                Text(dateLabel(latest.day), style = NoopType.caption, color = Palette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        item { Text(uiString(R.string.weight_profile_note), style = NoopType.caption, color = Palette.textSecondary) }
        items(visible.asReversed(), key = { it.day }) { entry ->
            NoopCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                        Text(UnitFormatter.massFromKilograms(entry.kilograms, system), style = NoopType.headline.copy(fontFeatureSettings = "tnum"), color = Palette.textPrimary)
                        Text(dateLabel(entry.day), style = NoopType.caption, color = Palette.textSecondary)
                        Text(weightSourceLabel(entry.source), style = NoopType.caption, color = Palette.textTertiary)
                    }
                    if (entry.isManual) {
                        IconButton(onClick = { editingDay = entry.day; showEditor = true }, enabled = !busy) {
                            Icon(Icons.Filled.Edit, uiString(R.string.l10n_today_screen_edit_5301648d), tint = Palette.accent)
                        }
                        IconButton(onClick = { deleting = entry }, enabled = !busy) {
                            Icon(Icons.Filled.Delete, uiString(R.string.workout_action_delete), tint = Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }
    if (showEditor && !loading) WeightEntryDialog(
        entry = history.firstOrNull { it.day == editingDay && it.isManual }, system = system, busy = busy, error = error,
        onDismiss = { if (!busy) { showEditor = false; error = null } },
        onSave = { day, kg -> change { store.save(day, kg) } },
    )
    deleting?.let { entry ->
        AlertDialog(
            onDismissRequest = { if (!busy) deleting = null },
            title = { Text(uiString(R.string.weight_delete_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Text(dateLabel(entry.day) + " · " + UnitFormatter.massFromKilograms(entry.kilograms, system))
                    error?.let { Text(uiString(it), color = Palette.statusCritical, style = NoopType.body) }
                }
            },
            confirmButton = { TextButton(enabled = !busy, onClick = { change { store.delete(entry.day) } }) { Text(uiString(R.string.workout_action_delete)) } },
            dismissButton = { TextButton(enabled = !busy, onClick = { deleting = null }) { Text(uiString(R.string.ground_truth_cancel)) } },
        )
    }
}

@Composable
private fun weightSourceLabel(source: String): String = when (source) {
    WeightHistory.MANUAL_SOURCE -> uiString(R.string.weight_manual)
    "apple-health" -> uiString(R.string.today_source_apple_health)
    "health-connect" -> uiString(R.string.today_source_health_connect)
    else -> uiString(R.string.l10n_data_sources_screen_imported_434eb26f)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WeightEntryDialog(
    entry: WeightEntry?, system: UnitSystem, busy: Boolean, error: Int?,
    onDismiss: () -> Unit, onSave: (String, Double) -> Unit,
) {
    val today = LocalDate.now()
    val initial = remember(entry, system) {
        entry?.let { if (system == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(it.kilograms) else it.kilograms }?.toString().orEmpty()
    }
    var amount by rememberSaveable(entry?.day) { mutableStateOf(initial) }
    var day by rememberSaveable(entry?.day) { mutableStateOf(entry?.day ?: today.toString()) }
    var pickingDate by remember { mutableStateOf(false) }
    val numeric = amount.trim().takeIf { it.matches(Regex("[0-9]+([.,][0-9]+)?")) }?.replace(',', '.')?.toDoubleOrNull()
    val kilograms = if (amount == initial && entry != null) entry.kilograms else numeric?.let {
        if (system == UnitSystem.IMPERIAL) it / UnitFormatter.kgToPounds(1.0) else it
    }
    val valid = kilograms?.let(WeightHistory::validKilograms) == true && WeightHistory.validDay(day) && day <= today.toString()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(uiString(if (entry == null) R.string.weight_add else R.string.l10n_today_screen_edit_5301648d)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                TextButton(onClick = { pickingDate = true }, enabled = entry == null && !busy) {
                    Text(LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)))
                }
                OutlinedTextField(
                    value = amount, onValueChange = { amount = it }, enabled = !busy, singleLine = true,
                    label = { Text(uiString(R.string.today_metric_weight)) },
                    suffix = { Text(UnitFormatter.massUnit(system)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    isError = amount.isNotEmpty() && !valid,
                    supportingText = { if (amount.isNotEmpty() && !valid) Text(uiString(R.string.weight_invalid)) },
                )
                Text(uiString(R.string.weight_per_day), style = NoopType.caption, color = Palette.textSecondary)
                error?.let { Text(uiString(it), color = Palette.statusCritical, style = NoopType.body) }
            }
        },
        confirmButton = { TextButton(enabled = valid && !busy, onClick = { kilograms?.let { onSave(day, it) } }) { Text(uiString(R.string.ground_truth_save)) } },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(uiString(R.string.ground_truth_cancel)) } },
    )
    if (pickingDate) {
        val dateState = rememberDatePickerState(
            initialSelectedDateMillis = LocalDate.parse(day).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean =
                    Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate() <= today
            },
        )
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = { TextButton(onClick = {
                dateState.selectedDateMillis?.let { day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString() }
                pickingDate = false
            }) { Text(uiString(R.string.ground_truth_save)) } },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text(uiString(R.string.ground_truth_cancel)) } },
        ) { DatePicker(state = dateState) }
    }
}
