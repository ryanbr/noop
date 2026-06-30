package com.noop.ui

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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.SleepDebt
import com.noop.analytics.SleepDebtLedger
import com.noop.analytics.SleepStageTotals
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
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
    // 0 = latest night, N = N sleep-sessions back. Reset to the newest night only on a REAL data
    // reload (new sync / re-import via `days` changing). The optimistic bed/wake edit rewrites
    // `sleeps` in place WITHOUT touching `days`, so it must not reset the browse — keeping the
    // user on the night they just edited. (#160)
    var nightOffset by remember { mutableIntStateOf(0) }
    LaunchedEffect(days) {
        sleeps = runCatching {
            val now = System.currentTimeMillis() / 1000L
            val imported = vm.repo.sleepSessions("my-whoop", 0L, now)
            val computed = vm.repo.sleepSessions(vm.repo.computedDeviceId("my-whoop"), 0L, now)
            // Key by the LOCAL wake-day (#304), matching WhoopRepository.mergeSleep — a UTC key
            // mis-attributed a UTC+ user's early-morning wake to yesterday. REUSE the existing
            // dayString(ts, offsetSec) overload; do not add a new one (it clashes on the JVM).
            fun localEndDay(ts: Long): String {
                val offsetSec = (java.util.TimeZone.getDefault().getOffset(ts * 1000) / 1000).toLong()
                return AnalyticsEngine.dayString(ts, offsetSec)
            }
            val importedDays = imported.map { localEndDay(it.endTs) }.toHashSet()
            val computedOnly = computed.filter { localEndDay(it.endTs) !in importedDays }
            // Sort by the EFFECTIVE onset so a hand-edited bedtime orders the night correctly. (PR #395)
            (imported + computedOnly).sortedBy { it.effectiveStartTs }
        }.getOrDefault(emptyList())
        nightOffset = 0
    }

    // The user's LEARNED habitual midsleep (local time-of-day seconds), or null under the cold-start
    // threshold. Loaded from `vm.repo.habitualMidsleepSec` — the SAME value AnalyticsEngine.analyzeDay
    // threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    // and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too.
    // null keeps the existing cold-start overnight-band fallback. Keyed on `days` so it refreshes
    // alongside `sleeps`. Mirrors iOS SleepView.habitualMidsleepSec. (#547)
    var habitualMidsleep by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(days) {
        habitualMidsleep = runCatching { vm.repo.habitualMidsleepSec("my-whoop") }.getOrNull()
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

    // Morning-journal nudge: once per calendar day, when the freshest night ended within the last
    // 12 hours, invite the user to log how they felt. The shown-day is persisted so the sheet never
    // re-pops on a recomposition or a same-day re-open. (PR #260)
    var showJournalPrompt by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(sleeps) {
        val latestEnd = sleeps.lastOrNull()?.endTs ?: return@LaunchedEffect
        val nowS = System.currentTimeMillis() / 1000L
        val hoursAgo = (nowS - latestEnd) / 3600.0
        if (hoursAgo in 0.0..12.0) {
            val today = LocalDate.now().toString()
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
                Text("Good morning!", style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    "Your night data is in. Logging how you felt helps NOOP learn what drives your best recovery.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Button(
                    onClick = { showJournalPrompt = false; onOpenJournal() },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                ) {
                    Text("Open Journal", style = NoopType.headline, color = Palette.surfaceBase)
                }
                TextButton(
                    onClick = { showJournalPrompt = false },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Maybe later", style = NoopType.subhead, color = Palette.textTertiary)
                }
            }
        }
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
    val model = remember(days, night, imported) {
        buildSleepModel(days, night?.session, imported, selectedDay = night?.dayKey,
            heroStages = night?.groupStages, heroSegments = night?.groupSegments)
    }
    val display = remember(model, night) { heroDisplay(model, night) }

    // Jump straight to a night by its (local) wake-day — the center date block opens a picker.
    // navDays is newest-day-first, so the day's index IS its offset (0 = last night). (#160, #59)
    val onPickNightDate: (LocalDate) -> Unit = { targetDate ->
        val targetStr = targetDate.toString()
        val dayIdx = navDays.indexOfFirst { day -> day.any { localDayString(it.endTs) == targetStr } }
        if (dayIdx >= 0) nightOffset = dayIdx
    }

    LazyScreenScaffold(title = "Sleep", subtitle = "Last night, read in two seconds.") {
        if (model == null && night == null) {
            // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
            item {
                if (backfillNote != null) SyncingHistoryNote(chunks = backfillNote!!)
                SleepEmptyState()
            }
        } else {
            // REST HERO — a scenic indigo backdrop with the night's sleep-performance score as a
            // layered BevelGauge (Rest gradient), else a big rounded hours-slept headline. Mirrors the
            // macOS SleepView.restHero. Presentation-only — reads the existing model figures. (Bevel)
            item {
                RestHero(
                    score = model?.performance?.latest,
                    asleepMin = model?.stages?.asleep,
                    source = restHeroSource(imported, days),
                )
            }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            // SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1). LOGGING ONLY:
            // a mark is persisted to the `sleep_mark` series + the shareable strap log; it never
            // changes the detected sleep. Mirrors macOS SleepView.sleepMarkCard.
            item {
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
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
            Hero(
                display = display,
                clock = night?.clockLabel ?: model?.clockLabel,
                nightOffset = nightOffset,
                lastIndex = max(navDays.lastIndex, 0),
                onNavigate = { nightOffset = it },
                session = night?.session,
                onUpdateTimes = { s, start, end ->
                    // Optimistic: rewrite this session in `sleeps` so every metric recomputes
                    // immediately, then persist DURABLY off the UI thread. Mirror the persist path —
                    // keep the IMMUTABLE detected startTs and store the corrected onset in
                    // startTsAdjusted with userEdited=true, so display (via effectiveStartTs) tracks the
                    // edit while the (deviceId,startTs) key never moves. (PR #260 + #395)
                    // Reclip stagesJSON in-memory so the hypnogram strip updates instantly (same
                    // reclip logic runs again in WhoopRepository for the durable DB copy).
                    sleeps = sleeps.map {
                        if (it.deviceId == s.deviceId && it.startTs == s.startTs) {
                            val reclipped = SleepWindowReclip.reclip(it.stagesJSON, it.effectiveStartTs, it.endTs, start, end)
                            it.copy(startTsAdjusted = start, endTs = end, userEdited = true,
                                    stagesJSON = reclipped ?: it.stagesJSON)
                        } else {
                            it
                        }
                    }
                    scope.launch { vm.updateSleepSessionTimes(s, start, end) }
                },
                onDeleteSession = { s ->
                    // Delete = the edit path minus the re-insert: drop this session from `sleeps`
                    // so every metric recomputes immediately as if the night were never recorded,
                    // then persist the removal off the UI thread. Lets the user clear a misread or
                    // spurious night. (#281)
                    sleeps = sleeps.filterNot { it.deviceId == s.deviceId && it.startTs == s.startTs }
                    scope.launch { vm.deleteSleepSession(s) }
                },
                onAddNap = { startTs, endTs ->
                    // Persist the new nap as its OWN session (#508); reload `sleeps` afterwards so the
                    // new block shows in the ◀/▶ browse without waiting for a sync. We don't optimistically
                    // insert here because the stages are staged from raw off the UI thread.
                    scope.launch {
                        vm.addManualNap(startTs, endTs)
                        sleeps = runCatching {
                            val now = System.currentTimeMillis() / 1000L
                            val imported = vm.repo.sleepSessions("my-whoop", 0L, now)
                            val computed = vm.repo.sleepSessions(vm.repo.computedDeviceId("my-whoop"), 0L, now)
                            fun localEndDay(ts: Long): String {
                                val offsetSec = (java.util.TimeZone.getDefault().getOffset(ts * 1000) / 1000).toLong()
                                return AnalyticsEngine.dayString(ts, offsetSec)
                            }
                            val importedDays = imported.map { localEndDay(it.endTs) }.toHashSet()
                            val computedOnly = computed.filter { localEndDay(it.endTs) !in importedDays }
                            (imported + computedOnly).sortedBy { it.effectiveStartTs }
                        }.getOrDefault(sleeps)
                    }
                },
                onPickNightDate = onPickNightDate,
                napBlocks = night?.napBlocks ?: emptyList(),
                habitualMidsleepSec = habitualMidsleep,
                motionEpochs = night?.groupMotion ?: emptyList(),
            )
            }
            if (model != null) {
                // Bind a non-null local so the smart-cast carries cleanly into each item {} lambda
                // (a nullable val doesn't smart-cast across a lambda boundary). Same model, same order.
                val m = model
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { MetricGrid(m, onMetricClick = { detailMetricKey = it }) }
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { SleepDebtLedgerCard(m.sleepDebtLedger) }
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { StagesVsTypical(m) }
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { DurationTrend(m) }
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { HoursVsNeededCard(m) }
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item { SleepConsistencyCard(sleeps) }
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

@Composable
private fun SleepMarkCard(onMark: (SleepMarkType) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = "Sleep marks", overline = "Tap to log", trailing = "Phase 1")
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Tap when you're heading to bed or when you wake. Each tap is logged with the time — it doesn't change tonight's detected sleep.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Button(
                        onClick = { onMark(SleepMarkType.BEDTIME) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = "Log going to sleep" },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.surfaceInset,
                            contentColor = Palette.textPrimary,
                        ),
                    ) {
                        Icon(Icons.Filled.Bedtime, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Going to sleep", style = NoopType.subhead)
                    }
                    Button(
                        onClick = { onMark(SleepMarkType.WAKE) },
                        modifier = Modifier.weight(1f).semantics { contentDescription = "Log waking up" },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.surfaceInset,
                            contentColor = Palette.textPrimary,
                        ),
                    ) {
                        Icon(Icons.Filled.WbSunny, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("I'm awake", style = NoopType.subhead)
                    }
                }
            }
        }
    }
}

// MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)
//
// The Rest world's opening: a scenic indigo [ScenicHeroBackground] with — when the night carries a
// 0–100 sleep-performance score — a layered [BevelGauge] in the Rest gradient; else a big rounded
// hours-slept headline over the same backdrop. A [SourceBadge] states whether the score is WHOOP's
// own imported figure or NOOP's on-device estimate. Mirrors the macOS SleepView.restHero. The number
// comes straight from the existing model figures — presentation-only.

