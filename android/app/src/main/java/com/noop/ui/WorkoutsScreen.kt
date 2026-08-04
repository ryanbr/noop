package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.Rowing
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.DownhillSkiing
import androidx.compose.material.icons.filled.Snowboarding
import androidx.compose.material.icons.filled.SportsBaseball
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsGolf
import androidx.compose.material.icons.filled.SportsGymnastics
import androidx.compose.material.icons.filled.SportsMartialArts
import androidx.compose.material.icons.filled.SportsVolleyball
import androidx.compose.material.icons.filled.Terrain
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.analytics.WorkoutSport
import com.noop.analytics.HeartRateRecovery
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Workouts — the activity log, instrument-grade and uniform. Ports the macOS
 * WorkoutsView (Strand/Screens/WorkoutsView.swift) onto the locked Android component
 * system (NoopCard / StatTile / SectionHeader / SegmentedPillControl / SourceBadge)
 * so every card, tile and row lines up:
 *
 *   - a range pill (7D / 30D / 90D / 1Y / All) that filters the loaded sessions,
 *   - a grid of summary StatTiles (count / time / calories / distance / most-active),
 *   - an "Activity Breakdown" of per-sport NoopCards with an identical internal layout,
 *   - an "All Sessions" NoopCard of fixed-height rows (date · sport · dur · HR · kcal ·
 *     dist · source).
 *
 * Sessions are loaded by the ViewModel from EVERY cached source — strap ("my-whoop": imported +
 * manual), Apple Health / Health Connect, and the on-device DETECTED bouts under "my-whoop-noop" —
 * merged newest first, with dismissed detected bouts filtered out (#107). Each row carries a source
 * badge (Whoop / Apple / HC / Detected / Manual) and an overflow menu to edit, re-label, dismiss or
 * delete. The windowing is anchored to the LATEST session (not "now"), so an old log still resolves;
 * an empty window auto-widens to the next larger range, exactly like the macOS screen.
 */
@Composable
fun WorkoutsScreen(vm: AppViewModel) {
    // The ViewModel owns the loaded rows now (ALL sources incl. detected, dismissed-filtered) so a
    // mutation (add / edit / relabel / dismiss / delete) republishes the list and the screen updates.
    val allRows by vm.workouts.collectAsState()
    val lastHistorySyncAt by vm.lastHistorySyncAt.collectAsStateWithLifecycle()
    // Cached daily metrics — the Charge side of the post-log activity-cost note (#439).
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()
    var loaded by remember { mutableStateOf(false) }
    var range by remember { mutableStateOf(WorkoutRange.All) }
    // Pick the default range ONCE on first non-empty load; later mutations must not fight a range the
    // user chose. Mirrors macOS, which sets the default only in `.task` / first onAppear.
    var didPickDefaultRange by remember { mutableStateOf(false) }

    // The manual add/edit dialog target: Some(null) = add, Some(row) = edit, null = closed.
    var dialog by remember { mutableStateOf<DialogTarget?>(null) }

    // #64: filters beyond the time range — sport (null = all), source class (null = all), free-text
    // search over the displayed sport. The pure WorkoutFilter applies them AFTER the window cut.
    var sportFilter by remember { mutableStateOf<String?>(null) }
    var sourceFilter by remember { mutableStateOf<WorkoutSource?>(null) }
    var searchText by remember { mutableStateOf("") }
    val filter = WorkoutFilter(sportFilter, sourceFilter, searchText)

    // #64: multi-select + merge. `selectionMode` toggles the leading checkmarks + the toolbar strip;
    // `selectedKeys` holds the natural keys ("startTs|sport") of the chosen rows. Only MANUAL / DETECTED
    // rows are selectable (imported history is read-only). `mergeSportPrompt` names an all-detected merge.
    var selectionMode by remember { mutableStateOf(false) }
    var selectedKeys by remember { mutableStateOf<Set<String>>(emptySet()) }
    var mergeSportPrompt by remember { mutableStateOf<List<WorkoutRow>?>(null) }

    // #64: displayed-sport names across ALL loaded rows, most-frequent first, for the sport-filter menu.
    // Computed here (a @Composable scope) since the LazyScreenScaffold content lambda is a LazyListScope.
    val availableSports = remember(allRows) {
        allRows.groupingBy { WorkoutEditing.displaySport(it.sport) }.eachCount()
            .entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .map { it.key }
    }

    // A transient one-line note shown after a manual save / relabel for a sport that already has a
    // solid/building ActivityCost entry — "Sessions like this usually …" (#439). Auto-clears.
    var postLogNote by remember { mutableStateOf<String?>(null) }
    var recoveryTrend by remember { mutableStateOf<List<WorkoutRecoveryTrendPoint>>(emptyList()) }
    // The sport whose recovery-cost note to surface once the reloaded sessions land. saveManualWorkout
    // / relabelDetected reload `vm.workouts` asynchronously, so we wait for `allRows` to update before
    // computing the note (otherwise it would read the pre-save list). Cleared once consumed.
    var pendingNoteSport by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(allRows, recentDays, pendingNoteSport) {
        val sport = pendingNoteSport ?: return@LaunchedEffect
        // Only a solid/building entry (n ≥ minSessions) clears the engine's gate, so this stays silent
        // until there's an honest personal pattern to show.
        val match = computeActivityCosts(allRows, recentDays).firstOrNull { it.sport == sport }
        pendingNoteSport = null
        if (match != null) {
            postLogNote = match.sentence()
            kotlinx.coroutines.delay(7_000)
            postLogNote = null
        }
    }

    // #516: use the same active filter/range as the workout page, capped to 90 days. The cap keeps a deep
    // imported history from launching hundreds of raw-HR reads; 7D/30D/90D are the promised trend views.
    val recoveryRange = run {
        val resolved = effectiveRange(allRows, range, filter)
        if (resolved.days == null || resolved.days > 90) WorkoutRange.Quarter else resolved
    }
    val recoveryRows = filter.apply(sessions(allRows, recoveryRange)).sortedBy { it.startTs }
    val recoveryInputKey = buildString {
        append(recoveryRange.name)
        recoveryRows.forEach { append('|').append(it.startTs).append(':').append(it.endTs) }
    }
    LaunchedEffect(recoveryInputKey, vm.activeStrapId, lastHistorySyncAt) {
        val built = ArrayList<WorkoutRecoveryTrendPoint>()
        for (row in recoveryRows) {
            val result = vm.workoutHeartRateRecovery(row.startTs, row.endTs, row.source, row.deviceId) ?: continue
            built += WorkoutRecoveryTrendPoint(row.startTs, result)
        }
        recoveryTrend = built
    }

    LaunchedEffect(Unit) {
        vm.loadWorkouts()
        loaded = true
    }
    LaunchedEffect(allRows) {
        if (!didPickDefaultRange && allRows.isNotEmpty()) {
            range = defaultRange(allRows)
            didPickDefaultRange = true
        }
    }

    // PERF (#707): migrate the eager ScreenScaffold to its lazy twin so each top-level section is its own
    // `item { }` and only the on-screen cards compose + get semantics-walked (the Compose accessibility
    // copy on scroll was a contributor to the OOM). Order / padding / 20dp spacing are unchanged: the
    // hero/summary/breakdown/zones/sessions cards stay one-per-item in the SAME sequence. The per-section
    // `val` resolves run ONCE in the content lambda (captured by each item), so this also de-dupes the
    // range/window/group computation that the eager column re-derived inline. The dialog overlay below the
    // scaffold is untouched. The All-Sessions list still lives inside its single enclosing card (appearance
    // is byte-identical) — see the report note on why it isn't flattened to top-level items here.
    // Day-cycle sky + sky-behind-cards: the SAME two Appearance gates every other screen honours.
    // (This screen previously drew the sky unconditionally - it now matches Today/Trends/Sleep,
    // including turning OFF with the day-cycle setting.) Read once; SharedPreferences isn't reactive.
    val skyCtx = androidx.compose.ui.platform.LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(skyCtx) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(skyCtx) }
    LazyScreenScaffold(
        title = uiString(R.string.l10n_workouts_screen_workouts_ccb58b22),
        subtitle = "Every session, threaded together.",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the theme canvas behind the header + top rows (bled full-width up behind the status bar via
        // the scaffold's topBackground plumbing), and the cards float OVER it on the flat surface below. The
        // Android equivalent of the iOS `ScreenScaffold(topBackground: liquidScaffoldSky())`.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        // Start (or stop) a workout right here, not only on Live — mirrors the Live control (#115).
        item {
        WorkoutStartSection(vm)
        }

        if (allRows.isEmpty()) {
            item {
            EmptyWorkouts(loaded, onAdd = { dialog = DialogTarget(null) })
            }
        } else {
            // Resolve the effective range + windowed rows + per-sport groups once. #64: the pure
            // WorkoutFilter narrows the window AFTER the range cut, so every section reads one filtered set.
            val resolved = effectiveRange(allRows, range, filter)
            val windowRows = filter.apply(sessions(allRows, resolved))
            val groups = sportGroups(windowRows)
            val fellBack = resolved != range

            item {
            RangeBar(
                range = range,
                effectiveRange = resolved,
                rowCount = windowRows.size,
                fellBack = fellBack,
                filterActive = filter.isActive,
                onSelect = { range = it },
                onAdd = { dialog = DialogTarget(null) },
            )
            }
            item {
            FilterBar(
                filter = filter,
                availableSports = availableSports,
                onSport = { sportFilter = it },
                onSource = { sourceFilter = it },
                onSearch = { searchText = it },
                onClear = { sportFilter = null; sourceFilter = null; searchText = "" },
            )
            }
            postLogNote?.let { item { PostLogNoteBanner(it) } }
            item { EffortHero(rows = windowRows, effectiveRange = resolved, groups = groups) }
            item { SummarySection(rows = windowRows, effectiveRange = resolved, groups = groups) }
            item { BreakdownSection(groups = groups, rows = windowRows) }
            item { ZonesSection(windowRows) }
            if (recoveryTrend.isNotEmpty()) {
                item { RecoveryTrendSection(recoveryTrend, recoveryRange.localizedCaption()) }
            }
            item {
            SessionsSection(
                vm = vm,
                rows = windowRows,
                selectionMode = selectionMode,
                selectedKeys = selectedKeys,
                onToggleSelectMode = {
                    selectionMode = !selectionMode
                    if (!selectionMode) selectedKeys = emptySet()
                },
                onToggleRow = { row ->
                    val key = sessionSelectionKey(row)
                    selectedKeys = if (key in selectedKeys) selectedKeys - key else selectedKeys + key
                },
                onMerge = { chosen ->
                    if (WorkoutMerge.resolvedSport(chosen) == null) {
                        mergeSportPrompt = chosen
                    } else {
                        vm.mergeWorkouts(chosen)
                        selectionMode = false; selectedKeys = emptySet()
                    }
                },
                onBulkDelete = { chosen ->
                    vm.bulkDeleteWorkouts(chosen)
                    selectionMode = false; selectedKeys = emptySet()
                },
                onCancelSelect = { selectionMode = false; selectedKeys = emptySet() },
                onEdit = { dialog = DialogTarget(it) },
                onRelabel = { row, sport ->
                    vm.relabelDetected(row, sport)
                    pendingNoteSport = WorkoutEditing.displaySport(sport)
                },
                onDismiss = { vm.dismissDetected(it) },
                onDelete = { vm.deleteWorkout(it) },
            )
            }
        }
    }

    // #64: name an all-detected merge (no sport to inherit) before committing it.
    mergeSportPrompt?.let { chosen ->
        MergeSportDialog(
            onDismiss = { mergeSportPrompt = null },
            onPick = { sport ->
                vm.mergeWorkouts(chosen, sport)
                mergeSportPrompt = null
                selectionMode = false; selectedKeys = emptySet()
            },
        )
    }

    dialog?.let { target ->
        ManualWorkoutDialog(
            editing = target.editing,
            onDismiss = { dialog = null },
            onSave = { row, replacing ->
                vm.saveManualWorkout(row, replacing)
                pendingNoteSport = WorkoutEditing.displaySport(row.sport)
                dialog = null
            },
        )
    }
}

/** Drives the manual add/edit dialog. [editing] null = add a new workout, non-null = edit it. */
private data class DialogTarget(val editing: WorkoutRow?)

private data class WorkoutRecoveryTrendPoint(
    val startTs: Long,
    val result: HeartRateRecovery.Result,
)

// MARK: - Empty / loading state

@Composable
private fun EmptyWorkouts(loaded: Boolean, onAdd: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        DataPendingNote(
            title = uiString(R.string.l10n_workouts_screen_no_workouts_yet_85a92042),
            body = "No workouts yet. They come from your WHOOP and Apple Health history. " +
                "Import in Data Sources to bring them in, or add one you tracked elsewhere.",
        )
        if (loaded) AddWorkoutButton(onAdd)
    }
}

