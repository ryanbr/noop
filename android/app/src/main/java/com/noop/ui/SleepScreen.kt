package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.widget.Toast
import com.noop.analytics.SleepMark
import com.noop.analytics.SleepMarkType
import com.noop.analytics.SleepWindowReclip
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.SleepDebtLedger
import com.noop.analytics.SleepEditGuard
import com.noop.analytics.SleepStageTotals
import com.noop.data.DismissedSleep
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

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
    var sleepUndo by remember { mutableStateOf<SleepSession?>(null) }
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
    LaunchedEffect(sleeps) {
        motionByStart = runCatching {
            vm.repo.sessionMotions("my-whoop", sleeps.map { it.startTs })
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
            SleepMetricDetailSheetContent(vm = vm, key = currentDetailKey)
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

    // Debt credit is the canonical main-night DailyMetric total PLUS actual asleep minutes from blocks
    // outside that main-night group. Keep the nap sum separate: Rest, the hero and daily total deliberately
    // remain main-night-only. Stage-less naps add no guessed in-bed time. Mirrors Swift SleepView. (#525)
    val napSleepMinByDay = remember(sleeps, habitualMidsleep) {
        napSleepMinutesByDay(sleeps, habitualMidsleep)
    }

    // The navigated night, decoded once per (offset, data) change — chevron taps re-pick
    // instantly without re-parsing stagesJSON on every recomposition. The offset now indexes
    // DAYS (navDays), so a day with a detected night always resolves to that night. (#160, #59)
    val night = remember(nightOffset, navDays, days, habitualMidsleep, motionByStart) {
        selectNight(navDays, days, nightOffset, habitualMidsleep, motionByStart)
    }

    // The HERO follows the selected night (its stage breakdown comes from that day's row); the
    // at-a-glance TILES, the debt ledger, the personal need and the trend stay full-history /
    // latest-anchored, matching iOS SleepView. `selectedDay` re-points only the hero. Model is null
    // when the selected day has no stage minutes. (#5)
    val model = remember(days, night, imported, napSleepMinByDay, sleeps) {
        buildSleepModel(days, night?.session, imported, selectedDay = night?.dayKey,
            heroStages = night?.groupStages, heroSegments = night?.groupSegments,
            napSleepMinByDay = napSleepMinByDay, sessions = sleeps)
    }
    val display = remember(model, night) { heroDisplay(model, night) }

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
        sleepUndo?.let { deleted ->
            item {
                SleepUndoBanner(
                    session = deleted,
                    onUndo = {
                        sleepUndo = null
                        scope.launch {
                            vm.undoDeleteSleepSession(deleted)
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
        // #940: the empty state is ONLY for a truly empty history. A newest day that merely fails
        // to merge (the phantom-edit shape) keeps the hero (night != null) and the full-history
        // tiles (tilesModel != null), so intact older nights are never hidden behind "no nights".
        if (tilesModel == null && night == null) {
            // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
            item {
                if (backfillNote != null) SyncingHistoryNote(chunks = backfillNote!!)
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
                    overline = nightRelativeLabel(nightOffset),
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
                    Hero(
                display = display,
                activeIsOura = activeIsOura,
                clock = night?.clockLabel ?: model?.clockLabel,
                nightOffset = nightOffset,
                lastIndex = max(navDays.lastIndex, 0),
                onNavigate = { nightOffset = it },
                session = night?.session,
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
                        sleeps = sleeps.map {
                            if (it.deviceId == s.deviceId && it.startTs == s.startTs) {
                                val reclipped = SleepWindowReclip.reclip(it.stagesJSON, it.effectiveStartTs, it.endTs, safeStart, safeEnd)
                                it.copy(startTsAdjusted = safeStart, endTs = safeEnd, userEdited = true,
                                        stagesJSON = reclipped ?: it.stagesJSON)
                            } else {
                                it
                            }
                        }
                        scope.launch { vm.updateSleepSessionTimes(s, safeStart, safeEnd) }
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
                    sleepUndo = s
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

/**
 * #65: the transient UNDO strip after a suppressing sleep delete. A Rest-tinted card stating the window
 * NOOP won't re-detect + a real Undo button. The banner auto-clears after ~7s (the caller's keyed
 * LaunchedEffect); Undo restores the deleted row into its ORIGINAL namespace and lifts the tombstone.
 * Mirrors the macOS SleepView.sleepUndoBanner (role-alert-ish, explicit Undo label).
 */
@Composable
private fun SleepUndoBanner(session: SleepSession, onUndo: () -> Unit) {
    val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
    // effectiveStartTs is the displayed onset (a userEdited night's corrected bed time), matching iOS.
    val startText = timeFmt.format(java.util.Date(session.effectiveStartTs * 1000L))
    val endText = timeFmt.format(java.util.Date(session.endTs * 1000L))
    // Branch the copy on userEdited: a hand-edited/added (nap) night writes NO tombstone (it is never
    // re-detected), so the suppression promise would be false for it. Only a DETECTED delete tombstones,
    // so only it gets the "won't detect ... again" wording. Mirrors the macOS branch. (#65 banner honesty.)
    val message = if (session.userEdited) {
        "Sleep deleted."
    } else {
        "Sleep deleted. NOOP won't detect sleep between $startText and $endText again."
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
    onNavigate: (Int) -> Unit,
    session: SleepSession? = null,
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
        NightNavHeader(nightOffset, lastIndex, clock, onNavigate, session, onUpdateTimes, onDeleteSession, onAddNap, onPickNightDate)
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
                if ((chartStyle == SleepChartStyle.FILLED || chartStyle == SleepChartStyle.RIBBON) &&
                    filledSegments != null) {
                    ChartCard(
                        title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                        subtitle = subtitle,
                        trailing = durationText(s.asleep),
                        tint = Palette.restColor,
                        // The stepped chart carries no built-in legend (the rows ARE the legend in the
                        // classic view), so surface the per-stage breakdown below it, like the reference.
                        footer = { StageBreakdownRows(s) },
                    ) {
                        FilledHypnogram(
                            segments = filledSegments,
                            onsetTs = windowOnsetTs ?: session?.effectiveStartTs,
                            wakeTs = windowWakeTs ?: session?.endTs,
                            filled = chartStyle == SleepChartStyle.FILLED,
                        )
                    }
                } else {
                    ChartCard(
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
                ChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = { StageBreakdownRows(s) },
                ) {
                    // Reconstructed architecture (light → deep → light → rem → light → awake) as the
                    // flat proportional strip. No MotionStrip and no fake steps here: invented
                    // architecture has no genuine timeline to anchor to (mirrors the iOS else-branch).
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
        }
        // Naps card (#508/#518): the day's blocks OTHER than the main night, each editable / deletable
        // with the SAME mechanism main sleep uses, plus a Main / Nap(s) / Total split so what drives the
        // day's Rest total is explainable. Mirrors iOS SleepView.napSection.
        if (session != null) {
            // Main = the WHOLE bridged main-night group's summed stage minutes (`display.stages.total`,
            // the shared SleepModel's group total), NOT the winning fragment's window — a biphasic/
            // bridged night has sibling fragments that are part of the main sleep, not naps. Mirrors iOS
            // SleepView.napSection (`night.stages.total`); the old single-block window undercounted the
            // Main / Total split on a fragmented night and disagreed with the hero above it. Window
            // fallback only for a stage-less stub day (display == null), byte-identical to before there.
            val mainMin = display?.stages?.total
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
    // The day's MAIN-sleep minutes = the whole bridged main-night group's summed stage minutes
    // (iOS `night.stages.total`), passed in from the hero's already-resolved `display.stages.total`
    // so the split matches the hero. NOT `main`'s own window — that undercounts a bridged night.
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
    val window = "${clockTimeLabel(nap.effectiveStartTs)} - ${clockTimeLabel(nap.endTs)}"
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
private fun StageTimeline(
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
                total = s.total,
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
    total: Double,
    color: Color,
    spans: List<Pair<Float, Float>>,
    selected: Boolean,
    dimmed: Boolean,
    onTap: () -> Unit,
) {
    val percent = if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0
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
        "Awake" -> stageInsightLine("Awake", s.awake, s.total)
        "Light" -> stageInsightLine("Light", s.light, s.total)
        "Deep" -> stageInsightLine("Deep", s.deep, s.total)
        "REM" -> stageInsightLine("REM", s.rem, s.total)
        else -> "Tap a stage to highlight it across the night."
    }
    Box(
        modifier = Modifier.fillMaxWidth().height(Metrics.stageInsightHeight),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 2)
    }
}

private fun stageInsightLine(label: String, minutes: Double, total: Double): String {
    val percent = if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0
    return "$label tonight: ${durationText(minutes)} — $percent% of the night."
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

/**
 * "Asleep / Woke" — the fell-asleep and woke clock times for the navigated night, read off the
 * session's onset (startTs) and wake (endTs) timestamps, each with a moon / sun glyph. Sits in the
 * hero between the night-nav header and the stage card so the two times people glance for first are
 * always visible, not truncated in the header caption. On-brand (surfaceRaised block, tokens) and
 * combined into one TalkBack element. Mirrors iOS SleepView.sleepWindowRow (PR #289).
 */
@Composable
private fun SleepWindowRow(onsetTs: Long, wakeTs: Long) {
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
private fun NightNavHeader(
    offset: Int,
    lastIndex: Int,
    clock: String?,
    onNavigate: (Int) -> Unit,
    session: SleepSession? = null,
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
        val coverageStart = minOf(s.startTs, s.effectiveStartTs)
        if (SleepEditGuard.isDisjoint(newStart, newEnd, coverageStart, s.endTs)) {
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

    val nightLabel = nightRelativeLabel(offset)
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
                        sleepEditDraft = SleepTimeEditDraft(session.effectiveStartTs, session.endTs)
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
                        "Removes this sleep and recomputes the day without it. You can undo for a few seconds after."
                    } else {
                        "Removes this recorded sleep and recomputes the day without it. NOOP won't re-detect sleep in this window. You can undo for a few seconds after."
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

/**
 * #today-hosted-cards: the "Night detail" metric grid rendered from the shared [SleepModel]. `internal` so
 * the Today host (TodayScreen) can render the SAME grid the Sleep tab does (a mirror, not a copy); lives
 * here so its [MetricGrid]/[SparkTile] siblings stay in-file. Twin of the iOS `NightDetailCard`. The Sleep
 * tab passes an [onMetricClick] to open per-metric detail; the Today host omits it (no detail sheet there),
 * so the tiles render read-only when hosted.
 */
@Composable
internal fun NightDetailHostCard(m: SleepModel, onMetricClick: (String) -> Unit = {}) {
    MetricGrid(m, onMetricClick = onMetricClick)
}

@Composable
private fun MetricGrid(m: SleepModel, onMetricClick: (String) -> Unit = {}) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { mod ->
            SparkTile(
                mod, "Rest",
                value = pctValue(m.performance.latest),
                caption = vsTypical(m.performance.latest, m.performance.typical, "%"),
                accent = m.performance.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.performance.series, sparkColor = Palette.restColor,
                onClick = { onMetricClick("performance") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Efficiency",
                value = pctValue(m.efficiency.latest),
                caption = vsTypical(m.efficiency.latest, m.efficiency.typical, "%"),
                accent = Palette.statusPositive,
                spark = m.efficiency.series, sparkColor = Palette.statusPositive,
                onClick = { onMetricClick("efficiency") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Consistency",
                value = pctValue(m.consistency.latest),
                caption = vsTypical(m.consistency.latest, m.consistency.typical, "%"),
                accent = m.consistency.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.consistency.series, sparkColor = Palette.metricCyan,
                onClick = { onMetricClick("consistency") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Hours vs Needed",
                value = pctValue(m.hoursVsNeeded.latest),
                caption = vsTypical(m.hoursVsNeeded.latest, m.hoursVsNeeded.typical, "%"),
                accent = m.hoursVsNeeded.latest?.let { Palette.recoveryColor(minOf(100.0, it)) } ?: Palette.textPrimary,
                spark = m.hoursVsNeeded.series, sparkColor = Palette.restColor,
                onClick = { onMetricClick("hours_vs_needed") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Restorative",
                value = pctValue(m.restorative.latest),
                caption = vsTypical(m.restorative.latest, m.restorative.typical, "%"),
                accent = Palette.sleepREM,
                spark = m.restorative.series, sparkColor = Palette.sleepREM,
                onClick = { onMetricClick("restorative") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Respiratory",
                value = m.respiratory.latest?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                caption = vsTypical(m.respiratory.latest, m.respiratory.typical, " rpm", decimals = 1),
                accent = Palette.metricPurple,
                spark = m.respiratory.series, sparkColor = Palette.metricPurple,
                onClick = { onMetricClick("respiratory") },
            )
        },
    )

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Night detail", overline = "Metrics", trailing = "vs typical")

        // Sleep Debt is the actionable summary for the section, so it leads at the full
        // two-column width. The remaining six peer metrics keep the established 2 × 3 grid.
        SparkTile(
            Modifier.fillMaxWidth(), "Sleep Debt",
            value = m.sleepDebt.latest?.let { durationText(it) } ?: "—",
            caption = debtCaption(m.sleepDebt.latest),
            accent = debtColor(m.sleepDebt.latest),
            spark = m.sleepDebt.series, sparkColor = Palette.metricRose,
            onClick = { onMetricClick("sleep_debt") },
        )

        // Two-up rows; IntrinsicSize.Max + fillMaxHeight keep row neighbors equal height even when
        // large font scales grow one tile past the tileHeight floor. No empty cells.
        tiles.chunked(2).forEach { rowTiles ->
            Row(
                modifier = Modifier.height(IntrinsicSize.Max),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                rowTiles.forEach { it(Modifier.weight(1f).fillMaxHeight()) }
            }
        }
    }
}

// MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

/**
 * A running balance of (slept − personal need) across the recent fortnight, surfaced as one
 * card: the net debt/surplus headline, a plain-English read, and a diverging bar of each
 * night's delta (surplus above the centre line, deficit below). Honest: a simple accumulator
 * — a surplus night offsets a deficit one — capped at 14 nights, no-data nights skipped.
 * Mirrors the macOS SleepDebtLedgerCard section-for-section. `internal` and keyed on the shared
 * [SleepModel] so the Today host (TodayScreen) can render the SAME view the Sleep tab does (a mirror,
 * not a copy); the nap-credited ledger is read from `m.sleepDebtLedger`, never recomputed here. Twin of
 * the iOS `SleepDebtLedgerCard`. (#242) (#today-hosted-cards)
 */
@Composable
internal fun SleepDebtLedgerHostCard(m: SleepModel) {
    val ledger = m.sleepDebtLedger
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Sleep-debt ledger", overline = "Last 14 nights", trailing = "running balance")
        NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
            if (ledger.nightCount == 0) {
                Text(
                    uiString(R.string.l10n_sleep_screen_no_nights_with_sleep_data_yet_fa71b6b3),
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                    // Headline: net balance + the short tag (sleep debt / surplus / balanced).
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            debtHeadline(ledger),
                            style = NoopType.tileValueLarge,
                            color = debtBalanceColor(ledger),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            debtTag(ledger),
                            style = NoopType.captionNumber,
                            color = debtBalanceColor(ledger),
                        )
                    }
                    // Plain-English read.
                    Text(
                        debtRead(ledger),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                    // Per-night diverging delta bars (surplus up, deficit down).
                    DebtDeltaBars(ledger)
                    Hairline()
                    ChartFooter(
                        listOf(
                            "Balance" to debtSigned(ledger.balanceMin),
                            "Per-night need" to durationText(ledger.needMin),
                            "Nights" to "${ledger.nightCount}",
                        ),
                    )
                }
            }
        }
    }
}

/**
 * The diverging per-night delta strip: each night a bar from the centre line — up (accent)
 * for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
 */
@Composable
private fun DebtDeltaBars(ledger: SleepDebtLedger) {
    val deltas = ledger.nights.map { it.deltaMin }
    val scale = max(deltas.maxOfOrNull { abs(it) } ?: 1.0, 1.0)
    val accentColor = Palette.accent
    val deficitColor = Palette.metricRose
    val centreColor = Palette.hairline
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp)
            .semantics {
                contentDescription =
                    uiString(R.string.l10n_sleep_screen_per_night_sleep_balance_ledger_nightcount_f339d0ab, ledger.nightCount, debtSigned(ledger.balanceMin))
            }
            .drawBehind {
                val n = max(deltas.size, 1)
                val slot = size.width / n
                val barW = max(2f, slot * 0.6f)
                val midY = size.height / 2f
                // Centre (zero) line.
                drawLine(
                    color = centreColor,
                    start = Offset(0f, midY),
                    end = Offset(size.width, midY),
                    strokeWidth = 1f,
                )
                deltas.forEachIndexed { i, d ->
                    val frac = (abs(d) / scale).toFloat().coerceIn(0f, 1f)
                    val h = max(2f, frac * (midY - 2f))
                    val cx = slot * i + slot / 2f
                    // Surplus grows upward from the centre, deficit downward.
                    val top = if (d >= 0.0) midY - h else midY
                    drawRoundRect(
                        color = if (d >= 0.0) accentColor else deficitColor,
                        topLeft = Offset(cx - barW / 2f, top),
                        size = Size(barW, h),
                        cornerRadius = CornerRadius(2f, 2f),
                    )
                }
            },
    )
}

// MARK: - Stages (read-only latest-night host card)

/**
 * #today-hosted-cards: the READ-ONLY "Stages" card hosted in Today — the latest night's stage chart +
 * breakdown rendered from the shared [SleepModel] (the SAME stages the Sleep tab hero shows). Unlike the
 * Sleep tab hero it carries NONE of the interaction: no night ◀/▶ navigation, no wake-time edit, no nap
 * add/edit/delete — only the display is mirrored. It reuses the SAME StageTimeline / FilledHypnogram /
 * HypnogramWithAxis + StageBreakdownRows renderers the hero uses (each owns its own transient tap-
 * highlight), so the stage split can never diverge between the two surfaces. `internal` so the Today host
 * (TodayScreen) can render it; lives here so its private [StageTimeline] sibling is in-file. Twin of the
 * iOS `StagesCard`.
 *
 * NOTE (feature-level parity): the Kotlin [SleepModel] carries no session timestamps or nap blocks (those
 * ride [HeroNight]/[HeroDisplay] on the Sleep tab), so — unlike iOS, whose `SleepModel.night` carries the
 * session + source blocks — this card shows no clock-window row and no Main/Nap(s)/Total split. The stage
 * chart + breakdown is the shared data both platforms mirror.
 */
@Composable
internal fun StagesHostCard(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Read-only header: the night's span label in the trailing slot — NO ◀/▶ nav controls.
        SectionHeader("Stages", overline = "Last night", trailing = m.clockLabel)
        // Verbatim of the Sleep tab Hero's stage-chart block, read from the shared model with a null
        // session window (no clock axis) and no motion strip — the fractions/segments are identical.
        val subtitle = "${durationText(s.total)} in bed · ${m.efficiencyText} efficiency" +
            (if (m.realSegments != null) " · approx. stages (on-device)" else "")
        val real = m.realSegments?.takeIf { it.size >= 2 }
        if (real != null) {
            val chartStyle = UnitPrefs.sleepChartStyle(LocalContext.current)
            val filledSegments = m.hypnogramSegments?.takeIf { it.size >= 2 }
            if ((chartStyle == SleepChartStyle.FILLED || chartStyle == SleepChartStyle.RIBBON) &&
                filledSegments != null) {
                ChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = { StageBreakdownRows(s) },
                ) {
                    FilledHypnogram(
                        segments = filledSegments,
                        onsetTs = null,
                        wakeTs = null,
                        filled = chartStyle == SleepChartStyle.FILLED,
                    )
                }
            } else {
                ChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = {},
                ) {
                    StageTimeline(
                        realSegments = real,
                        s = s,
                        onsetTs = null,
                        wakeTs = null,
                        motionEpochs = emptyList(),
                    )
                }
            }
        } else {
            ChartCard(
                title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                subtitle = subtitle,
                trailing = durationText(s.asleep),
                tint = Palette.restColor,
                footer = { StageBreakdownRows(s) },
            ) {
                val segments = stageSegments(s)
                if (segments.isNotEmpty()) {
                    HypnogramWithAxis(stages = segments, onsetTs = null, wakeTs = null)
                } else {
                    Text(
                        uiString(R.string.l10n_sleep_screen_no_stage_breakdown_for_this_night_b74bf9c3),
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - 3. Stages vs typical

/**
 * #today-hosted-cards: the "Stages vs typical" card — last night's Deep/REM/Light against the wearer's
 * personal per-stage means from the shared [SleepModel]. `internal` so the Today host (TodayScreen) can
 * render the SAME view the Sleep tab does (a mirror, not a copy); lives here so its StageRow/Hairline
 * siblings are in-file. Twin of the iOS `StagesVsTypicalCard`.
 */
@Composable
internal fun StagesVsTypicalHostCard(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Stages vs typical", overline = "Selected night", trailing = "marker = your mean")
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                StageRow("Deep", last = s.deep, typical = m.typicalDeepMin, color = Palette.sleepDeep)
                Hairline()
                StageRow("REM", last = s.rem, typical = m.typicalRemMin, color = Palette.sleepREM)
                Hairline()
                StageRow("Light", last = s.light, typical = m.typicalLightMin, color = Palette.sleepLight)
            }
        }
    }
}

@Composable
private fun Hairline() {
    Box(modifier = Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
}

/** One stage bar: last-night minutes filled, with a vertical marker at the typical mean. */
@Composable
private fun StageRow(label: String, last: Double, typical: Double?, color: Color) {
    val scaleMax = max(last, typical ?: 0.0) * 1.18
    val scale = if (scaleMax > 0.0) scaleMax else 1.0
    val deltaText: String = run {
        if (typical == null || typical <= 0.0) {
            ""
        } else {
            val diff = last - typical
            val sign = if (diff >= 0) "+" else "−"
            "$sign${durationText(abs(diff))} vs typ"
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(durationText(last), style = NoopType.captionNumber, color = Palette.textPrimary)
            if (deltaText.isNotEmpty()) {
                Text(
                    deltaText,
                    style = NoopType.footnote,
                    color = if (last >= (typical ?: last)) Palette.statusPositive else Palette.statusWarning,
                    modifier = Modifier.padding(start = Metrics.space8),
                )
            }
        }
        // Track + last-night fill + typical marker.
        val fillFrac = (last / scale).coerceIn(0.0, 1.0).toFloat()
        val markerFrac = typical?.takeIf { it > 0.0 }?.let { (it / scale).coerceIn(0.0, 1.0).toFloat() }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(Metrics.progressHeight)
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(Palette.surfaceInset)
                .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_label_minutes_vs_your_typical_bar_b8f6a482, label) }
                .drawBehind {
                    // last-night fill
                    if (fillFrac > 0f) {
                        drawRoundRectFill(color, fillFrac)
                    }
                    // typical marker
                    if (markerFrac != null) {
                        val x = (size.width * markerFrac).coerceIn(1f, size.width - 1f)
                        drawLine(
                            color = Palette.textPrimary,
                            start = Offset(x, 0f),
                            end = Offset(x, size.height),
                            strokeWidth = 2f,
                            cap = StrokeCap.Round,
                        )
                    }
                },
        )
    }
}

private fun DrawScope.drawRoundRectFill(color: Color, frac: Float) {
    val w = (size.width * frac).coerceAtLeast(size.height)
    val r = size.height / 2f
    drawRoundRect(
        color = color,
        size = Size(w, size.height),
        cornerRadius = CornerRadius(r, r),
    )
}

// MARK: - 4. 14-day asleep-hours trend

/**
 * #today-hosted-cards P1: the hosted "Asleep duration" card — the hours-asleep BarChart from [DurationTrend],
 * hours-only (no debt sub-chart, so no nap/session data needed), built from the pure [sleepDurationTrend].
 * `internal` so the Today host (TodayScreen) can render it; lives here so its ChartCard/BarChart siblings
 * are in-file. Twin of the iOS `AsleepDurationCard`.
 */
@Composable
internal fun AsleepDurationHostCard(hours: List<Double>, dates: List<String>) {
    val avg = hours.sleepAverageOrNull()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Asleep duration", overline = "Sleep", trailing = "Last 14 days")
        ChartCard(
            title = uiString(R.string.l10n_sleep_screen_hours_asleep_06f68993),
            subtitle = "Per night, trailing 14 days",
            trailing = avg?.let { String.format(Locale.US, "%.1f h avg", it) },
            tint = Palette.restColor,
            footer = {
                ChartFooter(
                    listOf(
                        "Avg" to (avg?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Min" to (hours.minOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Max" to (hours.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Nights" to "${hours.size}",
                    ),
                )
            },
        ) {
            if (hours.size >= 2) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    BarChart(
                        values = hours,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_hours_trend_chart_a6fbc46d) },
                        color = Palette.restColor,
                        selectionEnabled = true,
                        selectionLabels = dates.map(::shortDayLabel),
                    )
                    DateAxisRow(dates)
                }
            } else {
                TrendPlaceholder()
            }
        }
    }
}

@Composable
private fun DurationTrend(m: SleepModel) {
    val pts = m.trendHours
    val avg = pts.sleepAverageOrNull()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Trend", overline = "Sleep", trailing = "Last 14 days")
        ChartCard(
            title = uiString(R.string.l10n_sleep_screen_hours_asleep_06f68993),
            subtitle = "Per night, trailing 14 days",
            trailing = avg?.let { String.format(Locale.US, "%.1f h avg", it) },
            tint = Palette.restColor,
            footer = {
                ChartFooter(
                    listOf(
                        "Avg" to (avg?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Min" to (pts.minOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Max" to (pts.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Nights" to "${pts.size}",
                    ),
                )
            },
        ) {
            if (pts.size >= 2) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // #85: sleep duration reads as a per-night histogram (zero-based bars), matching the
                    // iOS Sleep tab's TrendChart(showsBars:) — a BarMark is proportional to hours slept,
                    // clearer than a line for a nightly total. BarChart floors at 0 like the iOS bar domain.
                    BarChart(
                        values = pts,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_hours_trend_chart_a6fbc46d) },
                        color = Palette.restColor,
                        selectionEnabled = true,
                        // #691: on tap, show the DATE alongside the value (the shared chart's tooltip),
                        // matching the other trend graphs. trendDates is index-aligned with the values.
                        selectionLabels = m.trendDates.map(::shortDayLabel),
                    )
                    DateAxisRow(m.trendDates)
                }
            } else {
                TrendPlaceholder()
            }
        }

        ChartCard(
            title = uiString(R.string.l10n_sleep_screen_sleep_debt_3aec7d9c),
            subtitle = "Sleep debt per day",
            // #691: sleep debt is usually well under an hour, so decimal hours ("0.6h") reads badly —
            // show hours+minutes. trendDebtHours is in hours; durationText takes minutes.
            trailing = m.trendDebtHours.lastOrNull()?.let { durationText(it * 60.0) },
            tint = Palette.restColor,
            footer = {
                ChartFooter(
                    listOf(
                        "Avg" to (m.trendDebtHours.sleepAverageOrNull()?.let { durationText(it * 60.0) } ?: "â€”"),
                        "Max" to (m.trendDebtHours.maxOrNull()?.let { durationText(it * 60.0) } ?: "â€”"),
                        "Days" to "${m.trendDebtHours.size}",
                    ),
                )
            },
        ) {
            if (m.trendDebtHours.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    BarChart(
                        values = m.trendDebtHours,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_debt_trend_chart_9e178776) },
                        color = Palette.metricRose,
                        selectionEnabled = true,
                        selectionLabels = m.trendDates.map(::shortDayLabel),   // #691: hover shows date + value
                    )
                    DateAxisRow(m.trendDates)
                }
            } else {
                TrendPlaceholder()
            }
        }
    }
}

@Composable
// internal (not private) so the Today hosted-cards duration card (#today-hosted-cards) can reuse it.
internal fun TrendPlaceholder() {
    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center,
    ) {
        InsetChartPlaceholder(message = "Not enough nights yet.")
    }
}

@Composable
private fun TrendLegend(items: List<Pair<String, Color>>) {
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
        items.forEach { (label, color) ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .width(Metrics.legendLineWidth)
                        .height(Metrics.legendLineHeight)
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(color),
                )
                Text(label, style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

// internal (not private) so the Today hosted-cards duration card (#today-hosted-cards) can reuse it.
@Composable
internal fun DateAxisRow(days: List<String>) {
    if (days.isEmpty()) return
    val labels = listOf(
        days.firstOrNull(),
        days.getOrNull(days.lastIndex / 2),
        days.lastOrNull(),
    ).map { it?.let(::shortDayLabel).orEmpty() }
    Row(modifier = Modifier.fillMaxWidth()) {
        labels.forEach { label ->
            Text(
                text = label,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// MARK: - ChartCard / ChartFooter (local — mirror the macOS ChartCard the screen used)

/**
 * The chart container the macOS screen leaned on: a NoopCard with a header (overline-
 * style title + subtitle + trailing read-out), the chart body, then a footer row of
 * label/value pairs. Kept local so the shared component set stays minimal.
 */
@Composable
private fun ChartCard(
    title: String,
    subtitle: String,
    trailing: String?,
    footer: @Composable () -> Unit,
    tint: Color? = null,
    chart: @Composable () -> Unit,
) {
    NoopCard(padding = Metrics.cardPadding, tint = tint) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, style = NoopType.headline, color = Palette.textPrimary)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary)
                }
                if (trailing != null) {
                    Text(trailing, style = NoopType.chartValue, color = Palette.textPrimary)
                }
            }
            chart()
            footer()
        }
    }
}

/** A footer strip of label/value pairs, evenly distributed. */
@Composable
private fun ChartFooter(items: List<Pair<String, String>>) {
    Row(modifier = Modifier.fillMaxWidth()) {
        items.forEach { (label, value) ->
            Column(modifier = Modifier.weight(1f)) {
                Overline(label, color = Palette.textTertiary)
                // Stage-breakdown values like "1h 23m (24%)" wrapped to a second line in a narrow column,
                // pushing the row taller and clipping against the card edge (#406). Hold them to one line.
                Text(
                    value,
                    style = NoopType.captionNumber,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    softWrap = false,
                )
            }
        }
    }
}

// MARK: - SparkTile (min-height metric tile, stacked: value + caption over a full-width 30-day sparkline)

@Composable
private fun SparkTile(
    modifier: Modifier,
    label: String,
    value: String,
    caption: String?,
    accent: Color,
    spark: List<Double>,
    sparkColor: Color,
    onClick: (() -> Unit)? = null,
) {
    // liquidPress on the tappable tile: it settles inward on press (the pilot's card feel). The SAME
    // interactionSource drives the clickable + the press; indication = null so only the liquid settle shows.
    val interaction = remember { MutableInteractionSource() }
    // heightIn (not height): tileHeight is a floor, matching the Swift StatTile. At normal font scale the
    // tile keeps its 108dp footprint; at large font scales it grows instead of clipping the caption. (#squish)
    val clickMod = if (onClick != null) {
        modifier
            .heightIn(min = Metrics.tileHeight)
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    } else {
        modifier.heightIn(min = Metrics.tileHeight)
    }
    NoopCard(modifier = clickMod, padding = Metrics.space14) {
        // fillMaxHeight so the weight-spacer can pin the sparkline to the card bottom once the
        // MetricGrid row bounds the height (Row height(IntrinsicSize.Max) + tile fillMaxHeight()).
        Column(modifier = Modifier.fillMaxWidth().fillMaxHeight()) {
            Overline(label)
            Text(
                value,
                style = NoopType.tileValue,
                color = accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (caption != null) {
                Text(
                    caption,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    // Full card width now, so the "-3% vs typical" caption fits; ellipsis stays as a
                    // safety net for extreme localized strings.
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = Metrics.space2),
                )
            }
            Spacer(Modifier.weight(1f))
            val tail = spark.takeLast(30)
            if (tail.size >= 2) {
                // Full-width bottom spark. Outer height(sparkHeight) deliberately overrides Sparkline's
                // internal 28dp default down to the 22dp tile spark (same override SparkTailBox does).
                Sparkline(
                    values = tail,
                    color = sparkColor,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = Metrics.space8)
                        .height(Metrics.sparkHeight),
                )
            }
        }
    }
}