@Composable
private fun RestHero(score: Double?, asleepMin: Double?, source: String) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Sleep performance", overline = "Last night", trailing = "Rest")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Metrics.cardRadius))
                // A subtle night atmosphere sits behind the sleep hero ONLY (the Rest world's whisper:
                // faint indigo wash + crescent moon + a few stars over the near-black canvas, no glow),
                // clipped to the card. Mirrors the macOS SleepView.restHero .timeOfDayBackground(.night),
                // replacing the heavier ScenicHeroBackground here. (Bevel)
                .timeOfDayBackground(DayPart.Night),
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(Metrics.space24),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metrics.space14),
            ) {
                if (score != null) {
                    BevelGauge(
                        fraction = (score / 100.0).coerceIn(0.0, 1.0),
                        stops = Palette.restGradientStops,
                        tipColor = Palette.restColor,
                        numberText = "${score.roundToInt()}",
                        captionText = "of 100",
                        stateText = sleepScoreWord(score),
                        diameter = 184.dp,
                        lineWidth = 15.dp,
                    )
                } else {
                    // No 0–100 score for the night — lead with hours slept as a big rounded headline
                    // whose minutes tick up on appear (the same count-up the scored hero's arc draws in
                    // with). Mirrors the macOS SleepView.restHero CountUpText fallback.
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
                        Text("asleep last night", style = NoopType.subhead, color = Palette.textSecondary)
                    }
                }
                SourceBadge(text = source, tint = Palette.restColor)
            }
        }
    }
}

/** A short Rest state word for the hero gauge — same banding the synthesis hero uses. */
private fun sleepScoreWord(score: Double): String = when {
    score < 50.0 -> "Poor"
    score < 70.0 -> "Fair"
    score < 85.0 -> "Good"
    else -> "Optimal"
}

/**
 * Whether the night's sleep-performance score is WHOOP's own imported figure or NOOP's on-device
 * approximation — so the hero is honest about provenance, like Today's badges. Mirrors the macOS
 * SleepView.sleepScoreSource.
 */
private fun restHeroSource(imported: ImportedSleepSeries, days: List<DailyMetric>): String {
    val lastDay = days.lastOrNull()?.day
    return if (lastDay != null && imported.performance[lastDay] != null) "Whoop" else "On-device"
}