/**
 * The transient "personal pattern" caption shown after a manual save / relabel (#439) — an
 * Effort-tinted frosted strip with a chart glyph and the engine's "Sessions like this usually …"
 * sentence. Mirrors the macOS WorkoutsView.postLogBanner. Auto-dismisses (the caller clears it).
 */
@Composable
private fun PostLogNoteBanner(text: String) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.effortColor.copy(alpha = 0.10f))
            .border(1.dp, Palette.effortColor.copy(alpha = 0.22f), shape)
            .padding(12.dp)
            .semantics { contentDescription = text },
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.AutoMirrored.Filled.ShowChart,
            contentDescription = null,
            tint = Palette.effortColor,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(10.dp))
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

/** The "Add workout" pill — opens the manual add dialog. Shown on both the populated screen
 *  (in the range bar) and the empty state, so a user with no imports can still log a session. */
@Composable
private fun AddWorkoutButton(onAdd: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.accentMuted)
            .clickable(onClick = onAdd)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Add, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(uiString(R.string.l10n_workouts_screen_add_workout_a196a2cc), style = NoopType.subhead, color = Palette.accent)
    }
}

// MARK: - Range control

@Composable
private fun RangeBar(
    range: WorkoutRange,
    effectiveRange: WorkoutRange,
    rowCount: Int,
    fellBack: Boolean,
    filterActive: Boolean,
    onSelect: (WorkoutRange) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Phone width can't fit the labelled Add button beside the 5-segment range pill without
        // crushing/clipping one — stack them (button, then pill), matching the iPhone fix (#234/#339).
        AddWorkoutButton(onAdd)
        SegmentedPillControl(
            items = WorkoutRange.entries,
            selection = range,
            label = { it.label },
            onSelect = onSelect,
        )
        val unit = if (rowCount == 1) "session" else "sessions"
        // #64: append "· filtered" when a sport/source/search filter narrows the list.
        val suffix = if (filterActive) " · filtered" else ""
        val caption = if (fellBack) {
            "$rowCount $unit · sparse, widened to ${effectiveRange.caption}$suffix"
        } else {
            "$rowCount $unit · ${effectiveRange.caption}$suffix"
        }
        Text(
            caption,
            style = NoopType.footnote,
            color = if (fellBack) Palette.statusWarning else Palette.textTertiary,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

// MARK: - Filters (#64)

/** The origin classes offered in the Source filter, in a stable menu order (matches the row badges). */
private val SOURCE_FILTER_OPTIONS = listOf(
    WorkoutSource.WHOOP, WorkoutSource.APPLE, WorkoutSource.DETECTED,
    WorkoutSource.MANUAL, WorkoutSource.LIFTING, WorkoutSource.ACTIVITY_FILE,
)

/** The Source-filter menu label for an origin class. */
private fun sourceFilterLabel(c: WorkoutSource): String = when (c) {
    WorkoutSource.WHOOP -> "Whoop"
    WorkoutSource.APPLE -> "Apple"
    WorkoutSource.DETECTED -> "Detected"
    WorkoutSource.MANUAL -> "Manual"
    WorkoutSource.LIFTING -> "Lifting"
    WorkoutSource.ACTIVITY_FILE -> "File"
}

/**
 * #64: filter controls beside the range pill — a Sport menu, a Source menu, and a search field, with a
 * "×" clear chip that appears only when a filter is active. Mirrors the iOS WorkoutsView.filterBar; the
 * predicate is the pure [WorkoutFilter], these controls only drive its state.
 */
@Composable
private fun FilterBar(
    filter: WorkoutFilter,
    availableSports: List<String>,
    onSport: (String?) -> Unit,
    onSource: (WorkoutSource?) -> Unit,
    onSearch: (String) -> Unit,
    onClear: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilterPillMenu(
                title = filter.sport ?: "All sports",
                active = filter.sport != null,
                contentDescription = uiString(R.string.l10n_workouts_screen_filter_by_sport_bcbbcb3b),
            ) { dismiss ->
                DropdownMenuItem(
                    text = { Text(uiString(R.string.l10n_workouts_screen_all_sports_dfad56f1), style = NoopType.body, color = Palette.textPrimary) },
                    onClick = { onSport(null); dismiss() },
                )
                availableSports.forEach { s ->
                    DropdownMenuItem(
                        text = { Text(s, style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { onSport(s); dismiss() },
                    )
                }
            }
            FilterPillMenu(
                title = filter.sourceClass?.let { sourceFilterLabel(it) } ?: "All sources",
                active = filter.sourceClass != null,
                contentDescription = uiString(R.string.l10n_workouts_screen_filter_by_source_db11bbb7),
            ) { dismiss ->
                DropdownMenuItem(
                    text = { Text(uiString(R.string.l10n_workouts_screen_all_sources_c0e8e58c), style = NoopType.body, color = Palette.textPrimary) },
                    onClick = { onSource(null); dismiss() },
                )
                SOURCE_FILTER_OPTIONS.forEach { opt ->
                    DropdownMenuItem(
                        text = { Text(sourceFilterLabel(opt), style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { onSource(opt); dismiss() },
                    )
                }
            }
            if (filter.isActive) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .clickable(onClick = onClear)
                        .padding(horizontal = 8.dp, vertical = 6.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_workouts_screen_clear_filters_41222671) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Close, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(uiString(R.string.l10n_workouts_screen_clear_719ea396), style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
        }
        OutlinedTextField(
            value = filter.search,
            onValueChange = onSearch,
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(18.dp)) },
            trailingIcon = {
                if (filter.search.isNotEmpty()) {
                    IconButton(onClick = { onSearch("") }) {
                        Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_workouts_screen_clear_search_67300d0f), tint = Palette.textTertiary, modifier = Modifier.size(16.dp))
                    }
                }
            },
            placeholder = { Text(uiString(R.string.l10n_workouts_screen_search_sport_004b7928), style = NoopType.body, color = Palette.textTertiary) },
            singleLine = true,
            colors = workoutFieldColors(),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** A pill-styled dropdown filter menu: the current selection as its label, Effort-tinted when active. */
@Composable
private fun FilterPillMenu(
    title: String,
    active: Boolean,
    contentDescription: String,
    items: @Composable (dismiss: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(if (active) Palette.effortColor.copy(alpha = 0.14f) else Palette.surfaceInset.copy(alpha = 0.6f))
                .clickable { open = true }
                .padding(horizontal = 10.dp, vertical = 6.dp)
                .semantics { this.contentDescription = uiString(R.string.l10n_workouts_screen_contentdescription_title_5585ff52, contentDescription, title) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                style = NoopType.footnote,
                color = if (active) Palette.effortColor else Palette.textSecondary,
                maxLines = 1,
            )
            Spacer(Modifier.width(4.dp))
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                tint = if (active) Palette.effortColor else Palette.textSecondary,
                modifier = Modifier.size(14.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            items { open = false }
        }
    }
}

/** #64: name an all-detected merge (no sport to inherit) via the shared sport picker before committing. */
@Composable
private fun MergeSportDialog(onDismiss: () -> Unit, onPick: (String) -> Unit) {
    var sport by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_workouts_screen_name_the_merged_session_031b0d8b), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    uiString(R.string.l10n_workouts_screen_these_sessions_have_no_sport_label_53993414),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                SportPickerField(sport, onChange = { sport = it })
            }
        },
        confirmButton = {
            val context = LocalContext.current
            TextButton(onClick = {
                if (sport.isNotBlank()) {
                    // #297: naming a merge is a real selection too — parity with the macOS/iOS sheet,
                    // whose reused StartWorkoutSheet records on its action button.
                    RecentSportsPrefs.record(context, sport.trim())
                    onPick(sport.trim())
                }
            }, enabled = sport.isNotBlank()) {
                Text(uiString(R.string.l10n_workouts_screen_merge_ea8f0d02), style = NoopType.body, color = if (sport.isNotBlank()) Palette.accent else Palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(uiString(R.string.l10n_workouts_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary) }
        },
    )
}

/** #64: the selection key for a row (its natural key), stable across a reload so checkmarks persist. */
private fun sessionSelectionKey(row: WorkoutRow): String = "${row.startTs}|${row.sport}"

// MARK: - Liquid hero tokens (the liquid Workouts restyle)
//
// The frosted card the Effort vessel floats on, mirroring the iOS/Today LiquidTodayView heroCard. `fill`
// is a translucent near-black (mock rgba(13,14,20,.80)) so it floats over the day-of-sky; the vessel + the
// white count-up read crisp on it. Radius 26 + a white@0.11 hairline give the frosted-glass edge. (These
// are file-scoped to Workouts — the Today equivalents are private to that file.)
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS: Dp = 26.dp

// MARK: - Effort hero (typical-effort liquid vessel over the day-of-sky)
//
// The liquid restyle of the Effort hero: the typical session Effort as a filling LiquidVessel with the
// headline number counting up over it (the Today HeroScoreVessel idiom), inside a translucent near-black
// frosted card that floats over the screen-level liquid sky. The vessel FILL fraction reads the AVERAGE
// per-session strain on the stored 0–100 Effort axis (scale-independent, so the fill is identical whether
// the user's display scale is Effort 0–100 or WHOOP 0–21); the count-up NUMBER is shown on the user's
// scale via UnitFormatter, exactly as the old StrainGauge label was. The scenic backdrop + BevelGauge are
// gone — the frosted card does the contrast work over the sky, matching the iOS liquid hero.

@Composable
private fun EffortHero(
    rows: List<WorkoutRow>,
    effectiveRange: WorkoutRange,
    groups: List<SportGroup>,
) {
    val effortScale = UnitPrefs.effortScale(LocalContext.current)
    val strains = rows.mapNotNull { it.strain }
    val hasEffort = strains.isNotEmpty()
    val avgStrain = if (strains.isEmpty()) 0.0 else strains.sum() / strains.size
    // Fill fraction on the stored 0–100 Effort axis — scale-independent, so the vessel fills the same on
    // either display scale. The count-up number below tracks the user's chosen scale.
    val fraction = (avgStrain / 100.0).coerceIn(0.0, 1.0)
    val shownEffort = UnitFormatter.effortValue(avgStrain, effortScale)
    val totalTimeH = rows.mapNotNull { it.durationS }.sum() / 3600.0
    val modal = groups.firstOrNull()

    // The liquid hero CARD: a translucent near-black that floats over the day-of-sky so the vessel + white
    // count-up read crisp. Radius 26 + a faint white hairline give the frosted-glass edge of the iOS liquid
    // heroCard (heroFill = rgba(13,14,20,.80), stroke white@0.11). Matches the Today pilot.
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
            .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * CardAppearance.opacity))
            .border(1.dp, Color.White.copy(alpha = 0.11f * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
            .padding(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Overline("Typical effort", color = Palette.effortColor)
                Box(modifier = Modifier.size(140.dp), contentAlignment = Alignment.Center) {
                    LiquidVessel(
                        value = fraction,
                        tint = Palette.effortColor,
                        // Only slosh once a real Effort value is loaded; an empty window poses static + empty.
                        animated = hasEffort,
                        modifier = Modifier.size(140.dp),
                    )
                    if (hasEffort) {
                        // Count-up number over the vessel — white, tabular, a soft shadow for legibility,
                        // hit-transparent so the tap reaches the vessel (splash). Honours the Effort scale.
                        CountUpText(
                            // `shownEffort` is already the display-scaled value, so the interpolated `it` is
                            // in the user's scale — roll it up with the same one-decimal format as before.
                            value = shownEffort,
                            format = { oneDecimal(it) },
                            style = NoopType.number(30f, weight = FontWeight.Bold)
                                .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                            color = Color.White,
                            modifier = Modifier.clearAndSetSemantics {},
                        )
                    }
                }
            }
            Spacer(Modifier.width(20.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    uiString(R.string.l10n_workouts_screen_effort_this_effectiverange_heroword_0bd5e794, effectiveRange.heroWord),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                    HeroStat("Sessions", "${rows.size}", Palette.effortColor, Modifier.weight(1f))
                    HeroStat("Active", oneDecimal(totalTimeH) + "h", Palette.textPrimary, Modifier.weight(1f))
                }
                Text(
                    if (modal != null) "Mostly ${WorkoutEditing.displaySport(modal.sport)} (${effectiveRange.caption})."
                    else "Logged sessions across ${effectiveRange.caption}.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun HeroStat(title: String, value: String, tint: Color, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Overline(title)
        Text(value, style = NoopType.number(20f), color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: - Summary tiles (uniform StatTiles)

@Composable
private fun SummarySection(
    rows: List<WorkoutRow>,
    effectiveRange: WorkoutRange,
    groups: List<SportGroup>,
) {
    // Imperial/Metric display preference (D#103). Distances are stored in metres; the toggle re-labels
    // them. Read here so a change recomposes the tiles. Display-only — nothing stored changes.
    val unitSystem = UnitPrefs.system(LocalContext.current)
    val totalCount = rows.size
    val totalTimeH = rows.mapNotNull { it.durationS }.sum() / 3600.0
    val totalKcal = rows.mapNotNull { it.energyKcal }.sum()
    val totalKm = rows.mapNotNull { it.distanceM }.sum() / 1000.0
    val modal = groups.firstOrNull()

    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_workouts_screen_total_workouts_7abd421f),
                value = "$totalCount",
                caption = effectiveRange.caption,
                accent = Palette.effortColor,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_workouts_screen_total_time_8ce2e6c3),
                value = oneDecimal(totalTimeH) + "h",
                caption = "active",
                accent = Palette.textPrimary,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_workouts_screen_total_calories_0a49da20),
                value = grouped(totalKcal),
                caption = "kcal",
                accent = Palette.metricAmber,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_workouts_screen_total_distance_e8260e11),
                value = UnitFormatter.distanceFromKilometers(totalKm, unitSystem),
                caption = "covered",
                accent = Palette.metricCyan,
            )
        },
        { m ->
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_workouts_screen_most_active_cf01766b),
                value = modal?.sport ?: "–",
                caption = modal?.let { "${it.count} session${if (it.count == 1) "" else "s"}" },
                accent = Palette.textPrimary,
            )
        },
    )

    // Two-column grid so tile heights stay uniform on phone widths.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - Activity breakdown (per-sport NoopCards, identical layout)

