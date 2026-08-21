package com.noop.ui

import com.noop.R
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.analytics.SleepEditGuard
import com.noop.analytics.SleepGroupEdit
import com.noop.data.SleepSession
import java.time.LocalDate
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

// Sleep window row + night navigation / edit / delete controls.
// Extracted from SleepScreen.kt (behavioral no-op; pure UI code-motion).

/**
 * "Asleep / Woke" — the fell-asleep and woke clock times for the navigated night, read off the
 * session's onset (startTs) and wake (endTs) timestamps, each with a moon / sun glyph. Sits in the
 * hero between the night-nav header and the stage card so the two times people glance for first are
 * always visible, not truncated in the header caption. On-brand (surfaceRaised block, tokens) and
 * combined into one TalkBack element. Mirrors iOS SleepView.sleepWindowRow (PR #289).
 */
@Composable
internal fun SleepWindowRow(onsetTs: Long, wakeTs: Long) {
    val asleep = clockTimeLabel(onsetTs)
    val woke = clockTimeLabel(wakeTs)
    // A frosted Rest-tinted card (was a flat surfaceRaised block) so the window row sits in the
    // same colour world as the rest of the screen. Bevel treatment — content unchanged.
    NoopCard(
        modifier = Modifier.semantics(mergeDescendants = true) {
            contentDescription = uiString(R.string.l10n_sleep_screen_fell_asleep_at_asleep_woke_at_80465b2d, asleep, woke)
        },
        padding = Metrics.space14,
        tint = Palette.restColor,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SleepTime(icon = Icons.Filled.Bedtime, label = uiString(R.string.l10n_sleep_screen_asleep_b9692bbe), value = asleep)
            Spacer(Modifier.width(Metrics.space12))
            Box(
                modifier = Modifier
                    .height(30.dp)
                    .width(Metrics.divider)
                    .background(Palette.hairline),
            )
            Spacer(Modifier.width(Metrics.space12))
            SleepTime(icon = Icons.Filled.WbSunny, label = uiString(R.string.l10n_sleep_screen_woke_cfbb59a8), value = woke)
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun SleepTime(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, value: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null, // row carries the combined description
            tint = Palette.restColor,
            modifier = Modifier.size(20.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space2)) {
            Overline(label, color = Palette.textTertiary)
            Text(value, style = NoopType.number(22f), color = Palette.textPrimary, maxLines = 1)
        }
    }
}

