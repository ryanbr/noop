package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.app.TimePickerDialog
import android.widget.Toast
import com.noop.analytics.SleepMark
import com.noop.analytics.SleepMarkType
import com.noop.analytics.SleepWindowReclip
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.filled.Tune
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import com.noop.data.HrBucket
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.CircadianEngine
import com.noop.analytics.HypnogramCoverage
import com.noop.analytics.SleepEditGuard
import com.noop.analytics.SleepGroupEdit
import com.noop.analytics.SleepStageTotals
import com.noop.analytics.StagePercentages
import com.noop.data.DismissedSleep
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.noop.analytics.ClockFormat

internal enum class SleepFreshnessStatus {
    SYNCING, CALCULATING, SYNC_FAILED, AWAITING_SYNC, NOT_DETECTED,
}

private data class SleepFreshnessLiveSnapshot(
    val backfilling: Boolean,
    val analyzing: Boolean,
    val lastSyncAt: Long?,
    val syncFailed: Boolean,
)

/** Pure priority ladder for the expected current night. The missing states wait until morning so opening
 * Sleep at 02:00 does not claim the night still in progress has been missed. Swift twin:
 * `resolveSleepFreshness`. */
internal fun resolveSleepFreshness(
    hasCurrentNight: Boolean,
    morningReady: Boolean,
    syncing: Boolean,
    calculating: Boolean,
    syncedSinceDayStart: Boolean,
    syncFailed: Boolean,
): SleepFreshnessStatus? {
    if (syncing) return SleepFreshnessStatus.SYNCING
    if (calculating) return SleepFreshnessStatus.CALCULATING
    if (hasCurrentNight || !morningReady) return null
    if (syncFailed) return SleepFreshnessStatus.SYNC_FAILED
    return if (syncedSinceDayStart) SleepFreshnessStatus.NOT_DETECTED
    else SleepFreshnessStatus.AWAITING_SYNC
}

@Composable
private fun SleepFreshnessNote(status: SleepFreshnessStatus, chunks: Int) {
    when (status) {
        SleepFreshnessStatus.SYNCING -> SyncingHistoryNote(chunks)
        SleepFreshnessStatus.CALCULATING -> DataPendingNote(
            title = stringResource(R.string.sleep_status_calculating_title),
            body = stringResource(R.string.sleep_status_calculating_body),
        )
        SleepFreshnessStatus.SYNC_FAILED -> DataPendingNote(
            title = stringResource(R.string.sleep_status_sync_failed_title),
            body = stringResource(R.string.sleep_status_sync_failed_body),
        )
        SleepFreshnessStatus.AWAITING_SYNC -> DataPendingNote(
            title = stringResource(R.string.sleep_status_waiting_title),
            body = stringResource(R.string.sleep_status_waiting_body),
        )
        SleepFreshnessStatus.NOT_DETECTED -> DataPendingNote(
            title = stringResource(R.string.sleep_status_not_detected_title),
            body = stringResource(R.string.sleep_status_not_detected_body),
        )
    }
}