@Composable
private fun BreakdownSection(groups: List<SportGroup>, rows: List<WorkoutRow>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = uiString(R.string.l10n_workouts_screen_activity_breakdown_214431d6),
            overline = "By sport",
            trailing = "${groups.size} sport${if (groups.size == 1) "" else "s"}",
        )
        // This sport's own sessions, so each card can carry an HR-zone mini-bar.
        groups.forEach { g -> SportCard(g, zones = zoneSummary(rows.filter { it.sport == g.sport })) }
    }
}

@Composable
private fun SportCard(g: SportGroup, zones: ZoneSummary?) {
    // Frosted Effort-tinted card with the sport glyph in the Effort world, plus an HR-zone mini-bar
    // when the sessions carry imported zones.
    NoopCard(tint = Palette.effortColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Identical header for every card.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    sportIcon(g.sport),
                    contentDescription = null,
                    tint = Palette.effortColor,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    WorkoutEditing.displaySport(g.sport),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(uiString(R.string.l10n_workouts_screen_g_count_247d8c10, g.count), style = NoopType.number(15f), color = Palette.effortBright)
            }
            if (zones != null) {
                SegmentBar(
                    segments = zones.minutes.mapIndexed { i, m ->
                        Palette.hrZoneColor(i + 1) to (m / zones.totalMinutes).toFloat()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    height = 8.dp,
                )
            }
            CardDivider()
            // Identical 4-up stat strip for every card.
            Row(modifier = Modifier.fillMaxWidth()) {
                MiniStat("Sessions", "${g.count}", Modifier.weight(1f))
                MiniStat("Time", oneDecimal(g.totalTimeH) + "h", Modifier.weight(1f))
                MiniStat("Kcal", grouped(g.totalKcal), Modifier.weight(1f), tint = Palette.metricAmber)
                MiniStat("Avg/sess", "${g.avgTimePerSessionMin.roundToInt()}m", Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun MiniStat(label: String, value: String, modifier: Modifier = Modifier, tint: Color = Palette.textPrimary) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Overline(label)
        Text(
            value,
            style = NoopType.number(15f),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - HR zones (imported per-workout zone split, one card)

@Composable
private fun ZonesSection(rows: List<WorkoutRow>) {
    val z = remember(rows) { zoneSummary(rows) } ?: return
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = uiString(R.string.l10n_workouts_screen_hr_zones_293d7175),
            overline = "Whoop import",
            trailing = "${z.sessionsWithZones} of ${rows.size} session${if (rows.size == 1) "" else "s"}",
        )
        NoopCard(tint = Palette.effortColor) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Proportional stacked bar — the Hypnogram geometry with zone colors.
                SegmentBar(
                    segments = z.minutes.mapIndexed { i, m ->
                        Palette.hrZoneColor(i + 1) to (m / z.totalMinutes).toFloat()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    height = 24.dp,
                )
                CardDivider()
                // 5-up stat strip, identical rhythm to the sport cards' MiniStat row.
                Row(modifier = Modifier.fillMaxWidth()) {
                    z.minutes.forEachIndexed { i, m ->
                        ZoneStat(i + 1, m, z.totalMinutes, Modifier.weight(1f))
                    }
                }
                Text(
                    uiString(R.string.l10n_workouts_screen_share_of_imported_zone_time_duration_b0985680),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ZoneStat(zone: Int, minutes: Double, total: Double, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(9.dp)
                    .background(Palette.hrZoneColor(zone), RoundedCornerShape(2.dp)),
            )
            Spacer(Modifier.width(5.dp))
            Overline("Z$zone")
        }
        Text(
            uiString(R.string.l10n_workouts_screen_minutes_total_100_roundtoint_5bb7c6d8, (minutes / total * 100).roundToInt()),
            style = NoopType.number(15f),
            color = Palette.textPrimary,
            maxLines = 1,
        )
        Text(durationLabel(minutes * 60), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
    }
}

// MARK: - All sessions (one NoopCard, uniform fixed-height rows)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionsSection(
    vm: AppViewModel,
    rows: List<WorkoutRow>,
    selectionMode: Boolean,
    selectedKeys: Set<String>,
    onToggleSelectMode: () -> Unit,
    onToggleRow: (WorkoutRow) -> Unit,
    onMerge: (List<WorkoutRow>) -> Unit,
    onBulkDelete: (List<WorkoutRow>) -> Unit,
    onCancelSelect: () -> Unit,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
) {
    var selectedRow by remember { mutableStateOf<WorkoutRow?>(null) }

    // #797: paginate the All-Sessions list. This card lives inside ONE LazyColumn item, so every session
    // row composes eagerly: a years-deep WHOOP/Apple import (hundreds to thousands of bouts) built the
    // whole table in one pass, a real jank/OOM contributor. Render a bounded page and grow it on demand,
    // so a heavy history opens fast and the user pages in the rest. Reset when the windowed range changes
    // (the row set changes identity), so switching range never leaves a stale "shown" count.
    var shownCount by remember(rows) { mutableStateOf(SESSIONS_PAGE_SIZE) }
    val visible = if (rows.size <= shownCount) rows else rows.take(shownCount)
    val remaining = rows.size - visible.size

    // #64: only MANUAL / DETECTED rows are selectable — a pure-imported list has nothing to merge/delete.
    val anySelectable = rows.any { WorkoutMerge.isMergeable(it) }
    val chosen = rows.filter { sessionSelectionKey(it) in selectedKeys }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader(title = uiString(R.string.l10n_workouts_screen_all_sessions_03bc4eb4), overline = "Log", trailing = "${rows.size} total")
            }
            if (anySelectable) SelectPill(selectionMode, onToggleSelectMode)
        }
        if (selectionMode) SelectionToolbar(chosen, onMerge, onBulkDelete, onCancelSelect)
        NoopCard(padding = 0.dp) {
            Column {
                SessionHeaderRow(selectionMode)
                FullDivider()
                visible.forEachIndexed { idx, row ->
                    SessionRow(
                        row = row,
                        background = if (idx % 2 == 1) Palette.surfaceInset.copy(alpha = 0.4f) else Color.Transparent,
                        selectionMode = selectionMode,
                        selected = sessionSelectionKey(row) in selectedKeys,
                        onToggleRow = onToggleRow,
                        onEdit = onEdit,
                        onRelabel = onRelabel,
                        onDismiss = onDismiss,
                        onDelete = onDelete,
                        onClick = { selectedRow = it },
                    )
                    if (idx != visible.lastIndex) FullDivider(alpha = 0.5f)
                }
                // "Show more" pages in the next [SESSIONS_PAGE_SIZE] bouts. Hidden once everything is shown.
                if (remaining > 0) {
                    FullDivider(alpha = 0.5f)
                    val more = minOf(remaining, SESSIONS_PAGE_SIZE)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { shownCount += SESSIONS_PAGE_SIZE }
                            .semantics { contentDescription = uiString(R.string.l10n_workouts_screen_show_more_more_sessions_25bce755, more) }
                            .padding(vertical = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            uiString(R.string.l10n_workouts_screen_show_more_more_remaining_remaining_d1662e67, more, remaining),
                            style = NoopType.subhead,
                            color = Palette.accent,
                        )
                    }
                }
            }
        }
    }

    selectedRow?.let { row ->
        WorkoutDetailSheet(vm = vm, row = row, onDismiss = { selectedRow = null })
    }
}

