package com.noop.ui

import android.app.DatePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import com.noop.analytics.LabBookProjection
import com.noop.analytics.LabMarkerCategory
import com.noop.analytics.MarkerCatalog
import com.noop.analytics.MarkerDefinition
import com.noop.data.LabMarkerRow
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.UUID

// MARK: - Marker editor (manual entry — MVP) — Compose twin of MarkerEditorView.swift
//
// The "+ add a reading" sheet for the Lab Book (Health Records pillar, spec §"Add / edit a
// marker"). Pick a marker from MarkerCatalog (searchable) OR add a custom marker, then:
// value (numeric, the canonical unit prefilled, a unit switcher where sensible — mmol/L↔
// mg/dL, conversion shown), date taken, optional note, and an OPTIONAL "reference range
// from my report" — NEVER a NOOP-shipped range. Blood pressure is a PAIRED marker
// (systolic + diastolic entered together, stored as two keys).
//
// On save it hands the caller `List<LabMarkerRow>` (one row, or two for BP) under the
// strap device id; the caller persists (which also projects to metricSeries) + reloads.
// SELF-CONTAINED: no AppViewModel/Settings edits; the sheet owns all its state.
//
// NON-CLINICAL: captures only what the user types. The reference field is theirs, shown
// back verbatim — NOOP defines no ranges and asserts no normality.

private const val EDITOR_STRAP_DEVICE_ID = "my-whoop"