/**
 * Sleep — Whoop-sleep clarity on the locked Noop component system. Mirrors the macOS
 * SleepView (Strand/Screens/SleepView.swift) section-for-section:
 *
 *   1. HERO — the stage breakdown for the navigated night. ◀/▶ chevrons flank the
 *      header and walk EVERY recorded night (0 = last night), replacing the fixed
 *      3-day selector (#160). A Hypnogram when stage minutes are present (deep / rem /
 *      light / awake reconstructed end-to-end), with a footer of REM / Deep / Light /
 *      Awake each "Xh Ym · NN%".
 *   2. A uniform grid of fixed StatTiles, each with a sparkline + "vs typical" caption:
 *      Rest, Efficiency, Consistency, Hours vs Needed, Restorative,
 *      Respiratory, Sleep Debt.
 *   3. "Stages vs typical" — Deep / REM / Light horizontal bars showing last-night
 *      minutes with a marker at the personal typical (mean).
 *   4. A 14-day asleep-hours trend LineChart.
 *
 * Data wiring is faithful to the macOS screen: the "typical" is the mean across the
 * cached daily metrics; the per-night stage split comes from the selected night's
 * DailyMetric deep/rem/light minutes (the grid/trends window ends on that day, exactly
 * as it followed the old day selector). The hero hypnogram prefers the REAL per-epoch
 * segments the on-device stager persists into sleepSession.stagesJSON ([{start,end,stage}])
 * when the merged session is the same night — labelled approximate (on-device staging).
 * Imported nights carry minutes only, so they keep the reconstructed plausible architecture
 * (deep early, REM later, awake last). No data is fabricated: with no nights the screen
 * shows an honest empty state, and a navigated night with no usable stage data says so
 * instead of silently showing another night (#160).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SleepScreen(
    vm: AppViewModel,
    onOpenJournal: () -> Unit = {},
) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    // Whether the ACTIVE strap is an Oura ring, off the canonical brand table (not an "oura" literal) — so
    // the sleep surfaces name a ring-PROVIDED night's provenance "Oura" and flag its split as the ring's
    // RAW on-device stages. Read/UI only, no stored value. Mirrors macOS Repository.activeDeviceIsOura.
    val activeIsOura = com.noop.data.DeviceBrandCatalog.isOura(vm.activeStrapId)
    // #1680: the body-clock phase behind the 24 h dial section. Same snapshot the Health screen reads for
    // BodyClockCard, so the two surfaces cannot disagree about the estimate.
    val v5Signals by vm.v5Signals.collectAsStateWithLifecycle()

    // PERF (#scroll-jank): the BLE live state ticks ~1Hz. This screen reads `live` ONLY for the
    // "syncing history" note (backfilling + the chunk count), so reading the whole `live` object at
    // body scope recomposed the entire Sleep screen on every HR tick. Collapse it to the two fields the
    // note needs via a structural-equality snapshot: a 72→73 bpm tick produces an EQUAL snapshot and
    // the body is NOT recomposed; it only recomposes when the backfilling state / chunk count actually
    // changes. Mirrors the shipped Today liveSnap fix. Appearance-preserving.
    val live by vm.live.collectAsStateWithLifecycle()
    val backfillNote by remember {
        derivedStateOf {
            val s = live
            if (s.backfilling) s.syncChunksThisSession else null
        }
    }
    // Like backfillNote, collapse the 1 Hz BLE state to only fields that can change the missing-night
    // banner. Live HR ticks then remain equality-identical and do not recompose this heavy screen.
    val freshnessLive by remember {
        derivedStateOf {
            SleepFreshnessLiveSnapshot(
                backfilling = live.backfilling,
                analyzing = live.analyzingHistory,
                lastSyncAt = live.lastSyncAt,
                syncFailed = live.lastSyncError != null,
            )
        }
    }

    // Every recorded sleep BLOCK, oldest→newest — the hero's ◀/▶ chevrons walk this whole list,
    // including same-day naps / split sleep that `sleepSessionsMerged` collapses to one-per-night
    // for the dashboard (#170). Derived un-deduplicated: every imported session, plus the computed
    // "-noop" sessions on days the import doesn't cover (imported-wins / computed-fills, mirroring
    // mergeSleep but WITHOUT the per-night collapse). Keyed on `days` so a sync/import (which always
    // rewrites dailyMetric too) reloads; these reads have no Flow. (#160, #170)
    var sleeps by remember { mutableStateOf<List<SleepSession>>(emptyList()) }
    // Durable deleted-night markers. Unlike the 7-second Undo banner these remain reachable after the
    // session row is gone, giving each suppressed window a "Recompute this night" escape hatch (#515).
    var dismissedSleeps by remember { mutableStateOf<List<DismissedSleep>>(emptyList()) }
    var recomputingSleep by remember { mutableStateOf<Pair<String, Long>?>(null) }
    // 0 = latest night, N = N sleep-sessions back. Reset to the newest night only on a REAL data
    // reload (new sync / re-import via `days` changing). The optimistic bed/wake edit rewrites
    // `sleeps` in place WITHOUT touching `days`, so it must not reset the browse — keeping the
    // user on the night they just edited. (#160)
    var nightOffset by remember { mutableIntStateOf(0) }
    LaunchedEffect(days) {
        sleeps = runCatching {
            val now = System.currentTimeMillis() / 1000L
            // Read the ACTIVE-strap ∪ canonical "my-whoop" union (#814/#1008), not the canonical id
            // alone: after a strap remove+re-add live nights land under the fresh "whoop-<uuid>" id, so
            // a canonical-only read left this screen STUCK on the last pre-re-add night while every
            // union-joined surface moved on (the #1014/#1009 stuck-sleep divergence, in the OTHER
            // direction). Exact-duplicate (startTs, endTs) blocks recorded under both ids are dropped;
            // naps/split blocks survive. Single-device installs collapse to one id, byte-identical.
            val imported = vm.repo.sleepSessionsUnion(vm.activeStrapId, 0L, now)
            val computed = vm.repo.computedSleepSessionsUnion(vm.activeStrapId, 0L, now)
            // Key by the LOCAL wake-day (#304), matching WhoopRepository.mergeSleep — a UTC key
            // mis-attributed a UTC+ user's early-morning wake to yesterday. REUSE the existing
            // dayString(ts, offsetSec) overload; do not add a new one (it clashes on the JVM).
            fun localEndDay(ts: Long): String {
                val offsetSec = (java.util.TimeZone.getDefault().getOffset(ts * 1000) / 1000).toLong()
                return AnalyticsEngine.dayString(ts, offsetSec)
            }
            // Imported wins per local wake-day, WITH the #241 richness exception (a stage-less import
            // yields to a computed day that has stages) — the SAME rule the browse/CSV path uses via
            // WhoopRepository.mergeSleep. Sort by the EFFECTIVE onset so a hand-edited bedtime orders the
            // night correctly (PR #395).
            WhoopRepository.mergeSleepRichness(imported, computed) { localEndDay(it.endTs) }
                .sortedBy { it.effectiveStartTs }
        }.getOrDefault(emptyList())
        nightOffset = 0
    }

    // Read the active∪canonical management union so a marker created before a strap re-add remains
    // visible. Keyed on days because deletes/recomputes both rescore and republish the affected day.
    LaunchedEffect(days) {
        dismissedSleeps = runCatching {
            vm.repo.dismissedSleepsUnion(vm.activeStrapId)
        }.getOrDefault(dismissedSleeps)
    }

    // #65: the transient UNDO banner shown after a suppressing delete. Holds the deleted SleepSession
    // (which still carries its OWNING deviceId + userEdited), so Undo restores it into the original
    // namespace and lifts the tombstone. Auto-cleared after ~7s by a keyed LaunchedEffect; a new delete
    // replaces it. Mirrors the macOS SleepView sleepUndoBanner + WorkoutsView postLogNote idiom.
    // #1492: a LIST, because a bed/wake correction can retire more than one fragment of a bridged night.
    // `fromEdit` distinguishes those from an outright delete so the banner says what actually happened.
    var sleepUndo by remember { mutableStateOf<SleepUndoState?>(null) }
    LaunchedEffect(sleepUndo) {
        if (sleepUndo != null) {
            kotlinx.coroutines.delay(7_000)
            sleepUndo = null
        }
    }

    // The user's LEARNED habitual midsleep (local time-of-day seconds), or null under the cold-start
    // threshold. Loaded from `vm.repo.habitualMidsleepSec` — the SAME value AnalyticsEngine.analyzeDay
    // threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    // and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too.
    // null keeps the existing cold-start overnight-band fallback. Keyed on `days` so it refreshes
    // alongside `sleeps`. Mirrors iOS SleepView.habitualMidsleepSec. (#547)
    var habitualMidsleep by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(days) {
        // Thread the ACTIVE strap id so the learner unions active + canonical nights (#814/#1008);
        // habitualMidsleepSec resolves the canonical "my-whoop" sibling internally either way.
        habitualMidsleep = runCatching { vm.repo.habitualMidsleepSec(vm.activeStrapId) }.getOrNull()
    }

    // Persisted per-epoch MOTION keyed by each session's detected startTs (#407). Loaded alongside
    // `sleeps`; `selectNight` reads only the ALREADY-resolved main-night GROUP's entries (no re-resolution)
    // and lays them along the hypnogram's timeline. A block with no stored series stays absent (honest empty
    // state for older rows whose motionJSON is NULL). Mirrors iOS SleepView.motionByStart.
    var motionByStart by remember { mutableStateOf<Map<Long, List<Double>>>(emptyMap()) }
    LaunchedEffect(sleeps, vm.activeStrapId) {
        motionByStart = runCatching {
            vm.repo.sessionMotions(vm.activeStrapId, sleeps)
        }.getOrDefault(emptyMap())
    }

    // Export-verbatim sleep figures (sleep_performance / consistency / need / debt) — the
    // headline tiles prefer them over the on-device approximations. Keyed on `days` so a
    // fresh import (which always rewrites dailyMetric too) reloads; metricSeries has no Flow.
    var imported by remember { mutableStateOf(ImportedSleepSeries()) }
    LaunchedEffect(days) {
        suspend fun load(key: String) = runCatching {
            vm.repo.metricSeries("my-whoop", key, "0000-00-00", "9999-99-99")
        }.getOrDefault(emptyList()).associate { it.day to it.value }
        imported = ImportedSleepSeries(
            performance = load("sleep_performance"),
            consistency = load("sleep_consistency"),
            needMin = load("sleep_need_min"),
            debtMin = load("sleep_debt_min"),
        )
    }

    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Day-cycle sky backdrop (#698). Default ON. When off, the screen drops the liquid sky and the
    // scaffold paints the plain dark surface canvas instead — the SAME gate the liquid Today honours.
    // SharedPreferences isn't reactive, so it's read once into local state (mirrors iOS @AppStorage).
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    // Sky-behind-cards (#434 family): when on, the sky fills the whole viewport so the transparent
    // cards reveal it the whole way down, exactly like Today and the metric-detail screens.
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    // Morning-journal nudge: once per calendar day, when the freshest night ended within the last
    // 12 hours, invite the user to log how they felt. The shown-day is persisted so the sheet never
    // re-pops on a recomposition or a same-day re-open. (PR #260)
    var showJournalPrompt by remember { mutableStateOf(false) }

    // #sleep-layout: the arrangeable analytical-card order + explicit hidden set (SleepLayoutPrefs).
    // SharedPreferences isn't reactive, so hold it in state and refresh after the Arrange sheet saves.
    // Mirrors TodayScreen's section-order state.
    var sleepSectionOrder by remember { mutableStateOf(SleepLayoutPrefs.order(context)) }
    var hiddenSections by remember { mutableStateOf(SleepLayoutPrefs.hidden(context)) }
    var showSleepArrange by remember { mutableStateOf(false) }
    // #sleep-layout (hold-to-drag): the hoisted list state (the drag math needs layoutInfo + scrollBy) and
    // the live drag state, mirroring Today (TodayScreen.kt §today-layout). The frame loop runs ONLY while a
    // card is lifted: each frame it retries the swap (so a card held still at a viewport edge keeps
    // reordering as the list scrolls under it — onDrag alone only fires while the finger moves) and applies
    // the edge auto-scroll velocity SleepReorderableSection's onDrag computed. Persistence is on drop
    // (onDrop below), not here — this only updates the in-memory order live.
    val sleepListState = rememberLazyListState()
    val sleepSectionDrag = remember { SleepSectionDragState() }
    val sleepDragActive = sleepSectionDrag.key != null
    LaunchedEffect(sleepDragActive) {
        // Auto-scroll is TIME-based (px/second × real frame delta), not per-frame, so it reads the same on
        // 60/90/120 Hz. dt is clamped so a dropped/backgrounded frame can't produce one giant jump.
        var lastFrameNanos = 0L
        while (sleepSectionDrag.key != null) {
            val frameNanos = withFrameNanos { it }
            val dtSec = if (lastFrameNanos == 0L) 0f
            else ((frameNanos - lastFrameNanos) / 1_000_000_000f).coerceAtMost(0.05f)
            lastFrameNanos = frameNanos
            swapTargetForDraggedSleepSection(sleepListState, sleepSectionDrag, sleepSectionOrder)?.let { (dragged, target) ->
                // Freeze the scroll anchor across the reorder so a swap involving the first visible item
                // can't leap the viewport by the two cards' height difference in a single frame.
                val anchorIndex = sleepListState.firstVisibleItemIndex
                val anchorOffset = sleepListState.firstVisibleItemScrollOffset
                sleepSectionOrder = sleepSectionOrder.movedSleepSection(dragged, target)
                sleepListState.scrollToItem(anchorIndex, anchorOffset)
            }
            if (sleepSectionDrag.autoScrollPxPerSecond != 0f && dtSec > 0f) {
                sleepListState.scrollBy(sleepSectionDrag.autoScrollPxPerSecond * dtSec)
            }
        }
    }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(sleeps) {
        // #627: the journal-reminder toggle (default ON) gates this morning sheet too, so disabling the
        // reminder silences both the Today card and this sheet with one switch.
        if (!NoopPrefs.journalReminderEnabled(context)) return@LaunchedEffect
        val latestEnd = sleeps.lastOrNull()?.endTs ?: return@LaunchedEffect
        val nowS = System.currentTimeMillis() / 1000L
        val hoursAgo = (nowS - latestEnd) / 3600.0
        if (hoursAgo in 0.0..12.0) {
            val today = LocalDate.now().toString()
            // #684: don't nudge when today's journal is already logged — e.g. via the Today card (#656),
            // which never sets KEY_LAST_JOURNAL_PROMPT, so the once-per-day dedup alone would still pop
            // this sheet. Reuse the SAME completion signal the Today card uses (repo.journal for today).
            val loggedToday = runCatching {
                vm.repo.journal(JOURNAL_DEVICE_ID, today, today).any { it.day == today }
            }.getOrDefault(false)
            if (loggedToday) return@LaunchedEffect
            val prefs = NoopPrefs.of(context)
            val lastPrompted = prefs.getString(NoopPrefs.KEY_LAST_JOURNAL_PROMPT, "")
            if (lastPrompted != today) {
                prefs.edit().putString(NoopPrefs.KEY_LAST_JOURNAL_PROMPT, today).apply()
                showJournalPrompt = true
            }
        }
    }

    if (showJournalPrompt) {
        ModalBottomSheet(
            onDismissRequest = { showJournalPrompt = false },
            sheetState = sheetState,
            containerColor = Palette.surfaceRaised,
            contentColor = Palette.textPrimary,
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(Metrics.space24),
                verticalArrangement = Arrangement.spacedBy(Metrics.space16),
            ) {
                Text(uiString(R.string.l10n_sleep_screen_good_morning_33e88869), style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    uiString(R.string.l10n_sleep_screen_your_night_data_is_in_logging_ec461720),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Button(
                    onClick = { showJournalPrompt = false; onOpenJournal() },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                ) {
                    Text(uiString(R.string.l10n_sleep_screen_open_journal_4bf0daee), style = NoopType.headline, color = Palette.surfaceBase)
                }
                TextButton(
                    onClick = { showJournalPrompt = false },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(uiString(R.string.l10n_sleep_screen_maybe_later_27ad1d83), style = NoopType.subhead, color = Palette.textTertiary)
                }
            }
        }
    }

    // #sleep-layout: the Arrange sheet — reorder / show-hide the analytical cards, persisted via
    // SleepLayoutPrefs. Reuses Today's generic EditableVisibilityRows editor. Refresh the in-memory
    // order/hidden state on save so the cards re-lay-out immediately (SharedPreferences isn't reactive).
    if (showSleepArrange) {
        SleepArrangeSheet(
            initialOrder = sleepSectionOrder,
            initialHidden = hiddenSections,
            onDismiss = { showSleepArrange = false },
            onSave = { order, hidden ->
                SleepLayoutPrefs.setOrder(context, order)
                SleepLayoutPrefs.setHidden(context, hidden)
                sleepSectionOrder = order
                hiddenSections = hidden
                showSleepArrange = false
            },
        )
    }

    // Debt credit is the canonical main-night DailyMetric total PLUS actual asleep minutes from blocks
    // outside that main-night group. Keep the nap sum separate: Rest, the hero and daily total deliberately
    // remain main-night-only. Stage-less naps add no guessed in-bed time. Mirrors Swift SleepView. (#525)
    val napSleepMinByDay = remember(sleeps, habitualMidsleep) {
        napSleepMinutesByDay(sleeps, habitualMidsleep)
    }

    // Tapping a metric tile opens a full-history detail sheet for that one metric. (PR #260)
    val metricSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var detailMetricKey by remember { mutableStateOf<String?>(null) }
    val currentDetailKey = detailMetricKey
    if (currentDetailKey != null) {
        ModalBottomSheet(
            onDismissRequest = { detailMetricKey = null },
            sheetState = metricSheetState,
            containerColor = Palette.surfaceRaised,
            contentColor = Palette.textPrimary,
        ) {
            SleepMetricDetailSheetContent(
                vm = vm,
                key = currentDetailKey,
                imported = imported,
                napSleepMinByDay = napSleepMinByDay,
            )
        }
    }

    // The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    // dashboard's per-night merge key, `localEndDay` above), newest day first, blocks within a day
    // oldest→newest. Each day is ONE ◀/▶ stop, so a split-sleep / nap day reads as a single night
    // and a WHOOP 4.0 user with one detected night isn't stuck on dead arrows — the chevrons step
    // by DAY, not by flat session index (#57/#59). Mirrors iOS SleepView.navDays (in-view grouping).
    val navDays = remember(sleeps) {
        sleeps.groupBy { localDayString(it.endTs) }
            .toSortedMap(reverseOrder())                       // newest day first
            .map { (_, blocks) -> blocks.sortedBy { it.effectiveStartTs } }
    }

    // The navigated night, decoded once per (offset, data) change — chevron taps re-pick
    // instantly without re-parsing stagesJSON on every recomposition. The offset now indexes
    // DAYS (navDays), so a day with a detected night always resolves to that night. (#160, #59)
    // #1821: the reader's chosen clock, resolved once for this screen. It is a remember KEY below so
    // changing the setting re-derives the labels instead of leaving the old clock on screen.
    val is24h = ClockPrefs.uses24Hour(LocalContext.current)
    val night = remember(nightOffset, navDays, days, habitualMidsleep, motionByStart, is24h) {
        selectNight(navDays, days, nightOffset, habitualMidsleep, motionByStart, is24h = is24h)
    }

    // #1311: label the carousel by CALENDAR nights, not the flat recorded-night index — a night with no
    // data (strap off-body) is skipped by the carousel, so labelling by index makes two nights either
    // side of it read as consecutive and desyncs the "N nights ago" labels. Shared by the Rest hero
    // overline and the nav header so both name the SAME calendar night.
    val nightLabel = nightRelativeLabel(
        calendarNightsAgo(navDays, nightOffset, java.util.TimeZone.getDefault())
    )

    // The HERO follows the selected night (its stage breakdown comes from that day's row); the
    // at-a-glance TILES, the debt ledger, the personal need and the trend stay full-history /
    // latest-anchored, matching iOS SleepView. `selectedDay` re-points only the hero. Model is null
    // when the selected day has no stage minutes. (#5)
    val model = remember(days, night, imported, napSleepMinByDay, sleeps, is24h) {
        buildSleepModel(days, night?.session, imported, selectedDay = night?.dayKey,
            heroStages = night?.groupStages, heroSegments = night?.groupSegments,
            napSleepMinByDay = napSleepMinByDay, sessions = sleeps, is24h = is24h)
    }
    val display = remember(model, night) { heroDisplay(model, night) }

    val sleepFreshness = remember(sleeps, freshnessLive) {
        val zone = ZoneId.systemDefault()
        val now = Instant.now().atZone(zone)
        val latestWake = sleeps.maxOfOrNull { it.endTs }
        val current = latestWake?.let {
            Instant.ofEpochSecond(it).atZone(zone).toLocalDate() == now.toLocalDate()
        } ?: false
        val dayStart = now.toLocalDate().atStartOfDay(zone).toEpochSecond()
        resolveSleepFreshness(
            hasCurrentNight = current,
            morningReady = now.hour >= 6,
            syncing = freshnessLive.backfilling,
            calculating = freshnessLive.analyzing,
            syncedSinceDayStart = (freshnessLive.lastSyncAt ?: 0L) >= dayStart,
            syncFailed = freshnessLive.syncFailed,
        )
    }

    // #940: ONE stage-less SELECTED day (typically the newest, after an impossible hand-edit staged
    // it all-awake) must not hide the whole tab's history. The tiles / ledger / trends are
    // full-history and independent of the browsed night (matching iOS, where browsing only
    // re-points the hero), so when the selected day's model fails to build, anchor them to the
    // newest stage-bearing day instead of vanishing. The HERO stays on `model`/`display` (an
    // honest no-stage-data fallback for the bad day, edit pencil reachable). Null only when NO day
    // has stage data: the true first-run empty state.
    val tilesModel = remember(model, days, imported, napSleepMinByDay, sleeps) {
        model ?: fallbackSleepModel(days, imported, napSleepMinByDay, sessions = sleeps)
    }

    // Jump straight to a night by its (local) wake-day — the center date block opens a picker.
    // navDays is newest-day-first, so the day's index IS its offset (0 = last night). (#160, #59)
    val onPickNightDate: (LocalDate) -> Unit = { targetDate ->
        val targetStr = targetDate.toString()
        val dayIdx = navDays.indexOfFirst { day -> day.any { localDayString(it.endTs) == targetStr } }
        if (dayIdx >= 0) nightOffset = dayIdx
    }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_sleep_screen_sleep_3cac34e6),
        subtitle = "Last night, read in two seconds.",
        listState = sleepListState,   // #sleep-layout: the hold-to-drag frame loop drives this list state
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the static time-of-day liquid sky
        // settles into the theme canvas behind the header + hero, bled full-width up behind the status bar
        // via the scaffold's topBackground plumbing. Gated on the day-cycle preference exactly like Today
        // (showDayCycleBackground ? sky : plain canvas). Replaces the classic per-hero scene backdrop.
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down
        // (Today / metric-detail parity — the same two prefs drive the same two behaviours everywhere).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        // #65: the transient UNDO banner after a suppressing delete. Restores the deleted row into its
        // ORIGINAL namespace + lifts the tombstone. Mirrors the macOS SleepView sleepUndoBanner.
        sleepUndo?.let { undo ->
            item {
                SleepUndoBanner(
                    undo = undo,
                    onUndo = {
                        sleepUndo = null
                        scope.launch {
                            vm.undoDeleteSleepSessions(undo.sessions)
                            // Re-read so the restored night reappears in the ◀/▶ browse. Same
                            // active∪canonical union as the main loader (#814/#1008), so the undo
                            // reload can't snap the browse back to a canonical-only night set.
                            sleeps = runCatching {
                                val now = System.currentTimeMillis() / 1000L
                                vm.repo.sleepSessionsUnion(vm.activeStrapId, 0L, now) +
                                    vm.repo.computedSleepSessionsUnion(vm.activeStrapId, 0L, now)
                            }.getOrDefault(sleeps)
                        }
                    },
                )
            }
        }
        if (dismissedSleeps.isNotEmpty()) {
            item {
                DeletedSleepWindowsCard(
                    windows = dismissedSleeps,
                    recomputing = recomputingSleep,
                    onHide = { marker ->
                        scope.launch {
                            val hidden = vm.hideDeletedSleepWindow(marker)
                            if (hidden) {
                                dismissedSleeps = dismissedSleeps.filterNot {
                                    it.deviceId == marker.deviceId && it.startTs == marker.startTs
                                }
                            }
                            Toast.makeText(
                                context,
                                if (hidden) {
                                    uiString(R.string.l10n_sleep_screen_deleted_sleep_window_hidden_5c848a32)
                                } else {
                                    uiString(R.string.l10n_sleep_screen_couldn_t_hide_this_deleted_sleep_bbedac55)
                                },
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    },
                    onRecompute = { marker ->
                        val key = marker.deviceId to marker.startTs
                        recomputingSleep = key
                        scope.launch {
                            val cleared = vm.recomputeDeletedSleep(marker)
                            dismissedSleeps = runCatching {
                                vm.repo.dismissedSleepsUnion(vm.activeStrapId)
                            }.getOrDefault(dismissedSleeps)
                            recomputingSleep = null
                            Toast.makeText(
                                context,
                                if (cleared) {
                                    uiString(R.string.l10n_sleep_screen_sleep_detection_reran_using_the_data_01757aad)
                                } else {
                                    uiString(R.string.l10n_sleep_screen_couldn_t_reopen_this_night_try_88265690)
                                },
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    },
                )
            }
        }
        sleepFreshness?.let { status ->
            item { SleepFreshnessNote(status, backfillNote ?: 0) }
        }
        // #940: the empty state is ONLY for a truly empty history. A newest day that merely fails
        // to merge (the phantom-edit shape) keeps the hero (night != null) and the full-history
        // tiles (tilesModel != null), so intact older nights are never hidden behind "no nights".
        if (tilesModel == null && night == null) {
            item {
                SleepEmptyState()
            }
        } else {
            // REST HERO — a scenic indigo backdrop with the night's sleep-performance score as a
            // layered BevelGauge (Rest gradient), else a big rounded hours-slept headline. Mirrors the
            // macOS SleepView.restHero. Presentation-only — reads the existing model figures. (Bevel)
            // The score is a full-history latest (series.last), so it reads from `tilesModel` when
            // the selected day's model failed to build (#940): real data over a zeroed gauge.
            item {
                RestHero(
                    // The DISPLAYED night's score (keyed by its wake-day), so the hero tracks the
                    // ◀/▶-navigated night instead of freezing on the full-history latest. When no night
                    // resolves but history exists (#940), keep the old "real data over a zeroed gauge"
                    // fallback to the latest score.
                    score = if (night != null) heroPerformanceScore(night, days, imported)
                            else tilesModel?.performance?.latest,
                    asleepMin = model?.stages?.asleep,
                    source = restHeroSource(imported, night?.dayKey ?: days.lastOrNull()?.day, activeIsOura),
                    overline = nightLabel,
                )
            }
            // #sleep-layout: a compact "Arrange" affordance (the same Tune entry Today uses) opens the
            // reorder / show-hide sheet. Pinned just above the arrangeable cards.
            item {
                Row(Modifier.fillMaxWidth().padding(top = Metrics.selectorTopUp)) {
                    Spacer(Modifier.weight(1f))
                    TextButton(
                        onClick = { showSleepArrange = true },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textTertiary),
                    ) {
                        Icon(Icons.Filled.Tune, contentDescription = stringResource(R.string.sleep_customize_title), modifier = Modifier.size(Metrics.iconSmall))
                        Spacer(Modifier.width(Metrics.space4))
                        // Concise verb on the affordance (the full "Customize Sleep" title is the icon's a11y
                        // label + the sheet header); reuses Today's generic "Customize" action string.
                        Text(stringResource(R.string.today_customize_action), style = NoopType.footnote)
                    }
                }
            }
            // Analytical cards render in the user's saved order (SleepLayoutPrefs), minus the hidden set.
            // Reordered via the Arrange sheet OR by long-press hold-to-drag on the card (#sleep-layout,
            // mirrors Today); each card's data guards (tilesModel/model) are preserved. Each section is ONE
            // keyed reorderable item so the whole card (incl. its top spacer) lifts and drops as a unit.
            // #sleep-layout: persist the live hold-to-drag reorder when the gesture drops (the in-memory
            // `sleepSectionOrder` already moved live in the frame loop; this writes it through).
            val persistSleepOrder = { SleepLayoutPrefs.setOrder(context, sleepSectionOrder) }
            sleepSectionOrder.filterNot { it in hiddenSections }.forEach { section ->
              val k = SLEEP_SECTION_KEY_PREFIX + section.raw
              when (section) {
                SleepSection.SLEEP_MARKS -> item(key = k) {
                    // SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1). LOGGING ONLY:
                    // a mark is persisted to the `sleep_mark` series + the shareable strap log; it never
                    // changes the detected sleep. Mirrors macOS SleepView.sleepMarkCard.
                    SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                    Column {
                    Spacer(Modifier.height(Metrics.selectorTopUp))
                    SleepMarkCard(
                onMark = { type ->
                    val mark = SleepMark.now(type)
                    // The shareable strap log is the human-readable surface in a debug export.
                    vm.ble.externalLog(mark.logLine())
                    scope.launch {
                        runCatching {
                            vm.repo.upsertMetricSeries(listOf(mark.metricPoint("my-whoop")))
                        }
                    }
                    Toast.makeText(context, mark.confirmation(), Toast.LENGTH_SHORT).show()
                },
            )
                    }
                    }
                }
                SleepSection.STAGES -> item(key = k) {
                    SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                    Column {
                    Spacer(Modifier.height(Metrics.selectorTopUp))
                    // #1537: the night's heart rate for the Classic view's line chart. Loaded here
                    // because Hero takes data rather than a repo, and keyed on the night so paging the
                    // carousel refetches. 60-second buckets, matching the iOS Sleep tab's hrBuckets call.
                    val hrFrom = night?.session?.effectiveStartTs
                    val hrTo = night?.session?.endTs
                    var nightHr by remember(hrFrom, hrTo) { mutableStateOf(emptyList<HrBucket>()) }
                    LaunchedEffect(hrFrom, hrTo, vm.activeStrapId) {
                        nightHr = if (hrFrom != null && hrTo != null && hrTo > hrFrom) {
                            runCatching {
                                vm.repo.hrBucketsUnion(vm.activeStrapId, hrFrom, hrTo, bucketSeconds = 60L)
                            }.getOrDefault(emptyList())
                        } else {
                            emptyList()
                        }
                    }
                    Hero(
                display = display,
                activeIsOura = activeIsOura,
                nightHr = nightHr,
                clock = night?.clockLabel ?: model?.clockLabel,
                nightOffset = nightOffset,
                lastIndex = max(navDays.lastIndex, 0),
                nightLabel = nightLabel,
                onNavigate = { nightOffset = it },
                session = night?.session,
                heroGroup = night?.heroGroup.orEmpty(),
                onUpdateTimes = { s, start, end ->
                    // #940 belt-and-braces: never apply (optimistically OR durably) a future-ending
                    // or inverted window, whatever the pickers produced. The editor's own guards
                    // (cross-midnight auto-correct + the disjoint confirm) should make this
                    // unreachable; sharing ONE safe window here keeps the in-memory copy and the DB
                    // write in lockstep. Same rule as WhoopRepository.updateSleepSessionTimes.
                    val safe = SleepEditGuard.clampedEditWindow(start, end, System.currentTimeMillis() / 1000L)
                    if (safe != null) {
                        val (safeStart, safeEnd) = safe
                        // Optimistic: rewrite this session in `sleeps` so every metric recomputes
                        // immediately, then persist DURABLY off the UI thread. Mirror the persist path —
                        // keep the IMMUTABLE detected startTs and store the corrected onset in
                        // startTsAdjusted with userEdited=true, so display (via effectiveStartTs) tracks the
                        // edit while the (deviceId,startTs) key never moves. (PR #260 + #395)
                        // Reclip stagesJSON in-memory so the hypnogram strip updates instantly (same
                        // reclip logic runs again in WhoopRepository for the durable DB copy).
                        // #1492: apply across the WHOLE bridged night. Editing only `s` (the winning
                        // fragment) left the fragments defining the displayed bedtime and wake exactly
                        // where they were, so a corrected night looked unchanged. ONE plan drives both the
                        // optimistic copy and the durable write, so they cannot disagree.
                        val group = night?.heroGroup.orEmpty().ifEmpty { listOf(s) }
                        val plan = SleepGroupEdit.plan(group, safeStart, safeEnd)
                        if (plan.clipped.isNotEmpty()) {
                            val edited = plan.clipped.associateBy { it.deviceId to it.startTs }
                            val gone = plan.dropped.map { it.deviceId to it.startTs }.toSet()
                            sleeps = sleeps.mapNotNull { row ->
                                val key = row.deviceId to row.startTs
                                when {
                                    key in gone -> null
                                    else -> edited[key] ?: row
                                }
                            }
                            if (plan.dropped.isNotEmpty()) {
                                sleepUndo = SleepUndoState(plan.dropped, fromEdit = true)
                            }
                            scope.launch { vm.updateSleepGroupTimes(group, safeStart, safeEnd) }
                        }
                    } else {
                        // The clamp refused a future/inverted window. Never drop an edit silently (the nap
                        // pickers used to do exactly that): tell the user why nothing changed. (#940)
                        Toast.makeText(
                            context,
                            "That time can't be saved (it lands in the future or ends before it starts).",
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                },
                onDeleteSession = { s ->
                    // Delete = the edit path minus the re-insert: drop this session from `sleeps`
                    // so every metric recomputes immediately as if the night were never recorded,
                    // then persist the removal off the UI thread. Lets the user clear a misread or
                    // spurious night. (#281)
                    // #65: offer a transient UNDO. `s` still carries its owning deviceId + userEdited,
                    // everything undo needs to restore it into the original namespace.
                    sleeps = sleeps.filterNot { it.deviceId == s.deviceId && it.startTs == s.startTs }
                    sleepUndo = SleepUndoState(listOf(s), fromEdit = false)
                    scope.launch {
                        vm.deleteSleepSession(s)
                        dismissedSleeps = runCatching {
                            vm.repo.dismissedSleepsUnion(vm.activeStrapId)
                        }.getOrDefault(dismissedSleeps)
                    }
                },
                onAddNap = { startTs, endTs ->
                    // Persist the new nap as its OWN session (#508); reload `sleeps` afterwards so the
                    // new block shows in the ◀/▶ browse without waiting for a sync. We don't optimistically
                    // insert here because the stages are staged from raw off the UI thread.
                    scope.launch {
                        vm.addManualNap(startTs, endTs)
                        sleeps = runCatching {
                            val now = System.currentTimeMillis() / 1000L
                            // Same active∪canonical union as the main loader (#814/#1008), so the
                            // post-nap reload can't snap the browse back to a canonical-only night set.
                            val importedSessions = vm.repo.sleepSessionsUnion(vm.activeStrapId, 0L, now)
                            val computed = vm.repo.computedSleepSessionsUnion(vm.activeStrapId, 0L, now)
                            fun localEndDay(ts: Long): String {
                                val offsetSec = (java.util.TimeZone.getDefault().getOffset(ts * 1000) / 1000).toLong()
                                return AnalyticsEngine.dayString(ts, offsetSec)
                            }
                            // Same imported-wins + #241 richness merge as the main loader.
                            WhoopRepository.mergeSleepRichness(importedSessions, computed) { localEndDay(it.endTs) }
                                .sortedBy { it.effectiveStartTs }
                        }.getOrDefault(sleeps)
                    }
                },
                onPickNightDate = onPickNightDate,
                napBlocks = night?.napBlocks ?: emptyList(),
                habitualMidsleepSec = habitualMidsleep,
                motionEpochs = night?.groupMotion ?: emptyList(),
                groupStages = night?.groupStages,
                groupInBedMin = night?.groupInBedMin,
                windowOnsetTs = night?.heroOnsetTs,
                windowWakeTs = night?.heroWakeTs,
            )
                    }
                    }
                }
                // Tiles / ledger / trends read the FULL-history model (#940): they stay up when only the
                // selected day's model failed to build, exactly as iOS keeps them while browsing. Each
                // `tilesModel?.let { m -> ... }` binds a non-null local so the smart-cast carries across
                // the item {} lambda boundary — same guard the old `if (tilesModel != null)` block used.
                // The 24 h body-clock dial (#1680). Drawn only for a fit that is at least WIDE: an
                // UNREADABLE rhythm has no phase to compare a night against, and an empty ring would read
                // as a broken chart rather than as "not enough data". It is a reorderable Sleep section,
                // so anyone who does not want it hides it in Arrange — the same affordance every other
                // card here already has, rather than a setting of its own. Mirrors SleepView.
                SleepSection.BODY_CLOCK -> {
                    val phase = v5Signals?.bodyClock
                    val session = night?.session
                    if (phase != null &&
                        phase.confidence != CircadianEngine.PhaseConfidence.UNREADABLE &&
                        session != null
                    ) {
                        item(key = k) {
                            SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                                Column {
                                    Spacer(Modifier.height(Metrics.selectorTopUp))
                                    BodyClockDialCard(
                                        estimate = phase,
                                        actualBedHour = localClockHour(session.effectiveStartTs),
                                        actualWakeHour = localClockHour(session.endTs),
                                    )
                                }
                            }
                        }
                    }
                }
                SleepSection.NIGHT_DETAIL -> tilesModel?.let { m ->
                    item(key = k) {
                        SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                            Column {
                                Spacer(Modifier.height(Metrics.selectorTopUp))
                                NightDetailHostCard(m, onMetricClick = { detailMetricKey = it })
                            }
                        }
                    }
                }
                SleepSection.SLEEP_DEBT -> tilesModel?.let { m ->
                    item(key = k) {
                        SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                            Column {
                                Spacer(Modifier.height(Metrics.selectorTopUp))
                                SleepDebtLedgerHostCard(m)
                            }
                        }
                    }
                }
                // StagesVsTypical reads the SELECTED day's model, never the full-history fallback: a
                // phantom newest day with no stage model would otherwise label ANOTHER night's stages as
                // this one (#940). Guarded on BOTH tilesModel and model, exactly as the pre-refactor
                // nesting was (it lived inside the `if (tilesModel != null)` block).
                SleepSection.STAGES_VS_TYPICAL -> if (tilesModel != null) model?.let { selectedModel ->
                    item(key = k) {
                        SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                            Column {
                                Spacer(Modifier.height(Metrics.selectorTopUp))
                                StagesVsTypicalHostCard(selectedModel)
                            }
                        }
                    }
                }
                SleepSection.ASLEEP_DURATION -> tilesModel?.let { m ->
                    item(key = k) {
                        SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                            Column {
                                Spacer(Modifier.height(Metrics.selectorTopUp))
                                DurationTrend(m)
                            }
                        }
                    }
                }
                // #sleep-layout: the two former pinned detail cards are now arrangeable sections.
                SleepSection.HOURS_VS_NEEDED -> tilesModel?.let { m ->
                    item(key = k) {
                        SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                            Column {
                                Spacer(Modifier.height(Metrics.selectorTopUp))
                                HoursVsNeededCard(m)
                            }
                        }
                    }
                }
                // Gated on tilesModel to preserve the pre-refactor visibility (both cards shared one
                // `tilesModel?.let` wrapper) — the card reads `sleeps`, not the model, but must not appear
                // in the #940 phantom-edit state (night != null, tilesModel == null) where it didn't before.
                SleepSection.CONSISTENCY -> if (tilesModel != null) item(key = k) {
                    SleepReorderableSection(k, sleepListState, sleepSectionDrag, persistSleepOrder) {
                        Column {
                            Spacer(Modifier.height(Metrics.selectorTopUp))
                            SleepConsistencyCard(sleeps, habitualMidsleep, tilesModel.consistency.latest)
                        }
                    }
                }
              }
            }
        }
    }
}

// MARK: - 0b. SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1)
//
// A compact additive card with two buttons. Tapping reports the chosen mark up to [onMark], which the
// screen persists to the `sleep_mark` metric series AND appends to the shareable strap log, then
// confirms with a Toast. LOGGING ONLY: a mark never touches the sleep detector or the night boundaries
// on this screen; it's a record for later tap-driven sleep bounds + calibration. Mirrors macOS
// SleepView.sleepMarkCard.

// Lives in the Sleep tab but also hostable in Today (#today-hosted-cards), so it is `internal` (not
// private). Self-contained apart from the [onMark] persistence callback the host supplies.
@Composable
internal fun SleepMarkCard(onMark: (SleepMarkType) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = uiString(R.string.l10n_sleep_screen_sleep_marks_8e9b86f0), overline = "Tap to log", trailing = "Phase 1")
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    uiString(R.string.l10n_sleep_screen_tap_when_you_re_heading_to_1f401690),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Button(
                        onClick = { onMark(SleepMarkType.BEDTIME) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = uiString(R.string.l10n_sleep_screen_log_going_to_sleep_6c2b519d) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.surfaceInset,
                            contentColor = Palette.textPrimary,
                        ),
                    ) {
                        Icon(Icons.Filled.Bedtime, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(uiString(R.string.l10n_sleep_screen_going_to_sleep_9c6c63fd), style = NoopType.subhead)
                    }
                    Button(
                        onClick = { onMark(SleepMarkType.WAKE) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = uiString(R.string.l10n_sleep_screen_log_waking_up_2f9c230e) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.surfaceInset,
                            contentColor = Palette.textPrimary,
                        ),
                    ) {
                        Icon(Icons.Filled.WbSunny, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(uiString(R.string.l10n_sleep_screen_i_m_awake_2caf0e7f), style = NoopType.subhead)
                    }
                }
            }
        }
    }
}

/** What the undo strip is holding: the retired sessions, plus whether they went as an outright delete or
 *  as fragments a bed/wake correction left outside a bridged night (#1492). A delete carries exactly one;
 *  a correction can retire several at once, and every one of them must come back on Undo.
 *
 *  Undo reverses the REMOVAL, not the whole correction: the retired fragments return with their original
 *  bounds while the surviving ones keep their corrected ones. That is what the strip offers in words
 *  ("sleep outside the new times was removed"), and it is the more useful half to be able to take back —
 *  the corrected bed and wake times were the point of the edit, and only the deletion is unrecoverable. */