/** #64: the "Select" pill in the All-Sessions header — toggles multi-select mode. */
@Composable
private fun SelectPill(selectionMode: Boolean, onToggle: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selectionMode) Palette.effortColor.copy(alpha = 0.14f) else Palette.surfaceInset.copy(alpha = 0.6f))
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .semantics {
                contentDescription = if (selectionMode) "Finish selecting" else "Select sessions to merge or delete"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (selectionMode) "Done" else "Select",
            style = NoopType.footnote,
            color = if (selectionMode) Palette.effortColor else Palette.accent,
        )
    }
}

/** #64: the Merge / Delete / Cancel strip shown above the card in selection mode. Merge needs 2+ eligible
 *  rows; Delete needs 1+. Imported rows are never selectable, so the chosen set is always mergeable. */
@Composable
private fun SelectionToolbar(
    chosen: List<WorkoutRow>,
    onMerge: (List<WorkoutRow>) -> Unit,
    onBulkDelete: (List<WorkoutRow>) -> Unit,
    onCancel: () -> Unit,
) {
    val canMerge = WorkoutMerge.canMerge(chosen)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .background(Palette.effortColor.copy(alpha = 0.08f))
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ToolbarAction(
            "Merge (${chosen.size})", Icons.AutoMirrored.Filled.MergeType,
            tint = if (canMerge) Palette.effortColor else Palette.textTertiary,
            enabled = canMerge, onClick = { onMerge(chosen) },
        )
        ToolbarAction(
            "Delete (${chosen.size})", Icons.Filled.Delete,
            tint = if (chosen.isEmpty()) Palette.textTertiary else Palette.metricRose,
            enabled = chosen.isNotEmpty(), onClick = { onBulkDelete(chosen) },
        )
        Spacer(Modifier.weight(1f))
        Text(
            uiString(R.string.l10n_workouts_screen_cancel_77dfd213),
            style = NoopType.subhead,
            color = Palette.textSecondary,
            modifier = Modifier.clickable(onClick = onCancel).padding(4.dp),
        )
    }
}

@Composable
private fun ToolbarAction(label: String, icon: ImageVector, tint: Color, enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 4.dp, vertical = 4.dp)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, style = NoopType.subhead, color = tint)
    }
}

/** #797: the All-Sessions list renders in pages of this size and grows on "Show more", so a years-deep
 *  workout history doesn't compose every row in one pass inside the single enclosing card. */
private const val SESSIONS_PAGE_SIZE = 50

@Composable
private fun SessionHeaderRow(selectionMode: Boolean = false) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(34.dp)
            .padding(horizontal = Metrics.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // #64: a leading spacer over the per-row selection glyph, so the columns stay aligned in select mode.
        if (selectionMode) Spacer(Modifier.width(30.dp))
        // Weights mirror SessionRow (#157: Date widened for the time range, taken from Sport).
        ColHeader("Date", Modifier.weight(1.7f), TextAlign.Start)
        ColHeader("Sport", Modifier.weight(1.3f), TextAlign.Start)
        ColHeader("Dur", Modifier.weight(1f), TextAlign.End)
        ColHeader("HR", Modifier.weight(1.1f), TextAlign.End)
        ColHeader("Kcal", Modifier.weight(1f), TextAlign.End)
        ColHeader("Src", Modifier.weight(1f), TextAlign.End)
        // Trailing spacer column over the per-row overflow menu, so headers line up with the cells.
        Spacer(Modifier.width(32.dp))
    }
}

@Composable
private fun ColHeader(text: String, modifier: Modifier, align: TextAlign) {
    // Built from the overline style directly (not the Overline composable) so the
    // numeric columns can right-align their headers over the right-aligned cells.
    Text(
        text = text.uppercase(),
        style = NoopType.overline,
        color = Palette.textSecondary,
        textAlign = align,
        maxLines = 1,
        modifier = modifier,
    )
}