/**
 * Hero header with ◀/▶ to browse past nights plus an accent-tinted center block that
 * mirrors the Today page's date-nav: tapping the block opens a [DatePickerDialog] to jump
 * to any night by date, and the edit-pen icon opens a chooser to adjust the session's
 * bed/wake times via [TimePickerDialog]. ◀ goes older (offset+1), ▶ newer; each is disabled
 * at its bound — tinted tertiary when disabled, accent when active. (#160)
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NightNavHeader(
    offset: Int,
    // #1311: calendar-aware "N nights ago" label, computed by the caller from navDays so a skipped
    // no-data night doesn't desync the count. Replaces the old offset-index labelling.
    nightLabel: String,
    lastIndex: Int,
    clock: String?,
    onNavigate: (Int) -> Unit,
    session: SleepSession? = null,
    // #1492: the bridged night's fragments. The editor seeds, coverage-tests and writes across the WHOLE
    // night; `session` alone is the winning fragment and on a split night defines neither displayed bound.
    heroGroup: List<SleepSession> = emptyList(),
    onUpdateTimes: (SleepSession, Long, Long) -> Unit = { _, _, _ -> },
    onDeleteSession: (SleepSession) -> Unit = {},
    onAddNap: (Long, Long) -> Unit = { _, _ -> },
    onPickNightDate: ((LocalDate) -> Unit)? = null,
) {
    val canGoOlder = offset < lastIndex
    val canGoNewer = offset > 0
    val context = LocalContext.current
    var showTimeChoice by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var editingBed by remember { mutableStateOf(false) }
    var editingWake by remember { mutableStateOf(false) }
    var sleepEditDraft by remember(session?.deviceId, session?.startTs) {
        mutableStateOf<SleepTimeEditDraft?>(null)
    }
    var showDatePicker by remember { mutableStateOf(false) }
    // #940 guard 2: a corrected (start, end) window that no longer touches the night's recorded
    // coverage parks here awaiting an explicit confirm; committing it silently fabricated an
    // all-awake phantom night that hid the tab's history. null = nothing pending.
    var pendingDisjointTimes by remember { mutableStateOf<Pair<Long, Long>?>(null) }
    // Manual nap add (#508): pick a start time, then an end time; both anchored to THIS night's wake day
    // so the new nap lands on the right day. napStartTs holds the chosen start between the two pickers.
    var addingNapStart by remember { mutableStateOf(false) }
    var addingNapEnd by remember { mutableStateOf(false) }
    var napStartTs by remember { mutableStateOf(0L) }

    // Commit funnel for the COMPLETE drafted window (#515/#940). Neither picker writes by itself:
    // only Save reaches this function, so an edited bedtime can never be persisted against the old
    // wake (or vice versa). A window outside the recorded coverage still uses #940's explicit confirm.
    fun commitTimes(s: SleepSession, newStart: Long, newEnd: Long) {
        // #1492: coverage is the WHOLE bridged night, not the winning fragment. Testing one fragment made a
        // window matching the night the user could see read as disjoint from it, diverting an ordinary edit
        // into the "outside the recorded coverage" confirm instead of saving it.
        val groupWindow = SleepGroupEdit.groupWindow(heroGroup)
        val coverageStart = groupWindow?.first ?: minOf(s.startTs, s.effectiveStartTs)
        val coverageEnd = groupWindow?.second ?: s.endTs
        if (SleepEditGuard.isDisjoint(newStart, newEnd, coverageStart, coverageEnd)) {
            pendingDisjointTimes = newStart to newEnd
        } else {
            onUpdateTimes(s, newStart, newEnd)
        }
    }

    // Atomic editor (#515): both rows mutate an in-memory draft. Save validates and commits the pair
    // once; Cancel discards it. This mirrors Apple SleepTimeEditor's single start+end save funnel.
    val currentDraft = sleepEditDraft
    if (showTimeChoice && session != null && currentDraft != null) {
        val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
        val bedText = timeFmt.format(Date(currentDraft.startTs * 1000L))
        val wakeText = timeFmt.format(Date(currentDraft.endTs * 1000L))
        val validated = currentDraft.validatedWindow(System.currentTimeMillis() / 1000L)
        val blockShape2 = RoundedCornerShape(Metrics.cornerSm)
        androidx.compose.material3.AlertDialog(
            onDismissRequest = {
                showTimeChoice = false
                sleepEditDraft = null
            },
            containerColor = Palette.surfaceRaised,
            titleContentColor = Palette.textPrimary,
            textContentColor = Palette.textSecondary,
            title = { Text(uiString(R.string.l10n_sleep_screen_adjust_sleep_times_1e325561), style = NoopType.headline) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(blockShape2)
                            .background(Palette.surfaceOverlay)
                            .clickable { showTimeChoice = false; editingBed = true }
                            .padding(horizontal = Metrics.space16, vertical = Metrics.space14),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Overline("Bedtime", color = Palette.textTertiary)
                            Spacer(Modifier.height(Metrics.space4))
                            Text(bedText, style = NoopType.headline, color = Palette.textPrimary)
                        }
                        Icon(Icons.Filled.Edit, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(20.dp))
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(blockShape2)
                            .background(Palette.surfaceOverlay)
                            .clickable { showTimeChoice = false; editingWake = true }
                            .padding(horizontal = Metrics.space16, vertical = Metrics.space14),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Overline("Wake-up", color = Palette.textTertiary)
                            Spacer(Modifier.height(Metrics.space4))
                            Text(wakeText, style = NoopType.headline, color = Palette.textPrimary)
                        }
                        Icon(Icons.Filled.Edit, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(20.dp))
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = validated != null,
                    onClick = {
                        val window = validated ?: return@TextButton
                        showTimeChoice = false
                        sleepEditDraft = null
                        commitTimes(session, window.first, window.second)
                    },
                ) {
                    Text(
                        uiString(R.string.l10n_sleep_screen_save_efc007a3),
                        style = NoopType.body,
                        color = if (validated != null) Palette.accent else Palette.textTertiary,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    showTimeChoice = false
                    sleepEditDraft = null
                }) {
                    Text(
                        uiString(R.string.l10n_sleep_screen_cancel_77dfd213),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            },
        )
    }

    // Bed-time picker mutates only the draft. Returning to the parent dialog lets the user inspect and
    // adjust BOTH endpoints before the single Save (#515). The cross-midnight correction stays in the
    // pure SleepTimeEditDraft/SleepEditGuard path pinned by JVM tests.
    val draftForBed = sleepEditDraft
    if (editingBed && session != null && draftForBed != null) {
        val startCal = Calendar.getInstance().apply { timeInMillis = draftForBed.startTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = draftForBed.startTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                    }
                    sleepEditDraft = draftForBed.withBedCandidate(
                        candidateBedTs = cal.timeInMillis / 1000L,
                        nowTs = System.currentTimeMillis() / 1000L,
                    )
                },
                startCal.get(Calendar.HOUR_OF_DAY),
                startCal.get(Calendar.MINUTE),
                true,
            ).apply { setTitle("Bedtime") }
            dialog.setOnDismissListener {
                editingBed = false
                if (sleepEditDraft != null) showTimeChoice = true
            }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // Wake-up editing mutates only the draft. Date and time are selected explicitly so a correction can
    // preserve the exact endpoint date instead of deriving it from bedtime (#970).
    val draftForWake = sleepEditDraft
    if (editingWake && session != null && draftForWake != null) {
        val endCal = Calendar.getInstance().apply { timeInMillis = draftForWake.endTs * 1000L }
        DisposableEffect(Unit) {
            var dateChosen = false
            val dateDialog = DatePickerDialog(
                context,
                { _, year, month, day ->
                    dateChosen = true
                    val selectedDate = Calendar.getInstance().apply {
                        timeInMillis = draftForWake.endTs * 1000L
                        set(Calendar.YEAR, year); set(Calendar.MONTH, month); set(Calendar.DAY_OF_MONTH, day)
                    }
                    val timeDialog = TimePickerDialog(
                        context,
                        { _, h, m ->
                            selectedDate.set(Calendar.HOUR_OF_DAY, h); selectedDate.set(Calendar.MINUTE, m)
                            selectedDate.set(Calendar.SECOND, 0); selectedDate.set(Calendar.MILLISECOND, 0)
                            sleepEditDraft = draftForWake.withWakeCandidate(selectedDate.timeInMillis / 1000L)
                        },
                        endCal.get(Calendar.HOUR_OF_DAY), endCal.get(Calendar.MINUTE), true,
                    ).apply { setTitle("Wake-up time") }
                    timeDialog.setOnDismissListener {
                        editingWake = false
                        if (sleepEditDraft != null) showTimeChoice = true
                    }
                    timeDialog.show()
                },
                endCal.get(Calendar.YEAR), endCal.get(Calendar.MONTH), endCal.get(Calendar.DAY_OF_MONTH),
            ).apply {
                datePicker.maxDate = System.currentTimeMillis()
                setTitle("Wake-up date")
                setOnDismissListener {
                    if (editingWake && !dateChosen) {
                        editingWake = false
                        if (sleepEditDraft != null) showTimeChoice = true
                    }
                }
            }
            dateDialog.show()
            onDispose { runCatching { dateDialog.dismiss() } }
        }
    }

    // Date jump — capped at today so a future night can't be selected.
    if (showDatePicker && onPickNightDate != null) {
        val cal = session?.let { Calendar.getInstance().apply { timeInMillis = it.effectiveStartTs * 1000L } }
            ?: Calendar.getInstance()
        DisposableEffect(Unit) {
            val dialog = DatePickerDialog(
                context,
                { _, year, month, day ->
                    onPickNightDate(LocalDate.of(year, month + 1, day))
                    showDatePicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            ).apply {
                datePicker.maxDate = System.currentTimeMillis()
                setOnDismissListener { showDatePicker = false }
            }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // Manual nap (#508) step 1: pick the nap's START time, anchored to the night's wake DAY (a natural
    // place to look for a missed daytime nap). Defaults to ~1h after the night's wake.
    if (addingNapStart && session != null) {
        val anchorTs = session.endTs + 3_600L
        val startCal = Calendar.getInstance().apply { timeInMillis = anchorTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = anchorTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                    }
                    // #940: a nap being logged already happened. The anchor day is the night's wake
                    // day (usually today), so a picked time later than the clock means the most
                    // recent PAST occurrence: snap back a day (no wake rule here; a nap after the
                    // night's wake is normal).
                    napStartTs = SleepEditGuard.autoCorrectedBed(
                        previousBedTs = anchorTs,
                        candidateBedTs = cal.timeInMillis / 1000L,
                        originalWakeTs = null,
                        nowTs = System.currentTimeMillis() / 1000L,
                    )
                    addingNapStart = false
                    addingNapEnd = true
                },
                startCal.get(Calendar.HOUR_OF_DAY),
                startCal.get(Calendar.MINUTE),
                true,
            ).apply { setTitle("Nap started") }
            dialog.setOnDismissListener { addingNapStart = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // Manual nap (#508) step 2: pick the nap's END time — TIME-ONLY, its day DERIVED from the chosen start
    // (first instant strictly after start, within 24h), mirroring the wake-edit cross-day constraint so a
    // nap can't be re-bucketed onto the wrong day. Then hand (start, end) to onAddNap.
    if (addingNapEnd && napStartTs > 0L) {
        val endCal = Calendar.getInstance().apply { timeInMillis = (napStartTs + 30 * 60L) * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val startTs = napStartTs
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = startTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                        if (timeInMillis / 1000L <= startTs) add(Calendar.DAY_OF_MONTH, 1)
                    }
                    onAddNap(startTs, cal.timeInMillis / 1000L)
                    addingNapEnd = false
                    napStartTs = 0L
                },
                endCal.get(Calendar.HOUR_OF_DAY),
                endCal.get(Calendar.MINUTE),
                true,
            ).apply { setTitle("Nap ended") }
            dialog.setOnDismissListener { addingNapEnd = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // #940 guard 2's consent step: the corrected window no longer touches the night's recorded
    // coverage, so there is nothing to stage it from. Same wording as the iOS SleepTimeEditor alert.
    val pendingTimes = pendingDisjointTimes
    if (pendingTimes != null && session != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingDisjointTimes = null },
            containerColor = Palette.surfaceRaised,
            titleContentColor = Palette.textPrimary,
            textContentColor = Palette.textSecondary,
            title = { Text(uiString(R.string.l10n_sleep_screen_move_this_sleep_438dd3b5), style = NoopType.headline) },
            text = {
                Text(
                    uiString(R.string.l10n_sleep_screen_this_moves_the_night_to_a_fac2fb46),
                    style = NoopType.subhead,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    onUpdateTimes(session, pendingTimes.first, pendingTimes.second)
                    pendingDisjointTimes = null
                }) { Text(uiString(R.string.l10n_sleep_screen_move_anyway_19ee824d), style = NoopType.subhead, color = Palette.statusWarning) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDisjointTimes = null }) {
                    Text(uiString(R.string.l10n_sleep_screen_cancel_77dfd213), style = NoopType.subhead, color = Palette.textSecondary)
                }
            },
        )
    }

    // #1311: nightLabel is now the calendar-aware label passed in (was nightRelativeLabel(offset)).
    val blockShape = RoundedCornerShape(Metrics.cornerSm)
    val clockParts = clock?.split(" · ", limit = 2)
    val dateLabel = clockParts?.getOrNull(0)
    val timeLabel = clockParts?.getOrNull(1)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Metrics.selectorSpacing),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { if (canGoOlder) onNavigate(offset + 1) }, enabled = canGoOlder) {
                Icon(Icons.Filled.ChevronLeft, contentDescription = uiString(R.string.l10n_sleep_screen_previous_night_9f339047), tint = if (canGoOlder) Palette.accent else Palette.textTertiary)
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(blockShape)
                    // Clean material surface (matches DayNavBar) — no gold wash behind the date;
                    // the gold pop lives only on the date text below.
                    .background(Palette.surfaceInset)
                    .border(Metrics.divider, Palette.hairline, blockShape)
                    .clickable(enabled = onPickNightDate != null, onClickLabel = "Pick night date") { showDatePicker = true }
                    .padding(vertical = Metrics.selectorPadding, horizontal = Metrics.selectorPadding),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(nightLabel, style = NoopType.caption, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (dateLabel != null) {
                    Text(dateLabel, style = NoopType.captionNumber, color = Palette.accentHover, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            IconButton(onClick = { if (canGoNewer) onNavigate(offset - 1) }, enabled = canGoNewer) {
                Icon(Icons.Filled.ChevronRight, contentDescription = uiString(R.string.l10n_sleep_screen_next_night_7deeb06b), tint = if (canGoNewer) Palette.accent else Palette.textTertiary)
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                timeLabel ?: clock ?: "—",
                style = NoopType.captionNumber,
                color = Palette.accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (session != null) {
                Spacer(Modifier.width(Metrics.space6))
                Icon(
                    Icons.Filled.Edit,
                    contentDescription = uiString(R.string.l10n_sleep_screen_adjust_sleep_times_1e325561),
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp).clickable {
                        // #1492: open on the window the header shows (the whole bridged night), not the
                        // winning fragment's — otherwise a split night's pickers pre-fill with times the
                        // user never saw and is not trying to correct.
                        val shown = SleepGroupEdit.groupWindow(heroGroup)
                        sleepEditDraft = SleepTimeEditDraft(
                            shown?.first ?: session.effectiveStartTs,
                            shown?.second ?: session.endTs,
                        )
                        showTimeChoice = true
                    },
                )
                Spacer(Modifier.width(Metrics.space12))
                Icon(
                    Icons.Filled.DeleteOutline,
                    contentDescription = uiString(R.string.l10n_sleep_screen_delete_this_sleep_session_6932e931),
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp).clickable { showDeleteConfirm = true },
                )
                // Add a missed nap as its OWN session (#508) — staged from raw, never folded into this
                // night's main sleep. Two pickers (start → end), the end day derived from the start.
                Spacer(Modifier.width(Metrics.space12))
                Icon(
                    Icons.Filled.Add,
                    contentDescription = uiString(R.string.l10n_sleep_screen_add_a_nap_a1b3204f),
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp).clickable { addingNapStart = true },
                )
            }
        }
        // When the older-night arrow is disabled because no earlier night is banked yet, the chevron
        // just greying out reads as broken. Show a short, honest hint instead — earlier nights only
        // appear once the strap has offloaded them (typically the next morning sync). (#614 follow-up)
        if (!canGoOlder) {
            Text(
                uiString(R.string.l10n_sleep_screen_no_earlier_night_stored_yet_earlier_ab637d4c),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    // Confirm before removing the night — the same on-brand AlertDialog the time-edit chooser
    // uses (surfaceRaised, Noop type tokens), not a bare Material default. (#281)
    if (showDeleteConfirm && session != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            containerColor = Palette.surfaceRaised,
            titleContentColor = Palette.textPrimary,
            textContentColor = Palette.textSecondary,
            title = { Text(uiString(R.string.l10n_sleep_screen_delete_this_sleep_session_c347b909), style = NoopType.headline) },
            text = {
                // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
                // tombstone, so its copy drops that (false) promise. Mirrors the undo banner. (#65)
                Text(
                    if (session.userEdited) {
                        uiString(R.string.sleep_delete_user_edited_body)
                    } else {
                        uiString(R.string.sleep_delete_recorded_body)
                    },
                    style = NoopType.subhead,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    onDeleteSession(session)
                }) {
                    Text(uiString(R.string.l10n_sleep_screen_delete_f6fdbe48), style = NoopType.headline, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) {
                    Text(uiString(R.string.l10n_sleep_screen_cancel_77dfd213), style = NoopType.subhead, color = Palette.textTertiary)
                }
            },
        )
    }
}

// MARK: - 2. Metric grid (row-equalized min-height tiles, each with a bottom sparkline)


