package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.data.JournalEntry
import java.time.LocalDate

// MARK: - Native journal logging (pure helpers + the Insights logging card)

/** Native answers are written under this dedicated source id, NEVER under "my-whoop": journal's
 *  PK is (deviceId, day, question) and has no source column, so a CSV re-import would silently
 *  overwrite in-app answers (and clears could delete imported rows). */
const val JOURNAL_DEVICE_ID = "noop-journal"

/** Starter behaviour catalog (mirrors WHOOP's most popular journal questions, full-question
 *  phrasing matching the export style). Question strings are opaque exact-match labels to the
 *  effects engine, so imported question strings lead the catalog resolution.
 *  They are DATA, not UI literals, stored verbatim in the journal table and never localised.
 *  Mirrors macOS JournalCatalogStore.starterQuestions value-for-value. */
val STARTER_JOURNAL_QUESTIONS: List<String> = listOf(
    "Did you drink any alcohol?",
    "Did you have caffeine late in the day?",
    "Did you view a screen in bed?",
    "Did you eat close to bedtime?",
    "Did you feel stressed?",
    "Did you use a sauna?",
    "Did you share your bed?",
    "Did you feel sick or ill?",
    "Did you take magnesium?",
    "Did you read before bed?",
)

/** Dedup/identity key for a question. Normalises ALL whitespace, leading/trailing AND internal
 *  runs collapse to a single space, then lowercases. A WHOOP export commonly leaves a trailing
 *  newline or non-breaking space on a journal cell; folding it here is what keeps an imported
 *  "Did you take magnesium?\n" from sitting beside the starter "Did you take magnesium?" as two
 *  separate rows (#224). The DISPLAYED string stays verbatim, only the match key is normalised, 
 *  so the stored behaviour key the effects engine joins on is untouched.
 *  Kept value-for-value in step with macOS `JournalCatalogStore.norm` (JournalCatalog.swift). */
internal fun normJournalKey(s: String): String =
    // Collapse every run of whitespace to a single space, then trim + lowercase. Uses Kotlin's
    // `Char.isWhitespace()` (Unicode-aware, it includes non-breaking space U+00A0 etc.) rather than
    // a regex: the previous `Regex("(?U)\\s+")` compiled on the desktop JVM but THREW
    // PatternSyntaxException on Android's ICU engine (the `(?U)` inline flag is unsupported there),
    // crashing the Insights screen for anyone with journal entries to merge (#224/#267). Matches the
    // Swift `.whitespacesAndNewlines` normalisation value-for-value.
    buildString {
        var prevSpace = true // suppress leading whitespace
        for (c in s) {
            if (c.isWhitespace()) {
                if (!prevSpace) append(' ')
                prevSpace = true
            } else {
                append(c)
                prevSpace = false
            }
        }
    }.trim().lowercase()

/** Union of imported + native entries; on a (day, question) collision the NATIVE row wins (the
 *  in-app answer is the user's most recent explicit action and stays editable). */
internal fun mergeJournalEntries(
    imported: List<JournalEntry>,
    native: List<JournalEntry>,
): List<JournalEntry> {
    val byKey = LinkedHashMap<Pair<String, String>, JournalEntry>()
    for (e in imported) byKey[e.day to e.question] = e
    for (e in native) byKey[e.day to e.question] = e
    return byKey.values.sortedWith(compareBy({ it.day }, { it.question }))
}

/** Importer convention (WhoopCsvImporter.parseJournal): journal day = the wake/cycle day whose
 *  morning recovery the previous ~24 h affected. "Log today" = answers about yesterday / last
 *  night, attributed to TODAY's local day key; daysBack=1 edits yesterday; daysBack=-1 logs ahead
 *  for TOMORROW (today's activities inform tomorrow's recovery). */
internal fun journalDayKey(daysBack: Long = 0L, today: LocalDate = LocalDate.now()): String =
    today.minusDays(daysBack).toString()