private data class SleepUndoState(val sessions: List<SleepSession>, val fromEdit: Boolean)

/**
 * #65: the transient UNDO strip after a suppressing sleep delete. A Rest-tinted card stating the window
 * NOOP won't re-detect + a real Undo button. The banner auto-clears after ~7s (the caller's keyed
 * LaunchedEffect); Undo restores the deleted row into its ORIGINAL namespace and lifts the tombstone.
 * Mirrors the macOS SleepView.sleepUndoBanner (role-alert-ish, explicit Undo label).
 */
@Composable
private fun SleepUndoBanner(undo: SleepUndoState, onUndo: () -> Unit) {
    // Both construction sites are non-empty (a delete carries one row, a correction only raises this when
    // it retired something), but `first()` on an empty list would take the whole Sleep tab down — too
    // steep a price for a strip that is only ever informational. Render nothing instead.
    val session = undo.sessions.firstOrNull() ?: return
    val timeFmt = SimpleDateFormat(                                   // #1821
        ClockFormat.hourMinutePattern(ClockPrefs.uses24Hour(LocalContext.current)), Locale.US,
    )
    // effectiveStartTs is the displayed onset (a userEdited night's corrected bed time), matching iOS.
    val startText = timeFmt.format(java.util.Date(session.effectiveStartTs * 1000L))
    val endText = timeFmt.format(java.util.Date(session.endTs * 1000L))
    // Branch the copy on userEdited: a hand-edited/added (nap) night writes NO tombstone (it is never
    // re-detected), so the suppression promise would be false for it. Only a DETECTED delete tombstones,
    // so only it gets the "won't detect ... again" wording. Mirrors the macOS branch. (#65 banner honesty.)
    // #1492: a correction that narrows a bridged night RETIRES the fragments left outside it — otherwise
    // they keep defining the night's displayed start or end and the edit looks like it did nothing. That is
    // real recorded sleep going away from an action that reads as "adjust the times", so it must be as
    // reversible, and as clearly stated, as an outright delete. Count-free wording so one dropped fragment
    // and several read the same (no plural forms in the Android catalogue yet).
    val message = when {
        undo.fromEdit -> uiString(R.string.l10n_sleep_screen_sleep_outside_the_new_times_was_6229881e)
        session.userEdited -> "Sleep deleted."
        else -> "Sleep deleted. NOOP won't detect sleep between $startText and $endText again."
    }
    NoopCard(tint = Palette.restColor) {
        Row(
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = message },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                message,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = onUndo,
                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_sleep_screen_undo_sleep_deletion_1774a23c) },
            ) {
                Text(uiString(R.string.l10n_sleep_screen_undo_39fc7212), style = NoopType.subhead, color = Palette.restColor)
            }
        }
    }
}