@Composable
private fun SessionRow(
    row: WorkoutRow,
    background: Color,
    selectionMode: Boolean,
    selected: Boolean,
    onToggleRow: (WorkoutRow) -> Unit,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
    onClick: (WorkoutRow) -> Unit,
) {
    // #64: only MANUAL / DETECTED rows are selectable — imported history is read-only.
    val selectable = WorkoutMerge.isMergeable(row)
    val rowLabel = "${WorkoutEditing.displaySport(row.sport)}, ${dateLabel(row.startTs)}" +
        if (selectionMode) {
            when {
                !selectable -> ". Imported, can't be merged."
                selected -> ". Selected."
                else -> ". Not selected."
            }
        } else ""
    // liquidPress on the whole tappable row — it settles inward on press (the iOS LiquidPressStyle feel).
    // The SAME interactionSource drives the clickable + the press. The edit/delete overflow menu and the
    // selection glyph stay their own hit targets on top.
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .liquidPress(interaction)
            .background(background)
            .clickable(
                interactionSource = interaction,
                indication = null,
            ) {
                if (selectionMode) { if (selectable) onToggleRow(row) } else onClick(row)
            }
            .height(56.dp)
            .padding(start = Metrics.cardPadding)
            .semantics { contentDescription = rowLabel },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // #64: leading selection glyph — filled/hollow check for a mergeable row, or a lock for imported.
        if (selectionMode) {
            if (selectable) {
                Icon(
                    if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (selected) Palette.effortColor else Palette.textTertiary,
                    modifier = Modifier.size(22.dp),
                )
            } else {
                Icon(
                    Icons.Filled.Lock,
                    contentDescription = null,
                    tint = Palette.textTertiary.copy(alpha = 0.6f),
                    modifier = Modifier.size(16.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
        }
        // Date + time range (#157). The 0.3f comes out of Sport: "HH:mm–HH:mm" clips at footnote
        // size in the old 1.4f, while sport names already ellipsize gracefully.
        Column(modifier = Modifier.weight(1.7f)) {
            Text(dateLabel(row.startTs), style = NoopType.subhead, color = Palette.textPrimary, maxLines = 1)
            Text(timeRangeLabel(row.startTs, row.endTs), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
        }
        // Sport ("detected" reads as "Activity").
        Row(modifier = Modifier.weight(1.3f), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                sportIcon(row.sport),
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(7.dp))
            Text(
                WorkoutEditing.displaySport(row.sport),
                style = NoopType.subhead,
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Cell(durationLabel(row.durationS), Modifier.weight(1f))
        Cell(
            row.avgHr?.toString() ?: "–",
            Modifier.weight(1.1f),
            color = if (row.avgHr != null) Palette.metricRose else null,
        )
        Cell(
            row.energyKcal?.let { grouped(it) } ?: "–",
            Modifier.weight(1f),
            color = if (row.energyKcal != null) Palette.metricAmber else null,
        )
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            val (srcLabel, srcTint) = row.sourceBadge
            SourceBadge(srcLabel, tint = srcTint)
        }
        // #64: hide the per-row ••• menu in selection mode (the toolbar owns the actions there); keep a
        // 32dp spacer so the Src column stays aligned with the header.
        if (selectionMode) Spacer(Modifier.width(32.dp)) else RowActionsMenu(row, onEdit, onRelabel, onDismiss, onDelete)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WorkoutDetailSheet(vm: AppViewModel, row: WorkoutRow, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Per-window reads (#410): the HR curve (downsampled bucket means) and the HR-zone split. Zones
    // prefer the imported per-workout percentages (a WHOOP-computed split); only when the row carries
    // none do we derive zone-minutes from the strap's own raw HR — so we never overwrite a real
    // imported split with an on-device approximation.
    var hrCurve by remember(row.startTs) { mutableStateOf<List<Double>>(emptyList()) }
    var zoneMinutes by remember(row.startTs) { mutableStateOf<List<Double>?>(null) }
    var zonesFromImport by remember(row.startTs) { mutableStateOf(false) }
    var heartRateRecovery by remember(row.startTs) { mutableStateOf<HeartRateRecovery.Result?>(null) }
    // Steps for an on-foot sport (#398): the strap's own counter over the window, computed at display time
    // so it "fills in after sync". null for non-foot sports or when no strap counter covers the window.
    var steps by remember(row.startTs) { mutableStateOf<Int?>(null) }
    LaunchedEffect(row.startTs, row.endTs) {
        hrCurve = vm.workoutHrBuckets(row.startTs, row.endTs, row.source, row.deviceId).map { it.avgBpm }
        steps = if (WorkoutSport.isOnFoot(row.sport)) vm.workoutSteps(row.startTs, row.endTs) else null
        val imported = parseZonePercents(row.zonesJSON)
        if (imported != null) {
            val durMin = (row.durationS ?: (row.endTs - row.startTs).toDouble()) / 60.0
            if (durMin > 0.0) {
                zoneMinutes = imported.map { durMin * it / 100.0 }
                zonesFromImport = true
            }
        }
        if (zoneMinutes == null) {
            zoneMinutes = vm.workoutZoneMinutes(row.startTs, row.endTs, row.source, row.deviceId)
            zonesFromImport = false
        }
        heartRateRecovery = vm.workoutHeartRateRecovery(row.startTs, row.endTs, row.source, row.deviceId)
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.surfaceOverlay,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    sportIcon(row.sport),
                    contentDescription = null,
                    tint = Palette.effortColor,
                    modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(WorkoutEditing.displaySport(row.sport), style = NoopType.title2, color = Palette.textPrimary)
                    Text(dateLabel(row.startTs), style = NoopType.footnote, color = Palette.textTertiary)
                }
                val (srcLabel, srcTint) = row.sourceBadge
                SourceBadge(srcLabel, tint = srcTint)
            }
            CardDivider()
            DetailRow("Time", timeRangeLabel(row.startTs, row.endTs))
            DetailRow("Duration", durationLabel(row.durationS))
            if (row.avgHr != null) DetailRow("Avg HR", "${row.avgHr} bpm")
            if (row.maxHr != null) DetailRow("Max HR", "${row.maxHr} bpm")
            if (row.energyKcal != null) DetailRow("Calories", "${grouped(row.energyKcal)} kcal")
            if (row.distanceM != null) {
                val unitSystem = UnitPrefs.system(LocalContext.current)
                DetailRow("Distance", UnitFormatter.distanceFromKilometers(row.distanceM / 1000.0, unitSystem))
            }
            steps?.let { DetailRow("Steps", "${grouped(it.toDouble())} steps") }  // #398, on-foot sports
            if (!row.notes.isNullOrBlank()) DetailRow("Notes", row.notes)

            // #796 - per-session Effort contribution. The session's captured strain re-homed from a plain
            // value row into a prominent Effort-amber card (the big count-up value + the "This session"
            // overline + an explainer), mirroring the iOS WorkoutDetailView.effortCard. Gated on a captured
            // strain - an imported session with none simply omits the card. The display honours the Effort
            // scale toggle (#268), so a WHOOP-axis user sees the rescaled 0–21 value; the stored value is
            // unchanged. Presentation only - no new data is computed here.
            row.strain?.let { strain ->
                val effortScale = UnitPrefs.effortScale(LocalContext.current)
                CardDivider()
                SessionEffortCard(strain = strain, effortScale = effortScale)
            }

            // HR curve over the session window (#410). A faint baseline shows under 2 points.
            if (hrCurve.size > 1) {
                CardDivider()
                Overline("Heart rate")
                LineChart(
                    values = hrCurve,
                    modifier = Modifier.height(Metrics.compactChartHeight),
                    color = Palette.effortColor,
                    fill = true,
                )
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val lo = hrCurve.minOrNull()?.roundToInt() ?: 0
                    val hi = hrCurve.maxOrNull()?.roundToInt() ?: 0
                    MiniStat("Avg", row.avgHr?.let { "$it bpm" } ?: "–", Modifier.weight(1f))
                    MiniStat("Peak", (row.maxHr ?: hi).let { "$it bpm" }, Modifier.weight(1f))
                    MiniStat("Low", "$lo bpm", Modifier.weight(1f))
                }
                // #18: the Avg HR shown above can be EDITED on the manual sheet while the graph, zones and
                // Effort stay from the recorded session (preservingCaptured keeps the captured strain/zones).
                // When the typed average disagrees materially with this trace's own mean AND the row carries
                // that captured strain/zones, say so plainly. We do NOT re-score from the typed number.
                // Parity with macOS WorkoutDetailView.avgHrEditedDisclosure.
                val traceMean = hrCurve.sum() / hrCurve.size
                val captured = row.strain != null || !row.zonesJSON.isNullOrEmpty()
                if (captured && row.avgHr != null && kotlin.math.abs(row.avgHr - traceMean) > 3.0) {
                    Text(
                        uiString(R.string.l10n_workouts_screen_the_average_above_was_edited_the_0a7881f0),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            // HR-zone split — imported percentages when present, else derived from strap HR (#410).
            zoneMinutes?.let { z ->
                val total = z.sum()
                if (total > 0.0) {
                    CardDivider()
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Overline("HR zones", modifier = Modifier.weight(1f))
                        Text(
                            if (zonesFromImport) "Whoop import" else "From strap HR",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    SegmentBar(
                        segments = z.mapIndexed { i, m -> Palette.hrZoneColor(i + 1) to (m / total).toFloat() },
                        modifier = Modifier.fillMaxWidth(),
                        height = 24.dp,
                    )
                    Row(modifier = Modifier.fillMaxWidth()) {
                        z.forEachIndexed { i, m -> ZoneStat(i + 1, m, total, Modifier.weight(1f)) }
                    }
                    Text(
                        if (zonesFromImport) "WHOOP's imported per-zone split for this session."
                        else "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate).",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            heartRateRecovery?.let {
                CardDivider()
                HeartRateRecoveryCard(it)
            }
        }
    }
}

/** Per-workout HRR readout (#516). Values are signed bpm changes from the exercise-end HR; missing
 *  minute windows remain dashes rather than being interpolated across a strap disconnect. */
@Composable
private fun HeartRateRecoveryCard(result: HeartRateRecovery.Result) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionHeader(
            title = uiString(R.string.l10n_workouts_screen_heart_rate_recovery_516),
            overline = uiString(R.string.l10n_workouts_screen_after_high_intensity_effort_516),
            trailing = uiString(R.string.l10n_workouts_screen_peak_hr_bpm_516, result.endHr),
        )
        NoopCard(tint = Palette.metricRose) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(modifier = Modifier.fillMaxWidth()) {
                    RecoveryStat(
                        uiString(R.string.l10n_workouts_screen_hrr_one_minute_516),
                        result.after1Minute,
                        Modifier.weight(1f),
                    )
                    RecoveryStat(
                        uiString(R.string.l10n_workouts_screen_hrr_two_minutes_516),
                        result.after2Minutes,
                        Modifier.weight(1f),
                    )
                    RecoveryStat(
                        uiString(R.string.l10n_workouts_screen_hrr_five_minutes_516),
                        result.after5Minutes,
                        Modifier.weight(1f),
                    )
                }
                CardDivider()
                Text(
                    uiString(R.string.l10n_workouts_screen_hrr_explanation_516),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun RecoveryStat(label: String, value: Int?, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.semantics {
            contentDescription = uiString(
                R.string.l10n_workouts_screen_hrr_accessibility_516,
                label,
                value?.toString() ?: uiString(R.string.l10n_workouts_screen_hrr_not_available_516),
            )
        },
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Overline(label)
        Text(
            value?.toString() ?: "–",
            style = NoopType.number(24f),
            color = value?.let { if (it >= 0) Palette.statusPositive else Palette.statusWarning }
                ?: Palette.textTertiary,
        )
        Text(
            uiString(R.string.l10n_workouts_screen_hrr_bpm_516),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

/** Shared-axis 1/2/5-minute HRR trend (#516). These are raw bpm changes, not normalized values, so the
 *  distance between lines remains meaningful. Missing minute windows are omitted from that series. */
@Composable
private fun RecoveryTrendSection(points: List<WorkoutRecoveryTrendPoint>, rangeCaption: String) {
    val oneColor = Palette.metricRose
    val twoColor = Palette.metricCyan
    val fiveColor = Palette.metricPurple
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = uiString(R.string.l10n_workouts_screen_recovery_trend_516),
            overline = uiString(R.string.l10n_workouts_screen_hrr_range_516, rangeCaption),
            trailing = uiPlural(
                R.plurals.l10n_workouts_screen_hrr_workout_count_516,
                points.size,
                points.size,
            ),
        )
        NoopCard(tint = Palette.metricRose) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                RecoveryTrendChart(
                    points = points,
                    oneColor = oneColor,
                    twoColor = twoColor,
                    fiveColor = fiveColor,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                )
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(dateLabel(points.first().startTs), style = NoopType.footnote, color = Palette.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(dateLabel(points.last().startTs), style = NoopType.footnote, color = Palette.textTertiary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    RecoveryLegend(uiString(R.string.l10n_workouts_screen_hrr_one_minute_516), oneColor)
                    RecoveryLegend(uiString(R.string.l10n_workouts_screen_hrr_two_minutes_516), twoColor)
                    RecoveryLegend(uiString(R.string.l10n_workouts_screen_hrr_five_minutes_516), fiveColor)
                }
                CardDivider()
                Text(
                    uiString(R.string.l10n_workouts_screen_hrr_trend_explanation_516),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun RecoveryLegend(label: String, color: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(androidx.compose.foundation.shape.CircleShape).background(color))
        Text(label, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun RecoveryTrendChart(
    points: List<WorkoutRecoveryTrendPoint>,
    oneColor: Color,
    twoColor: Color,
    fiveColor: Color,
    modifier: Modifier = Modifier,
) {
    val allValues = points.flatMap {
        listOfNotNull(it.result.after1Minute, it.result.after2Minutes, it.result.after5Minutes)
    }
    if (allValues.isEmpty()) return
    val low = allValues.minOrNull() ?: 0
    val high = allValues.maxOrNull() ?: low
    val padding = maxOf(4.0, (high - low) * 0.12)
    val yMin = low - padding
    val yMax = high + padding
    val xMin = points.first().startTs
    val xMax = points.last().startTs
    val chartDescription = uiString(R.string.l10n_workouts_screen_hrr_chart_accessibility_516)

    Canvas(modifier = modifier.semantics { contentDescription = chartDescription }) {
        val gridColor = Palette.hairline
        repeat(4) { index ->
            val y = size.height * index / 3f
            drawLine(gridColor, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
        }

        fun x(ts: Long): Float = if (xMax == xMin) size.width / 2f
            else ((ts - xMin).toDouble() / (xMax - xMin).toDouble() * size.width).toFloat()
        fun y(value: Int): Float =
            (size.height - ((value - yMin) / (yMax - yMin) * size.height)).toFloat()

        fun drawSeries(color: Color, pick: (HeartRateRecovery.Result) -> Int?) {
            val series = points.mapNotNull { point -> pick(point.result)?.let { point.startTs to it } }
            if (series.isEmpty()) return
            val path = Path()
            series.forEachIndexed { index, (ts, value) ->
                val px = x(ts)
                val py = y(value)
                if (index == 0) path.moveTo(px, py) else path.lineTo(px, py)
            }
            if (series.size > 1) {
                drawPath(
                    path = path,
                    color = color,
                    style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                )
            }
            series.forEach { (ts, value) -> drawCircle(color, radius = 3.5.dp.toPx(), center = Offset(x(ts), y(value))) }
        }

        drawSeries(oneColor) { it.after1Minute }
        drawSeries(twoColor) { it.after2Minutes }
        drawSeries(fiveColor) { it.after5Minutes }
    }
}

/**
 * #796 - the workout detail's per-session Effort contribution card. The Effort-amber tinted [NoopCard]
 * carries a "This session" overline, the captured strain as a big count-up value (the NOOP signature),
 * its scale caption (Effort 0–100 or strain 0–21), and a one-line explainer. Mirrors the iOS
 * WorkoutDetailView.effortCard: same colour world, same count-up, same copy. [strain] is the stored
 * 0–100 Effort value; [effortScale] only changes how it is DISPLAYED, never the stored number.
 */
@Composable
private fun SessionEffortCard(strain: Double, effortScale: EffortScale) {
    val shown = UnitFormatter.effortValue(strain, effortScale)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        SectionHeader("Effort", overline = "This session")
        NoopCard(tint = Palette.effortColor) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(Metrics.space2),
                    modifier = Modifier.semantics {
                        contentDescription =
                            uiString(R.string.l10n_workouts_screen_this_session_s_effort_onedecimal_shown_74eed8be, oneDecimal(shown)) +
                                (if (effortScale == EffortScale.WHOOP) "0 to 21 strain" else "0 to 100 Effort") +
                                " scale."
                    },
                ) {
                    CountUpText(
                        value = shown,
                        format = { oneDecimal(it) },
                        style = NoopType.number(34f),
                        color = Palette.effortBright,
                    )
                    Text(
                        if (effortScale == EffortScale.WHOOP) "strain (0-21)" else "Effort (0-100)",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text(
                    uiString(R.string.l10n_workouts_screen_this_session_s_contribution_to_the_fe40ab3d),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Overline(label)
        Text(
            value,
            style = NoopType.body,
            color = Palette.textPrimary,
            maxLines = 3,
            textAlign = TextAlign.End,
            modifier = Modifier.padding(start = 16.dp),
        )
    }
}

/**
 * Per-row overflow menu. A DETECTED bout can be re-labelled (becomes a real manual session that
 * survives re-detection) or dismissed (durably hidden so it doesn't come back). A MANUAL session can
 * be edited or deleted. Imported WHOOP / Apple rows are read-only — we never rewrite imported history
 * — but can be duplicated as an editable manual copy. (#107)
 */
@Composable
private fun RowActionsMenu(
    row: WorkoutRow,
    onEdit: (WorkoutRow) -> Unit,
    onRelabel: (WorkoutRow, String) -> Unit,
    onDismiss: (WorkoutRow) -> Unit,
    onDelete: (WorkoutRow) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var relabelOpen by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Filled.MoreVert, contentDescription = uiString(R.string.l10n_workouts_screen_workout_actions_88be5c37),
                tint = Palette.textTertiary, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            when (WorkoutEditing.classify(row.source)) {
                WorkoutSource.DETECTED -> {
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_re_label_as_33fec7b2), style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; relabelOpen = true },
                    )
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_edit_details_9e62bb59), style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row) },
                    )
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_dismiss_not_a_workout_560c7bb5), style = NoopType.body, color = Palette.statusCritical) },
                        onClick = { open = false; onDismiss(row) },
                    )
                }
                WorkoutSource.MANUAL -> {
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_edit_b454359e), style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row) },
                    )
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_delete_f6fdbe48), style = NoopType.body, color = Palette.statusCritical) },
                        onClick = { open = false; onDelete(row) },
                    )
                }
                WorkoutSource.WHOOP, WorkoutSource.APPLE, WorkoutSource.LIFTING, WorkoutSource.ACTIVITY_FILE -> {
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_workouts_screen_duplicate_as_manual_2d580d46), style = NoopType.body, color = Palette.textPrimary) },
                        onClick = { open = false; onEdit(row.copy(source = "manual", sport = WorkoutEditing.displaySport(row.sport))) },
                    )
                }
            }
        }
        // Sub-menu of common sports for re-labelling a detected bout.
        DropdownMenu(expanded = relabelOpen, onDismissRequest = { relabelOpen = false }) {
            WorkoutEditing.relabelSports.forEach { sport ->
                DropdownMenuItem(
                    text = { Text(sport, style = NoopType.body, color = Palette.textPrimary) },
                    onClick = { relabelOpen = false; onRelabel(row, sport) },
                )
            }
        }
    }
}