// MARK: - 1. HERO — stage breakdown for the navigated night

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Hero(
    display: HeroDisplay?,
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
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        NightNavHeader(nightOffset, lastIndex, clock, onNavigate, session, onUpdateTimes, onDeleteSession, onAddNap, onPickNightDate)
        // The night's clock window — when you fell asleep and when you woke — as its own clearly
        // labelled row. These were only ever in the nav-header's trailing caption, which truncates
        // between the two chevrons on a phone, so in practice the two times people look for first
        // were effectively hidden. Shown for every night that has a session (including the stage-less
        // stub, where it's the only thing the hero can say). Mirrors iOS SleepView.sleepWindowRow.
        session?.let { SleepWindowRow(it) }
        if (display == null) {
            // Honest fallback: this night recorded no usable stage data — never silently
            // substitute another night's hypnogram. (#160)
            NoopCard(tint = Palette.restColor) {
                Text(
                    "No stage data recorded for this night.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            val s = display.stages
            // After a bed/wake edit the session window is the source of truth for time-in-bed,
            // so the subtitle tracks the edit even before the stage minutes are recomputed. Uses the
            // EFFECTIVE onset so a hand-edited bedtime is reflected. (#160 / PR #395)
            val inBedMin = session?.let { (it.endTs - it.effectiveStartTs) / 60.0 } ?: s.total
            ChartCard(
                title = "Stage breakdown",
                subtitle = "${durationText(inBedMin)} in bed · ${display.efficiencyText} efficiency" +
                    (if (display.realSegments != null) " · approx. stages (on-device)" else ""),
                trailing = durationText(s.asleep),
                tint = Palette.restColor,
                footer = {
                    // WHOOP-style stage rows in the NOOP pip language: swatch + UPPERCASE stage +
                    // coloured % + a segmented PipBar of the share-of-night + right-aligned duration.
                    // Same minutes/percentages the old "label · value" footer carried — no new numbers.
                    // Mirrors the macOS SleepView.stageBreakdownRows. (PipBar)
                    StageBreakdownRows(s)
                },
            ) {
                // True per-epoch segments when the stager persisted them; else the reconstructed
                // architecture: light → deep → light → rem → light → awake.
                val segments = display.realSegments ?: stageSegments(s)
                if (segments.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        // Hero strip with the band-min-thickness floor (so a short Awake reads as a
                        // bar, not a tick) + an onset · midpoint · wake time axis when the session
                        // gives clock times. Mirrors the Swift Hypnogram(showsTimeAxis:).
                        HypnogramWithAxis(
                            stages = segments,
                            onsetTs = session?.effectiveStartTs,
                            wakeTs = session?.endTs,
                        )
                        // #407 — subordinate movement/restlessness trace UNDER the hypnogram, on the SAME
                        // timeline, for the SAME main-night GROUP blocks the hero resolved (selectNight's
                        // group). Honest empty state when no fragment has persisted motion (older rows).
                        MotionStrip(motionEpochs)
                        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                            StageLegend("Deep", Palette.sleepDeep)
                            StageLegend("Light", Palette.sleepLight)
                            StageLegend("REM", Palette.sleepREM)
                            StageLegend("Awake", Palette.sleepAwake)
                        }
                    }
                } else {
                    Text(
                        "No stage breakdown for this night.",
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
        // Naps card (#508/#518): the day's blocks OTHER than the main night, each editable / deletable
        // with the SAME mechanism main sleep uses, plus a Main / Nap(s) / Total split so what drives the
        // day's Rest total is explainable. Mirrors iOS SleepView.napSection.
        if (session != null) {
            NapsCard(
                main = session,
                naps = napBlocks,
                onEditNapTimes = onUpdateTimes,
                onDeleteNap = onDeleteSession,
                habitualMidsleepSec = habitualMidsleepSec,
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
    naps: List<SleepSession>,
    onEditNapTimes: (SleepSession, Long, Long) -> Unit,
    onDeleteNap: (SleepSession) -> Unit,
    // The LEARNED habitual midsleep, fed to the main-night selector so the "why this is your main sleep"
    // reason matches the block the hero shows. null = cold-start band. Mirrors iOS SleepView. (C1)
    habitualMidsleepSec: Long? = null,
) {
    val mainMin = (main.endTs - main.effectiveStartTs) / 60.0
    val napMin = naps.sumOf { (it.endTs - it.effectiveStartTs) / 60.0 }
    NoopCard(padding = Metrics.space14, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Text("DAYTIME SLEEP", style = NoopType.overline, color = Palette.textTertiary)
            Text("Naps", style = NoopType.subhead, color = Palette.textPrimary)
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
                    "No naps recorded for this day.",
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
            MainSleepFooter(main = main, naps = naps, habitualMidsleepSec = habitualMidsleepSec)
        }
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
) {
    val reason = mainSleepReasonText(listOf(main) + naps, habitualMidsleepSec)
    // C4 — the real merge winner, the SAME wording the By-Day badge uses ("On-device" / "Whoop" /
    // "Apple Health"), keyed on the main block's source. Mirrors iOS SleepView.nightSource.
    val (sourceText, sourceTint) = daySourceBadge(main.deviceId)
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
                        .semantics { contentDescription = "Why this is your main sleep" },
                ) {
                    Icon(
                        Icons.Filled.Info,
                        contentDescription = null,
                        tint = Palette.restColor,
                        modifier = Modifier.size(16.dp),
                    )
                    Text("Why this sleep?", style = NoopType.footnote, color = Palette.restColor)
                }
            }
        }
        if (showWhy && reason != null) {
            Text("About your main sleep", style = NoopType.subhead, color = Palette.textPrimary)
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
    val window = "${clockTimeLabel(nap.effectiveStartTs)}–${clockTimeLabel(nap.endTs)}"
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
                        contentDescription = "Nap $window, ${durationText(durMin)}"
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
                    contentDescription = "Why this is logged as a nap",
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
                    contentDescription = "Delete this nap",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        if (showWhy) {
            Text("About this nap", style = NoopType.subhead, color = Palette.textPrimary)
            Text(
                "Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.",
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
                    pendingStart = cal.timeInMillis / 1000L
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

/**
 * The four WHOOP-style stage rows that replace the old "label · value" footer grid, read like WHOOP's
 * sleep detail: a colour swatch, the UPPERCASE stage name, the share-of-night % in the stage colour, a
 * segmented [PipBar] (the NOOP signature) tinted in the stage colour, and the right-aligned duration.
 * Same data as the prior footer (rem / deep / light / awake over total) — no new numbers. Mirrors the
 * macOS SleepView.stageBreakdownRows. (PipBar)
 */
@Composable
private fun StageBreakdownRows(s: Stages) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
        StageBreakdownRow("REM", s.rem, s.total, Palette.sleepREM)
        StageBreakdownRow("Deep", s.deep, s.total, Palette.sleepDeep)
        StageBreakdownRow("Light", s.light, s.total, Palette.sleepLight)
        StageBreakdownRow("Awake", s.awake, s.total, Palette.sleepAwake)
    }
}

/**
 * One WHOOP-style stage row. `fraction = minutes / total` sets both the % and the PipBar fill, so the
 * coloured percent and the segmented bar always agree. Mirrors the macOS SleepView.stageBreakdownRow.
 */
@Composable
private fun StageBreakdownRow(stage: String, minutes: Double, total: Double, color: Color) {
    val fraction = if (total > 0.0) (minutes / total).coerceIn(0.0, 1.0) else 0.0
    val percent = (fraction * 100.0).roundToInt()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                contentDescription =
                    "$stage: ${durationText(minutes)}, $percent percent of the night"
            },
    ) {
        Box(
            modifier = Modifier
                .size(12.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(color),
        )
        Text(
            stage.uppercase(Locale.getDefault()),
            style = NoopType.overline,
            color = Palette.textPrimary,
            maxLines = 1,
            modifier = Modifier.width(56.dp),
        )
        Text(
            "$percent%",
            style = NoopType.captionNumber,
            color = color,
            maxLines = 1,
            modifier = Modifier.width(38.dp),
        )
        // The NOOP signature: a segmented bar that counts up to the share-of-night fraction, tinted in
        // the stage colour over the canonical inset track. Flat, crisp, no glow. Takes the remaining width.
        PipBar(
            value = (fraction * 100.0).toFloat(),
            segments = 20,
            tint = color,
            height = 8.dp,
            modifier = Modifier.weight(1f),
        )
        Text(
            durationText(minutes),
            style = NoopType.captionNumber,
            color = Palette.textPrimary,
            textAlign = TextAlign.End,
            maxLines = 1,
            modifier = Modifier.width(60.dp),
        )
    }
}

/**
 * The hero hypnogram strip plus an optional onset · midpoint · wake time axis. Mirrors the Swift
 * Hypnogram(showsTimeAxis:): a proportional stage strip with a per-segment WIDTH floor (so a brief
 * stage — especially a short Awake blip — reads as a rounded block, not a hairline tick), three
 * faint vertical hairlines at frac 0 / 0.5 / 1.0, and a clock-label row underneath. The axis only
 * appears when the session supplies onset/wake timestamps; otherwise this is just the floored strip.
 * Presentation-only — the segment weights and stage→colour mapping are unchanged.
 */
@Composable
private fun HypnogramWithAxis(
    stages: List<Pair<String, Float>>,
    onsetTs: Long?,
    wakeTs: Long?,
) {
    val showsAxis = onsetTs != null && wakeTs != null
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Canvas(modifier = Modifier.fillMaxWidth().height(Metrics.stageStripHeight)) {
            val w = size.width
            val h = size.height
            if (w <= 0f || h <= 0f) return@Canvas

            // Inset well so the strip reads as a recessed track (matches the shared Hypnogram).
            drawLine(
                color = Palette.surfaceInset,
                start = Offset(0f, h / 2f),
                end = Offset(w, h / 2f),
                strokeWidth = h,
                cap = StrokeCap.Round,
            )

            val weights = stages.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
            val total = weights.sum()
            if (stages.isEmpty() || total <= 0f) return@Canvas

            // WIDTH floor: a segment narrower than this reads as a tick. Floor it to ~one strip-height
            // square so short stages are legible blocks (the Android analogue of the Swift band-min
            // thickness). Stretches sub-floor stages slightly; proportions of normal stages are intact.
            val minSegW = h
            val gap = if (stages.size > 1) 1.5f else 0f
            var x = 0f
            stages.forEachIndexed { i, (name, _) ->
                val rawW = w * (weights[i] / total)
                if (rawW <= 0f) return@forEachIndexed
                val segW = maxOf(rawW, minSegW)
                val drawW = (segW - if (i < stages.size - 1) gap else 0f).coerceAtLeast(0f)
                if (drawW > 0f) {
                    val cap = (h / 2f).coerceAtMost(drawW / 2f)
                    drawLine(
                        color = stageColorFor(name),
                        start = Offset(x + cap, h / 2f),
                        end = Offset((x + drawW - cap).coerceAtLeast(x + cap), h / 2f),
                        strokeWidth = h,
                        cap = StrokeCap.Round,
                    )
                }
                x += segW
            }

            // Time-axis vertical hairlines: onset · midpoint · wake.
            if (showsAxis) {
                listOf(0f, 0.5f, 1f).forEach { frac ->
                    val hx = w * frac
                    drawLine(
                        color = Palette.hairline,
                        start = Offset(hx, 0f),
                        end = Offset(hx, h),
                        strokeWidth = 1f,
                    )
                }
            }
        }
        if (showsAxis && onsetTs != null && wakeTs != null) {
            val onset = clockTimeLabel(onsetTs)
            val mid = clockTimeLabel((onsetTs + wakeTs) / 2L)
            val wake = clockTimeLabel(wakeTs)
            Row(modifier = Modifier.fillMaxWidth()) {
                Text(
                    onset,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Start,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    mid,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                    overflow = TextOverflow.Ellipsis,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    wake,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.End,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
            }
        }
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
            "No movement detail for this night.",
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

/** Map a stage name to its design-system sleep tone (case-insensitive) — local to this screen so the
 *  hero strip needn't reach into Charts.kt's private helper. */
private fun stageColorFor(name: String): Color = when (name.trim().lowercase()) {
    "deep" -> Palette.sleepDeep
    "rem" -> Palette.sleepREM
    "light" -> Palette.sleepLight
    "awake", "wake" -> Palette.sleepAwake
    else -> Palette.sleepLight
}

/**
 * "Asleep / Woke" — the fell-asleep and woke clock times for the navigated night, read off the
 * session's onset (startTs) and wake (endTs) timestamps, each with a moon / sun glyph. Sits in the
 * hero between the night-nav header and the stage card so the two times people glance for first are
 * always visible, not truncated in the header caption. On-brand (surfaceRaised block, tokens) and
 * combined into one TalkBack element. Mirrors iOS SleepView.sleepWindowRow (PR #289).
 */
@Composable
private fun SleepWindowRow(session: SleepSession) {
    val asleep = clockTimeLabel(session.effectiveStartTs)
    val woke = clockTimeLabel(session.endTs)
    // A frosted Rest-tinted card (was a flat surfaceRaised block) so the window row sits in the
    // same colour world as the rest of the screen. Bevel treatment — content unchanged.
    NoopCard(
        modifier = Modifier.semantics(mergeDescendants = true) {
            contentDescription = "Fell asleep at $asleep, woke at $woke"
        },
        padding = Metrics.space14,
        tint = Palette.restColor,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SleepTime(icon = Icons.Filled.Bedtime, label = "Asleep", value = asleep)
            Spacer(Modifier.width(Metrics.space12))
            Box(
                modifier = Modifier
                    .height(30.dp)
                    .width(Metrics.divider)
                    .background(Palette.hairline),
            )
            Spacer(Modifier.width(Metrics.space12))
            SleepTime(icon = Icons.Filled.WbSunny, label = "Woke", value = woke)
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
    var showDatePicker by remember { mutableStateOf(false) }
    // Manual nap add (#508): pick a start time, then an end time; both anchored to THIS night's wake day
    // so the new nap lands on the right day. napStartTs holds the chosen start between the two pickers.
    var addingNapStart by remember { mutableStateOf(false) }
    var addingNapEnd by remember { mutableStateOf(false) }
    var napStartTs by remember { mutableStateOf(0L) }

    // Step 1 of the time edit: pick which end of the night to adjust (bedtime or wake-up).
    if (showTimeChoice && session != null) {
        val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
        val bedText = timeFmt.format(Date(session.effectiveStartTs * 1000L))
        val wakeText = timeFmt.format(Date(session.endTs * 1000L))
        val blockShape2 = RoundedCornerShape(Metrics.cornerSm)
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showTimeChoice = false },
            containerColor = Palette.surfaceRaised,
            titleContentColor = Palette.textPrimary,
            textContentColor = Palette.textSecondary,
            title = { Text("Adjust sleep times", style = NoopType.headline) },
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
            confirmButton = {},
        )
    }

    // Bed-time picker — keeps the original calendar date, only moves the hour/minute. Pre-fills from
    // the EFFECTIVE onset so re-editing an already-corrected night starts from the edited bedtime, and
    // the new onset is passed through onUpdateTimes (which stores it in startTsAdjusted). (PR #395)
    if (editingBed && session != null) {
        val startCal = Calendar.getInstance().apply { timeInMillis = session.effectiveStartTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = session.effectiveStartTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                    }
                    onUpdateTimes(session, cal.timeInMillis / 1000L, session.endTs)
                    editingBed = false
                },
                startCal.get(Calendar.HOUR_OF_DAY),
                startCal.get(Calendar.MINUTE),
                true,
            ).apply { setTitle("Bedtime") }
            dialog.setOnDismissListener { editingBed = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // Wake-up time picker — TIME-ONLY; its calendar day is always DERIVED from bedtime, never the
    // original detected wake day. Picking a wake time-of-day lands it on the FIRST occurrence strictly
    // after the effective bed instant (within 24h), so a 23:00→07:00 night resolves 07:00 to the next
    // morning and an evening nap resolves to the same evening. An independent wake date was what let an
    // edit silently re-bucket a night onto the wrong day (selectNight keys the day off endTs) and split
    // its stages/totals across two days — the edit-scramble half of #406. Mirrors the iOS sleep-edit
    // cross-day constraint (SleepView.SleepTimeEditor.resolvedWake).
    if (editingWake && session != null) {
        val endCal = Calendar.getInstance().apply { timeInMillis = session.endTs * 1000L }
        DisposableEffect(Unit) {
            val dialog = TimePickerDialog(
                context,
                { _, h, m ->
                    // Land the picked hour:minute on the first instant strictly after bed: start at the
                    // bed day, set the time-of-day, then roll forward one day if that is at or before bed
                    // (keeps wake inside (bed, bed+24h], matching iOS's nextDate(after: bed+60s)).
                    val bedTs = session.effectiveStartTs
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = bedTs * 1000L
                        set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                        if (timeInMillis / 1000L <= bedTs) add(Calendar.DAY_OF_MONTH, 1)
                    }
                    // Pass the EFFECTIVE onset so a wake-only edit preserves a previously-edited
                    // bedtime (startTsAdjusted) rather than resetting it to the detected startTs. (PR #395)
                    onUpdateTimes(session, bedTs, cal.timeInMillis / 1000L)
                    editingWake = false
                },
                endCal.get(Calendar.HOUR_OF_DAY),
                endCal.get(Calendar.MINUTE),
                true,
            ).apply { setTitle("Wake-up time") }
            dialog.setOnDismissListener { editingWake = false }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
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
                    napStartTs = cal.timeInMillis / 1000L
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

    val nightLabel = when (offset) {
        0 -> "Last night"
        1 -> "1 night ago"
        else -> "$offset nights ago"
    }
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
                Icon(Icons.Filled.ChevronLeft, contentDescription = "Previous night", tint = if (canGoOlder) Palette.accent else Palette.textTertiary)
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
                Icon(Icons.Filled.ChevronRight, contentDescription = "Next night", tint = if (canGoNewer) Palette.accent else Palette.textTertiary)
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
                    contentDescription = "Adjust sleep times",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp).clickable { showTimeChoice = true },
                )
                Spacer(Modifier.width(Metrics.space12))
                Icon(
                    Icons.Filled.DeleteOutline,
                    contentDescription = "Delete this sleep session",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp).clickable { showDeleteConfirm = true },
                )
                // Add a missed nap as its OWN session (#508) — staged from raw, never folded into this
                // night's main sleep. Two pickers (start → end), the end day derived from the start.
                Spacer(Modifier.width(Metrics.space12))
                Icon(
                    Icons.Filled.Add,
                    contentDescription = "Add a nap",
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
                "No earlier night stored yet. Earlier nights sync in the morning.",
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
            title = { Text("Delete this sleep session?", style = NoopType.headline) },
            text = {
                Text(
                    "Removes this recorded sleep and recomputes the day without it. This can't be undone.",
                    style = NoopType.subhead,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    onDeleteSession(session)
                }) {
                    Text("Delete", style = NoopType.headline, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) {
                    Text("Cancel", style = NoopType.subhead, color = Palette.textTertiary)
                }
            },
        )
    }
}

@Composable
private fun StageLegend(label: String, color: Color) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .height(Metrics.legendSwatch)
                .width(Metrics.legendSwatch)
                .clip(RoundedCornerShape(Metrics.cornerXs))
                .background(color),
        )
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - 2. Metric grid (uniform fixed-height tiles, each with a sparkline)

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
        { mod ->
            SparkTile(
                mod, "Sleep Debt",
                value = m.sleepDebt.latest?.let { durationText(it) } ?: "—",
                caption = debtCaption(m.sleepDebt.latest),
                accent = debtColor(m.sleepDebt.latest),
                spark = m.sleepDebt.series, sparkColor = Palette.metricRose,
                onClick = { onMetricClick("sleep_debt") },
            )
        },
    )

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Night detail", overline = "Metrics", trailing = "vs typical")
        // Two-up rows keep every tile the same fixed height with no empty cells.
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { it(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
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
 * Mirrors the macOS SleepView sleepDebtLedger card section-for-section. (#242)
 */
@Composable
internal fun SleepDebtLedgerCard(ledger: SleepDebtLedger) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Sleep-debt ledger", overline = "Last 14 nights", trailing = "running balance")
        NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
            if (ledger.nightCount == 0) {
                Text(
                    "No nights with sleep data yet — your ledger fills in as you wear the strap to bed.",
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
                    "Per-night sleep balance: ${ledger.nightCount} nights, net ${debtSigned(ledger.balanceMin)}"
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

// MARK: - 3. Stages vs typical

@Composable
private fun StagesVsTypical(m: SleepModel) {
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
                .semantics { contentDescription = "$label minutes vs your typical bar" }
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

@Composable
private fun DurationTrend(m: SleepModel) {
    val pts = m.trendHours
    val avg = pts.averageOrNull()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Trend", overline = "Sleep", trailing = "Last 14 days")
        ChartCard(
            title = "Hours asleep",
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
                    LineChart(
                        values = pts,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = "Sleep hours trend chart" },
                        color = Palette.restColor,
                        fill = true,
                        selectionEnabled = true,
                    )
                    DateAxisRow(m.trendDates)
                }
            } else {
                TrendPlaceholder()
            }
        }

        ChartCard(
            title = "Sleep Debt",
            subtitle = "Hours of sleep debt per day",
            trailing = m.trendDebtHours.lastOrNull()?.let { String.format(Locale.US, "%.1f h", it) },
            tint = Palette.restColor,
            footer = {
                ChartFooter(
                    listOf(
                        "Avg" to (m.trendDebtHours.averageOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "â€”"),
                        "Max" to (m.trendDebtHours.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "â€”"),
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
                            .semantics { contentDescription = "Sleep debt trend chart" },
                        color = Palette.metricRose,
                        selectionEnabled = true,
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
private fun TrendPlaceholder() {
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

@Composable
private fun DateAxisRow(days: List<String>) {
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

// MARK: - SparkTile (fixed-height metric tile with a trailing 30-day sparkline)

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
    val clickMod = if (onClick != null) modifier.height(Metrics.tileHeight).clickable(onClick = onClick)
        else modifier.height(Metrics.tileHeight)
    NoopCard(modifier = clickMod, padding = Metrics.space14) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Column(modifier = Modifier.weight(1f)) {
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
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = Metrics.space2),
                        )
                    }
                }
                val tail = spark.takeLast(30)
                if (tail.size >= 2) {
                    SparkTailBox {
                        Sparkline(values = tail, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Empty state

@Composable
private fun SleepEmptyState() {
    DataPendingNote(
        title = "No nights here yet",
        body = "No nights here yet. Import your WHOOP export in Data Sources to see " +
            "every night, your sleep stages and trends straight away.",
    )
}

// MARK: - Model + derivation (faithful to SleepView.swift)

/** Stage minutes for a single night (mirrors the macOS Stages struct). */
internal data class Stages(
    val awake: Double,
    val light: Double,
    val deep: Double,
    val rem: Double,
) {
    /** Total time in bed (includes awake). */
    val total: Double get() = awake + light + deep + rem

    /** Asleep time = total minus awake. */
    val asleep: Double get() = light + deep + rem
}

/** (latest, typical mean, full history) per metric — mirrors the macOS Metric tuple. */
internal data class Metric(
    val latest: Double?,
    val typical: Double?,
    val series: List<Double>,
)

/** Export-verbatim per-day sleep figures (metricSeries keys mirroring macOS WhoopImporter). */
internal data class ImportedSleepSeries(
    val performance: Map<String, Double> = emptyMap(), // sleep_performance, 0–100
    val consistency: Map<String, Double> = emptyMap(), // sleep_consistency, 0–100
    val needMin: Map<String, Double> = emptyMap(),     // sleep_need_min, minutes
    val debtMin: Map<String, Double> = emptyMap(),     // sleep_debt_min, minutes
)

/** Everything the screen renders, derived once per data change. */
internal data class SleepModel(
    val stages: Stages,
    val clockLabel: String,
    val efficiencyText: String,
    val performance: Metric,
    val efficiency: Metric,
    val consistency: Metric,
    val hoursVsNeeded: Metric,
    val restorative: Metric,
    val respiratory: Metric,
    val sleepDebt: Metric,
    val typicalTotalMin: Double?,
    val typicalDeepMin: Double?,
    val typicalRemMin: Double?,
    val typicalLightMin: Double?,
    val trendHours: List<Double>,
    val trendNeedHours: List<Double>,
    val trendDebtHours: List<Double>,
    val trendDates: List<String>,
    /** Persisted per-epoch segments as ordered (stage, minutes) weights — the REAL
     *  hypnogram (on-device APPROXIMATE staging) — or null → synthesized fallback. */
    val realSegments: List<Pair<String, Float>>?,
    /** Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
     *  fortnight, with the per-night deltas behind it. Computed once per data change. (#242) */
    val sleepDebtLedger: SleepDebtLedger,
)

/** The night the ◀/▶ chevrons selected: its MAIN session, the day-metric key it resolves to, its
 *  persisted per-epoch weights (or null), the "EEE d MMM · HH:mm–HH:mm" clock, and the day's other
 *  blocks (naps / split-sleep) for the naps card. (#160, #518) */
internal data class HeroNight(
    val session: SleepSession,
    val dayKey: String,
    val realSegments: List<Pair<String, Float>>?,
    val clockLabel: String,
    val napBlocks: List<SleepSession> = emptyList(),
    // The bridged main-night GROUP (#561): summed stage minutes + the full-night segments, when the night
    // is more than one fragment. `session` above stays the single WINNING block (the edit anchor); these
    // let buildSleepModel render the WHOLE night instead of one fragment (#555). Null for a single-block day.
    val groupStages: StageMins? = null,
    val groupSegments: List<PersistedSegment>? = null,
    // Per-epoch MOTION for the main-night GROUP (#407), laid fragment-by-fragment in the SAME order the
    // group's stage segments are laid. Empty when no group fragment has a persisted motionJSON (older rows)
    // → the hero shows an honest empty state instead of a fabricated zero trace. Read off the already-
    // resolved group, NOT a re-resolution of the night.
    val groupMotion: List<Double> = emptyList(),
)

/** What the hero card draws for the selected night — null means no usable stage data
 *  (renders the honest "No stage data recorded for this night." fallback). (#160) */
internal data class HeroDisplay(
    val stages: Stages,
    val realSegments: List<Pair<String, Float>>?,
    val efficiencyText: String,
)

/**
 * Pick the night for the DAY [offset] stops back from the most recent (0 = latest). [navDays]
 * is grouped-by-calendar-day, newest first, so the chevrons step by DAY not by flat session
 * index — a WHOOP 4.0 user with a single detected night has exactly one stop (both arrows
 * correctly disabled) instead of arrows that move within naps/split blocks of one night and
 * appear stuck (#57/#59). Mirrors iOS SleepView.decodedNight(at:)/navDays.
 *
 * The day's REPRESENTATIVE session is its MAIN sleep block — the LONGEST block, preferring an
 * OVERNIGHT-anchored onset (#518). A day can hold an overnight AND an afternoon nap (both end on
 * the same calendar day, so both bucket here); the OLD `maxByOrNull { endTs }` picked the
 * latest-ending block, which is the afternoon nap — so the overnight vanished from the Sleep tab.
 * Picking the longest overnight block fixes it; the other blocks are carried as `napBlocks` for
 * the naps card. The day key tries UTC then local-tz attribution of the MAIN block's wake — imported
 * DailyMetric.day is local-tz while dayString is UTC, so a near-midnight-UTC wake needs the second
 * key; both derive from THIS night's endTs, never another night. (#160, #518)
 */
internal fun selectNight(
    navDays: List<List<SleepSession>>,
    days: List<DailyMetric>,
    offset: Int,
    // The LEARNED habitual midsleep the engine threaded into the daily total, so the hero, the naps split,
    // and the edit target pick the SAME block the analytics rollup did — for a shift/late sleeper too. null
    // = cold-start band. (#547)
    habitualMidsleepSec: Long? = null,
    // Per-epoch MOTION keyed by detected startTs (#407). The group's fragments' series are concatenated in
    // group order onto HeroNight.groupMotion. Empty/absent → honest empty state. Default empty so existing
    // callers/tests compile unchanged.
    motionByStart: Map<Long, List<Double>> = emptyMap(),
): HeroNight? {
    if (navDays.isEmpty()) return null
    val dayIdx = offset.coerceIn(0, navDays.size - 1)
    val blocks = navDays[dayIdx]
    val session = mainSleepBlock(blocks, habitualMidsleepSec) ?: return null
    // The day's MAIN sleep is the bridged main-night GROUP (#561): a briefly-interrupted / biphasic night's
    // sibling fragments belong to the night, NOT the naps card — only blocks OUTSIDE the group are naps.
    // `session` stays the single WINNING block (the durable-edit anchor at SleepTimeEditor), but the group
    // drives the naps split, the hero's summed stage minutes, and the full-night hypnogram, so the tab
    // matches AnalyticsEngine.analyzeDay instead of rendering phantom naps (#555). A single-block day is
    // byte-identical to the prior behaviour. (#518/#555/#561)
    val group = mainSleepGroup(blocks, habitualMidsleepSec)
    val groupStarts = group.map { it.startTs }.toHashSet()
    val napBlocks = blocks.filter { it.startTs !in groupStarts }
        .sortedBy { it.effectiveStartTs }
    // Drop a spurious leading pre-sleep awake stub from the hero's RECONSTRUCTION so the hypnogram and the
    // summed minutes start where the displayed bedtime (the main block's onset) does (#736). A night can
    // record a brief, all-awake pre-onset block (e.g. lying in bed before sleep); the gap-bridge folds it
    // into the group, so the chart drew sleep beginning before the labelled "Asleep" time. We only drop a
    // BRIEF, essentially-sleepless leading fragment that also sits before the main block, so a genuine first
    // sleep fragment of an interrupted/biphasic night is never lost. The stub still rides in `groupStarts`
    // above, so it is never mislabelled as a nap. `session` (the edit anchor) is already the main block, so
    // the bedtime label and the pencil were aligned — this aligns the chart to that same bedtime. (#736/#555)
    val onsetTsForHero = session.effectiveStartTs
    val heroGroup = group.dropWhile { it.effectiveStartTs < onsetTsForHero && isPreOnsetAwakeStub(it) }
    val utcKey = AnalyticsEngine.dayString(session.endTs)
    val localKey = localDayString(session.endTs)
    val dayKey = listOf(utcKey, localKey).firstOrNull { key ->
        days.any { it.day == key && (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0 }
    } ?: utcKey
    // Lay every fragment's persisted segments end-to-end so a biphasic night draws as one continuous
    // hypnogram, and SUM their stage minutes for the hero. Built from `heroGroup` (the group minus a leading
    // spurious stub, #736) so the chart and minutes start at the displayed bedtime. Null for a single-block
    // hero → prior behaviour.
    val groupSegments = if (heroGroup.size > 1) {
        heroGroup.flatMap { parsePersistedSegments(it.stagesJSON).orEmpty() }
            .sortedBy { it.start }
            .takeIf { it.size >= 2 }
    } else null
    val groupStages = if (heroGroup.size > 1) sumGroupStages(heroGroup) else null
    val segments = (groupSegments ?: parsePersistedSegments(session.stagesJSON))
        ?.map { seg -> seg.stage to ((seg.end - seg.start) / 60f) }
    // #407: lay the GROUP's per-epoch motion fragment-by-fragment in `heroGroup` order (the same order
    // `groupSegments` lays the stage timeline), reading the already-chosen group's stored series. The
    // detected key (`startTs`) is the motion store's key. A fragment with no series contributes nothing; if
    // NO fragment has one, `groupMotion` is empty → honest empty state.
    val groupMotion = heroGroup.flatMap { motionByStart[it.startTs].orEmpty() }
    // #736 parity: the displayed bedtime must match where the hypnogram starts. The chart is built from
    // heroGroup (first non-stub fragment onward), so label from THAT fragment's onset (mirrors Swift
    // nightOnsetTs / synth.startTs), closed by the group's latest wake. `session` stays the edit anchor only.
    val heroOnsetTs = heroGroup.firstOrNull()?.effectiveStartTs ?: session.effectiveStartTs
    val heroWakeTs = heroGroup.maxOfOrNull { it.endTs } ?: session.endTs
    return HeroNight(session, dayKey, segments, clockLabelFor(heroOnsetTs, heroWakeTs), napBlocks, groupStages,
        groupSegments, groupMotion)
}

/**
 * The day's MAIN sleep block — the night people mean by "last night" — resolved by the SINGLE shared
 * selector ([SleepStageTotals.mainNightIndex]) the analytics rollup uses: the LEARNED-TIMING score
 * (asleep span + alignment bonus on each block's EFFECTIVE onset) rather than a re-derived overnight
 * gate, so the hero, the edit affordance, the analytics total, and the Sleep tab ALL resolve to the
 * identical block (the whole point of #525/#547). Scores on each block's EFFECTIVE onset (what the user
 * sees) and returns the owning session. This is the BARE single-block pick (the durable-edit anchor): the
 * HERO display and the nap split use [mainSleepGroup], which bridges the winner's adjacent fragments into
 * ONE night (#561) so a biphasic night isn't shown as phantom naps (#555). [habitualMidsleepSec] is the
 * SAME learned value the engine threads into the
 * persisted totals (loaded via `vm.repo.habitualMidsleepSec`), so a shift/late sleeper's hero and analytics
 * total resolve to the identical block; null keeps the cold-start overnight-band bonus, which matches a
 * cold-start engine run. Mirrors iOS SleepView.mainNightSession. (#518/#547)
 */
internal fun mainSleepBlock(blocks: List<SleepSession>, habitualMidsleepSec: Long? = null): SleepSession? {
    if (blocks.isEmpty()) return null
    val idx = SleepStageTotals.mainNightIndex(
        blocks.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
        uiTzOffsetSec(),
        habitualMidsleepSec,
    ) ?: return null
    return blocks[idx]
}

/**
 * The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake gap
 * shorter than [SleepStageTotals.gapBridgeMaxMin]), so a briefly-interrupted / biphasic night reads as ONE
 * continuous sleep exactly the way AnalyticsEngine.analyzeDay rolls it up for the daily total (#561). The
 * hero aggregates this whole group and ONLY blocks outside it are naps; without it the tab used the
 * un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with no
 * bridgeable gap collapses to the single block [mainSleepBlock] picks. Returns ascending by effective
 * onset. Mirrors iOS SleepView.mainNightGroup. (#561/#555)
 */
internal fun mainSleepGroup(blocks: List<SleepSession>, habitualMidsleepSec: Long? = null): List<SleepSession> {
    val idx = SleepStageTotals.mainNightGroupIndices(
        blocks.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
        uiTzOffsetSec(),
        habitualMidsleepSec,
    ) ?: return emptyList()
    return idx.map { blocks[it] }.sortedBy { it.effectiveStartTs }
}

/** Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
 *  before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of pre-sleep
 *  awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first sleep fragment
 *  is [PRE_ONSET_STUB_ASLEEP_MAX_MIN]: a stub must be essentially SLEEPLESS. Mirrors iOS
 *  SleepView.preOnsetStubMaxMin. (#736) */
private const val PRE_ONSET_STUB_MAX_MIN = 240.0
/** Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
 *  first sleep fragment of a biphasic night carries far more. Mirrors iOS SleepView.preOnsetStubAsleepMaxMin.
 *  (#736) */
private const val PRE_ONSET_STUB_ASLEEP_MAX_MIN = 3.0

/** A fragment is a spurious pre-onset awake stub when it is within the lie-in cap (<= [PRE_ONSET_STUB_MAX_MIN])
 *  and carries essentially no sleep (asleep minutes <= [PRE_ONSET_STUB_ASLEEP_MAX_MIN]). Used only to skip such
 *  a stub when it leads the main-night group, so the hero's hypnogram and minutes start at the displayed
 *  bedtime (the main block's onset) rather than before it. Mirrors iOS SleepView.isPreOnsetAwakeStub. (#736) */
internal fun isPreOnsetAwakeStub(frag: SleepSession): Boolean {
    val spanMin = (frag.endTs - frag.effectiveStartTs) / 60.0
    if (spanMin > PRE_ONSET_STUB_MAX_MIN) return false
    val stages = parseSessionStages(frag.stagesJSON)
    val asleepMin = stages?.let { it.light + it.deep + it.rem } ?: 0.0
    return asleepMin <= PRE_ONSET_STUB_ASLEEP_MAX_MIN
}

/** SUM the per-stage minutes across a bridged main-night group, so the hero's stage breakdown reflects the
 *  WHOLE night (#561) instead of one fragment (#555). The inter-fragment wake gap belongs to no fragment,
 *  so it is excluded exactly as AnalyticsEngine excludes it. Null if no fragment has parseable stages. */
private fun sumGroupStages(group: List<SleepSession>): StageMins? {
    var aw = 0.0; var li = 0.0; var dp = 0.0; var rm = 0.0; var any = false
    for (frag in group) {
        val s = parseSessionStages(frag.stagesJSON) ?: continue
        aw += s.awake; li += s.light; dp += s.deep; rm += s.rem; any = true
    }
    return if (any) StageMins(aw, li, dp, rm) else null
}

/** The device's current UTC offset (seconds east), evaluated per pick, fed to the selector's `offsetSec`
 *  so the timing test reads the user's clock via the SAME `offsetSec` math the engine uses
 *  ([SleepStageTotals.localSecOfDay]) instead of `Calendar.get(HOUR_OF_DAY)` — the duplicated, DST-fragile
 *  gate the audit flagged. Mirrors the engine's `TimeZone.getDefault().getOffset(...)`. (#547) */
internal fun uiTzOffsetSec(): Long =
    java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L

/**
 * Resolve what the hero shows: the day-metric model when it resolved for the selected
 * night; else the session's own persisted segments (the day row can miss while the
 * segments exist); else null → the honest fallback. Never another night's data. (#160)
 */
internal fun heroDisplay(model: SleepModel?, night: HeroNight?): HeroDisplay? {
    if (model != null) return HeroDisplay(model.stages, model.realSegments, model.efficiencyText)
    val segments = night?.realSegments ?: return null
    val stages = stagesFromSegments(segments) ?: return null
    val eff = night.session.efficiency
        ?.let { e -> "${(if (e <= 1.0) e * 100.0 else e).roundToInt()}%" } ?: "—"
    return HeroDisplay(stages, segments, eff)
}

/** Sum (stage, minutes) weights into per-stage totals; null when nothing is > 0. */
internal fun stagesFromSegments(segments: List<Pair<String, Float>>): Stages? {
    var awake = 0.0; var light = 0.0; var deep = 0.0; var rem = 0.0
    for ((stage, minutes) in segments) {
        val m = minutes.toDouble()
        when (stage) {
            "wake", "awake" -> awake += m
            "light" -> light += m
            "deep" -> deep += m
            "rem" -> rem += m
        }
    }
    val s = Stages(awake = awake, light = light, deep = deep, rem = rem)
    return if (s.total > 0.0) s else null
}

internal data class StageMins(val awake: Double, val light: Double, val deep: Double, val rem: Double)

/**
 * Extract stage minute counts from a session's stagesJSON, handling both formats:
 *  • Minute dict  {"awake":…,"light":…,"deep":…,"rem":…}  — imported nights (noopdb / WHOOP export)
 *  • Segment array [{start,end,stage}]                     — on-device computed nights
 * Returns null when the JSON is absent or unparseable, so callers fall back to DailyMetric columns.
 * SleepWindowReclip keeps the minute dict up to date after a wake-time edit, so stage counts
 * are correct immediately — no rescore needed for imported nights.
 */
private fun parseSessionStages(stagesJSON: String?): StageMins? {
    stagesJSON ?: return null
    return runCatching {
        val trimmed = stagesJSON.trim()
        when {
            trimmed.startsWith("{") -> {
                val obj = JSONObject(trimmed)
                val aw = obj.optDouble("awake", 0.0)
                val li = obj.optDouble("light", 0.0)
                val dp = obj.optDouble("deep", 0.0)
                val rm = obj.optDouble("rem", 0.0)
                if (aw + li + dp + rm > 0.0) StageMins(aw, li, dp, rm) else null
            }
            trimmed.startsWith("[") -> {
                val arr = JSONArray(trimmed)
                var aw = 0.0; var li = 0.0; var dp = 0.0; var rm = 0.0
                for (i in 0 until arr.length()) {
                    val seg = arr.optJSONObject(i) ?: continue
                    val start = seg.optLong("start", -1)
                    val end = seg.optLong("end", -1)
                    if (end <= start) continue
                    val durMin = (end - start) / 60.0
                    when (seg.optString("stage")) {
                        "wake"  -> aw += durMin
                        "light" -> li += durMin
                        "deep"  -> dp += durMin
                        "rem"   -> rm += durMin
                    }
                }
                if (aw + li + dp + rm > 0.0) StageMins(aw, li, dp, rm) else null
            }
            else -> null
        }
    }.getOrNull()
}

/**
 * Build the whole model from the cached daily metrics + the latest sleep session + the
 * export-verbatim sleep figures. Returns null when there is no usable latest night (no
 * stage minutes), which renders the empty state. All series are computed in one pass-set
 * here, matching the macOS buildModel(). Internal so SleepImportedFiguresTest can pin the
 * prefer-imported logic (the recoveryCalibrationNights test pattern).
 */
internal fun buildSleepModel(
    days: List<DailyMetric>,
    session: SleepSession?,
    imported: ImportedSleepSeries = ImportedSleepSeries(),
    selectedDay: String? = null,
    // The bridged main-night GROUP's summed stage minutes + full-night segments (#561), threaded from
    // selectNight so a biphasic night's hero shows the WHOLE night, not one fragment (#555). Null for a
    // single-block day → the session/DailyMetric path below is unchanged.
    heroStages: StageMins? = null,
    heroSegments: List<PersistedSegment>? = null,
): SleepModel? {
    val effectiveDay = selectedDay ?: days.lastOrNull()?.day ?: return null
    // The HERO night = the selected day's stage-bearing row. The TILE / debt / need / trend
    // window, by contrast, is the FULL history (latest-anchored) — matching iOS SleepView, which
    // builds every tile series + the debt ledger + the personal need from `repo.days` regardless
    // of which night the hero is browsing. Browsing a past night only re-points the hero, never
    // the at-a-glance tiles or the "Last 14 nights" ledger. One cross-platform definition. (#5)
    val latest = days.lastOrNull {
        it.day == effectiveDay && (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0
    }
        ?: return null

    // Prefer stage minutes from the session's (possibly reclipped) stagesJSON when it belongs
    // to this night — so a wake-time edit on an imported or computed night updates stage cards
    // (StagesVsTypical, Hypnogram footer) immediately without waiting on a rescore.
    val sessionStageMins = session
        ?.takeIf { AnalyticsEngine.dayString(it.endTs) == latest.day || localDayString(it.endTs) == latest.day }
        ?.let { parseSessionStages(it.stagesJSON) }
    val deep = heroStages?.deep ?: sessionStageMins?.deep ?: latest.deepMin ?: 0.0
    val rem = heroStages?.rem ?: sessionStageMins?.rem ?: latest.remMin ?: 0.0
    val light = heroStages?.light ?: sessionStageMins?.light ?: latest.lightMin ?: 0.0

    // Hero awake estimate works off ASLEEP minutes (totalSleepMin), never the in-bed window. The
    // old code substituted the edited session's (wake − onset) duration — TIME IN BED — for the
    // asleep figure here and across every per-tile pass, which inflated awake / hours-vs-needed /
    // debt vs the actual sleep. iOS never did this (it derives awake straight from the decoded
    // stage segments). Dropped for parity (#1/#7); a sleep edit now reaches the tiles via the
    // re-score path, not a display-time in-bed swap.
    val asleep = latest.totalSleepMin ?: (deep + rem + light)
    // Awake estimate: prefer (time-in-bed − asleep) implied by efficiency; else from
    // disturbances; matches the macOS "awake minutes" carried in the stagesJSON.
    val effFrac = latest.efficiency?.let { if (it > 1.0) it / 100.0 else it }
    val awake = when {
        effFrac != null && effFrac in 0.01..0.999 -> max(0.0, asleep / effFrac - asleep)
        latest.disturbances != null -> latest.disturbances * 6.0
        else -> 0.0
    }
    val stages = Stages(awake = awake, light = light, deep = deep, rem = rem)
    if (stages.total <= 0.0) return null

    // Typical = mean across ALL nights with data (full history, latest-anchored — never bounded
    // to the browsed night), mirroring iOS typicalTotalMin / typicalStageMin over repo.days.
    val typicalTotalMin = mean(days.mapNotNull { it.totalSleepMin }.filter { it > 0.0 })
    val typicalDeepMin = mean(days.mapNotNull { it.deepMin }.filter { it > 0.0 })
    val typicalRemMin = mean(days.mapNotNull { it.remMin }.filter { it > 0.0 })
    val typicalLightMin = mean(days.mapNotNull { it.lightMin }.filter { it > 0.0 })

    // Personal sleep need (minutes): mean asleep, floored at 7.5h (450 min).
    val needMin = max(450.0, typicalTotalMin ?: 450.0)

    // Per-tile metrics — each a full pass over the FULL day history (asleep totals, no in-bed
    // substitution), latest = the most-recent day. Mirrors iOS SleepView, where every tile series
    // is `metric { … }` over repo.days. Where the WHOOP export carried the figure verbatim
    // (metricSeries), it wins per day; the on-device recomputation is the APPROXIMATE fallback.
    val performance = metric(days) { d ->
        imported.performance[d.day]   // WHOOP's own 0–100 figure wins per day
            ?: d.totalSleepMin?.takeIf { it > 0.0 && needMin > 0.0 }
                ?.let { minOf(100.0, it / needMin * 100.0) }   // APPROXIMATE fallback
    }
    val efficiency = metric(days) { d ->
        d.efficiency?.let { if (it <= 1.0) it * 100.0 else it }
    }
    val consistency = run {
        // Prefer the imported sleep_consistency series, but only when it covers the latest
        // night — otherwise "latest" would silently be a months-old import-era value.
        val lastDay = days.lastOrNull()?.day
        if (lastDay != null && imported.consistency[lastDay] != null) {
            val series = days.mapNotNull { imported.consistency[it.day] }
            Metric(series.lastOrNull(), mean(series), series)
        } else {
            consistencySeries(days)
        }
    }
    val hoursVsNeeded = metric(days) { d ->
        val need = imported.needMin[d.day] ?: needMin   // imported need wins per day
        d.totalSleepMin?.takeIf { it > 0.0 && need > 0.0 }?.let { it / need * 100.0 }
    }
    val restorative = metric(days) { d ->
        val dp = d.deepMin; val rm = d.remMin; val sl = d.totalSleepMin
        if (dp != null && rm != null && sl != null && sl > 0.0) (dp + rm) / sl * 100.0 else null
    }
    val respiratory = metric(days) { it.respRateBpm }
    val sleepDebt = run {
        val series = days.mapNotNull { d ->
            imported.debtMin[d.day]   // minutes, export-verbatim
                ?: d.totalSleepMin?.takeIf { it > 0.0 && needMin > 0.0 }
                    ?.let { max(0.0, needMin - it) }   // APPROXIMATE fallback
        }
        Metric(series.lastOrNull(), mean(series), series)
    }

    // Trend set = the most-recent nights with data (asleep totals, full history — latest-anchored,
    // not the browsed night). Mirrors iOS's trailing trend over repo.days.
    val trendRows = days.filter { (it.totalSleepMin ?: 0.0) > 0.0 }.takeLast(14)
    val trendHours = trendRows.mapNotNull { it.totalSleepMin?.let { minutes -> minutes / 60.0 } }
    val trendNeedHours = trendRows.map { row -> ((imported.needMin[row.day] ?: needMin) / 60.0) }
    val trendDebtHours = trendRows.map { row ->
        val sleptMin = row.totalSleepMin ?: 0.0
        val neededMin = imported.needMin[row.day] ?: needMin
        ((imported.debtMin[row.day] ?: max(0.0, neededMin - sleptMin)) / 60.0)
    }
    val trendDates = trendRows.map { it.day }

    // Real per-epoch timeline only when the merged session IS this night — UTC OR local-tz
    // end-day match (imported DailyMetric.day is local-tz while dayString is UTC, so a
    // near-midnight-UTC wake only matches via the local key; selectNight attributes the
    // night the same way). A non-matching session degrades safely to synthesis, never to
    // a wrong night. (#160)
    val realSegments = heroSegments?.map { seg -> seg.stage to ((seg.end - seg.start) / 60f) }
        ?: session
            ?.takeIf {
                AnalyticsEngine.dayString(it.endTs) == latest.day || localDayString(it.endTs) == latest.day
            }
            ?.let { parsePersistedSegments(it.stagesJSON) }
            ?.map { seg -> seg.stage to ((seg.end - seg.start) / 60f) }

    // Rolling 14-night sleep-debt ledger over the FULL day history (the analytics caps to the
    // most-recent 14 counted nights and skips no-data nights), using the SAME personal need the
    // tiles use (`needMin`, ≥ 7.5 h — the per-user override over the 8 h default). Full history,
    // not the browsed-night window: the ledger is a "Last 14 nights" at-a-glance summary that
    // matches the debt TILE (both now read asleep totals over `days`), and mirrors iOS's
    // debtLedger over repo.days. (#242, #5)
    val sleepDebtLedger = SleepDebt.ledger(
        series = days.map { it.day to it.totalSleepMin },
        needHours = needMin / 60.0,
    )

    return SleepModel(
        stages = stages,
        clockLabel = clockLabel(latest, session),
        efficiencyText = efficiency.latest?.let { "${it.roundToInt()}%" } ?: "—",
        performance = performance,
        efficiency = efficiency,
        consistency = consistency,
        hoursVsNeeded = hoursVsNeeded,
        restorative = restorative,
        respiratory = respiratory,
        sleepDebt = sleepDebt,
        typicalTotalMin = typicalTotalMin,
        typicalDeepMin = typicalDeepMin,
        typicalRemMin = typicalRemMin,
        typicalLightMin = typicalLightMin,
        trendHours = trendHours,
        trendNeedHours = trendNeedHours,
        trendDebtHours = trendDebtHours,
        trendDates = trendDates,
        realSegments = realSegments,
        sleepDebtLedger = sleepDebtLedger,
    )
}

/** Build a metric from a per-day transform, keeping only finite values. */
private fun metric(days: List<DailyMetric>, transform: (DailyMetric) -> Double?): Metric {
    val series = days.mapNotNull(transform).filter { it.isFinite() }
    return Metric(series.lastOrNull(), mean(series), series)
}

/**
 * Consistency per day from the rolling bedtime spread — but Android's daily metrics carry
 * no per-night onset timestamp, so a bedtime-variance score isn't reconstructable from the
 * cached `days` alone. We approximate the same intent (steadier nights → higher score) from
 * the trailing-14 spread of total-sleep duration: low duration variability ≈ a consistent
 * routine. Each day's score uses the window ending at that day, matching the macOS rolling
 * shape. Honest note: this is a duration-based proxy, not the onset-spread score.
 */
private fun consistencySeries(days: List<DailyMetric>): Metric {
    val mins = days.mapNotNull { it.totalSleepMin?.takeIf { m -> m > 0.0 } }
    if (mins.size < 3) return Metric(null, null, emptyList())
    val scores = ArrayList<Double>()
    for (i in mins.indices) {
        val lo = max(0, i - 13)
        val window = mins.subList(lo, i + 1)
        if (window.size < 3) continue
        val m = window.average()
        val variance = window.sumOf { (it - m) * (it - m) } / window.size
        val sd = Math.sqrt(variance)
        // 90 min of duration SD maps to a 0 score; tighter routines climb to 100.
        scores.add((100.0 * (1.0 - sd / 90.0)).coerceIn(0.0, 100.0))
    }
    return Metric(scores.lastOrNull(), mean(scores), scores)
}

private fun mean(vals: List<Double>): Double? = if (vals.isEmpty()) null else vals.sum() / vals.size

// MARK: - Stage segment reconstruction (durations only — same architecture as macOS)

/**
 * Lay the stage minutes end-to-end as proportional hypnogram segments: light → deep →
 * light → rem → light → awake (deep early, REM later, awake last). Weights are minutes;
 * the Hypnogram normalizes them to width.
 */
private fun stageSegments(s: Stages): List<Pair<String, Float>> {
    val out = ArrayList<Pair<String, Float>>()
    fun add(name: String, minutes: Double) {
        if (minutes > 0.0) out.add(name to minutes.toFloat())
    }
    add("light", s.light * 0.4)
    add("deep", s.deep)
    add("light", s.light * 0.3)
    add("rem", s.rem)
    add("light", s.light * 0.3)
    add("awake", s.awake)
    return out
}

// MARK: - Formatting helpers (mirror SleepView.swift)

private fun pct(minutes: Double, total: Double): Int =
    if (total > 0.0) (minutes / total * 100.0).roundToInt() else 0

private fun pctValue(v: Double?): String = v?.let { "${it.roundToInt()}%" } ?: "—"

/** "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries. */
private fun vsTypical(latest: Double?, typical: Double?, suffix: String, decimals: Int = 0): String {
    if (latest == null || typical == null || typical == 0.0) return "vs typical —"
    val diff = latest - typical
    val sign = if (diff >= 0) "+" else "−"
    val mag = abs(diff)
    val num = if (decimals == 0) "${mag.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", mag)
    return "$sign$num$suffix vs typical"
}

private fun debtCaption(debt: Double?): String {
    if (debt == null) return "vs need"
    return if (debt < 15.0) "On target" else "Below need"
}

private fun debtColor(debt: Double?): Color = when {
    debt == null -> Palette.textPrimary
    debt < 15.0 -> Palette.statusPositive
    debt < 60.0 -> Palette.statusWarning
    else -> Palette.statusCritical
}

// MARK: - Sleep-debt ledger formatting (mirror SleepView.swift)

/**
 * "≈2h 10m" magnitude headline — leading "≈" because it's an accumulated estimate. Reads
 * "On target" inside the deadband so a few stray minutes don't show as debt.
 */
private fun debtHeadline(ledger: SleepDebtLedger): String =
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) "On target"
    else "≈${durationText(ledger.magnitudeMin)}"

/** Short tag beside the headline: sleep debt / surplus / balanced. */
private fun debtTag(ledger: SleepDebtLedger): String = when {
    ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN -> "balanced"
    ledger.isDebt -> "sleep debt"
    else -> "surplus"
}

/** Plain-English read of the running balance over the window. */
private fun debtRead(ledger: SleepDebtLedger): String {
    val nights = ledger.nightCount
    val span = "the last $nights night${if (nights == 1) "" else "s"}"
    if (ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN) {
        return "You're roughly on top of your sleep across $span — slept minutes balance out against your need."
    }
    val mag = durationText(ledger.magnitudeMin)
    return if (ledger.isDebt) {
        "You've banked about $mag of sleep debt over $span. Surplus nights count back against it — an earlier night or two would clear it."
    } else {
        "You're carrying about $mag of surplus over $span — you've slept past your need on balance. Nicely ahead."
    }
}

/**
 * Color the balance by sign + size: surplus/within-band → positive green, modest debt →
 * warning, heavier debt → critical.
 */
private fun debtBalanceColor(ledger: SleepDebtLedger): Color = when {
    ledger.magnitudeMin < SleepDebt.ON_TARGET_BAND_MIN || !ledger.isDebt -> Palette.statusPositive
    ledger.magnitudeMin < 180.0 -> Palette.statusWarning
    else -> Palette.statusCritical
}

/** Signed "+1h 20m" / "−2h 10m" / "0m" balance string. */
private fun debtSigned(minutes: Double): String {
    if (abs(minutes) < 1.0) return "0m"
    val sign = if (minutes >= 0.0) "+" else "−"
    return "$sign${durationText(abs(minutes))}"
}

private fun durationText(minutes: Double): String {
    val m = max(0, minutes.roundToInt())
    return if (m < 60) "${m}m" else "${m / 60}h ${m % 60}m"
}

/** "Wed 4 Jun · 22:50–06:48" style trailing label from the session clock, when available. */
private fun shortDayLabel(day: String): String =
    runCatching {
        LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }.getOrDefault(day)

private fun List<Double>.averageOrNull(): Double? =
    if (isEmpty()) null else sum() / size

private fun clockLabel(latest: DailyMetric, session: SleepSession?): String {
    if (session != null) return sessionClockLabel(session)
    // Fall back to the daily metric's day string (YYYY-MM-DD), formatted to "EEE d MMM".
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.US)
    return runCatching {
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        parser.parse(latest.day)?.let { dateFmt.format(it) }
    }.getOrNull() ?: latest.day
}

/** "Wed 4 Jun · 22:50–06:48" — the night-nav header's date · onset–wake line. (#160) */
private fun sessionClockLabel(session: SleepSession): String =
    clockLabelFor(session.effectiveStartTs, session.endTs) // EFFECTIVE onset so an edited bedtime shows (PR #395)

/** Same date · onset–wake line from explicit unix-second bounds (the #736 group-aligned bedtime). */
private fun clockLabelFor(onsetTs: Long, wakeTs: Long): String {
    val timeFmt = SimpleDateFormat("HH:mm", Locale.US)
    val dateFmt = SimpleDateFormat("EEE d MMM", Locale.US)
    val onset = Date(onsetTs * 1000L)
    val wake = Date(wakeTs * 1000L)
    return "${dateFmt.format(onset)} · ${timeFmt.format(onset)}–${timeFmt.format(wake)}"
}

/** Unix seconds → "YYYY-MM-DD" in the DEVICE timezone (vs AnalyticsEngine.dayString = UTC). */
private fun localDayString(ts: Long): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(ts * 1000L))

/** Unix seconds → a local wall-clock "HH:mm" (same 24h formatting the nav-header span uses). */
private fun clockTimeLabel(ts: Long): String =
    SimpleDateFormat("HH:mm", Locale.US).format(Date(ts * 1000L))

/** One persisted per-epoch stage segment (wall-clock unix seconds). */
internal data class PersistedSegment(val start: Long, val end: Long, val stage: String)

/**
 * Parse the verbatim per-epoch segments array the on-device stager persists
 * ([{"start","end","stage"}], unix seconds, stage ∈ wake|light|deep|rem — see
 * AnalyticsEngine.encodeStages). Returns null for the imported minutes shapes
 * (the macOS {"light",…} dict and the CSV-import [{stage,min}] array) and any
 * malformed input, so callers keep the synthesized fallback. Pure + unit-tested
 * (see SleepStageSegmentsTest).
 */
internal fun parsePersistedSegments(json: String?): List<PersistedSegment>? {
    if (json.isNullOrBlank()) return null
    val trimmed = json.trim()
    if (!trimmed.startsWith("[")) return null
    return runCatching {
        val arr = JSONArray(trimmed)
        val out = ArrayList<PersistedSegment>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: return@runCatching null
            val start = o.optLong("start", Long.MIN_VALUE)
            val end = o.optLong("end", Long.MIN_VALUE)
            val stage = o.optString("stage", "")
            if (start == Long.MIN_VALUE || end <= start || stage.isEmpty()) return@runCatching null
            out.add(PersistedSegment(start, end, stage))
        }
        out.takeIf { it.size >= 2 }
    }.getOrNull()
}

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
    val score = (sleptH / neededH * 100.0).coerceIn(0.0, 100.0)
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
                    Text("Hours vs Needed", style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(trendArrow, style = NoopType.title2, color = arrowColor)
                Spacer(Modifier.width(Metrics.space6))
                Text("${score.roundToInt()}%", style = NoopType.chartValue, color = Palette.restColor)
            }

            // Gradient progress bar: slept / needed.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.progressHeight)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.surfaceInset)
                    .semantics { contentDescription = "Hours vs Needed progress bar, ${score.roundToInt()} percent" },
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
                    "Debt" to if (debtH > 0.05) String.format(Locale.US, "%.1f h", debtH) else "None",
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

// MARK: - Sleep Consistency card

/**
 * Sleep-consistency chart: for the trailing 14 sessions, draws each night's bed→wake window
 * as a vertical bar against a time-of-day axis, with dashed overlays at the typical bed and
 * wake times. The headline score is the share of nights whose bed AND wake fell within 45 min
 * of the personal typical. (PR #260)
 */
@Composable
internal fun SleepConsistencyCard(sleeps: List<SleepSession>) {
    val recent = sleeps.takeLast(14)
    if (recent.size < 3) return

    data class NightTiming(val label: String, val bedHour: Float, val wakeHour: Float)
    val sdf = SimpleDateFormat("EEE", Locale.US)
    val timings = recent.map { s ->
        val bedCal = Calendar.getInstance().apply { timeInMillis = s.effectiveStartTs * 1000L } // edited bedtime (PR #395)
        val wakeCal = Calendar.getInstance().apply { timeInMillis = s.endTs * 1000L }
        val bedH = bedCal.get(Calendar.HOUR_OF_DAY) + bedCal.get(Calendar.MINUTE) / 60f
        // Fold an evening bedtime to a negative hour so it sorts ABOVE the next-day wake on the axis.
        val bedNorm = if (bedH > 12f) bedH - 24f else bedH
        val wakeH = wakeCal.get(Calendar.HOUR_OF_DAY) + wakeCal.get(Calendar.MINUTE) / 60f
        NightTiming(sdf.format(Date(s.endTs * 1000L)), bedNorm, wakeH)
    }

    fun sd(vals: List<Float>): Float {
        val m = vals.average().toFloat()
        return kotlin.math.sqrt(vals.sumOf { ((it - m) * (it - m)).toDouble() }.toFloat() / vals.size)
    }
    val bedSdH = sd(timings.map { it.bedHour })
    val wakeSdH = sd(timings.map { it.wakeHour })
    val typicalBed = timings.map { it.bedHour }.average().toFloat()
    val typicalWake = timings.map { it.wakeHour }.average().toFloat()
    // Count nights where bed AND wake are within 45 min of the typical.
    val threshold = 0.75f
    val consistentNights = timings.count { t ->
        abs(t.bedHour - typicalBed) <= threshold && abs(t.wakeHour - typicalWake) <= threshold
    }
    val consistencyPct = (consistentNights.toFloat() / timings.size * 100f).coerceIn(0f, 100f)
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
                    Text("Bedtime & wake time", style = NoopType.headline, color = Palette.textPrimary)
                    Text("Sleep window over recent nights", style = NoopType.footnote, color = Palette.textSecondary)
                }
                Text("${consistencyPct.roundToInt()}%", style = NoopType.chartValue, color = Palette.restColor)
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
                    .semantics { contentDescription = "Sleep consistency nightly bed and wake chart" }
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
                    "Nights" to "${recent.size}",
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

private enum class SleepMetricRange(val label: String, val days: Long?) {
    WEEK("W", 7), MONTH("M", 30), THREE_MONTH("3M", 90),
    SIX_MONTH("6M", 180), YEAR("1Y", 365), ALL("ALL", null),
}

private data class SleepMetricSpec(
    val title: String,
    val unit: String,
    val color: Color,
    val format: (Double) -> String,
)

private fun sleepMetricSpec(key: String): SleepMetricSpec = when (key) {
    "performance"     -> SleepMetricSpec("Rest", "%", Palette.restColor) { "${it.roundToInt()}" }
    "efficiency"      -> SleepMetricSpec("Sleep Efficiency", "%", Palette.statusPositive) { "${it.roundToInt()}" }
    "consistency"     -> SleepMetricSpec("Consistency", "%", Palette.metricCyan) { "${it.roundToInt()}" }
    "hours_vs_needed" -> SleepMetricSpec("Hours vs Needed", "%", Palette.restColor) { "${it.roundToInt()}" }
    "restorative"     -> SleepMetricSpec("Restorative", "%", Palette.sleepREM) { "${it.roundToInt()}" }
    "respiratory"     -> SleepMetricSpec("Respiratory Rate", "rpm", Palette.metricPurple) { String.format(Locale.US, "%.1f", it) }
    "sleep_debt"      -> SleepMetricSpec("Sleep Debt", "h", Palette.metricRose) { String.format(Locale.US, "%.1f", it) }
    else              -> SleepMetricSpec(key, "", Palette.accent) { "${it.roundToInt()}" }
}

private fun buildSleepMetricPoints(days: List<DailyMetric>, key: String): List<Pair<String, Double>> {
    val needMin = max(450.0, days.mapNotNull { it.totalSleepMin?.takeIf { m -> m > 0.0 } }.average().let { if (it.isNaN()) 480.0 else it })
    return days.mapNotNull { d ->
        val v: Double? = when (key) {
            // The Rest detail graph reads the REAL resolved Rest composite per day — the same single
            // source of truth the Today Rest score uses (RestScorer.restFromDaily, the composite the
            // sleep_performance series carries) — not a local hours-vs-need approximation. Keeps the
            // graph and the score in agreement. (#614 follow-up)
            "performance" -> com.noop.analytics.RestScorer.restFromDaily(d)?.takeIf { it in 0.0..100.0 }
            "efficiency"  -> d.efficiency?.let { if (it <= 1.0) it * 100.0 else it }
            "consistency" -> {
                val idx = days.indexOf(d)
                val lo = max(0, idx - 13)
                val window = days.subList(lo, idx + 1).mapNotNull { it.totalSleepMin?.takeIf { m -> m > 0.0 } }
                if (window.size < 3) null else {
                    val m = window.average()
                    val sd = kotlin.math.sqrt(window.sumOf { (it - m) * (it - m) } / window.size)
                    (100.0 * (1.0 - sd / 90.0)).coerceIn(0.0, 100.0)
                }
            }
            "hours_vs_needed" -> d.totalSleepMin?.takeIf { it > 0.0 }?.let { minOf(100.0, it / needMin * 100.0) }
            "restorative" -> {
                val dp = d.deepMin ?: return@mapNotNull null
                val rm = d.remMin ?: return@mapNotNull null
                val sl = d.totalSleepMin ?: return@mapNotNull null
                if (sl > 0.0) (dp + rm) / sl * 100.0 else null
            }
            "respiratory" -> d.respRateBpm
            "sleep_debt"  -> d.totalSleepMin?.let { max(0.0, needMin - it) / 60.0 }
            else          -> null
        }
        v?.takeIf { it.isFinite() }?.let { d.day to it }
    }
}

private fun filterSleepMetricPoints(
    points: List<Pair<String, Double>>,
    range: SleepMetricRange,
): List<Pair<String, Double>> {
    val windowDays = range.days ?: return points
    val latestDate = points.lastOrNull()?.first?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        ?: return points.takeLast(windowDays.toInt())
    val cutoff = latestDate.minusDays(windowDays - 1)
    val filtered = points.filter { (day, _) ->
        runCatching { LocalDate.parse(day) }.getOrNull()?.let { !it.isBefore(cutoff) } ?: false
    }
    return filtered.ifEmpty { points.takeLast(windowDays.toInt()) }
}

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
            Text("Not enough history yet", style = NoopType.headline, color = Palette.textPrimary)
            Text(
                "This metric needs at least two nights of data.",
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
            Text("Not enough history in this range — try 3M, 6M, or ALL.", style = NoopType.subhead, color = Palette.textSecondary)
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
                    Text("as of ${latest.first}", style = NoopType.footnote, color = Palette.textTertiary)
                }
                Text(
                    "${spec.format(latest.second)} ${spec.unit}".trim(),
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
                    Text("${spec.format(maxV)} ${spec.unit}".trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("${spec.format(avgV)} ${spec.unit}".trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("${spec.format(minV)} ${spec.unit}".trim(), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                LineChart(
                    values = values,
                    modifier = Modifier.weight(1f).height(Metrics.chartHeight)
                        .semantics { contentDescription = "${spec.title} trend chart" },
                    color = spec.color,
                    fill = true,
                    selectionEnabled = true,
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
                            "${spec.format(v)} ${spec.unit}".trim(),
                            style = NoopType.captionNumber, color = Palette.textPrimary,
                        )
                    }
                }
            }
            Spacer(Modifier.height(Metrics.space8))
        }
    }
}