/** Persistent management surface for detected nights whose deletion tombstone outlived the transient
 * Undo banner. Each row targets one exact marker; clearing it lets the normal analysis pass derive sleep
 * from the raw data again without weakening the default "deleted means deleted" behaviour (#515). */
@Composable
private fun DeletedSleepWindowsCard(
    windows: List<DismissedSleep>,
    recomputing: Pair<String, Long>?,
    onHide: (DismissedSleep) -> Unit,
    onRecompute: (DismissedSleep) -> Unit,
) {
    val dateFmt = remember { SimpleDateFormat("MMM d, HH:mm", Locale.getDefault()) }
    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space2)) {
                Text(
                    uiString(R.string.l10n_sleep_screen_deleted_sleep_windows_46fea77a),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    uiString(R.string.l10n_sleep_screen_recompute_a_night_to_clear_its_fd9e15c3),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            windows.forEach { marker ->
                val key = marker.deviceId to marker.startTs
                val busy = recomputing == key
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Text(
                        uiString(
                            R.string.l10n_sleep_screen_deleted_sleep_window_range_7bc5f027,
                            dateFmt.format(Date(marker.startTs * 1000L)),
                            dateFmt.format(Date(marker.endTs * 1000L)),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        enabled = recomputing == null,
                        onClick = { onHide(marker) },
                        modifier = Modifier.semantics {
                            contentDescription = uiString(
                                R.string.l10n_sleep_screen_hide_this_deleted_sleep_window_c349003f,
                            )
                        },
                    ) {
                        Text(
                            uiString(R.string.l10n_sleep_screen_hide_7aee4b04),
                            style = NoopType.subhead,
                            color = if (recomputing == null) Palette.textSecondary else Palette.textTertiary,
                        )
                    }
                    TextButton(
                        enabled = recomputing == null,
                        onClick = { onRecompute(marker) },
                        modifier = Modifier.semantics {
                            contentDescription = uiString(
                                R.string.l10n_sleep_screen_recompute_this_deleted_sleep_night_2d2f46f6,
                            )
                        },
                    ) {
                        Text(
                            if (busy) {
                                uiString(R.string.l10n_sleep_screen_recomputing_6f8e54e3)
                            } else {
                                uiString(R.string.l10n_sleep_screen_recompute_this_night_5ba0d05c)
                            },
                            style = NoopType.subhead,
                            color = if (recomputing == null) Palette.restColor else Palette.textTertiary,
                        )
                    }
                }
            }
            Text(
                uiString(R.string.l10n_sleep_screen_if_this_sleep_came_only_from_d0892088),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Liquid hero tokens (the liquid Sleep restyle)
//
// The hero card the sleep-performance vessel floats on, ported from the liquid Today (TodayScreen.kt). The
// fill is a translucent near-black (mock rgba(13,14,20,.80)) so the card floats OVER the day-of-sky and the
// vessel + white count-up number stay crisp — the CARD does the contrast work, not a muted sky. Radius 26 +
// a white@0.11 hairline give the frosted-glass edge. Same constants as the liquid Today heroCard.
private val LIQUID_HERO_RADIUS: Dp = 26.dp

// MARK: - 0. REST HERO — liquid sky + sleep-performance vessel (liquid restyle)
//
// The Rest world's opening, restyled to the liquid pilot: a frosted translucent-black hero card floating on
// the screen-level liquid sky (the scaffold's topBackground), carrying — when the night has a 0–100
// sleep-performance score — a [LiquidVessel] filled to score/100 in the Rest colour with the number counting
// up over it (the Today HeroScoreVessel idiom). No score → the big count-up hours-slept headline. A
// [SourceBadge] states whether the score is WHOOP's imported figure or NOOP's on-device estimate. The
// figures, fraction math and Rest tint are UNCHANGED from the BevelGauge this replaced — presentation-only.

@Composable
private fun RestHero(score: Double?, asleepMin: Double?, source: String, overline: String) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Sleep performance", overline = overline, trailing = "Rest")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                // The liquid hero CARD: a translucent near-black that floats over the day-of-sky so the
                // vessel + white count-up number stay crisp. Rounded 26 corner + a faint white hairline give
                // the frosted-glass edge of the liquid Today heroCard (fill rgba(13,14,20,.80), stroke
                // white@0.11). Replaces the per-hero night atmosphere (the sky now lives at screen level).
                .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                .background(Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity))
                .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS)),
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(Metrics.space24),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metrics.space14),
            ) {
                if (score != null) {
                    // The sleep-performance score as a liquid VESSEL, filled to score/100 in the Rest colour
                    // (the SAME recovery-colour scale the BevelGauge tipColor used), with the number counting
                    // up over it. The vessel runs live (slosh + tilt) since a real value is loaded. Mirrors
                    // the Today HeroScoreVessel.
                    SleepHeroVessel(
                        fraction = (score / 100.0).coerceIn(0.0, 1.0),
                        value = score,
                        tint = Palette.restColor,
                        diameter = 184.dp,
                    )
                    Text(sleepScoreWord(score), style = NoopType.subhead, color = Palette.textSecondary)
                } else {
                    // No 0–100 score for the night — lead with hours slept as a big rounded headline
                    // whose minutes tick up on appear (the same count-up the scored hero rolls). Mirrors the
                    // macOS SleepView.restHero CountUpText fallback.
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                        modifier = Modifier.padding(vertical = Metrics.space16),
                    ) {
                        CountUpText(
                            value = asleepMin ?: 0.0,
                            format = { durationText(it) },
                            style = NoopType.number(46f),
                            color = Palette.restBright,
                        )
                        Text(uiString(R.string.l10n_sleep_screen_asleep_last_night_b969b068), style = NoopType.subhead, color = Palette.textSecondary)
                    }
                }
                SourceBadge(text = source, tint = Palette.restColor)
            }
        }
    }
}