/** How many days back the journal day picker can reach (#656): today (0) plus the 6 prior days = a
 *  7-day backfill window, plus Tomorrow (-1). Bounded on purpose — journal answers feed the
 *  correlation engine, so unbounded backfill of stale days would distort it (matches WHOOP's limited
 *  retroactive window and the strip the Today widget shows). */
internal const val JOURNAL_BACKFILL_DAYS = 6

/** Short chip label for a journal day-picker [offset] (daysBack; -1 = Tomorrow). Hardcoded English to
 *  match the sibling Yesterday/Today/Tomorrow chips. */
internal fun journalDayChipLabel(offset: Long): String = when (offset) {
    -1L -> "Tomorrow"
    0L -> "Today"
    1L -> "Yesterday"
    else -> "$offset days ago"
}

// MARK: - Custom-question persistence
//
// Stored in the shared "noop_prefs" file under a "noop."-prefixed key, newline-joined (a string
// set loses order). Kept here rather than in NoopPrefs so the logging card is self-contained.

private const val JOURNAL_PREFS = "noop_prefs"
private const val JOURNAL_CUSTOM_KEY = "noop.journalCustomQuestions"
private const val JOURNAL_HIDDEN_KEY = "noop.journalHiddenQuestions"

private fun loadJournalList(context: Context, key: String): List<String> =
    (context.getSharedPreferences(JOURNAL_PREFS, Context.MODE_PRIVATE)
        .getString(key, "") ?: "")
        .split('\n').map { it.trim() }.filter { it.isNotEmpty() }

private fun saveJournalList(context: Context, key: String, questions: List<String>) {
    context.getSharedPreferences(JOURNAL_PREFS, Context.MODE_PRIVATE)
        .edit().putString(key, questions.joinToString("\n")).apply()
}

internal fun loadCustomJournalQuestions(context: Context): List<String> =
    loadJournalList(context, JOURNAL_CUSTOM_KEY)

internal fun saveCustomJournalQuestions(context: Context, questions: List<String>) =
    saveJournalList(context, JOURNAL_CUSTOM_KEY, questions)

internal fun loadHiddenJournalQuestions(context: Context): List<String> =
    loadJournalList(context, JOURNAL_HIDDEN_KEY)

internal fun saveHiddenJournalQuestions(context: Context, questions: List<String>) =
    saveJournalList(context, JOURNAL_HIDDEN_KEY, questions)

// MARK: - The logging card (hosted at the top of Insights)

/**
 * Yes/no chips and numeric fields for the merged behaviour catalog, grouped into collapsible blocks,
 * plus a custom-item field. Tri-state: no answer logged → neither chip filled; tapping the selected
 * chip again clears the answer (deletes the native row, imported rows are never touched). Numeric
 * items commit a value; the value writes answeredYes=true too so effects still see the logged day.
 * Edit mode adds rename / regroup / convert / remove per item. Renaming keeps the stored KEY
 * (`canonical`) so a WHOOP import still lines up. Mirrors the macOS JournalLogCard.
 */