@Composable
private fun Cell(text: String, modifier: Modifier, color: Color? = null) {
    Text(
        text,
        style = NoopType.number(13f, androidx.compose.ui.text.font.FontWeight.Normal),
        color = color ?: if (text == "–") Palette.textTertiary else Palette.textPrimary,
        textAlign = TextAlign.End,
        maxLines = 1,
        modifier = modifier,
    )
}

// MARK: - Manual workout add / edit dialog
//
// Five inputs — sport, start (date-time, here entered as minutes-ago for simplicity on phone),
// duration, average HR, calories — validated by WorkoutEditing.buildManualRow (the same honest-row
// rules the engine uses). Editing carries the original's captured maxHr/strain/route over via
// preservingCaptured so changing sport/duration never wipes them. Android mirror of macOS
// ManualWorkoutSheet (the macOS sheet uses a DatePicker; on phone we take "minutes ago" to keep the
// dialog to plain numeric fields — the persisted startTs is identical).

@Composable
private fun ManualWorkoutDialog(
    editing: WorkoutRow?,
    onDismiss: () -> Unit,
    onSave: (row: WorkoutRow, replacing: WorkoutRow?) -> Unit,
) {
    val nowSec = System.currentTimeMillis() / 1000
    // Pre-fill from the edited row ("detected" shown as "Activity" so a re-label starts clean).
    var sport by remember { mutableStateOf(editing?.let { WorkoutEditing.displaySport(it.sport) } ?: "") }
    // #598 — absolute start date+time (parity with the macOS/iOS sheet's DatePicker) instead of the old
    // "minutes ago" field. Defaults to the edited row's start, or one hour ago for a fresh add.
    var startMillis by remember {
        mutableStateOf((editing?.startTs ?: (nowSec - 3_600)) * 1000L)
    }
    var durationMin by remember {
        mutableStateOf(
            editing?.let { (((it.durationS ?: (it.endTs - it.startTs).toDouble()) / 60).roundToInt()).coerceAtLeast(1).toString() }
                ?: "45",
        )
    }
    var avgHr by remember { mutableStateOf(editing?.avgHr?.toString() ?: "") }
    var kcal by remember { mutableStateOf(editing?.energyKcal?.let { it.roundToInt().toString() } ?: "") }

    // Build the validated row (null disables Save). Start = the chosen date+time. Captured fields preserved.
    val built: WorkoutRow? = run {
        val dur = durationMin.trim().toIntOrNull()
        val hrText = avgHr.trim()
        val kText = kcal.trim()
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — reject before building.
        val hr: Int? = if (hrText.isEmpty()) null else hrText.toIntOrNull()
        val k: Double? = if (kText.isEmpty()) null else kText.toDoubleOrNull()
        if (dur == null) return@run null
        if (hrText.isNotEmpty() && hr == null) return@run null
        if (kText.isNotEmpty() && k == null) return@run null
        // A manual workout ALWAYS lives under the strap source (where live-tracked sessions land), so
        // a "duplicate as manual" of an imported apple-health/whoop row never writes back to it.
        val base = WorkoutEditing.buildManualRow(
            deviceId = "my-whoop",
            startSeconds = (startMillis / 1000L).coerceAtMost(nowSec),
            durationMin = dur,
            sport = sport,
            avgHr = hr,
            energyKcal = k,
            nowSeconds = nowSec,
        ) ?: return@run null
        WorkoutEditing.preservingCaptured(base, editing)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            // A small Effort-world glyph so the dialog reads as part of the workouts (amber) world.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Palette.effortColor.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = Palette.effortColor,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(if (editing == null) "Add Workout" else "Edit Workout",
                    style = NoopType.title2, color = Palette.textPrimary)
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SportPickerField(sport, onChange = { sport = it })
                StartTimeField(startMillis, onPick = { startMillis = it })
                DialogField("Duration (minutes)", durationMin, onChange = { durationMin = it }, numeric = true)
                DialogField("Avg HR (bpm, optional)", avgHr, onChange = { avgHr = it }, numeric = true)
                DialogField("Calories (kcal, optional)", kcal, onChange = { kcal = it }, numeric = true)
                if (built == null) {
                    Text(
                        uiString(R.string.l10n_workouts_screen_enter_a_sport_a_positive_duration_3da88ad5),
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
                // #18: editing the Avg HR on a row that carries CAPTURED strain/zones saves the typed
                // average while the HR graph, zones and Effort stay from the recorded session
                // (preservingCaptured keeps them verbatim). That mismatch is silent, so say so plainly.
                // We do NOT re-score from one number. Parity with macOS ManualWorkoutSheet.avgHrEditedNote.
                if (built != null && WorkoutEditing.avgHrEdited(built, editing)) {
                    Text(
                        uiString(R.string.l10n_workouts_screen_avg_hr_is_shown_as_typed_2c8db249),
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
            }
        },
        confirmButton = {
            // Pass `replacing` only when editing an existing MANUAL or DETECTED row (the repo replaces
            // it: a manual key change deletes the stale row; a detected original is durably dismissed).
            // Duplicating an imported WHOOP/Apple row is a pure ADD — never pass it, or a changed key
            // would delete the imported original.
            val replacing = editing?.takeIf {
                val c = WorkoutEditing.classify(it.source)
                c == WorkoutSource.MANUAL || c == WorkoutSource.DETECTED
            }
            val context = LocalContext.current
            TextButton(onClick = {
                built?.let {
                    // #297: a confirmed save is a real selection — fold the (validated) sport into the recents.
                    RecentSportsPrefs.record(context, it.sport)
                    onSave(it, replacing)
                }
            }, enabled = built != null) {
                Text(if (editing == null) "Add" else "Save",
                    style = NoopType.body, color = if (built != null) Palette.accent else Palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_workouts_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/**
 * Sport field for the manual add/edit dialog — a searchable PICKER over the shared catalogue
 * ([WorkoutSport.all], the SAME list the live "Start a workout" sheet uses) with a free-text
 * FALLBACK so an unusual sport NOOP doesn't enumerate still saves exactly as typed (#519). The text
 * field IS the value: typing filters the catalogue beneath it; tapping a match fills the field; not
 * tapping anything keeps whatever was typed. The list only shows while the typed text is a partial
 * match (an exact catalogue hit, or a free-typed sport, collapses it).
 */
/**
 * Absolute start date + time for the manual add/edit dialog — parity with the macOS/iOS sheet's
 * DatePicker (#598; the old Android sheet only took "minutes ago"). A tappable row that opens a date
 * picker, then chains to a time picker, both capped at now (you can't log a workout in the future).
 */
@Composable
private fun StartTimeField(millis: Long, onPick: (Long) -> Unit) {
    val context = LocalContext.current
    val label = remember(millis) { SimpleDateFormat("d MMM yyyy, h:mm a", Locale.US).format(java.util.Date(millis)) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(uiString(R.string.l10n_workouts_screen_started_faa9e7e7), style = NoopType.footnote, color = Palette.textSecondary)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, RoundedCornerShape(10.dp))
                .clickable {
                    val cal = Calendar.getInstance().apply { timeInMillis = millis }
                    DatePickerDialog(
                        context,
                        { _, y, mo, d ->
                            TimePickerDialog(
                                context,
                                { _, h, mi ->
                                    val c = Calendar.getInstance().apply {
                                        timeInMillis = millis
                                        set(Calendar.YEAR, y); set(Calendar.MONTH, mo); set(Calendar.DAY_OF_MONTH, d)
                                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, mi); set(Calendar.SECOND, 0)
                                    }
                                    onPick(c.timeInMillis.coerceAtMost(System.currentTimeMillis()))
                                },
                                cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE), false,
                            ).show()
                        },
                        cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH),
                    ).apply { datePicker.maxDate = System.currentTimeMillis() }.show()
                }
                .padding(horizontal = 12.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.width(16.dp))
            Text(label, style = NoopType.body, color = Palette.textPrimary)
        }
    }
}

@Composable
private fun SportPickerField(value: String, onChange: (String) -> Unit) {
    val context = LocalContext.current
    val sportScroll = rememberScrollState()
    val q = value.trim()
    val matches = if (q.isEmpty()) WorkoutSport.all
    else WorkoutSport.all.filter { it.name.contains(q, ignoreCase = true) }
    // Hide the list once the field exactly equals a catalogue name (a settled choice) or once it's a
    // free-typed sport with no partial matches — so the dialog isn't permanently half-covered.
    val exact = WorkoutSport.all.any { it.name.equals(q, ignoreCase = true) }
    val showList = matches.isNotEmpty() && !exact
    // #297: the user's last selections, one tap away above the full catalogue. Raw stored names —
    // this picker allows free text, so an off-catalogue recent stays selectable here (it just
    // carries no GPS hint). Only rendered while the field is empty (typing means searching).
    val recents = if (q.isEmpty()) RecentSportsPrefs.recent(context) else emptyList()

    DialogField("Sport", value, onChange = onChange, placeholder = uiString(R.string.l10n_workouts_screen_e_g_running_7dc6eba4))
    if (showList) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 168.dp)
                .verticalScroll(sportScroll),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (recents.isNotEmpty()) {
                Overline("Recent", modifier = Modifier.padding(top = 6.dp))
                recents.forEach { name ->
                    SportSuggestionRow(
                        name = name,
                        isDistance = WorkoutSport.all
                            .firstOrNull { it.name.equals(name, ignoreCase = true) }?.isDistanceSport == true,
                        onPick = { onChange(name) },
                    )
                }
                Overline("All activities", modifier = Modifier.padding(top = 6.dp))
            }
            matches.forEach { sp ->
                SportSuggestionRow(name = sp.name, isDistance = sp.isDistanceSport, onPick = { onChange(sp.name) })
            }
        }
    }
}