/**
 * The sleep-performance score as a liquid VESSEL with the value counting up over it — the liquid Sleep hero
 * element, the Today `HeroScoreVessel` idiom. A [LiquidVessel] fills to [fraction] (0..1) in [tint], sized to
 * [diameter]; over it a [CountUpText] rolls the number up to [value] (white, tabular, a soft shadow so it
 * reads on the vessel). The number is hit-transparent (clearAndSetSemantics + no clickable) so a tap falls
 * THROUGH to the vessel — LiquidVessel owns its own tap→splash+haptic. `animated = true`: a real score is
 * always loaded when this is drawn (the no-score branch shows the hours headline instead).
 */
@Composable
private fun SleepHeroVessel(fraction: Double, value: Double, tint: Color, diameter: Dp) {
    Box(modifier = Modifier.size(diameter), contentAlignment = Alignment.Center) {
        LiquidVessel(
            value = fraction.coerceIn(0.0, 1.0),
            tint = tint,
            animated = true,
            modifier = Modifier.size(diameter),
        )
        // Count-up number over the vessel — white, tabular, a soft shadow for legibility, hit-transparent so
        // the tap reaches the vessel (splash). Size ≈ diameter × 0.27 (the Today 96→26 ratio), capped.
        val numberSp = (diameter.value * 0.27f).coerceIn(20f, 52f)
        CountUpText(
            value = value,
            format = { it.roundToInt().toString() },
            style = NoopType.number(numberSp, weight = FontWeight.Bold)
                .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
            color = Color.White,
            modifier = Modifier.clearAndSetSemantics {},
        )
    }
}