@Composable
fun JournalLogCard(
    items: List<JournalCatalogItem>,
    answers: Map<String, Boolean>,
    numericAnswers: Map<String, Double> = emptyMap(),
    dayOffset: Long,
    onDayOffset: (Long) -> Unit,
    onAnswer: (String, Boolean) -> Unit,
    onNumeric: (String, Double) -> Unit,
    onClear: (String) -> Unit,
    onAddCustom: (String, JournalKind, JournalGroup) -> Unit,
    onRename: (String, String) -> Unit = { _, _ -> },
    onSetGroup: (String, JournalGroup) -> Unit = { _, _ -> },
    onSetKind: (String, JournalKind) -> Unit = { _, _ -> },
    onRemoveQuestion: (String) -> Unit = {},
    onRestoreQuestion: (String) -> Unit = {},
) {
    var editing by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<JournalCatalogItem?>(null) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Header: title/overline on the left, the Tomorrow/Today/Yesterday toggle (or Edit/Done) on the right.
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Overline("Log")
                Text(
                    uiString(R.string.l10n_journal_log_journal_57d7f743),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (editing) {
                JournalChip("Done", selected = true) { editing = false }
            } else {
                JournalChip("Edit", selected = false) { editing = true }
            }
        }
        // Day picker (#656): a bounded, scrollable range — Tomorrow back through the last 7 days — so any
        // recent day can be backfilled (was Yesterday/Today/Tomorrow only). Chronological left→right
        // (oldest → Tomorrow, #443); auto-scrolls to the selected day, so a deep-link from the Today
        // journal widget lands on that day's chip. Only when not editing.
        if (!editing) {
            val dayOffsets = remember { (JOURNAL_BACKFILL_DAYS.toLong() downTo -1L).toList() }
            val dayListState = rememberLazyListState()
            LaunchedEffect(dayOffset) {
                // Snap (not animate) to the selected day: an animated scroll would visibly slide from the
                // leftmost day to Today every time the journal opens.
                dayOffsets.indexOf(dayOffset).takeIf { it >= 0 }?.let { dayListState.scrollToItem(it) }
            }
            LazyRow(
                state = dayListState,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(dayOffsets) { off ->
                    JournalChip(journalDayChipLabel(off), selected = dayOffset == off) { onDayOffset(off) }
                }
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    when {
                        editing ->
                            "Rename, regroup, or remove an item to tidy your list. Renaming keeps the " +
                                "original question behind the scenes, so a WHOOP import still lines up. " +
                                "Custom items are deleted; built-in ones are hidden and can be restored below."
                        dayOffset == -1L ->
                            "Logging ahead for tomorrow: today's activities inform tomorrow's " +
                                "recovery, just as yesterday's are reflected in today's. Tomorrow's " +
                                "answers line up with tomorrow's morning."
                        else ->
                            "Answers are about the night and day leading into this morning, the " +
                                "same attribution a WHOOP export uses, so logged and imported days " +
                                "line up."
                    },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                // Grouped, collapsible blocks in the fixed display order. Empty groups hide outside edit.
                JournalGroup.displayOrder.forEach { group ->
                    val groupItems = items.filter { it.group == group }
                        .sortedWith(compareBy({ it.sortIndex }, { it.display }))
                    if (groupItems.isNotEmpty() || editing) {
                        JournalGroupBlock(
                            group = group,
                            items = groupItems,
                            editing = editing,
                            answers = answers,
                            numericAnswers = numericAnswers,
                            onAnswer = onAnswer,
                            onNumeric = onNumeric,
                            onClear = onClear,
                            onStartRename = { renaming = it },
                            onSetGroup = onSetGroup,
                            onSetKind = onSetKind,
                            onRemoveQuestion = onRemoveQuestion,
                            onRestoreQuestion = onRestoreQuestion,
                        )
                    }
                }
                JournalDivider()
                JournalAddRow(onAddCustom = onAddCustom)
            }
        }
    }

    renaming?.let { item ->
        JournalRenameDialog(
            item = item,
            onDismiss = { renaming = null },
            onSave = { name -> onRename(item.canonical, name); renaming = null },
        )
    }
}