@Composable
fun MarkerEditorScreen(
    onDismiss: () -> Unit,
    onSave: (List<LabMarkerRow>) -> Unit,
) {
    var selection by remember { mutableStateOf<MarkerDefinition?>(null) }
    var addingCustom by remember { mutableStateOf(false) }
    var customName by remember { mutableStateOf("") }
    var customUnit by remember { mutableStateOf("") }
    var search by remember { mutableStateOf("") }

    var valueText by remember { mutableStateOf("") }
    var diastolicText by remember { mutableStateOf("") }
    var unitChoice by remember { mutableStateOf(0) }
    var takenAtMillis by remember { mutableStateOf(System.currentTimeMillis()) }
    var note by remember { mutableStateOf("") }
    var referenceText by remember { mutableStateOf("") }

    val markerKey = remember(selection, customName, addingCustom) {
        if (addingCustom) MarkerUnits.slug(customName) else (selection?.key ?: "")
    }
    val isBloodPressure = markerKey == LabBookProjection.BP_SYSTOLIC_KEY
    val canonicalUnit = remember(markerKey, customUnit, addingCustom) {
        if (addingCustom) customUnit else MarkerCatalog.definition(markerKey)?.canonicalUnit ?: ""
    }
    val unitOptions = remember(markerKey, canonicalUnit, addingCustom) {
        if (addingCustom) listOf(customUnit) else MarkerUnits.options(markerKey, canonicalUnit)
    }
    val activeUnit = unitOptions.getOrElse(unitChoice) { canonicalUnit }

    fun parsed(s: String): Double? = s.trim().toDoubleOrNull()

    // Build the validated draft row(s): two for BP, one otherwise. Empty when not usable yet.
    val drafts: List<LabMarkerRow> = run {
        val epoch = takenAtMillis / 1000L
        val day = labDayKey(takenAtMillis)
        val trimmedNote = note.trim().ifEmpty { null }
        val trimmedRef = referenceText.trim().ifEmpty { null }
        fun row(key: String, category: LabMarkerCategory, value: Double, unit: String) = LabMarkerRow(
            id = "$key-$epoch-${UUID.randomUUID().toString().take(8)}",
            deviceId = EDITOR_STRAP_DEVICE_ID,
            markerKey = key,
            category = category.raw,
            day = day,
            takenAt = epoch,
            value = value,
            valueText = null,
            unit = unit,
            source = "manual",
            note = trimmedNote,
            referenceText = trimmedRef,
        )
        when {
            addingCustom -> {
                val v = parsed(valueText)
                if (customName.isBlank() || customUnit.isBlank() || v == null) emptyList()
                else listOf(row(markerKey, LabMarkerCategory.OTHER, v, customUnit))
            }
            selection == null -> emptyList()
            isBloodPressure -> {
                val sys = parsed(valueText)
                val dia = parsed(diastolicText)
                if (sys == null || dia == null) emptyList()
                else listOf(
                    row(LabBookProjection.BP_SYSTOLIC_KEY, LabMarkerCategory.BLOOD_PRESSURE, sys, "mmHg"),
                    row(LabBookProjection.BP_DIASTOLIC_KEY, LabMarkerCategory.BLOOD_PRESSURE, dia, "mmHg"),
                )
            }
            else -> {
                val raw = parsed(valueText)
                if (raw == null) emptyList()
                else {
                    val stored = MarkerUnits.toCanonical(markerKey, raw, activeUnit)
                    listOf(row(markerKey, selection!!.category, stored, canonicalUnit))
                }
            }
        }
    }

    NoopBottomSheet(onDismiss = onDismiss) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
            Text("Add a reading", style = NoopType.title2, color = Palette.textPrimary)
            Text(
                "Type in a number from your own report. It stays on this phone.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            // --- Marker picker ---
            SectionHeader("Marker", overline = "what are you logging?")
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when {
                        addingCustom -> {
                            EditorField("Name") {
                                EditorTextField(customName, { customName = it }, "e.g. Magnesium")
                            }
                            EditorField("Unit") {
                                EditorTextField(customUnit, { customUnit = it }, "e.g. mmol/L")
                            }
                            LinkText("Back to the marker list") { addingCustom = false }
                        }
                        selection != null -> {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(selection!!.displayName, style = NoopType.headline, color = Palette.textPrimary)
                                    Text(selection!!.category.displayName, style = NoopType.footnote, color = Palette.textTertiary)
                                }
                                LinkText("Change") {
                                    selection = null; valueText = ""; diastolicText = ""; unitChoice = 0; search = ""
                                }
                            }
                        }
                        else -> {
                            OutlinedTextField(
                                value = search,
                                onValueChange = { search = it },
                                placeholder = { Text("Search markers (e.g. LDL, ferritin)", style = NoopType.body, color = Palette.textTertiary) },
                                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = Palette.textTertiary) },
                                singleLine = true,
                                colors = editorFieldColors(),
                                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search markers" },
                            )
                            CatalogList(search) { def ->
                                selection = def; unitChoice = 0
                            }
                            LinkText("+ Add a custom marker") { addingCustom = true }
                        }
                    }
                }
            }

            // --- Reading inputs ---
            if (selection != null || addingCustom) {
                SectionHeader("Reading", overline = "your number, date and any note")
                NoopCard {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        if (isBloodPressure) {
                            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                EditorField("Systolic", modifier = Modifier.weight(1f)) {
                                    NumberBox(valueText, { valueText = it }, "e.g. 120", "mmHg")
                                }
                                EditorField("Diastolic", modifier = Modifier.weight(1f)) {
                                    NumberBox(diastolicText, { diastolicText = it }, "e.g. 80", "mmHg")
                                }
                            }
                            Text(
                                "Entered together; stored as two markers so each lines up cleanly against your signals.",
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        } else {
                            EditorField("Value") {
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    if (unitOptions.size > 1) {
                                        SegmentedPillControl(
                                            items = unitOptions.indices.toList(),
                                            selection = unitChoice,
                                            label = { unitOptions[it] },
                                            onSelect = { unitChoice = it },
                                        )
                                    }
                                    NumberBox(valueText, { valueText = it }, "e.g. 3.1", activeUnit)
                                    if (unitOptions.size > 1 && activeUnit != canonicalUnit) {
                                        Text(
                                            "Stored as $canonicalUnit.",
                                            style = NoopType.footnote,
                                            color = Palette.textTertiary,
                                        )
                                    }
                                }
                            }
                        }
                        EditorField("Date taken") {
                            DateRow(takenAtMillis) { picked -> takenAtMillis = picked }
                        }
                        EditorField("Note (optional)") {
                            EditorTextField(note, { note = it }, "e.g. fasting, morning draw")
                        }
                        EditorField("Reference range from my report (optional)") {
                            EditorTextField(referenceText, { referenceText = it }, "e.g. 2.0–5.0 (your report's own range)")
                        }
                        Text(
                            "NOOP never fills this in — it only shows back exactly what you type from your own report.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }

            Text(
                "Lab Book keeps your own numbers — it doesn't test, read, or judge them, and it's not medical " +
                    "advice. Everything stays on this phone.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )

            Row(verticalAlignment = Alignment.CenterVertically) {
                LinkText("Cancel", color = Palette.textSecondary) { onDismiss() }
                Spacer(Modifier.weight(1f))
                Box(modifier = Modifier.width(160.dp)) {
                    PrimaryActionButton("Save", Icons.Filled.Add, enabled = drafts.isNotEmpty()) {
                        if (drafts.isNotEmpty()) onSave(drafts)
                    }
                }
            }
        }
    }
}

// MARK: - Catalog list