/** One tappable suggestion row — shared by the #297 Recent block and the full catalogue list. */
@Composable
private fun SportSuggestionRow(name: String, isDistance: Boolean, onPick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onPick)
            .padding(vertical = 8.dp),
    ) {
        Text(name, style = NoopType.body, color = Palette.textPrimary)
        if (isDistance) {
            Spacer(Modifier.width(6.dp))
            Text(uiString(R.string.l10n_workouts_screen_gps_124667d8), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun DialogField(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    placeholder: String = "",
    numeric: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label, style = NoopType.footnote) },
        placeholder = { if (placeholder.isNotEmpty()) Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        singleLine = true,
        keyboardOptions = if (numeric) KeyboardOptions(keyboardType = KeyboardType.Number) else KeyboardOptions.Default,
        colors = workoutFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun workoutFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedLabelColor = Palette.accent,
    unfocusedLabelColor = Palette.textSecondary,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

// MARK: - Dividers

@Composable
private fun CardDivider() {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
}

@Composable
private fun FullDivider(alpha: Float = 1f) {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline.copy(alpha = alpha)))
}

// MARK: - Range model

private enum class WorkoutRange(val label: String, val caption: String, val days: Int?, val heroWord: String) {
    Week("7D", "last 7 days", 7, "week"),
    Month("30D", "last 30 days", 30, "month"),
    Quarter("90D", "last 90 days", 90, "quarter"),
    Year("1Y", "last year", 365, "year"),
    All("All", "all time", null, "log"),
}

/** The HRR card must not interpolate the range enum's legacy English-only caption into localized copy. */
private fun WorkoutRange.localizedCaption(): String = when (this) {
    WorkoutRange.Week -> uiString(R.string.l10n_workouts_screen_hrr_last_7_days_516)
    WorkoutRange.Month -> uiString(R.string.l10n_workouts_screen_hrr_last_30_days_516)
    WorkoutRange.Quarter, WorkoutRange.Year, WorkoutRange.All ->
        uiString(R.string.l10n_workouts_screen_hrr_last_90_days_516)
}

/** This range plus every larger range, ascending — the auto-expand search order. */
private fun WorkoutRange.widening(): List<WorkoutRange> {
    val order = WorkoutRange.entries
    val i = order.indexOf(this)
    return if (i < 0) listOf(WorkoutRange.All) else order.subList(i, order.size)
}

/** Sessions inside a range, RELATIVE TO THE LATEST session. `All` = everything. */
private fun sessions(all: List<WorkoutRow>, r: WorkoutRange): List<WorkoutRow> {
    val days = r.days ?: return all
    val last = all.maxOfOrNull { it.startTs } ?: return emptyList()
    val cutoff = last - days * 86_400L
    return all.filter { it.startTs >= cutoff }
}

/** The range actually shown: the selected range if it holds ≥1 session (after the active #64 filter),
 *  else the smallest larger range that does — so only an empty window widens. */
private fun effectiveRange(all: List<WorkoutRow>, selected: WorkoutRange, filter: WorkoutFilter = WorkoutFilter()): WorkoutRange {
    if (all.isEmpty()) return selected
    for (r in selected.widening()) {
        if (filter.apply(sessions(all, r)).isNotEmpty()) return r
    }
    return WorkoutRange.All
}

/** Pick the tightest range that still holds ≥2 sessions; otherwise show All. */
private fun defaultRange(source: List<WorkoutRow>): WorkoutRange {
    val last = source.maxOfOrNull { it.startTs } ?: return WorkoutRange.All
    for (r in WorkoutRange.entries) {
        val days = r.days ?: continue
        val cutoff = last - days * 86_400L
        if (source.count { it.startTs >= cutoff } >= 2) return r
    }
    return WorkoutRange.All
}

// MARK: - Aggregation

private data class SportGroup(
    val sport: String,
    val count: Int,
    val totalTimeS: Double,
    val totalKcal: Double,
) {
    val totalTimeH: Double get() = totalTimeS / 3600.0
    val avgTimePerSessionMin: Double get() = if (count > 0) (totalTimeS / count) / 60.0 else 0.0
}

/** Sessions grouped by sport, ordered by count (desc), then total time. */
private fun sportGroups(rows: List<WorkoutRow>): List<SportGroup> =
    rows.groupBy { it.sport }
        .map { (sport, list) ->
            SportGroup(
                sport = sport,
                count = list.size,
                totalTimeS = list.sumOf { it.durationS ?: 0.0 },
                totalKcal = list.sumOf { it.energyKcal ?: 0.0 },
            )
        }
        .sortedWith(compareByDescending<SportGroup> { it.count }.thenByDescending { it.totalTimeS })

/**
 * The Src-column badge (label + tint) for a session. Sessions are loaded by their source's
 * deviceId — "my-whoop" / "apple-health" / "health-connect" — and each row also carries a `source`
 * label ("my-whoop" / "Apple Health" / "health-connect"), so we classify on both. This used to be a
 * binary `isWhoop ? "Whoop" : "Apple"`, which mislabelled EVERY Health Connect workout as "Apple"
 * (#53). "HC" is abbreviated to fit the narrow column (Apple is likewise short for "Apple Health");
 * the Data Sources and Today screens spell out "Health Connect". Tints match those screens: WHOOP
 * accent green, Apple cyan, Health Connect purple.
 */
/**
 * Pure source → short badge label. `internal` + Compose-free so the unit test can pin the three
 * stored origins ("my-whoop" / "apple-health"+"Apple Health" / "health-connect") to their labels
 * without dragging in Palette. This is the classification that used to be a binary
 * `isWhoop ? "Whoop" : "Apple"`, which mislabelled every Health Connect workout as "Apple" (#53).
 * Rows are loaded by deviceId, and also carry a `source` label, so we check both.
 */
internal fun workoutSourceLabel(deviceId: String, source: String): String {
    val id = deviceId.lowercase()
    val src = source.lowercase()
    return when {
        id == "health-connect" || src.contains("health-connect") -> "HC"
        id.contains("whoop") || src.contains("whoop") -> "Whoop"
        else -> "Apple"
    }
}

// MARK: - Zone parsing/aggregation (internal + Compose-free so the unit test can pin them,
// same pattern as workoutSourceLabel). zonesJSON is a flat one-level numeric object in BOTH
// stored shapes — "zone1".."zone5" (WhoopCsvImporter.zonesJson) and "z1".."z5" (the macOS
// importer's rows) — so an anchored regex is safe, and it keeps org.json (an unmocked
// Android stub in plain-JVM unit tests) out of test-reachable code.

private val ZONE_KEY = Regex("\"z(?:one)?([1-5])\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)")

/** Zone percentages (0–100) indexed Z1..Z5, or null when the row has no usable zone data. */
internal fun parseZonePercents(zonesJSON: String?): List<Double>? {
    if (zonesJSON.isNullOrBlank()) return null
    val out = MutableList(5) { 0.0 }
    var any = false
    for (m in ZONE_KEY.findAll(zonesJSON)) {
        val v = m.groupValues[2].toDoubleOrNull() ?: continue
        out[m.groupValues[1].toInt() - 1] = v.coerceIn(0.0, 100.0)
        any = true
    }
    return if (any && out.sum() > 0.0) out else null
}

internal data class ZoneSummary(val minutes: List<Double>, val sessionsWithZones: Int) {
    val totalMinutes: Double get() = minutes.sum()
}

/** Duration-weighted zone minutes across [rows] — mirrors the macOS WorkoutZones.summary
 *  (duration-minutes × pct ÷ 100). APPROXIMATE: an on-device aggregate of imported
 *  per-workout percentages, not a WHOOP-computed figure. */
internal fun zoneSummary(rows: List<WorkoutRow>): ZoneSummary? {
    val mins = MutableList(5) { 0.0 }
    var n = 0
    for (r in rows) {
        val p = parseZonePercents(r.zonesJSON) ?: continue
        val durMin = (r.durationS ?: (r.endTs - r.startTs).toDouble()) / 60.0
        if (durMin <= 0.0) continue
        for (i in 0 until 5) mins[i] += durMin * p[i] / 100.0
        n++
    }
    return if (n > 0 && mins.sum() > 0.0) ZoneSummary(mins, n) else null
}

/**
 * The Src-column badge (label + tint). "HC" is abbreviated to fit the narrow column (Apple is
 * likewise short for "Apple Health"); Data Sources / Today spell out "Health Connect". Tints match
 * those screens: WHOOP accent green, Apple cyan, Health Connect purple.
 */
private val WorkoutRow.sourceBadge: Pair<String, Color>
    get() = when (WorkoutEditing.classify(source)) {
        // Detected (on-device auto-detector) is honestly labelled so a duplicate is recognisable +
        // removable (#107); manual = user-logged. Both classify on `source` BEFORE the import labels.
        // #486: SHORT badge codes so the label fits the narrow weight-1 Src column on a phone instead of
        // ellipsising ("Manual"->"MA...", "Whoop"->"WH...", "Detected"->"DE..."). The colour + the row
        // context disambiguate. iOS keeps the full words — its Source column is a fixed 80pt that fits them
        // and those labels are localized; Android's badge labels are hardcoded, so this stays platform-local.
        WorkoutSource.DETECTED -> "AUTO" to Palette.metricPurple
        WorkoutSource.MANUAL -> "MAN" to Palette.statusWarning
        WorkoutSource.LIFTING -> "LIFT" to Palette.zone2 // imported Hevy / Liftosaur strength log
        WorkoutSource.ACTIVITY_FILE -> "FILE" to Palette.metricAmber // imported GPX / TCX / FIT
        else -> when (workoutSourceLabel(deviceId, source)) {
            "HC" -> "HC" to Palette.metricPurple
            "Whoop" -> "WHP" to Palette.accent
            else -> "APL" to Palette.metricCyan
        }
    }

// MARK: - Formatting

private val dateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.US).withZone(ZoneId.systemDefault())
private val timeFmt: DateTimeFormatter =
    // Respect the device's 12-/24-hour locale (#337): "7:10 AM" or "19:10", not forced 24-hour.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private fun dateLabel(ts: Long): String = dateFmt.format(Instant.ofEpochSecond(ts))