// MARK: - 1. HERO — stage breakdown for the navigated night

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Hero(
    display: HeroDisplay?,
    // Whether the active strap is an Oura ring — names an Oura night's provenance and captions its split as
    // the ring's RAW on-device stages. Read/UI only. Mirrors macOS Repository.activeDeviceIsOura.
    activeIsOura: Boolean = false,
    clock: String?,
    nightOffset: Int,
    lastIndex: Int,
    // #1311: the calendar-aware "N nights ago" label for the shown night, computed by the caller from
    // navDays so a skipped no-data night doesn't desync the count. Used by the overline + nav header.
    nightLabel: String,
    onNavigate: (Int) -> Unit,
    session: SleepSession? = null,
    // #1537: the night's HR buckets for the Classic view's heart-rate line, loaded by the caller (which
    // holds the repo) and passed in like every other input here. Empty = nothing to draw.
    nightHr: List<HrBucket> = emptyList(),
    // #1492: the bridged night's fragments, forwarded to the editor so it frames itself on the whole
    // night rather than on `session` (the winning fragment, which defines neither displayed bound).
    heroGroup: List<SleepSession> = emptyList(),
    onUpdateTimes: (SleepSession, Long, Long) -> Unit = { _, _, _ -> },
    onDeleteSession: (SleepSession) -> Unit = {},
    onAddNap: (Long, Long) -> Unit = { _, _ -> },
    onPickNightDate: ((LocalDate) -> Unit)? = null,
    napBlocks: List<SleepSession> = emptyList(),
    // The LEARNED habitual midsleep the engine threaded into the daily total, passed to the main-night
    // selector so the "why this is your main sleep" reason matches the block the hero shows — for a
    // shift/late sleeper too. null = cold-start band. Mirrors iOS SleepView.habitualMidsleepSec. (C1)
    habitualMidsleepSec: Long? = null,
    // Per-epoch MOTION for the main-night GROUP (#407), laid in group order by `selectNight`. Empty → honest
    // empty state. Drawn UNDER the hypnogram on the same timeline. Mirrors iOS SleepView.Night.motionEpochs.
    motionEpochs: List<Double> = emptyList(),
    // The bridged main-night GROUP's summed DECODED stage minutes (`sumGroupStages`, gaps excluded) —
    // the byte-for-byte twin of iOS `night.stages.total`, used for the Naps card's "Main sleep". Null
    // for single-block days → the session's own decoded stages below. NOT `display.stages`, whose awake
    // is efficiency-derived and only approximates the decoded total.
    groupStages: StageMins? = null,
    // Whole-group time-in-bed minutes for a fragmented night (#561): Σ fragment windows, gaps
    // excluded, computed by `selectNight`. Null for single-block days → the session-window /
    // stage-total fallbacks below apply unchanged.
    groupInBedMin: Double? = null,
    // The whole bridged night's clock window (#345, HeroNight.heroOnsetTs/heroWakeTs): on a split
    // night `session` is one fragment, so its endTs is NOT the night's wake — the Asleep/Woke row
    // and the hypnogram axis read these instead. Null (single-block days, older callers) falls back
    // to the session window below, byte-identical to before.
    windowOnsetTs: Long? = null,
    windowWakeTs: Long? = null,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        NightNavHeader(nightOffset, nightLabel, lastIndex, clock, onNavigate, session,
            heroGroup = heroGroup, onUpdateTimes = onUpdateTimes, onDeleteSession = onDeleteSession,
            onAddNap = onAddNap, onPickNightDate = onPickNightDate)
        // The night's clock window — when you fell asleep and when you woke — as its own clearly
        // labelled row. These were only ever in the nav-header's trailing caption, which truncates
        // between the two chevrons on a phone, so in practice the two times people look for first
        // were effectively hidden. Shown for every night that has a session (including the stage-less
        // stub, where it's the only thing the hero can say). Mirrors iOS SleepView.sleepWindowRow.
        // #345: the row shows the WHOLE night's window — on a split night the session (edit anchor)
        // ends mid-night and its endTs contradicted the header pill two lines above.
        session?.let { SleepWindowRow(windowOnsetTs ?: it.effectiveStartTs, windowWakeTs ?: it.endTs) }
        if (display == null) {
            // Honest fallback: this night recorded no usable stage data — never silently
            // substitute another night's hypnogram. (#160)
            NoopCard(tint = Palette.restColor) {
                Text(
                    uiString(R.string.l10n_sleep_screen_no_stage_data_recorded_for_this_93a86806),
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            val s = display.stages
            // After a bed/wake edit the session window is the source of truth for time-in-bed,
            // so the subtitle tracks the edit even before the stage minutes are recomputed. Uses the
            // EFFECTIVE onset so a hand-edited bedtime is reflected. (#160 / PR #395)
            // A fragmented night prefers the GROUP total (#561): `session` is only the WINNING
            // fragment, so its window alone undershot the summed stage minutes shown beside it.
            val inBedMin = groupInBedMin
                ?: session?.let { (it.endTs - it.effectiveStartTs) / 60.0 }
                ?: s.total
            // An Oura night's stages are the ring's RAW on-device SleepNet classification (decoded off the
            // 0x49 phase stream), NOT a NOOP approximation — so it gets its own honest caption instead of the
            // "approx. stages (on-device)" one that describes NOOP's own sparse-motion staging.
            val stageCaption = if (activeIsOura) " · raw on-device stages" else " · approx. stages (on-device)"
            val subtitle = "${durationText(inBedMin)} in bed · ${display.efficiencyText} efficiency" +
                (if (display.realSegments != null) stageCaption else "")
            // iOS #988 port: true per-epoch segments (≥ 2 — a single run has no transitions to lay
            // out) get the per-stage timeline rows; the rows ARE the legend, so no footer. Anything
            // else keeps the honest proportional strip + StageBreakdownRows footer.
            val real = display.realSegments?.takeIf { it.size >= 2 }
            if (real != null) {
                // #sleep-chart-style: the opt-in FILLED stepped hypnogram when the user selected it AND the
                // night has real timestamped segments; otherwise the classic per-stage-rows timeline (the
                // default, unchanged for everyone who doesn't switch).
                val chartStyle = UnitPrefs.sleepChartStyle(LocalContext.current)
                val filledSegments = display.hypnogramSegments?.takeIf { it.size >= 2 }
                if (chartStyle != SleepChartStyle.CLASSIC && filledSegments != null) {
                    SleepChartCard(
                        title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                        subtitle = subtitle,
                        trailing = durationText(s.asleep),
                        tint = Palette.restColor,
                        // #1536: the stage LEGEND that used to sit here is gone, and the rows below now
                        // take the chart's ramp. Those two go together. The legend decoded the hypnogram
                        // above it, which is real work — but it listed the stages in a different order than
                        // the rows, and the rows were drawing FIXED theme tokens while the chart drew ramp
                        // colours, so on Oura/Garmin three things in one card disagreed. Making the rows
                        // ramp-aware leaves them naming and colouring every stage correctly, which IS the
                        // key; a separate legend above a correct key is the redundancy that was reported.
                        footer = { StageBreakdownRows(s, chartStyle.stagePalette) },
                    ) {
                        FilledHypnogram(
                            segments = filledSegments,
                            onsetTs = windowOnsetTs ?: session?.effectiveStartTs,
                            wakeTs = windowWakeTs ?: session?.endTs,
                            filled = chartStyle.isFilled,
                            palette = chartStyle.stagePalette,
                        )
                    }
                } else {
                    SleepChartCard(
                        title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                        subtitle = subtitle,
                        trailing = durationText(s.asleep),
                        tint = Palette.restColor,
                        footer = {},
                    ) {
                        StageTimeline(
                            realSegments = real,
                            s = s,
                            // #345: the axis spans the WHOLE night. The group hypnogram (#364 seams) runs to
                            // the group's last wake; labelling the axis off the session fragment's endTs cut
                            // the clock labels short on a split night.
                            onsetTs = windowOnsetTs ?: session?.effectiveStartTs,
                            wakeTs = windowWakeTs ?: session?.endTs,
                            motionEpochs = motionEpochs,
                        )
                    }
                }
            } else {
                SleepChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = { StageBreakdownRows(s) },
                ) {
                    // Reconstructed architecture (light → deep → light → rem → light → awake) as the
                    // flat proportional strip. No MotionStrip and no fake steps here: invented
                    // architecture has no genuine timeline to anchor to (mirrors the iOS else-branch).
                    // #1537: heart rate across the night, above the stage strip — the twin of the iOS
                    // Classic view's `sleepHRChart`, which Android never had. Same window as the stage
                    // strip below (the night's own onset..wake), and the same 60-second buckets iOS asks
                    // for, so the two platforms plot the same shape from the same rows. Drawn only with
                    // at least two buckets, matching iOS's `buckets.count >= 2`: one point is not a line,
                    // and a night the strap never sampled should show nothing rather than a flat stub.
                    if (nightHr.size >= 2) {
                        LineChart(
                            values = nightHr.map { it.avgBpm },
                            modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                                .semantics {
                                    contentDescription = uiString(R.string.l10n_sleep_screen_sleep_heart_rate_chart_8ec47ae1)
                                },
                            color = Palette.metricRose,
                            fill = false,
                            timestamps = nightHr.map { it.bucket },
                            formatValue = { "${Math.round(it)} bpm" },
                        )
                    }
                    val segments = stageSegments(s)
                    if (segments.isNotEmpty()) {
                        HypnogramWithAxis(
                            stages = segments,
                            onsetTs = session?.effectiveStartTs,
                            wakeTs = session?.endTs,
                        )
                    } else {
                        Text(
                            uiString(R.string.l10n_sleep_screen_no_stage_breakdown_for_this_night_b74bf9c3),
                            style = NoopType.subhead,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
            // For an Oura-provided night, say plainly this split is the ring's RAW on-device classification —
            // so the larger Awake / smaller Deep+REM here isn't misread as the polished numbers the Oura app
            // shows for the same night (the app post-processes the same stream). Mirrors iOS ouraRawStagesNote.
            if (activeIsOura) OuraRawStagesNote()
            // #345 follow-up: a night staged on SPARSE motion coverage can UNDER-detect and read short
            // ("slept 8h, shows 1h"). Say so honestly, gated on the persisted stagingSparse flag (the day's
            // SleepStager.isGravitySparse verdict). `session` is the REAL main block (selectNight's edit
            // anchor), so it carries the flag; nil (imported / pre-migration) is never flagged. Mirrors iOS
            // SleepView.stageIncompleteNote.
            if (session?.stagingSparse == true) SleepIncompleteNote()
            // #1716 — a device-provided hypnogram assembled from records that never all arrived leaves a
            // HOLE in the timeline while the session still spans the whole night, so a night we saw a
            // fraction of renders as a complete one. Asked of the bridged main-night GROUP (the quantity
            // analyzeDay gates on), never of one fragment. This is the only place the coverage guard
            // becomes visible: the engine's matching Rest downgrade lands in a transient DayResult field
            // no screen reads. Mirrors iOS SleepView.stagePartialNote.
            val coverageGroup = heroGroup.ifEmpty { listOfNotNull(session) }
            val stageCoverage = HypnogramCoverage.groupFraction(
                coverageGroup.map {
                    HypnogramCoverage.Fragment(it.stagesJSON, (it.endTs - it.startTs).toDouble())
                }
            )
            if (stageCoverage != null && stageCoverage < HypnogramCoverage.minCoverage) {
                SleepPartialNote(stageCoverage)
            }
        }
        // Naps card (#508/#518): the day's blocks OTHER than the main night, each editable / deletable
        // with the SAME mechanism main sleep uses, plus a Main / Nap(s) / Total split so what drives the
        // day's Rest total is explainable. Mirrors iOS SleepView.napSection.
        if (session != null) {
            // Main = the WHOLE main-night's summed DECODED stage minutes (awake+light+deep+rem), NOT the
            // winning fragment's window — a biphasic/bridged night has sibling fragments that are part of
            // the main sleep, not naps, and the old single-block window undercounted the Main / Total
            // split on a fragmented night. Byte-for-byte twin of iOS SleepView.napSection (`night.stages
            // .total`): the bridged group's `sumGroupStages` (gaps excluded, mirrors iOS mergeDay), or the
            // single block's own decoded stages, both clamped to onset. NOT `display.stages`, whose awake
            // is efficiency-derived. Window fallback only for a stage-less stub day, unchanged from before.
            val mainStages = groupStages
                ?: parseSessionStages(SleepStageTotals.clampStagesToOnset(session.stagesJSON, session.effectiveStartTs))
            val mainMin = mainStages?.let { it.awake + it.light + it.deep + it.rem }
                ?: (session.endTs - session.effectiveStartTs) / 60.0
            NapsCard(
                main = session,
                mainMin = mainMin,
                naps = napBlocks,
                onEditNapTimes = onUpdateTimes,
                onDeleteNap = onDeleteSession,
                habitualMidsleepSec = habitualMidsleepSec,
                activeIsOura = activeIsOura,
            )
        }
    }
}

/**
 * Naps card (#508/#518): the day's MAIN sleep is the hero above; this lists every OTHER block of the
 * day (afternoon naps, split-sleep) as its own editable / deletable row, and — once the day has at
 * least one nap — a Main / Nap(s) / Total split so the time driving the day's Rest total is explicit.
 * A single-night day shows just the "No naps" line, reading exactly as before. Reuses the main-sleep
 * edit/delete callbacks (they key off each row's immutable (deviceId, startTs)). Mirrors iOS
 * SleepView.napSection.
 */
@Composable
private fun NapsCard(
    main: SleepSession,
    // The day's MAIN-sleep minutes = the whole main-night's summed DECODED stage minutes (iOS
    // `night.stages.total`): the bridged group's `sumGroupStages` or the single block's own decoded
    // stages. Computed by the caller. NOT `main`'s own window — that undercounts a bridged night.
    mainMin: Double,
    naps: List<SleepSession>,
    onEditNapTimes: (SleepSession, Long, Long) -> Unit,
    onDeleteNap: (SleepSession) -> Unit,
    // The LEARNED habitual midsleep, fed to the main-night selector so the "why this is your main sleep"
    // reason matches the block the hero shows. null = cold-start band. Mirrors iOS SleepView. (C1)
    habitualMidsleepSec: Long? = null,
    // Active strap is an Oura ring → a computed night's provenance reads "Oura" not "On-device" (C4).
    activeIsOura: Boolean = false,
) {
    val napMin = naps.sumOf { (it.endTs - it.effectiveStartTs) / 60.0 }
    NoopCard(padding = Metrics.space14, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Text(uiString(R.string.l10n_sleep_screen_daytime_sleep_871c03ca), style = NoopType.overline, color = Palette.textTertiary)
            Text(uiString(R.string.l10n_sleep_screen_naps_2f83e350), style = NoopType.subhead, color = Palette.textPrimary)
            if (naps.isNotEmpty()) {
                // Main / Nap(s) / Total split — only meaningful once a nap exists. Total = main + naps.
                Row(modifier = Modifier.fillMaxWidth()) {
                    NapSummaryCell("Main sleep", durationText(mainMin), Modifier.weight(1f))
                    NapSummaryCell("Nap(s)", durationText(napMin), Modifier.weight(1f))
                    NapSummaryCell("Total", durationText(mainMin + napMin), Modifier.weight(1f))
                }
            }
            if (naps.isEmpty()) {
                Text(
                    uiString(R.string.l10n_sleep_screen_no_naps_recorded_for_this_day_b17c148f),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            } else {
                naps.forEachIndexed { i, nap ->
                    NapRow(nap, onEditNapTimes, onDeleteNap)
                    if (i < naps.lastIndex) {
                        Box(Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
                    }
                }
            }
            // Provenance (C4) + the "why this is your main sleep" explainer (C1). The badge names the REAL
            // per-day merge winner; the info affordance reveals the foundation reason for the pick. Mirrors
            // iOS SleepView.mainSleepFooter. (spec 2026-06-20 C1/C4)
            Box(Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
            MainSleepFooter(main = main, naps = naps, habitualMidsleepSec = habitualMidsleepSec, activeIsOura = activeIsOura)
        }
    }
}

/**
 * Honest caveat for an Oura-provided night: the stage split shown is the ring's RAW on-device SleepNet
 * classification read straight off the BLE phase stream — NOT the adjusted stages the Oura app displays.
 * The app post-processes the same night, so its Deep/REM run higher and its Awake lower; cross-checks put
 * our Awake well above the app's. Surfaced so the breakdown isn't taken for the app's. Mirrors iOS
 * SleepView.ouraRawStagesNote. Copy + tint (design token [Palette.restColor]) match Swift.
 */
@Composable
private fun OuraRawStagesNote() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
        modifier = Modifier.padding(horizontal = 2.dp),
    ) {
        SourceBadge(text = "Raw on-device stages", tint = Palette.restColor)
        Text(
            "This split is the ring's raw on-device classification read over Bluetooth, not the adjusted " +
                "stages the Oura app shows. Expect more Awake and less Deep/REM here than in the Oura app " +
                "for the same night.",
            style = NoopType.caption,
            color = Palette.textTertiary,
        )
    }
}

/** The sparse-coverage caveat (#345): a night staged on thin motion data can under-detect and read short
 *  ("slept 8h, shows 1h"). Honest + actionable. Mirrors iOS SleepView.stageIncompleteNote. */
@Composable
private fun SleepIncompleteNote() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
        modifier = Modifier.padding(horizontal = 2.dp),
    ) {
        SourceBadge(text = uiString(R.string.l10n_sleep_screen_may_be_incomplete_7230dc27), tint = Palette.statusWarning)
        Text(
            uiString(R.string.l10n_sleep_screen_little_motion_was_recorded_over_f061b7e4),
            style = NoopType.caption,
            color = Palette.textTertiary,
        )
    }
}

/**
 * The PARTIAL-TIMELINE caveat (#1716): this night's stage segments account for less than
 * [HypnogramCoverage.minCoverage] of the window the session claims, so the stage totals describe only the
 * part of the night the timeline accounts for. Distinct from BOTH notes above — #H9 doubts the deep/REM SPLIT
 * of a fully-described night, #345 doubts a night staged on thin motion, and this one says plainly that
 * some of the night is MISSING rather than doubted.
 *
 * HONEST-DATA: reports only what was observed and changes no number. The percentage is FLOORED, never
 * rounded — 94.8% must not print as "95%" beside a badge raised because coverage fell below 95% — which is
 * why this takes the fraction and floors it here rather than accepting a pre-rounded Int from the caller.
 * The copy names NO cause and offers NO remedy: the captures behind this note show the missing codes DID
 * reach the phone (the ring reported them unwritten, 0xFF) and that re-persisting the night does not fill
 * the hole. Mirrors iOS SleepView.stagePartialNote.
 */
@Composable
private fun SleepPartialNote(coverage: Double) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
        modifier = Modifier.padding(horizontal = 2.dp),
    ) {
        SourceBadge(text = uiString(R.string.l10n_sleep_screen_partly_recorded_f43509ab), tint = Palette.statusWarning)
        Text(
            uiString(R.string.l10n_sleep_screen_only_of_this_night_s_window_9660332a,
                     floor(coverage * 100.0).toInt()),
            style = NoopType.caption,
            color = Palette.textTertiary,
        )
    }
}