@Composable
private fun CatalogList(search: String, onPick: (MarkerDefinition) -> Unit) {
    val q = search.trim().lowercase()
    val filtered = remember(q) {
        if (q.isEmpty()) MarkerCatalog.builtIn
        else MarkerCatalog.builtIn.filter { it.displayName.lowercase().contains(q) || it.key.contains(q) }
    }
    // No inner verticalScroll — the enclosing bottom sheet already scrolls (a nested same-axis
    // scroll would conflict). The list renders in full inside that single scroll.
    Column {
        filtered.forEachIndexed { idx, def ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onPick(def) }
                    .padding(vertical = 9.dp)
                    .semantics { contentDescription = "${def.displayName}, ${def.canonicalUnit}" },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(def.displayName, style = NoopType.subhead, color = Palette.textPrimary)
                    Text(def.category.displayName, style = NoopType.footnote, color = Palette.textTertiary)
                }
                Text(def.canonicalUnit, style = NoopType.captionNumber, color = Palette.textSecondary)
            }
            if (idx < filtered.size - 1) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            }
        }
        if (filtered.isEmpty()) {
            Text("No match. Add it as a custom marker below.", style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.padding(vertical = 8.dp))
        }
    }
}

// MARK: - Date row (opens a DatePickerDialog capped at today)

@Composable
private fun DateRow(millis: Long, onPick: (Long) -> Unit) {
    val context = LocalContext.current
    val cal = remember(millis) { Calendar.getInstance().apply { timeInMillis = millis } }
    val label = remember(millis) { SimpleDateFormat("d MMM yyyy", Locale.US).format(java.util.Date(millis)) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
            .clickable {
                DatePickerDialog(
                    context,
                    { _, y, m, d ->
                        val c = Calendar.getInstance().apply {
                            timeInMillis = millis
                            set(Calendar.YEAR, y); set(Calendar.MONTH, m); set(Calendar.DAY_OF_MONTH, d)
                        }
                        onPick(c.timeInMillis)
                    },
                    cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH),
                ).apply { datePicker.maxDate = System.currentTimeMillis() }.show()
            }
            .padding(horizontal = 12.dp, vertical = 11.dp)
            .semantics { contentDescription = "Date taken" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.width(16.dp))
        Text(label, style = NoopType.body, color = Palette.textPrimary)
    }
}

// MARK: - Small field builders

@Composable
private fun EditorField(label: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Overline(label)
        content()
    }
}

@Composable
private fun EditorTextField(value: String, onChange: (String) -> Unit, placeholder: String) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        singleLine = true,
        colors = editorFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun NumberBox(value: String, onChange: (String) -> Unit, placeholder: String, unit: String) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        trailingIcon = { Text(unit, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.padding(end = 10.dp)) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        colors = editorFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun LinkText(label: String, color: androidx.compose.ui.graphics.Color = Palette.accent, onClick: () -> Unit) {
    Text(
        label,
        style = NoopType.caption,
        color = color,
        modifier = Modifier
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
    )
}

@Composable
private fun editorFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

// MARK: - Unit handling (transparent mmol/L ↔ mg/dL switcher) — twin of Swift MarkerUnits

object MarkerUnits {
    /** mg/dL → canonical (mmol/L) factors for the dual-unit markers. Lipids 38.67, glucose 18.0,
     *  triglycerides 88.57. Byte-identical to the Swift MarkerUnits table. */
    private val mgdlToMmol: Map<String, Double> = mapOf(
        "total_cholesterol" to 1.0 / 38.67,
        "ldl" to 1.0 / 38.67,
        "hdl" to 1.0 / 38.67,
        "triglycerides" to 1.0 / 88.57,
        "fasting_glucose" to 1.0 / 18.0,
    )

    fun canonicalUnit(key: String, fallback: String): String =
        MarkerCatalog.definition(key)?.canonicalUnit ?: fallback

    /** Two entries (canonical + mg/dL) for dual-unit markers; otherwise the single canonical unit. */
    fun options(key: String, canonical: String): List<String> =
        if (mgdlToMmol.containsKey(key)) listOf(canonicalUnit(key, canonical), "mg/dL") else listOf(canonical)

    fun factorToCanonical(markerKey: String, from: String): Double? =
        if (from == "mg/dL") mgdlToMmol[markerKey] else null

    fun toCanonical(markerKey: String, value: Double, from: String): Double =
        factorToCanonical(markerKey, from)?.let { value * it } ?: value

    /** A lower-cased, underscored slug for a custom marker name → its stable key. */
    fun slug(name: String): String {
        val lowered = name.trim().lowercase()
        val mapped = lowered.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        val collapsed = mapped.replace("__", "_").trim('_')
        return "custom_$collapsed"
    }
}

/** "yyyy-MM-dd" LOCAL day key for the reading's takenAt millis (the projection key). */
private fun labDayKey(millis: Long): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(java.util.Date(millis))