/** One collapsible group of journal items. Header shows the group title + count + a collapse chevron. */
@Composable
private fun JournalGroupBlock(
    group: JournalGroup,
    items: List<JournalCatalogItem>,
    editing: Boolean,
    answers: Map<String, Boolean>,
    numericAnswers: Map<String, Double>,
    onAnswer: (String, Boolean) -> Unit,
    onNumeric: (String, Double) -> Unit,
    onClear: (String) -> Unit,
    onStartRename: (JournalCatalogItem) -> Unit,
    onSetGroup: (String, JournalGroup) -> Unit,
    onSetKind: (String, JournalKind) -> Unit,
    onRemoveQuestion: (String) -> Unit,
    onRestoreQuestion: (String) -> Unit,
) {
    var collapsed by remember(group) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().clickable { collapsed = !collapsed },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(group.title.uppercase(), style = NoopType.overline, color = Palette.textTertiary)
            Spacer(Modifier.width(6.dp))
            Text(uiString(R.string.l10n_journal_log_items_size_f76ab912, items.size), style = NoopType.caption, color = Palette.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(if (collapsed) "▸" else "▾", style = NoopType.caption, color = Palette.textTertiary)
        }
        if (!collapsed) {
            items.forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        item.display,   // display = rename ?? canonical; data, not a UI literal
                        style = NoopType.body,
                        color = if (item.hidden) Palette.textTertiary else Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    when {
                        item.hidden -> JournalChip("Restore", selected = false) { onRestoreQuestion(item.canonical) }
                        editing -> JournalItemEditControls(
                            item = item,
                            onStartRename = { onStartRename(item) },
                            onSetGroup = { onSetGroup(item.canonical, it) },
                            onSetKind = { onSetKind(item.canonical, it) },
                            onRemove = { onRemoveQuestion(item.canonical) },
                        )
                        item.kind.isNumeric -> JournalNumericField(
                            item = item,
                            value = numericAnswers[item.canonical],
                            onCommit = { onNumeric(item.canonical, it) },
                            onClear = { onClear(item.canonical) },
                        )
                        else -> {
                            JournalChip("Yes", selected = answers[item.canonical] == true) {
                                if (answers[item.canonical] == true) onClear(item.canonical) else onAnswer(item.canonical, true)
                            }
                            Spacer(Modifier.width(6.dp))
                            JournalChip("No", selected = answers[item.canonical] == false) {
                                if (answers[item.canonical] == false) onClear(item.canonical) else onAnswer(item.canonical, false)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Compact numeric log field: current value or a placeholder, commits a Double, with -/+ steppers. */
@Composable
private fun JournalNumericField(
    item: JournalCatalogItem,
    value: Double?,
    onCommit: (Double) -> Unit,
    onClear: () -> Unit,
) {
    var text by remember(value) { mutableStateOf(value?.let { formatNumeric(it) } ?: "") }
    Row(verticalAlignment = Alignment.CenterVertically) {
        JournalChip("−", selected = false) { onCommit(((value ?: 0.0) - 1).coerceAtLeast(0.0)) }
        Spacer(Modifier.width(4.dp))
        OutlinedTextField(
            value = text,
            onValueChange = { new ->
                text = new
                new.replace(',', '.').toDoubleOrNull()?.let { onCommit(it) }
            },
            placeholder = { Text("—", style = NoopType.body, color = Palette.textTertiary) },
            singleLine = true,
            textStyle = NoopType.body,
            colors = journalFieldColors(),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.width(72.dp),
        )
        item.kind.unitLabel?.takeIf { it.isNotEmpty() }?.let { unit ->
            Spacer(Modifier.width(4.dp))
            Text(unit, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(4.dp))
        JournalChip("+", selected = false) { onCommit((value ?: 0.0) + 1) }
        if (value != null) {
            Spacer(Modifier.width(4.dp))
            Text("✕", style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.clickable { onClear() })
        }
    }
}

private fun formatNumeric(v: Double): String =
    if (v == Math.floor(v) && !v.isInfinite()) v.toInt().toString() else String.format("%.1f", v)

/** Edit-mode per-item controls: rename, change group, convert type, remove. */
@Composable
private fun JournalItemEditControls(
    item: JournalCatalogItem,
    onStartRename: () -> Unit,
    onSetGroup: (JournalGroup) -> Unit,
    onSetKind: (JournalKind) -> Unit,
    onRemove: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    var groupMenuOpen by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box {
            Text("⋯", style = NoopType.body, color = Palette.textSecondary,
                modifier = Modifier.clickable { menuOpen = true }.padding(horizontal = 8.dp))
            androidx.compose.material3.DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(uiString(R.string.l10n_journal_log_rename_94ac9a58)) },
                    onClick = { menuOpen = false; onStartRename() },
                )
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(uiString(R.string.l10n_journal_log_group_995a11e5)) },
                    onClick = { menuOpen = false; groupMenuOpen = true },
                )
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(if (item.kind.isNumeric) "Change to Yes/No" else "Change to Number") },
                    onClick = {
                        menuOpen = false
                        onSetKind(if (item.kind.isNumeric) JournalKind.Bool else JournalKind.Numeric(null))
                    },
                )
            }
            androidx.compose.material3.DropdownMenu(expanded = groupMenuOpen, onDismissRequest = { groupMenuOpen = false }) {
                JournalGroup.displayOrder.forEach { g ->
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(g.title) },
                        onClick = { groupMenuOpen = false; onSetGroup(g) },
                    )
                }
            }
        }
        JournalRemoveButton(isCustom = item.custom) { onRemove() }
    }
}