/**
 * The Naps card footer: the night's provenance badge (the REAL per-day merge winner) next to a tappable
 * "Why this sleep?" affordance that reveals the foundation [SleepStageTotals.MainNightReason] copy inline,
 * so the pick is explainable on the spot. The reason words + the provenance wording are IDENTICAL to iOS
 * SleepView.mainSleepFooter/whyPopover. Compose has no anchored popover idiom here, so the reveal is an
 * inline disclosure — the COPY and LOGIC match Swift exactly, only the reveal chrome differs.
 * (spec 2026-06-20 C1/C4)
 */
@Composable
private fun MainSleepFooter(
    main: SleepSession,
    naps: List<SleepSession>,
    habitualMidsleepSec: Long?,
    activeIsOura: Boolean = false,
) {
    val reason = mainSleepReasonText(listOf(main) + naps, habitualMidsleepSec)
    // C4 — the real merge winner, the SAME wording the By-Day badge uses ("Oura" / "On-device" / "Whoop" /
    // "Apple Health"), keyed on the main block's source. A persisted Oura night already carries the ring id
    // (→ "Oura" from daySourceBadge); a night that merely COMPUTED under a live Oura strap reads "On-device"
    // there, so flip it to "Oura" too, matching iOS SleepView.nightSource (WHOOP/Apple imports still win).
    val base = daySourceBadge(main.deviceId)
    val (sourceText, sourceTint) =
        if (base.first == "On-device" && activeIsOura) "Oura" to Palette.restColor else base
    var showWhy by remember(main.startTs) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SourceBadge(text = sourceText, tint = sourceTint)
            Spacer(Modifier.weight(1f))
            if (reason != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    modifier = Modifier
                        .clickable { showWhy = !showWhy }
                        .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_why_this_is_your_main_sleep_71efd756) },
                ) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = null,
                        tint = Palette.restColor,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(uiString(R.string.l10n_sleep_screen_why_this_sleep_ab42b016), style = NoopType.footnote, color = Palette.restColor)
                }
            }
        }
        if (showWhy && reason != null) {
            Text(uiString(R.string.l10n_sleep_screen_about_your_main_sleep_1da8a640), style = NoopType.subhead, color = Palette.textPrimary)
            Text(reason, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

/**
 * The verbatim "why this is your main sleep" reason for the day's [blocks], with {DUR} filled as "Xh Ym"
 * from the chosen block's asleep duration — driven entirely by the foundation [SleepStageTotals.MainNightReason]
 * so the explainer states exactly what the selector decided (never a re-derived guess). Resolved via the
 * SAME [SleepStageTotals.mainNightSelection] API the analytics pick uses, with the SAME learned habitual
 * the hero used, so the words match the block the hero shows. null only when the day has no blocks. The
 * copy is byte-identical to iOS SleepView.mainSleepReasonText. (spec 2026-06-20 C1)
 */
internal fun mainSleepReasonText(blocks: List<SleepSession>, habitualMidsleepSec: Long?): String? {
    val sel = SleepStageTotals.mainNightSelection(
        blocks.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
        uiTzOffsetSec(),
        habitualMidsleepSec,
    ) ?: return null
    // Round to whole minutes for "Xh Ym", matching Swift durationText(sel.asleepMinutes).
    val dur = durationText(sel.asleepSec / 60.0)
    return when (sel.reason) {
        SleepStageTotals.MainNightReason.onlyBlock ->
            "This is your only sleep block today."
        SleepStageTotals.MainNightReason.longest ->
            "Picked as your main sleep because it was your longest block ($dur)."
        SleepStageTotals.MainNightReason.longestNearUsual ->
            "Picked as your main sleep because it was your longest block ($dur), near your usual bedtime."
        SleepStageTotals.MainNightReason.alignedToUsual ->
            "Picked as your main sleep because it started near your usual sleep time."
    }
}

/** One Main / Nap(s) / Total cell: an overline label over a duration number. (#518) */
@Composable
private fun NapSummaryCell(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Text(label, style = NoopType.overline, color = Palette.textTertiary)
        Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
    }
}

/** One nap row: its clock window + duration, with the SAME edit (re-pick start then end) and delete
 *  affordances main sleep uses, keyed on the nap's own immutable (deviceId, startTs). The edit reuses
 *  the night-edit picker pattern (bed time-of-day on the nap's own day, then a wake time-only derived
 *  to the first instant after that start) so a nap can't be re-bucketed onto the wrong day. (#508/#518) */
@Composable
private fun NapRow(
    nap: SleepSession,
    onEditNapTimes: (SleepSession, Long, Long) -> Unit,
    onDeleteNap: (SleepSession) -> Unit,
) {
    val context = LocalContext.current
    var editingStart by remember(nap.startTs) { mutableStateOf(false) }
    var editingEnd by remember(nap.startTs) { mutableStateOf(false) }
    var pendingStart by remember(nap.startTs) { mutableStateOf(0L) }
    // C1 — "why this is a nap" explainer: everything other than the chosen main block is logged as a nap,
    // with the Edit next-step. Inline disclosure (Compose has no anchored popover here); the COPY matches
    // iOS SleepView.whyPopover(napSuffix:) exactly. (spec 2026-06-20)
    var showWhy by remember(nap.startTs) { mutableStateOf(false) }
    val napIs24h = ClockPrefs.uses24Hour(LocalContext.current)   // #1821
    val window = "${clockTimeLabel(nap.effectiveStartTs, napIs24h)} - ${clockTimeLabel(nap.endTs, napIs24h)}"
    val durMin = (nap.endTs - nap.effectiveStartTs) / 60.0
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // A11Y: the row's readable label lives on the NON-actionable leading content (decorative
            // icon + window/duration text) as a single merged node, so the three action IconButtons
            // below stay individually focusable with their own contentDescriptions (TalkBack-reachable).
            Row(
                modifier = Modifier
                    .weight(1f)
                    .semantics(mergeDescendants = true) {
                        contentDescription = uiString(R.string.l10n_sleep_screen_nap_window_durationtext_durmin_bbc35167, window, durationText(durMin))
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Palette.restColor, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(Metrics.space10))
                Column {
                    Text(window, style = NoopType.body, color = Palette.textPrimary)
                    Text(durationText(durMin), style = NoopType.overline, color = Palette.textTertiary)
                }
            }
            // Each action gets a 48dp IconButton touch target and keeps its own contentDescription.
            IconButton(onClick = { showWhy = !showWhy }) {
                Icon(
                    Icons.Filled.Info,
                    contentDescription = uiString(R.string.l10n_sleep_screen_why_this_is_logged_as_a_83ed7c06),
                    tint = Palette.restColor,
                    modifier = Modifier.size(18.dp),
                )
            }
            IconButton(onClick = { editingStart = true }) {
                Icon(
                    Icons.Filled.Edit,
                    contentDescription = if (nap.userEdited) "Edit nap times (edited)" else "Edit nap times",
                    tint = Palette.restColor,
                    modifier = Modifier.size(18.dp),
                )
            }
            IconButton(onClick = { onDeleteNap(nap) }) {
                Icon(
                    Icons.Filled.DeleteOutline,
                    contentDescription = uiString(R.string.l10n_sleep_screen_delete_this_nap_1adf0a3f),
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        if (showWhy) {
            Text(uiString(R.string.l10n_sleep_screen_about_this_nap_e2719b9b), style = NoopType.subhead, color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_sleep_screen_logged_as_a_nap_wrong_tap_4285d23e),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }

    // Edit step 1 — nap START time-of-day, kept on the nap's own calendar day (only the hour/minute move).
    if (editingStart) {
        val startCal = Calendar.getInstance().apply { timeInMillis = nap.effectiveStartTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = nap.effectiveStartTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                    }
                    // #940 guard 1: the time-only picker keeps the nap's own calendar day, so rolling the
                    // start EARLIER across midnight (00:20 -> 23:50) lands it in the future. Snap the date
                    // back a day for the previous evening, exactly like the Add-nap path (no wake rule:
                    // a nap start after the night's wake is normal). Without this the future window was
                    // clamped to null downstream and the whole edit was silently dropped.
                    pendingStart = SleepEditGuard.autoCorrectedBed(
                        previousBedTs = nap.effectiveStartTs,
                        candidateBedTs = cal.timeInMillis / 1000L,
                        originalWakeTs = null,
                        nowTs = System.currentTimeMillis() / 1000L,
                    )
                    editingStart = false
                    editingEnd = true
                },
                startCal.get(Calendar.HOUR_OF_DAY), startCal.get(Calendar.MINUTE), true,
            ).apply { setTitle("Nap started") }
            dialog.setOnDismissListener { editingStart = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // Edit step 2 — nap END time-only; its day DERIVED as the first instant strictly after the chosen
    // start (within 24h), mirroring the wake-edit cross-day constraint so a nap stays on the right day.
    if (editingEnd && pendingStart > 0L) {
        val endCal = Calendar.getInstance().apply { timeInMillis = nap.endTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = pendingStart * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                        if (timeInMillis / 1000L <= pendingStart) add(Calendar.DAY_OF_MONTH, 1)
                    }
                    onEditNapTimes(nap, pendingStart, cal.timeInMillis / 1000L)
                    editingEnd = false
                    pendingStart = 0L
                },
                endCal.get(Calendar.HOUR_OF_DAY), endCal.get(Calendar.MINUTE), true,
            ).apply { setTitle("Nap ended") }
            dialog.setOnDismissListener { editingEnd = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }
}

/** 90 s display floor for the stage rows — rows tolerate fine texture, so 90 s, not the staircase's 300 s. */
private const val STAGE_ROW_SMOOTH_SEC = 90.0

/**
 * iOS #988 port — the WHOOP-style per-stage timeline stack that replaces the flat hypnogram strip
 * for real-stage nights. Four tappable rows in WHOOP order (AWAKE · LIGHT · DEEP · REM), each a
 * hatched full-night track with solid segments on the shared onset→wake axis; MotionStrip and the
 * clock-label axis sit under the rows on the SAME timeline; a fixed-height insight slot closes the
 * stack. The rows ARE the legend — no dot row, no footer. Mirrors SleepView.stageTimeline.
 */
@Composable
internal fun StageTimeline(
    realSegments: List<Pair<String, Float>>,
    s: Stages,
    onsetTs: Long?,
    wakeTs: Long?,
    motionEpochs: List<Double>,
) {
    // Night span: the session window when we have one (the clock axis uses the same span), else
    // the segments' own summed minutes — the fractions are identical either way.
    val weightSec = realSegments.sumOf { (_, wt) -> if (wt.isFinite() && wt > 0f) wt.toDouble() * 60.0 else 0.0 }
    val spanSec = if (onsetTs != null && wakeTs != null && wakeTs > onsetTs) {
        (wakeTs - onsetTs).toDouble()
    } else {
        weightSec
    }
    val intervals = remember(realSegments, spanSec) {
        displaySmoothed(stageIntervalsFromWeights(realSegments, spanSec), STAGE_ROW_SMOOTH_SEC)
    }
    // Tap-to-highlight; keyed on the night's segments so navigating nights clears the selection.
    var selectedStage by remember(realSegments) { mutableStateOf<String?>(null) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        listOf(
            Triple("Awake", s.awake, Palette.sleepAwake),
            Triple("Light", s.light, Palette.sleepLight),
            Triple("Deep", s.deep, Palette.sleepDeep),
            Triple("REM", s.rem, Palette.sleepREM),
        ).forEach { (label, minutes, color) ->
            StageTimelineRow(
                label = label,
                minutes = minutes,
                percent = stageSharePercent(label, s),
                color = color,
                spans = stageRowSpans(intervals, label, spanSec),
                selected = selectedStage == label,
                dimmed = selectedStage != null && selectedStage != label,
                onTap = { selectedStage = if (selectedStage == label) null else label },
            )
        }
        // #407 — MotionStrip component + data path untouched; relocated UNDER the rows on the SAME
        // timeline. Same inner insets as the rows' tracks so epochs don't skew against the segments.
        Box(modifier = Modifier.padding(horizontal = Metrics.stageRowPadH)) {
            MotionStrip(motionEpochs)
        }
        if (onsetTs != null && wakeTs != null) {
            Box(modifier = Modifier.padding(horizontal = Metrics.stageRowPadH)) {
                ClockLabelRow(onsetTs, wakeTs)
            }
        }
        StageInsight(selectedStage, s)
    }
}

/**
 * One per-stage timeline row: STAGE overline + coloured % + right-aligned duration over a hatched
 * full-night track with the stage's solid segments. Selected row gets a hairlineStrong stroke;
 * when ANOTHER row is selected this row's segments and % dim to tertiary. One collapsed a11y node —
 * "Awake: 49 min, 10 percent of the night". Mirrors SleepView.stageTimelineRow.
 */
@Composable
private fun StageTimelineRow(
    label: String,
    minutes: Double,
    percent: Int,
    color: Color,
    spans: List<Pair<Float, Float>>,
    selected: Boolean,
    dimmed: Boolean,
    onTap: () -> Unit,
) {
    val segColor = if (dimmed) Palette.textTertiary.copy(alpha = 0.55f) else color
    val pctColor = if (dimmed) Palette.textTertiary else color
    val shape = RoundedCornerShape(Metrics.stageRowCorner)
    Column(
        verticalArrangement = Arrangement.spacedBy(Metrics.space6),
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.textPrimary.copy(alpha = 0.045f))
            .then(if (selected) Modifier.border(1.5.dp, Palette.hairlineStrong, shape) else Modifier)
            .clickable(onClickLabel = "Highlights this stage on the sleep chart", onClick = onTap)
            .padding(horizontal = Metrics.stageRowPadH, vertical = Metrics.stageRowPadV)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_sleep_screen_label_durationtext_minutes_percent_percent_of_6ab7ae87, label, durationText(minutes), percent)
            },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label.uppercase(Locale.getDefault()),
                style = NoopType.overline,
                color = Palette.textPrimary,
                maxLines = 1,
            )
            Spacer(modifier = Modifier.width(Metrics.space8))
            Text(uiString(R.string.l10n_sleep_screen_percent_2281d326, percent), style = NoopType.captionNumber, color = pctColor, maxLines = 1)
            Spacer(modifier = Modifier.weight(1f))
            Text(
                durationText(minutes),
                style = NoopType.captionNumber,
                color = Palette.textPrimary,
                maxLines = 1,
            )
        }
        StageRowTrack(spans = spans, color = segColor)
    }
}