private fun timeLabel(ts: Long): String = timeFmt.format(Instant.ofEpochSecond(ts))

/** Session span "HH:mm–HH:mm"; start-only when the end isn't after the start (#157). */
private fun timeRangeLabel(startTs: Long, endTs: Long): String =
    if (endTs > startTs) "${timeLabel(startTs)} - ${timeLabel(endTs)}" else timeLabel(startTs)

private fun durationLabel(s: Double?): String {
    if (s == null || s <= 0.0) return "–"
    val total = s.roundToInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

private fun oneDecimal(v: Double): String = String.format(Locale.US, "%.1f", v)

private fun grouped(v: Double): String = String.format(Locale.US, "%,d", v.roundToInt())

// MARK: - Sport icons (Material equivalents of the SF Symbols used on macOS)

// internal (not private): reused by the Today Overview-HR chart to glyph each workout at its HR peak.
internal fun sportIcon(sport: String): ImageVector {
    val s = sport.lowercase()
    return when {
        s.contains("run") -> Icons.AutoMirrored.Filled.DirectionsRun
        s.contains("walk") || s.contains("hike") -> Icons.AutoMirrored.Filled.DirectionsWalk
        s.contains("cycl") || s.contains("bike") || s.contains("ride") -> Icons.AutoMirrored.Filled.DirectionsBike
        s.contains("swim") -> Icons.Filled.Pool
        s.contains("row") -> Icons.Filled.Rowing
        s.contains("yoga") || s.contains("pilates") || s.contains("meditat") || s.contains("stretch") -> Icons.Filled.SelfImprovement
        s.contains("strength") || s.contains("weight") || s.contains("lift") -> Icons.Filled.FitnessCenter
        s.contains("box") || s.contains("martial") || s.contains("jiu") || s.contains("judo") || s.contains("karate") -> Icons.Filled.SportsMartialArts
        s.contains("hiit") || s.contains("functional") || s.contains("gymnast") -> Icons.Filled.SportsGymnastics
        s.contains("snowboard") -> Icons.Filled.Snowboarding
        s.contains("ski") -> Icons.Filled.DownhillSkiing
        // All racquet sports share the tennis glyph (no dedicated icon for padel/pickleball/squash etc.).
        s.contains("tennis") || s.contains("padel") || s.contains("pickle") || s.contains("squash") || s.contains("racquet") || s.contains("badminton") -> Icons.Filled.SportsTennis
        s.contains("volleyball") -> Icons.Filled.SportsVolleyball
        s.contains("golf") -> Icons.Filled.SportsGolf
        // No dedicated bowling icon in the Material set; the plain ball glyph is the closest match
        // (iOS has figure.bowling). (D#850)
        s.contains("bowl") -> Icons.Filled.SportsBaseball
        s.contains("climb") -> Icons.Filled.Terrain
        s.contains("soccer") || s.contains("football") -> Icons.Filled.SportsSoccer
        s.contains("basketball") -> Icons.Filled.SportsBasketball
        else -> Icons.Filled.FitnessCenter
    }
}