/** Rename dialog: display-name field + the honest "history stays under the original question" note. */
@Composable
private fun JournalRenameDialog(
    item: JournalCatalogItem,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var draft by remember { mutableStateOf(item.displayName ?: item.canonical) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(uiString(R.string.l10n_journal_log_rename_item_3d21d6ca)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text(uiString(R.string.l10n_journal_log_display_name_c7874aaa)) },
                    singleLine = true,
                    colors = journalFieldColors(),
                )
                Text(
                    uiString(R.string.l10n_journal_log_history_stays_under_the_original_question_dc91ce89),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        },
        confirmButton = { Text(uiString(R.string.l10n_journal_log_save_efc007a3), color = Palette.accent, modifier = Modifier.clickable { onSave(draft) }.padding(8.dp)) },
        dismissButton = { Text(uiString(R.string.l10n_journal_log_cancel_77dfd213), color = Palette.textSecondary, modifier = Modifier.clickable { onDismiss() }.padding(8.dp)) },
    )
}

/** The add-a-custom-item row: text field + a Yes/No↔Number type toggle + a group picker + Add. */
@Composable
private fun JournalAddRow(onAddCustom: (String, JournalKind, JournalGroup) -> Unit) {
    var draft by remember { mutableStateOf("") }
    var numeric by remember { mutableStateOf(false) }
    var group by remember { mutableStateOf(JournalGroup.Other) }
    var groupMenu by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text(uiString(R.string.l10n_journal_log_add_a_custom_item_0dbd8f7c), style = NoopType.body, color = Palette.textTertiary) },
                singleLine = true,
                textStyle = NoopType.body,
                colors = journalFieldColors(),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            JournalChip(if (numeric) "Number" else "Yes/No", selected = numeric) { numeric = !numeric }
            Spacer(Modifier.width(8.dp))
            JournalChip("Add", selected = draft.isNotBlank()) {
                val t = draft.trim()
                if (t.isNotEmpty()) {
                    onAddCustom(t, if (numeric) JournalKind.Numeric(null) else JournalKind.Bool, group)
                    draft = ""
                }
            }
        }
        Box {
            Text(uiString(R.string.l10n_journal_log_group_group_title_1f88621e, group.title), style = NoopType.footnote, color = Palette.textSecondary,
                modifier = Modifier.clickable { groupMenu = true })
            androidx.compose.material3.DropdownMenu(expanded = groupMenu, onDismissRequest = { groupMenu = false }) {
                JournalGroup.displayOrder.forEach { g ->
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(g.title) },
                        onClick = { groupMenu = false; group = g },
                    )
                }
            }
        }
    }
}

@Composable
private fun JournalDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .height(1.dp)
            .background(Palette.hairline),
    )
}

/** A pill chip, filled with the accent when selected, hairline-bordered otherwise. Shared by the
 *  day toggle, the yes/no answers, and the "Add" action so they read identically. */
@Composable
private fun JournalChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        label,
        style = NoopType.caption,
        color = if (selected) Palette.surfaceBase else Palette.textSecondary,
        modifier = Modifier
            .clip(shape)
            .background(if (selected) Palette.accent else Palette.surfaceInset)
            .border(1.dp, if (selected) Palette.accent else Palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/** Edit-mode remove control: "Delete" for a custom question, "Hide" for a built-in one. Red-tinted
 *  text chip so it reads as removal; the label is self-describing for accessibility. */
@Composable
private fun JournalRemoveButton(isCustom: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        if (isCustom) "Delete" else "Hide",
        style = NoopType.caption,
        color = Palette.statusCritical,
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.statusCritical.copy(alpha = 0.5f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun journalFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    disabledTextColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    disabledBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
)