/**
 * The row's track, drawn in a SINGLE Canvas (PERF: a fragmented night must not become hundreds of
 * composables — Charts.kt hoist convention): a recessed full-night base with faint diagonal
 * hatching ("no segment here" reads as "elsewhere in the night", not missing data), then the
 * stage's solid rounded segments with a width floor, clamped so floored widths stay on-canvas
 * (same #36 lesson as HypnogramWithAxis).
 */
@Composable
private fun StageRowTrack(spans: List<Pair<Float, Float>>, color: Color) {
    Canvas(modifier = Modifier.fillMaxWidth().height(Metrics.stageRowTrackHeight)) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas

        val trackRadius = CornerRadius(Metrics.stageSegCorner.toPx(), Metrics.stageSegCorner.toPx())
        drawRoundRect(color = Palette.surfaceInset, size = Size(w, h), cornerRadius = trackRadius)
        clipRect(0f, 0f, w, h) {
            val step = 6.dp.toPx()
            var x = -h
            while (x < w) {
                drawLine(
                    color = Palette.hairline,
                    start = Offset(x, h),
                    end = Offset(x + h, 0f),
                    strokeWidth = 1f,
                )
                x += step
            }
        }

        val minW = Metrics.stageSegMinWidth.toPx()
        val segRadius = CornerRadius(Metrics.stageSegCorner.toPx(), Metrics.stageSegCorner.toPx())
        spans.forEach { (fracStart, fracWidth) ->
            if (!fracStart.isFinite() || !fracWidth.isFinite() || fracWidth <= 0f) return@forEach
            val segW = maxOf(w * fracWidth, minW).coerceAtMost(w)
            val x0 = (w * fracStart).coerceIn(0f, w - segW)
            drawRoundRect(
                color = color,
                topLeft = Offset(x0, 0f),
                size = Size(segW, h),
                cornerRadius = segRadius,
            )
        }
    }
}

/**
 * Fixed-height per-stage insight slot under the axis: with a stage selected, that stage tonight;
 * otherwise the quiet "tap a row" hint. Fixed height so selection never reflows the card. The
 * 30-day typical-range compare is a follow-up — no such repo call exists on Android yet (design
 * §Real-stage nights item 6).
 */
@Composable
private fun StageInsight(selectedStage: String?, s: Stages) {
    val text = when (selectedStage) {
        "Awake" -> stageInsightLine("Awake", s.awake, stageSharePercent("Awake", s))
        "Light" -> stageInsightLine("Light", s.light, stageSharePercent("Light", s))
        "Deep" -> stageInsightLine("Deep", s.deep, stageSharePercent("Deep", s))
        "REM" -> stageInsightLine("REM", s.rem, stageSharePercent("REM", s))
        else -> "Tap a stage to highlight it across the night."
    }
    Box(
        modifier = Modifier.fillMaxWidth().height(Metrics.stageInsightHeight),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 2)
    }
}

private fun stageInsightLine(label: String, minutes: Double, percent: Int): String =
    "$label tonight: ${durationText(minutes)} — $percent% of the night."

/**
 * The night's four stages as whole percentages that sum to exactly 100 (largest-remainder), keyed by
 * label — so the breakdown rows, the timeline rows and the insight line all read ONE apportionment: they
 * agree with each other and add up, instead of four independent roundings landing on 99/101. The bar
 * fills still track the raw minutes/total fraction. 0 for a night with no minutes. Twin of the Swift
 * SleepView.stageSharePercent. (tanarchytan)
 */
internal fun stageSharePercent(label: String, s: Stages): Int {
    val p = StagePercentages.wholePercentages(listOf(s.awake, s.light, s.deep, s.rem)) ?: return 0
    return when (label) {
        "Awake" -> p[0]
        "Light" -> p[1]
        "Deep" -> p[2]
        "REM" -> p[3]
        else -> 0
    }
}

/**
 * #407 — the subordinate per-epoch MOVEMENT / restlessness strip drawn UNDER the hypnogram, on the SAME
 * timeline. [epochs] is the main-night GROUP's per-epoch motion magnitudes (laid fragment-by-fragment in
 * `selectNight`, oldest→newest), self-normalised to the night's own peak so a quiet and a restless night
 * both fill the strip — it shows the SHAPE of movement, not an absolute scale the strap doesn't calibrate.
 * HONESTY: an empty series (no persisted motionJSON on any group fragment — older rows) renders an honest
 * "no movement detail" note instead of a fabricated flat zero trace. Mirrors the Swift MotionTrace + the
 * SleepView motionStrip. Presentation-only.
 */
@Composable
private fun MotionStrip(epochs: List<Double>) {
    if (epochs.size < 2) {
        Text(
            uiString(R.string.l10n_sleep_screen_no_movement_detail_for_this_night_a6f9736a),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        return
    }
    val tint = Palette.restColor
    Canvas(modifier = Modifier.fillMaxWidth().height(Metrics.motionStripHeight)) {
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas
        // Faint baseline so the strip reads as a grounded trace even on a calm night.
        drawLine(
            color = Palette.hairline,
            start = Offset(0f, h - 1f),
            end = Offset(w, h - 1f),
            strokeWidth = 1f,
        )
        val peak = epochs.maxOrNull()?.takeIf { it > 0.0 } ?: return@Canvas
        val n = epochs.size
        val usable = h - 2f
        // One screen point per epoch: x spread evenly across the width (matching the hypnogram's left→right
        // time mapping), y the magnitude normalised to the night's own peak (baseline at the bottom).
        fun pointAt(i: Int): Offset {
            val x = i.toFloat() / (n - 1).toFloat() * w
            val frac = (epochs[i] / peak).coerceIn(0.0, 1.0).toFloat()
            return Offset(x, h - frac * usable)
        }
        // Filled area under the per-epoch magnitude.
        val area = Path().apply {
            moveTo(0f, h)
            for (i in 0 until n) { val p = pointAt(i); lineTo(p.x, p.y) }
            lineTo(w, h)
            close()
        }
        drawPath(area, color = tint.copy(alpha = 0.22f))
        // The crest line on top of the fill for definition.
        val crest = Path().apply {
            val first = pointAt(0)
            moveTo(first.x, first.y)
            for (i in 1 until n) { val p = pointAt(i); lineTo(p.x, p.y) }
        }
        drawPath(crest, color = tint.copy(alpha = 0.8f), style = Stroke(width = 1.5f))
    }
}


// MARK: - Sleep window and night navigation UI lives in SleepNightNavUi.kt
// MARK: - Sleep metric cards, debt ledger, stages, trends + chart helpers live in SleepMetricCardsUi.kt
// MARK: - Sleep metric detail sheet UI lives in SleepMetricDetailSheet.kt