// MARK: - Empty state

@Composable
private fun SleepEmptyState() {
    DataPendingNote(
        title = uiString(R.string.l10n_sleep_screen_no_nights_here_yet_607248f5),
        body = "No nights here yet. Import your WHOOP export in Data Sources to see " +
            "every night, your sleep stages and trends straight away.",
    )
}

// MARK: - Model + derivation (faithful to SleepView.swift)

// MARK: - Model + derivation lives in SleepModels.kt, SleepNightSelection.kt, SleepModelLogic.kt, and SleepStageTimelineLogic.kt

// MARK: - Hours vs Needed card

/**
 * A standalone "Hours vs Needed" card: a gradient slept/needed bar, a stacked component bar
 * (Healthy Minimum / Strain buffer / Debt repayment) and a slept/needed/debt footer. The
 * trend arrow compares the last two nights' hours. (PR #260)
 */
@Composable
internal fun HoursVsNeededCard(m: SleepModel) {
    // trendHours.last() is the most-recent night's ASLEEP total (totalSleepMin / 60) over the
    // full history — the same asleep figure the tiles and the debt ledger read, never an in-bed
    // window. Falls back to the hero stages' asleep sum when no trend rows exist.
    val sleptH = m.trendHours.lastOrNull() ?: (m.stages.asleep / 60.0)
    val neededH = (m.trendNeedHours.lastOrNull() ?: 8.0)
    val debtH = m.trendDebtHours.lastOrNull() ?: 0.0
    // #691: show the TRUE percentage (e.g. 104% when you slept past your need) instead of a capped
    // "100%" that's indistinguishable from exactly meeting it. The progress-bar fill below stays
    // clamped to 1.0 (it can't overfill); only the displayed number is uncapped.
    val score = (sleptH / neededH * 100.0).coerceAtLeast(0.0)
    val trendArrow = if (m.trendHours.size >= 2) {
        val delta = m.trendHours.last() - m.trendHours[m.trendHours.lastIndex - 1]
        when {
            delta > 0.25 -> "↑"
            delta < -0.25 -> "↓"
            else -> "→"
        }
    } else "→"
    val arrowColor = when (trendArrow) {
        "↑" -> Palette.statusPositive
        "↓" -> Palette.statusCritical
        else -> Palette.textTertiary
    }

    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep")
                    Text(uiString(R.string.l10n_sleep_screen_hours_vs_needed_500a0aca), style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(trendArrow, style = NoopType.title2, color = arrowColor)
                Spacer(Modifier.width(Metrics.space6))
                Text(uiString(R.string.l10n_sleep_screen_score_roundtoint_a2d1cc99, score.roundToInt()), style = NoopType.chartValue, color = Palette.restColor)
            }

            // Gradient progress bar: slept / needed.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.progressHeight)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.surfaceInset)
                    .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_hours_vs_needed_progress_bar_score_4baad051, score.roundToInt()) },
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth((sleptH / neededH).coerceIn(0.0, 1.0).toFloat())
                        .height(Metrics.progressHeight)
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(Brush.horizontalGradient(listOf(Palette.restDeep, Palette.restBright))),
                )
            }

            // Stacked component bar: Healthy Min / Strain buffer / Debt repayment.
            val healthyMin = 7.0
            val strainBuffer = (neededH - healthyMin).coerceAtLeast(0.0)
            val debtRepay = debtH.coerceAtLeast(0.0)
            val totalBar = (healthyMin + strainBuffer + debtRepay).coerceAtLeast(1.0)
            Row(modifier = Modifier.fillMaxWidth().height(Metrics.space8).clip(RoundedCornerShape(Metrics.cornerPill))) {
                Box(modifier = Modifier.weight((healthyMin / totalBar).toFloat()).fillMaxHeight().background(Palette.metricPurple))
                if (strainBuffer > 0) Box(modifier = Modifier.weight((strainBuffer / totalBar).toFloat()).fillMaxHeight().background(Palette.strain066))
                if (debtRepay > 0) Box(modifier = Modifier.weight((debtRepay / totalBar).toFloat()).fillMaxHeight().background(Palette.statusCritical))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                LegendDot("Healthy Min", Palette.metricPurple)
                LegendDot("Strain", Palette.strain066)
                LegendDot("Debt", Palette.statusCritical)
            }

            Hairline()
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    "Slept" to String.format(Locale.US, "%.1f h", sleptH),
                    "Needed" to String.format(Locale.US, "%.1f h", neededH),
                    "Debt" to if (debtH > 0.05) durationText(debtH * 60.0) else "None",   // #691: h+m, not "0.6 h"
                ).forEach { (lbl, v) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(lbl, color = Palette.textTertiary)
                        Text(v, style = NoopType.captionNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

@Composable
private fun LegendDot(label: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.space4)) {
        Box(modifier = Modifier.size(Metrics.space6).clip(RoundedCornerShape(50)).background(color))
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - Consistency host card (#today-hosted-cards)

/**
 * A SIMPLE standalone "Consistency" score card for the Today host — mirrors the [HoursVsNeededCard]
 * presentation (a NoopCard header with a trend arrow + big % + a sparkline), NOT the rich scatter
 * [SleepConsistencyCard] (which needs raw sessions). Renders `m.consistency` (latest / typical / series) —
 * the SAME shared SleepModel metric the Sleep tab's Night-detail tile reads (bedtime-onset spread, honouring
 * the imported-consistency preference, byte-identical to iOS `SleepModel.consistency`), so the number and the
 * sparkline can never diverge between the two surfaces.
 */
@Composable
internal fun ConsistencyHostCard(m: SleepModel) {
    val cons = m.consistency
    // Uncapped % (consistency is already 0–100); "—" when there is no latest night yet.
    val latest = cons.latest
    // Trend arrow off the last two nights of the consistency series (same idiom as HoursVsNeededCard).
    val trendArrow = if (cons.series.size >= 2) {
        val delta = cons.series.last() - cons.series[cons.series.lastIndex - 1]
        when {
            delta > 0.5 -> "↑"
            delta < -0.5 -> "↓"
            else -> "→"
        }
    } else "→"
    val arrowColor = when (trendArrow) {
        "↑" -> Palette.statusPositive
        "↓" -> Palette.statusCritical
        else -> Palette.textTertiary
    }
    // The simple host card summarizes the trend via the arrow + sparkline rather than a "vs typical"
    // caption (mirrors the Android HoursVsNeeded host presentation, which carries no caption literal).
    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep")
                    Text(uiString(R.string.l10n_sleep_screen_consistency_0ea7b95e), style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(trendArrow, style = NoopType.title2, color = arrowColor)
                Spacer(Modifier.width(Metrics.space6))
                Text(
                    if (latest != null) uiString(R.string.l10n_sleep_screen_score_roundtoint_a2d1cc99, latest.roundToInt()) else "—",
                    style = NoopType.chartValue,
                    color = Palette.restColor,
                )
            }
            // Sparkline of the consistency history, in metricCyan to match the Sleep-tab Night-detail tile.
            if (cons.series.size > 1) {
                Sparkline(values = cons.series.takeLast(30), color = Palette.metricCyan)
            }
        }
    }
}

// MARK: - Sleep Consistency card

/** One night's bed/wake fold for [SleepConsistencyCard], memoized off `sleeps` (#perf). */
private data class SleepNightTiming(val label: String, val bedHour: Float, val wakeHour: Float)

/**
 * Sleep-consistency chart: for the trailing 14 sessions, draws each night's bed→wake window
 * as a vertical bar against a time-of-day axis, with dashed overlays at the typical bed and
 * wake times. The headline score is the share of nights whose bed AND wake fell within 45 min
 * of the personal typical. (PR #260)
 */
@Composable
internal fun SleepConsistencyCard(
    sleeps: List<SleepSession>,
    habitualMidsleepSec: Long? = null,
    // #sleep-consistency-parity: the iOS-canonical onset-spread score (model.consistency, which also
    // honours the imported-consistency preference). Passed in so the card headline matches iOS + the tile
    // instead of the old local "share of nights within 45 min" count (a third, divergent value).
    consistencyScore: Double? = null,
) {
    // #perf: building the per-night fold allocates 2 Calendars + a SimpleDateFormat per session (~28
    // objects for 14 nights). It's a pure derivation of `sleeps` (no wall-clock input), so memoize it on
    // `sleeps` — scrolling the Sleep screen then reuses it instead of rebuilding it every recompose frame.
    val timings = remember(sleeps, habitualMidsleepSec) {
        val sdf = SimpleDateFormat("EEE", Locale.US)
        // #699: bridged bed→wake spans (one per day, night-tail fragments folded in), not raw sessions —
        // see consistencyNightSpans.
        consistencyNightSpans(sleeps, habitualMidsleepSec).map { (onsetTs, wakeTs) ->
            val bedCal = Calendar.getInstance().apply { timeInMillis = onsetTs * 1000L } // edited bedtime (PR #395)
            val wakeCal = Calendar.getInstance().apply { timeInMillis = wakeTs * 1000L }
            val bedH = bedCal.get(Calendar.HOUR_OF_DAY) + bedCal.get(Calendar.MINUTE) / 60f
            // Fold an evening bedtime to a negative hour so it sorts ABOVE the next-day wake on the axis.
            val bedNorm = if (bedH > 12f) bedH - 24f else bedH
            val wakeH = wakeCal.get(Calendar.HOUR_OF_DAY) + wakeCal.get(Calendar.MINUTE) / 60f
            SleepNightTiming(sdf.format(Date(wakeTs * 1000L)), bedNorm, wakeH)
        }
    }
    if (timings.size < 3) return

    fun sd(vals: List<Float>): Float {
        val m = vals.average().toFloat()
        return kotlin.math.sqrt(vals.sumOf { ((it - m) * (it - m)).toDouble() }.toFloat() / vals.size)
    }
    val bedSdH = sd(timings.map { it.bedHour })
    val wakeSdH = sd(timings.map { it.wakeHour })
    val typicalBed = timings.map { it.bedHour }.average().toFloat()
    val typicalWake = timings.map { it.wakeHour }.average().toFloat()
    // #sleep-consistency-parity: the headline is the shared onset-spread score (iOS-canonical), not the
    // old "share of nights within 45 min of typical" count. The bed/wake scatter + SD labels below are
    // unchanged (they visualise the same onsets). Falls back to 0 only when the score is unavailable.
    val consistencyPct = consistencyScore?.toFloat()?.coerceIn(0f, 100f) ?: 0f
    val typicalBedLabel = run {
        val h = ((typicalBed + 24f) % 24f).toInt()
        String.format(Locale.US, "%02d:00", h)
    }
    val typicalWakeLabel = String.format(Locale.US, "%02d:00", typicalWake.toInt().coerceIn(0, 23))

    // Y from −4h (20:00) to 18h (18:00 next day) — matches the 6 PM sensor-read window cap.
    val yMin = -4f; val yMax = 18f; val yRange = yMax - yMin

    fun hourToLabel(h: Float): String {
        val norm = ((h % 24f) + 24f) % 24f
        return String.format(Locale.US, "%02d:00", norm.toInt())
    }

    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            // Header: title + trend-score.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Schedule")
                    Text(uiString(R.string.l10n_sleep_screen_bedtime_wake_time_b2a22c32), style = NoopType.headline, color = Palette.textPrimary)
                    Text(uiString(R.string.l10n_sleep_screen_sleep_window_over_recent_nights_cc5fd9b8), style = NoopType.footnote, color = Palette.textSecondary)
                }
                Text(uiString(R.string.l10n_sleep_screen_consistencypct_roundtoint_b23a9d40, consistencyPct.roundToInt()), style = NoopType.chartValue, color = Palette.restColor)
            }

            // Canvas chart — clipped so bars never bleed outside the 160dp box. The nightly
            // sleep-window bars + wake marker read in the Rest world's indigo; the bed marker keeps
            // the periwinkle (metricPurple) so the two overlays stay distinguishable. (Bevel)
            val accentColor = Palette.restColor
            val purpleColor = Palette.metricPurple
            val hairlineColor = Palette.hairline
            val labelArgb = Palette.textTertiary.toArgb()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .clip(RoundedCornerShape(Metrics.cornerSm))
                    .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_consistency_nightly_bed_and_wake_14526f89) }
                    .drawBehind {
                        val yAxisW = 52f
                        val chartW = size.width - yAxisW
                        val chartH = size.height

                        val gridHours = listOf(-4f, 0f, 4f, 8f, 12f, 16f)
                        // The top "20:00" was drawn at x=0 with its baseline pinned to y=20, so its
                        // glyphs bled above the chart top and into the card's rounded top-left corner and
                        // got cropped (#443). Fix: a smaller label that fits the 52px gutter, and a
                        // baseline that's CENTRED on each gridline then clamped so the full glyph
                        // (ascent..descent) clears the rounded corners (cornerSm, in px) top and bottom.
                        val cornerPx = Metrics.cornerSm.toPx()
                        val paint = android.graphics.Paint().apply {
                            color = labelArgb
                            textSize = 20f
                            isAntiAlias = true
                        }
                        val fm = paint.fontMetrics
                        gridHours.forEach { h ->
                            val y = (chartH * ((h - yMin) / yRange)).coerceIn(0f, chartH)
                            drawLine(color = hairlineColor, start = Offset(yAxisW, y), end = Offset(size.width, y), strokeWidth = 1f)
                            val baseline = (y - (fm.ascent + fm.descent) / 2f)
                                .coerceIn(cornerPx - fm.ascent, chartH - fm.descent)
                            // Small left inset (4px) keeps the text off the very edge; at these clamped
                            // baselines every label sits clear of the rounded corner arc.
                            drawContext.canvas.nativeCanvas.drawText(hourToLabel(h), 4f, baseline, paint)
                        }

                        // Per-night bars (bed → wake), coordinates clamped to [0, chartH].
                        val barW = (chartW / timings.size * 0.6f).coerceAtLeast(4f)
                        val step = chartW / timings.size
                        timings.forEachIndexed { i, t ->
                            val cx = yAxisW + step * i + step / 2f
                            val rawBedY = chartH * ((t.bedHour - yMin) / yRange)
                            val rawWakeY = chartH * ((t.wakeHour - yMin) / yRange)
                            val topY = minOf(rawBedY, rawWakeY).coerceIn(0f, chartH)
                            val botY = maxOf(rawBedY, rawWakeY).coerceIn(0f, chartH)
                            val barH = (botY - topY).coerceAtLeast(4f)
                            drawRoundRect(
                                color = accentColor.copy(alpha = 0.65f),
                                topLeft = Offset(cx - barW / 2f, topY),
                                size = Size(barW, barH),
                                cornerRadius = CornerRadius(barW / 4f),
                            )
                        }

                        // Dashed typical bed (purple) / wake (accent) overlay lines.
                        val dashLen = 12f; val gapLen = 8f
                        listOf(typicalBed to purpleColor, typicalWake to accentColor).forEach { (h, col) ->
                            val y = (chartH * ((h - yMin) / yRange)).coerceIn(0f, chartH)
                            var x = yAxisW
                            while (x < size.width) {
                                drawLine(col.copy(alpha = 0.7f), Offset(x, y), Offset(minOf(x + dashLen, size.width), y), strokeWidth = 2f)
                                x += dashLen + gapLen
                            }
                        }
                    },
            ) {}

            // X-axis day labels (first, mid, last).
            Row(modifier = Modifier.fillMaxWidth().padding(start = 52.dp)) {
                val xLabels = listOf(
                    timings.firstOrNull()?.label.orEmpty(),
                    timings.getOrNull(timings.size / 2)?.label.orEmpty(),
                    timings.lastOrNull()?.label.orEmpty(),
                )
                xLabels.forEach { lbl ->
                    Text(lbl, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                LegendDot("Typical bedtime  $typicalBedLabel", Palette.metricPurple)
                LegendDot("Wake  $typicalWakeLabel", Palette.restColor)
            }

            Hairline()
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    "Score" to "${consistencyPct.roundToInt()}%",
                    "Typical" to "${((bedSdH + wakeSdH) / 2f * 60f).roundToInt()} min SD",
                    "Nights" to "${timings.size}",
                ).forEach { (lbl, v) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(lbl, color = Palette.textTertiary)
                        Text(v, style = NoopType.captionNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

// MARK: - Sleep metric detail sheet

@Composable
private fun SleepMetricDetailSheetContent(vm: AppViewModel, key: String) {
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
            Hairline()
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
