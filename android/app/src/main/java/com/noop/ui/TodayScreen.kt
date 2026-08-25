package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Accessibility
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.automirrored.filled.BatteryUnknown
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MonitorWeight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.zIndex
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.app.DatePickerDialog
import android.content.Context
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.Baselines
import com.noop.analytics.BatteryEstimator
import com.noop.analytics.ChargeDriver
import com.noop.analytics.ChargeDriverLabel
import com.noop.analytics.ChargeDriverUnit
import com.noop.analytics.ChargeDriverVerdict
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.SleepMark
import com.noop.analytics.SleepMarkType
import com.noop.analytics.StepsEstimateEngine
import com.noop.analytics.StrainScorer
import com.noop.ble.WhoopModel
import com.noop.data.DailyMetric
import com.noop.data.HrBucket
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Calendar
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

@Composable
private fun DisplayText.localized(): String = when (this) {
    is DisplayText.Resource -> uiString(id, *args.toTypedArray())
    is DisplayText.Dynamic -> value
}

@Composable
private fun List<DisplayText>.localizedSourceList(): String {
    val labels = ArrayList<String>(size)
    for (label in this) labels += label.localized()
    return labels.joinToString(uiString(R.string.today_source_joiner))
}

/**
 * Control Center, the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics, each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the my-whoop source). Missing current-day values render as explicit
 * "No Data" states instead of raw dashes, so old imports do not look like today.
 */

/** Stable Today info-card ids (the dismissed-flag suffix + the inbox `restorePayload`). Match the
 *  iOS card ids so an export/import round-trips. */
private const val CARD_SCORES_BUILDING = "scoresBuilding"
private const val CARD_NEW_HERE = "newHere"
// #827: the "Building your baseline, N more nights" calibrating note is dismissible-into-the-inbox like
// the other Today info-cards, so a returning user who has read it once isn't nagged with it every day
// through the multi-night calibration window. Same id on both platforms so it round-trips an export/import.
private const val CARD_CALIBRATING = "calibratingBaseline"
// The "Latest sleep · <date>" / "Last night · <date>" carry-over note (ScoreState.CarriedLastNight). iOS
// has nothing in this slot, so on Android it's dismissible-into-the-inbox like the other Today info-cards:
// a small × tucks it into Updates (restorable), so it never sits permanently between the header and the
// hero throwing off the compact liquid look. Local-only id (iOS has no twin), matching the dismiss plumbing.
private const val CARD_CARRIED_SLEEP = "carriedSleep"

/** #860 item 1: process-lifetime guard for the launch snap-to-today. `selectedDayOffset` is rememberSaveable
 *  so a tab-away keeps the user's chosen day (#614/#739). The same persistence, however, rides the
 *  saved-instance-state bundle across a system-initiated process kill + restore (common after an app UPDATE),
 *  so a user who was browsing an OLD day when the process died - or a calibrating user the now-retired
 *  #605/#739 auto-land would have snapped to an old day - reopened the app pinned to that day instead of
 *  today. A top-level var = one value per LAUNCH (reset only on a genuine fresh process), so we run the pure
 *  `launchDayOffset` policy exactly once per launch (forcing today) and leave in-session tab-away/restore
 *  behaviour untouched. iOS parity: TodayView's selectedDayOffset is plain @State, which is never persisted
 *  and so already re-inits to 0 on every fresh launch, reaching the same offset through the same helper. */
private var todayDidSnapToTodayThisLaunch = false

// MARK: - Liquid hero tokens (the liquid Today restyle)
//
// The hero card the score vessels float on, ported from the iOS LiquidTodayView. `heroFill` is a
// translucent near-black (mock rgba(13,14,20,.80)) so it floats over the day-of-sky; the vessels + white
// count-up numbers read crisp on it. Radius 26 + a white@0.11 hairline give the frosted-glass edge.
private val LIQUID_HERO_RADIUS: Dp = 26.dp

// The Vitality vessel purple (#9b7bff) — no exact Palette token in this theme, so a fixed brand literal
// matching the iOS liquid Today's `liquidPurple` (Color(.sRGB, red:0x9b, green:0x7b, blue:0xff)). Used by
// the mini "Your cards" vessel so Vitality reads the same purple as iOS.
private val LIQUID_PURPLE: Color = Color(red = 0x9b / 255f, green = 0x7b / 255f, blue = 0xff / 255f, alpha = 1f)

/**
 * The minimal, stable slice of the BLE [com.noop.ble.LiveState] the Today top-level body reads. Pulled out
 * so a per-second heart-rate tick, which the body does not display numerically, produces an EQUAL value
 * and skips recomposing the whole dashboard (the redesign's scroll-jank fix). `hrStreaming` collapses the
 * ticking bpm to "is a live stream present" (the only thing the recording light needs); all other fields
 * change at most every few seconds. A plain data class so [androidx.compose.runtime.derivedStateOf] can
 * structurally-compare successive snapshots and emit only on a real change.
 */
private data class TodayLiveSnapshot(
    val connected: Boolean,
    val bonded: Boolean,
    val hrStreaming: Boolean,
    val lastSyncAt: Long?,
    val backfilling: Boolean,
    val syncChunksThisSession: Int,
    val historySyncExperimental: Boolean,
    val batteryPct: Double?,
    /** True once a WHOOP 5/MG strap has been seen this session, picks the 5/MG rated-life fallback for the
     *  battery runtime estimate (#713). Changes at most once per connection, so it doesn't reintroduce the
     *  per-tick churn the snapshot exists to avoid. */
    val whoop5: Boolean,
    /** Charging hides the runtime estimate (no "X left" while topping up). Rare flips, snapshot-safe. */
    val charging: Boolean?,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
@Suppress("UNUSED_PARAMETER")
fun TodayScreen(
    viewModel: AppViewModel,
    onQuickActions: () -> Unit = {},
    updateStore: UpdateStore? = null,
    onOpenUpdates: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    onOpenHydration: () -> Unit = {},
    // #706/#684: the "Your cards" dashboard rows are tappable on iOS but only Hydration navigated on Android.
    // These push each card's detail (Stress card -> Stress; Sleep -> Sleep), matching the iOS pinnedCardRow
    // destinations. Defaulted to no-ops so the call site stays compiling; AppRoot binds them to nav.navigate(...)
    // like onOpenHydration.
    onOpenStress: () -> Unit = {},
    onOpenHealth: () -> Unit = {},
    // Every metric/vital card (HRV, Resting HR, Respiratory, SpO₂, Skin Temp, Fitness age, Vitality, Steps,
    // Calories) opens ITS OWN focused detail trend, not the shared Health hub (2026-07-03: cards were
    // wrongly dumping into the Health monitor). Mirrors the iOS liquidCard `metricDetail(key)`. Takes the
    // vital_detail key; defaults to the Health screen so an unbound caller keeps the old behaviour.
    onOpenMetric: (String) -> Unit = { onOpenHealth() },
    // A blank WHOOP 4.0 Steps tile can open calibration directly (#1515). AppRoot binds this to the same
    // nested destination Settings uses; other Steps states continue through [onOpenMetric].
    onOpenStepsCalibration: () -> Unit = {},
    onOpenSleep: () -> Unit = {},
    // Optional Coupled view card (task #43): a tap-through to the WHOOP-style day screen. Defaulted to a
    // no-op so the call site stays compiling; AppRoot binds it to nav.navigate(CoupledView).
    onOpenCoupled: () -> Unit = {},
    // The "workout in progress" indicator card routes to Live and re-opens the in-exercise overlay. Defaulted
    // to a no-op so the call site stays compiling; AppRoot binds it to openActiveWorkout() + nav.navigate(Live).
    onOpenActiveWorkout: () -> Unit = {},
    // The liquid header battery ring taps through to Devices (iOS parity: the battery ring → router.openDevices()).
    // Defaulted to fall back to Settings so the call site stays compiling; AppRoot binds it to the Devices route.
    onOpenDevices: () -> Unit = onOpenSettings,
    // The #627 journal-reminder card links straight to the journal (Insights). Defaulted to a no-op so
    // the call site stays compiling; AppRoot binds it to nav.navigateTopLevel(Insights), same as Sleep.
    onOpenJournal: () -> Unit = {},
) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val spo2CandidateByDay by viewModel.spo2CandidateByDay.collectAsStateWithLifecycle()
    val v5Signals by viewModel.v5Signals.collectAsStateWithLifecycle()
    val cycleEnabled by viewModel.cycleTrackingEnabled.collectAsStateWithLifecycle()
    val cycleHidden by viewModel.cycleAwarenessHidden.collectAsStateWithLifecycle()
    val periodStarts by viewModel.periodStarts.collectAsStateWithLifecycle()
    var showCycleTracker by remember { mutableStateOf(false) }
    val live by viewModel.live.collectAsStateWithLifecycle()
    // The in-flight manual workout (single source of truth, survives an app kill via rehydration), so the
    // indicator card auto-appears/clears off this alone. Null↔non-null + the start drive the card; the
    // per-second clock ticks inside the card's own LaunchedEffect, never recomposing the Today body.
    val activeWorkout by viewModel.activeWorkout.collectAsStateWithLifecycle()
    // PERF (#scroll-jank): the BLE live state ticks the heart rate roughly once a second. Reading the raw
    // `live` object directly in this top-level body would recompose the ENTIRE Today tree (rings, cards,
    // scene-positioning) on every bpm change, visible as scroll stutter on real devices. The body only
    // needs a handful of stable, slow-changing fields, and the live HR matters here only as "is a stream
    // present" (null↔non-null), never the bpm number. Funnel those through a `derivedStateOf` snapshot so a
    // 72→73 bpm tick produces an EQUAL snapshot and the body is NOT recomposed; it only recomposes when
    // connection / sync / battery / streaming-presence actually change. The live bpm number is rendered
    // elsewhere (HeartRateTrendCard), which scopes its own collection. Appearance-preserving.
    val liveSnap by remember {
        derivedStateOf {
            val s = live
            TodayLiveSnapshot(
                connected = s.connected,
                bonded = s.bonded,
                hrStreaming = s.heartRate != null,
                lastSyncAt = s.lastSyncAt,
                backfilling = s.backfilling,
                syncChunksThisSession = s.syncChunksThisSession,
                historySyncExperimental = s.historySyncExperimental,
                batteryPct = s.batteryPct,
                whoop5 = s.whoop5Detected,
                charging = s.charging,
            )
        }
    }
    // #849: seed from the ViewModel cache so a re-mount (tab-return / post-import) restores the last footer
    // immediately instead of flashing empty while the heavy reload is (now) skipped for unchanged data.
    var footer by remember { mutableStateOf(viewModel.todayFooterCache ?: TodayFooterState()) }
    // rememberSaveable (not plain remember): the bottom-tab NavHost (AppRoot) navigates with
    // saveState/restoreState, which only restores rememberSaveable-backed state. With plain remember a
    // tab-away wiped the chosen day back to 0, so on return the dashboard "shifted" off the day the user was
    // looking at (#614 follow-up). Persisting it across the save/restore keeps the chosen day put. The
    // launch snap-to-today is a separate process-lifetime flag (todayDidSnapToTodayThisLaunch below).
    var selectedDayOffset by rememberSaveable { mutableIntStateOf(0) }
    // #860 item 1: on a GENUINE fresh process (not a tab-away/recomposition), force the selected day back to
    // today via the pure `launchDayOffset` policy. rememberSaveable restores selectedDayOffset from the
    // saved-instance-state bundle, which the system reuses across a process kill + restore (the after-an-update
    // case in the report); without this, a user who was viewing an old day when the process died - OR a
    // calibrating user the retired auto-land would have snapped to an old day - reopened the app stranded
    // there. The top-level guard is false exactly once per launch, so `launchDayOffset(isFreshLaunch = true)`
    // forces today a single time and never fights the in-session tab-away day-memory (#614/#739) afterwards.
    // Done in composition (not a LaunchedEffect) so the stale restored day never paints for a frame. iOS uses
    // plain @State (re-inits to 0 every launch) and reaches the same offset through the same helper.
    if (!todayDidSnapToTodayThisLaunch) {
        todayDidSnapToTodayThisLaunch = true
        val landed = launchDayOffset(
            isFreshLaunch = true,
            savedOffset = selectedDayOffset,
            hasTodayData = today != null,
            latestDataDayBack = selectedDayOffset,
        )
        if (selectedDayOffset != landed) selectedDayOffset = landed
    }
    // Anchor offset-0 to the LOGICAL day (rolls at 04:00 local), so between midnight and 4am "Today"
    // still resolves to the prior calendar day's banked row instead of an empty new-calendar-day row
    // that blanks the dashboard (#144). Past offsets count back from this anchor. Presentation-only.
    val todayDate = logicalDayNow()
    // #860 item 1: the launch auto-land (#605/#739 "snap to the most recent data day when today is empty")
    // is RETIRED. It fired on a fresh process when today had no row yet, and for a calibrating user whose
    // newest data was a few days back it stranded them on that old day, overriding the snap-to-today above.
    // A fresh launch now lands on today via `launchDayOffset` (the inline guard above), and in-session day
    // memory (#739/#614) is preserved because nothing rewrites `selectedDayOffset` after launch. iOS parity
    // in TodayView (which retired the same block).
    val selectedDay = remember(selectedDayOffset, todayDate) { todayDate.minusDays(selectedDayOffset.toLong()) }
    // The key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    // follows the resolver's `today?.day` so it tracks the row actually surfaced, including the non-UTC
    // pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one. Falls
    // back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    val selectedDayKey = remember(selectedDay, today, selectedDayOffset) {
        if (selectedDayOffset == 0) today?.day ?: selectedDay.toString() else selectedDay.toString()
    }
    val historicalMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val displayMetric = remember(today, historicalMetric, selectedDayOffset) {
        if (selectedDayOffset == 0) today ?: historicalMetric else historicalMetric
    }
    // Keep the explicit calendar date visible alongside Today/Yesterday so the logical-day remap stays
    // honest, between midnight and 04:00 "Today" still points at the prior calendar date, and showing
    // that date makes it obvious which day's row is on screen (#144).
    val dayLabel = run {
        // Date the label by the row ACTUALLY on screen, not the raw logical date. `selectedDayKey` already
        // follows the resolver's `today?.day` at offset 0, so when the resolver surfaces yesterday's
        // complete row (today not scored yet) the date now reads that row's day, instead of stamping
        // "Today · <today>" over yesterday's values, which disagreed with the Intelligence History row for
        // the same data (#434). iOS/Mac already label by the shown row's day; this brings Android to parity.
        val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
        val date = keyDate.format(DateTimeFormatter.ofPattern("EEE, d MMM", Locale.getDefault()))
        when (selectedDayOffset) {
            0 -> uiString(R.string.today_day_with_date, date)
            1 -> uiString(R.string.today_yesterday_with_date, date)
            else -> date
        }
    }
    // Display-only unit system + the SI profile weight, read once like every other Settings-backed
    // preference (SharedPreferences isn't reactive, a Settings write triggers recomposition).
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    // Effort display scale (#268), drives the Effort tile's value + caption. Display-only.
    val effortScale = UnitPrefs.effortScale(context)
    val profileWeightKg = remember { ProfileStore.from(context).weightKg }
    // Body profile for the live Effort computation below, age/sex/HR-max-override drive the same
    // StrainScorer call the daily pass uses. Read once like every other Settings-backed value. (#402)
    val profileStore = remember { ProfileStore.from(context) }

    // Editable Key-Metrics layout (#251), an ordered list of the enabled tiles, persisted display-only.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showMetricsEditor by remember { mutableStateOf(false) }
    var enabledKeyMetrics by remember { mutableStateOf(KeyMetricPrefs.enabled(context)) }
    // Detailed Key-Metrics tiles (squarer + trend graph), set from the same editor, plus the chosen
    // trend window (1 week / 2 weeks / 1 month) the detailed graphs cover.
    var keyMetricsDetailed by remember { mutableStateOf(KeyMetricPrefs.detailed(context)) }
    var keyMetricsWindowDays by remember { mutableStateOf(KeyMetricPrefs.detailWindowDays(context)) }
    // #today-layout: the user-ordered below-hero section list + its editor dialog flag. Read once (prefs
    // aren't reactive) and re-read on the editor's save, exactly like enabledKeyMetrics above.
    var showLayoutEditor by remember { mutableStateOf(false) }
    var sectionOrder by remember { mutableStateOf(TodayLayoutPrefs.order(context)) }
    var hiddenSections by remember { mutableStateOf(TodayLayoutPrefs.hidden(context)) }
    // #today-layout (hold-to-drag): the hoisted list state (the drag math needs layoutInfo + scrollBy) and
    // the live drag state. The frame loop below runs ONLY while a section is lifted: each frame it retries
    // the swap (so a card held still at a viewport edge keeps reordering as the list scrolls under it —
    // onDrag alone only fires while the finger moves) and applies the edge auto-scroll velocity that
    // TodayReorderableSection's onDrag computed.
    val todayListState = rememberLazyListState()
    val sectionDrag = remember { TodaySectionDragState() }
    val sectionDragActive = sectionDrag.key != null
    LaunchedEffect(sectionDragActive) {
        // Auto-scroll is TIME-based (px/second × real frame delta), not per-frame: a per-frame step runs
        // twice as fast on a 120 Hz panel and reads as jarring — the first on-device feedback. dt is
        // clamped so a dropped/backgrounded frame can't produce one giant jump.
        var lastFrameNanos = 0L
        while (sectionDrag.key != null) {
            val frameNanos = withFrameNanos { it }
            val dtSec = if (lastFrameNanos == 0L) 0f
            else ((frameNanos - lastFrameNanos) / 1_000_000_000f).coerceAtMost(0.05f)
            lastFrameNanos = frameNanos
            swapTargetForDraggedSection(todayListState, sectionDrag, sectionOrder)?.let { (dragged, target) ->
                // Freeze the scroll anchor across the reorder. LazyColumn re-anchors the viewport to the
                // FIRST VISIBLE item's key — when a swap involves that item (usual while dragging near the
                // top of the screen), the whole content leaps by the two cards' height difference in a
                // single frame (the on-device "not smooth with other cards" report). Re-pinning the same
                // positional index+offset around the move keeps the viewport still; a swap far below the
                // anchor re-pins to the identical spot (visual no-op).
                val anchorIndex = todayListState.firstVisibleItemIndex
                val anchorOffset = todayListState.firstVisibleItemScrollOffset
                sectionOrder = sectionOrder.movedTodaySection(dragged, target)
                todayListState.scrollToItem(anchorIndex, anchorOffset)
            }
            if (sectionDrag.autoScrollPxPerSecond != 0f && dtSec > 0f) {
                todayListState.scrollBy(sectionDrag.autoScrollPxPerSecond * dtSec)
            }
        }
    }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard"), a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only, these cards read the SAME values the rest of Today already loads.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showDashboardEditor by remember { mutableStateOf(false) }
    var enabledDashboardCards by remember { mutableStateOf(DashboardCardPrefs.enabled(context)) }
    // #today-hosted-cards: the Trends/Sleep cards hosted in Today (empty/opt-in). Mirrored into local
    // state like the dashboard selection and re-read when the hosted-cards editor saves.
    var showHostedEditor by remember { mutableStateOf(false) }
    var enabledHostedCards by remember { mutableStateOf(HostedCardPrefs.enabled(context)) }

    // The pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced on Today so the buried
    // Explore features sit on the home screen (#582). The same merged resolvedSeries reads their detail
    // screens use; null simply renders a dash on that card. Mirror the iOS Today lane's stressToday /
    // fitnessAgeToday / vitalityToday loads (last resolved value over all history). Loaded off the main
    // thread; re-read as the data grows.
    // #849: seed from the ViewModel cache so a re-mount restores the pinned-card numbers instead of flashing
    // dashes while the heavy history-wide read is (now) skipped for unchanged data.
    var stressToday by remember { mutableStateOf(viewModel.todayStressCache) }
    var fitnessAgeToday by remember { mutableStateOf(viewModel.todayFitnessAgeCache) }
    var vo2maxToday by remember { mutableStateOf(viewModel.todayVo2maxCache) }
    var vitalityToday by remember { mutableStateOf(viewModel.todayVitalityCache) }
    LaunchedEffect(days) {
        // #849 re-mount guard: skip the whole-history scan when `days` is content-identical to the last load
        // (data class hashCode is a stable structural signature). The marker + cached values live on the
        // long-lived ViewModel, so a tab-return / post-import re-mount restores the numbers without re-reading.
        val sig = days.hashCode()
        if (viewModel.todayCardsLoadedSig == sig) return@LaunchedEffect
        // Read each pinned card from the SAME source its own detail screen reads, the proven path that
        // already shows real numbers there (and the resolution iOS's exploreSeries uses). Stress is derived
        // from the imported strap data (StressScreen reads "my-whoop"); Fitness age + Vitality are
        // NOOP-COMPUTED weekly scores the IntelligenceEngine writes under "<activeStrapId>-noop". Read them
        // through the computed UNION (active strap's sibling + canonical "my-whoop-noop"), the same helper
        // HealthScreen uses — a hardcoded "my-whoop-noop" misses a live-BLE strap's "whoop-<mac>-noop" (#349).
        // Take the latest value (series are day-ascending), null → the card shows a dash, never a fabricated number.
        // #753: build the SAME StressModel the detail screen (StressScreen) shows and take `model.score`,
        // rather than the stress series' last banked row. StressModel.build prefers today's stored stress row
        // but otherwise DERIVES today's score from the live `days` RHR/HRV baseline; the old `.lastOrNull()`
        // read returned the latest *banked* day, so on a day with no stored stress row the pinned card sat on
        // yesterday's number (e.g. "2") while the detail page moved on. Reading the stored series the same way
        // StressScreen does (day → value, clamped 0–3) and feeding the same `days` ties the two together; both
        // recompute off `days`, so the pinned card stays in sync. null (no usable signal) keeps the honest
        // "Calibrating" placeholder, matching StressScreen's empty state.
        stressToday = runCatching {
            val stored = viewModel.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
                .associate { it.day to it.value.coerceIn(0.0, 3.0) }
            StressModel.build(days, stored)?.score
        }.getOrNull()
        fitnessAgeToday = runCatching {
            viewModel.repo.latestMetricComputedUnion(viewModel.activeStrapId, "fitness_age")?.value
        }.getOrNull()
        vo2maxToday = runCatching {
            viewModel.repo.latestMetricComputedUnion(viewModel.activeStrapId, "vo2max_est")?.value
        }.getOrNull()
        vitalityToday = runCatching {
            viewModel.repo.latestMetricComputedUnion(viewModel.activeStrapId, "vitality")?.value
        }.getOrNull()
        // Cache the computed triple + signature so a later re-mount with unchanged data restores them and
        // short-circuits the history-wide read above.
        viewModel.todayStressCache = stressToday
        viewModel.todayFitnessAgeCache = fitnessAgeToday
        viewModel.todayVo2maxCache = vo2maxToday
        viewModel.todayVitalityCache = vitalityToday
        viewModel.todayCardsLoadedSig = sig
    }

    // #713, strap battery runtime estimate ("~X left") for the Data-sources battery row. The battery lane
    // banks a SoC time series; here we read it and run the SHARED BatteryEstimator (the iOS twin computes the
    // same value off LiveState.batteryEstimate). Rated-life fallback is chosen by strap generation: WHOOP 5/MG
    // gets the ~12-day figure, WHOOP 4.0 the ~4.5-day one. Recomputed when the banked series grows (a new
    // reading lands ~every 8 min), when the link comes/goes, or when the strap generation resolves. Charging
    // hides it (no "X left" while topping up); a too-short discharge run returns null and the badge shows just
    // the %. Display rule: hours < 48 -> "~Nh left", else "~N days left"; null hides the estimate.
    var batteryEstimateText by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(liveSnap.connected, liveSnap.batteryPct, liveSnap.whoop5, liveSnap.charging) {
        batteryEstimateText = if (!liveSnap.connected || liveSnap.charging == true) {
            null
        } else {
            runCatching {
                val now = System.currentTimeMillis() / 1000
                // A wide window: SoC readings are sparse (~8 min apart), so a few days back is plenty for the
                // estimator to find the trailing discharge run and still cheap to load.
                val from = now - 14L * 86_400
                // #1304/#512: a 2nd active strap banks its SoC under "whoop-<uuid>", so a "my-whoop" read
                // returned empty and the runtime estimate went blank. Read the active strap's own battery.
                val samples = viewModel.repo.batterySamples(viewModel.activeStrapId, from, now, limit = 2_000)
                    .mapNotNull { s -> s.soc?.let { s.ts to it } }
                val rated = if (liveSnap.whoop5) BatteryEstimator.ratedLifeHoursWhoop5
                            else BatteryEstimator.ratedLifeHoursWhoop4
                // Battery test mode (Test Centre #713): emit the discharge-run / fitted-slope / gate ANALYSIS
                // trace, not only the per-reading "bank soc=" line. This LaunchedEffect re-runs on a natural
                // throttle (battery% / connection / charging changes), never a tight loop, and reuses the
                // samples + rated just loaded, so there is no extra Room read. estimateTrace returns the SAME
                // Estimate the badge shows, so no displayed number changes. Gated zero-cost when the mode is off
                // (one SharedPreferences bool read) and routed to the .battery-tagged strap log via externalLog.
                if (com.noop.testcentre.TestCentre.from(context)
                        .active(com.noop.testcentre.TestDomain.BATTERY)) {
                    for (line in BatteryEstimator.estimateTrace(samples, rated).second) {
                        viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.BATTERY)
                    }
                }
                BatteryEstimator.estimate(samples, rated)?.let { est ->
                    val hours = est.hoursRemaining
                    if (!hours.isFinite() || hours <= 0.0) null
                    else if (hours < 48) context.resources.getQuantityString(
                        R.plurals.today_strap_hours_left, hours.roundToInt(), hours.roundToInt(),
                    )
                    else {
                        val daysLeft = (hours / 24).roundToInt()
                        context.resources.getQuantityString(
                            R.plurals.today_strap_days_left, daysLeft, daysLeft,
                        )
                    }
                }
            }.getOrNull()
        }
    }

    // #616: ONE calorie definition across the card, the Key-Metrics tile and the detail — resolve per day,
    // IMPORTED-FIRST (the phone's Apple/Health-Connect activeKcal, the figure these surfaces already showed),
    // falling back to NOOP's on-device HR estimate (activeKcalEst) only for days the phone didn't cover.
    // Keyed by day; `caloriesByDay` feeds the SELECTED-day value the dashboard card + Key-Metrics tile both
    // read — day-scoped like every other card, and like steps.
    var caloriesByDay by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    LaunchedEffect(days) {
        caloriesByDay = runCatching {
            val onDevice = viewModel.repo.resolvedSeries("active_kcal", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = viewModel.activeStrapId).points.associate { it.day to it.value }
            val imported = LinkedHashMap<String, Double>()
            for (r in viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31") +
                viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31")) {
                r.activeKcal?.takeIf { it > 0 }?.let { imported.putIfAbsent(r.day, it) }
            }
            (onDevice.keys + imported.keys)
                .mapNotNull { day -> (imported[day] ?: onDevice[day])?.let { day to it } }.toMap()
        }.getOrDefault(emptyMap())
    }

    // #616: the Calories tile's 14-day sparkline — the IMPORTED-FIRST resolved series (caloriesByDay),
    // windowed to the trailing calendar window, so a Health-Connect / Apple-only calorie user gets a trend
    // that matches the tile's value (not the on-device estimate alone). Mirrors restCompositeSpark's build.
    var caloriesSpark by remember { mutableStateOf<List<Double>>(emptyList()) }
    LaunchedEffect(caloriesByDay, selectedDay, keyMetricsWindowDays) {
        val cutoff = selectedDay.minusDays((keyMetricsWindowDays - 1).toLong()).toString()
        val end = selectedDay.toString()
        caloriesSpark = caloriesByDay.entries
            .filter { it.key in cutoff..end }
            .sortedBy { it.key }
            .map { it.value }
    }

    // HYDRATION (opt-in, default OFF), the Today "Hydration" card + its detail are hidden unless the user
    // turns Hydration tracking on in Settings. When on, the card reads today's logged total (ml, from the
    // local-only HydrationStore series) against the pure HydrationGoal (sex baseline + today's Effort bump).
    // Both are loaded off the main thread and re-read as the day's data grows; SharedPreferences isn't
    // reactive, so the toggle is read once into local state.
    val hydrationEnabled = remember { NoopPrefs.hydrationTracking(context) }
    // Day-cycle scene backdrop (#698). Default ON. When off, Today drops the SceneScreenBackground and
    // the scaffold paints the plain dark surface canvas instead. SharedPreferences isn't reactive, so
    // this is read once into local state (mirrors iOS @AppStorage in TodayView).
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    // "Sky behind cards" (opt-in, default OFF): extend the day-cycle sky behind the WHOLE scroll so the
    // Card-transparency slider reveals it under every card (no effect when the scene is off). Read once.
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    var hydrationTotalMl by remember { mutableStateOf(0.0) }
    // #989: `days` only changes on a data refresh, which a hydration write never causes, so the card sat
    // stale after logging a drink until an unrelated sync landed. Keying on the store's mutationSeq too
    // re-reads the one metric row the moment a drink is logged / edited / deleted. Mirrors the iOS
    // Repository.hydrationSeq trigger.
    val hydrationSeq by HydrationStore.mutationSeq.collectAsStateWithLifecycle()
    LaunchedEffect(days, hydrationEnabled, hydrationSeq) {
        hydrationTotalMl = if (hydrationEnabled) {
            runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0)
        } else 0.0
    }
    // The day's Effort/strain (0..100) drives the goal's effort bump. Prefer the live in-progress Effort
    // for today (floored at the stored value, mirroring the Effort gauge) so the goal reflects a hard day
    // as it accrues; null leaves the bump at 0. Computed below where liveTodayStrain is in scope.
    val hydrationGoalMl = remember(displayMetric, profileStore) {
        if (!hydrationEnabled) 0 else HydrationGoal.dailyGoalMl(profileStore.sex, displayMetric?.strain)
    }

    // "How your scores work" guide, opened from the per-score ⓘ affordances and the one-time
    // first-run card. `guideSection` carries which score to deep-link to (null = open at the top);
    // `showGuide` gates the presenting Dialog. The first-run card's seen-state lives in
    // ScoringGuidePrefs and is read once (SharedPreferences isn't reactive), then driven locally.
    var showGuide by remember { mutableStateOf(false) }
    var guideSection by remember { mutableStateOf<ScoreSection?>(null) }
    val openGuide: (ScoreSection?) -> Unit = { section ->
        guideSection = section
        showGuide = true
    }
    // A1 (#514/#706): the Charge breakdown sheet, opened by tapping the hero Charge ring. Hosts the
    // existing RecoveryDriversSection (gated to the calibration countdown when the night can't score) plus
    // the folded Readiness card (S4). Not persisted, so it reopens closed. Mirrors iOS showChargeBreakdown.
    var showChargeBreakdown by remember { mutableStateOf(false) }
    // LIVE SESSIONS (beta, default ON): the "Start session" entry under the hero + its full-screen Dialog
    // (the same presentation the live-workout overlay / Charge breakdown use — deliberately NOT a nav
    // destination, so dismissing it leaves the session's runner coaching and this entry is the way back
    // in). Gated on the Settings `live_sessions_beta` flag; SharedPreferences isn't reactive, so it's read
    // once into local state like the hydration/day-cycle gates above. The ACTIVE runner is also collected
    // here (null ↔ runner only — the per-second snapshot is scoped inside the entry card) so a running
    // session keeps its way-back-in card even if the beta flag was just switched off.
    var showLiveSession by remember { mutableStateOf(false) }
    val liveSessionsEnabled = remember { LiveSessionPrefs.enabled(context) }
    val activeLiveSession by LiveSessionRunner.active.collectAsStateWithLifecycle()
    // The journal widget's own opt-out (default ON). Read here too so its reorderable section emits no
    // item when disabled — an always-present zero-height slot would leave a blank draggable gap. Same
    // remember-once idiom the card uses; a resume/recompose re-reads it. (#656)
    val journalReminderOn = remember { NoopPrefs.journalReminderEnabled(context) }
    // S4: the Synthesis card collapses to a one-liner that expands on tap (default collapsed). Mirrors iOS.
    var synthesisExpanded by remember { mutableStateOf(false) }
    // S5: the Key Metrics grid caps at the first METRICS_COLLAPSED_CAP tiles behind a "Show all metrics"
    // expander, and the Data Sources footer collapses to a single "Synced from: ..." line. Both default
    // collapsed and are NOT persisted, so the home screen reopens compact. Mirrors iOS.
    var metricsExpanded by remember { mutableStateOf(false) }
    var sourcesExpanded by remember { mutableStateOf(false) }

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // via the shared TodayCardDismissal key. Read once (SharedPreferences isn't reactive), driven locally.
    var scoresBuildingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_SCORES_BUILDING))
    }
    var newHereDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_NEW_HERE))
    }
    // #827: the calibrating note's own dismissed flag, read once from the same shared store.
    var calibratingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_CALIBRATING))
    }
    // The carried "Latest sleep · <date>" note's dismissed flag (iOS has no such card; on Android it's
    // dismissible so it doesn't sit permanently above the hero and break the compact look). Read once.
    var carriedSleepDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_CARRIED_SLEEP))
    }
    // Dismiss a Today info-card INTO the inbox: persist its flag, hide it, and post a restorable
    // `.dismissedCard` update carrying the card id. Mirrors the iOS `dismissTodayCard`.
    val dismissTodayCard: (String, String, String) -> Unit = { id, title, message ->
        TodayCardDismissal.setDismissed(context, id, true)
        when (id) {
            CARD_SCORES_BUILDING -> scoresBuildingDismissed = true
            CARD_NEW_HERE -> newHereDismissed = true
            CARD_CALIBRATING -> calibratingDismissed = true
            CARD_CARRIED_SLEEP -> carriedSleepDismissed = true
        }
        updateStore?.post(
            UpdateItem(
                kind = UpdateKind.DISMISSED_CARD,
                title = title,
                message = message,
                restorePayload = id,
            ),
        )
    }
    // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the card
    // reappears (the inbox also cleared the shared pref directly, but this re-reads it into local state
    // for an already-mounted Today). Cleared once handled. Mirrors the iOS restoreRequest observer.
    val restoreSignal = updateStore?.restoreRequest
    LaunchedEffect(restoreSignal) {
        if (updateStore != null && restoreSignal != null) {
            when (restoreSignal) {
                CARD_SCORES_BUILDING -> scoresBuildingDismissed = false
                CARD_NEW_HERE -> newHereDismissed = false
                CARD_CALIBRATING -> calibratingDismissed = false
                CARD_CARRIED_SLEEP -> carriedSleepDismissed = false
            }
            updateStore.restoreRequest = null
        }
    }

    // Announce NEW history to the inbox only when the NEWEST day-key (max yyyy-MM-dd) moves strictly
    // forward, not on a count change (#521). A background recompute rebuilds the window via
    // delete-then-reinsert, so the count momentarily dips and recovers while the newest key is unchanged
    //, keying off the count mistook that churn for new history and re-posted "New data added" on a
    // loop. The baseline is PERSISTED in SharedPreferences (not `remember`), so a relaunch over the same
    // history never re-announces. Empty baseline = first sight → record silently, never announce
    // historical data. The "added" count is the distinct days strictly above the old watermark, real,
    // never fabricated. Deep-links to Trends. Mirrors the Swift `announceNewDaysIfNeeded`.
    LaunchedEffect(days, updateStore) {
        val store = updateStore ?: return@LaunchedEffect
        val newestKey = days.maxOfOrNull { it.day } ?: return@LaunchedEffect   // no history yet
        val previousKey = NewDataWatermark.lastAnnouncedKey(context)
        NewDataWatermark.setLastAnnouncedKey(context, newestKey)
        if (previousKey.isEmpty()) return@LaunchedEffect            // first sight → silent baseline
        if (newestKey <= previousKey) return@LaunchedEffect         // recompute churn, not new history
        val added = days.map { it.day }.toSet().count { it > previousKey }
        if (added <= 0) return@LaunchedEffect
        store.post(
            UpdateItem(
                kind = UpdateKind.READING,
                title = uiString(R.string.l10n_today_screen_new_data_added_e59345b4),
                message = context.resources.getQuantityString(
                    R.plurals.today_new_history_ready, added, added,
                ),
                deepLink = "trends",
            ),
        )
    }

    // The newest Apple Health / Health Connect body weight, loaded off the main thread. Null until the
    // load runs or when neither source carries a weight, the Weight tile then falls back to the profile.
    var weightKg by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        weightKg = latestWeightKg(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
        )
    }

    // Steps for the selected day from imported Apple Health / Health Connect data, the Today Steps
    // tile's fallback when the strap itself didn't bank an on-device count. A WHOOP 4.0 DOES count
    // steps (in the official WHOOP app), but NOOP can't yet read them off the strap over Bluetooth, so
    // on a 4.0 the tile shows your imported steps instead of "No Data". Reloads as the day selector
    // moves. On-device WHOOP 5/MG steps still take precedence. (#150)
    var importedStepsForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        // Today's steps keep moving after the manual one-shot HC import, so the stored row goes
        // stale within minutes, top it up with ONE live StepsRecord read before the stored-row
        // read below. Best-effort: any HC hiccup just falls through to whatever is stored. (#150)
        if (selectedDayOffset == 0) {
            try {
                HealthConnectImporter.refreshTodaySteps(context, viewModel.repo)
            } catch (_: Exception) { /* best-effort */ }
        }
        importedStepsForDay = stepsForDay(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
            selectedDayKey,
        )
    }

    // On-device steps ESTIMATE for the selected day (key "steps_est", computed "-noop" source). The
    // Steps tile prefers a REAL step count (strap @57 counter / imported Health Connect); only when a
    // day has NEITHER does it fall back to this estimate, shown with an "est." caption so it's never read
    // as a measured count. resolvedSeries reads the computed source for the my-whoop key, exactly like
    // the Explore "steps_est" metric. Null until loaded / no estimate for the day. (#150)
    var stepsEstForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("steps_est", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = viewModel.activeStrapId)
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        stepsEstForDay = byDay[selectedDayKey]?.let { Math.round(it).toInt() }
    }

    // The selected day's representative activity class for the Steps tile icon (#316 / @63). Reads the day's
    // step samples (now carrying `activityClass` after the v13 column) over the local-day window and takes the
    // LAST non-null class as "what the wrist was doing most recently today" (0=still, 1=walk, 2=run). null when
    // the day has no classed sample (a 4.0 strap, a pre-v13 row, or every record's @63 byte was invalid), then
    // the tile shows NO icon. Mirrors the iOS Today step-activity read exactly. Best-effort: a read hiccup just
    // drops the optional icon.
    var stepActivityClassForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDay, today) {
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDayOffset == 0) now else (nextStart - 1)
        // #908 family: read the active strap ∪ canonical "my-whoop" union, NOT a hardcoded "my-whoop". A strap
        // re-added through the device manager banks its live step samples (which carry the @63 class) under its
        // own fresh id, so a pinned "my-whoop" read dropped the tile icon for a re-added strap. Single-WHOOP ⇒
        // one id ⇒ byte-identical read. Mirrors the iOS Repository.stepActivityClassLatest union.
        stepActivityClassForDay = runCatching {
            viewModel.repo.stepActivityClassLatestUnion(viewModel.activeStrapId, start, end)
        }.getOrNull()
    }

    // The Rest SCORE (0–100) for the selected day, IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series. The Key-Metrics "Rest" tile shows THIS, with hours-in-bed kept
    // as the caption; the tile previously showed hours where the score belonged (#248). resolvedSeries
    // merges imported + computed sleep_performance (imported-wins), so an importer sees the export's
    // figure and a Bluetooth-only user sees the on-device composite. Null until loaded / no night yet.
    var restScoreForDay by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, selectedDayKey, selectedDayOffset) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = viewModel.activeStrapId)
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        // #977: the tail-fallback (latest scored night) is now freshness-gated. A live 5.0 whose sleep never
        // scores used to pin Rest to the weeks-old series tail forever while Charge advanced; if that tail is
        // stale, fall through to null so the Rest ring shows its needs-a-tracked-night state instead of a
        // frozen number. `selectedDayKey` is today's key at offset 0, so it anchors the freshness check.
        val latest = byDay.entries.maxByOrNull { it.key }
        restScoreForDay = freshRestScore(
            todayValue = byDay[selectedDayKey], lastDay = latest?.key, lastValue = latest?.value,
            isTodaySelected = selectedDayOffset == 0, today = selectedDayKey)
    }

    // The Rest tile's SPARKLINE series (#614 follow-up). The Rest tile's NUMBER is the Rest composite
    // (0–100) from `sleep_performance` above, but its mini-graph used to plot raw sleep MINUTES
    // (`w.sleepMin`), so the trend line didn't track the score it sat under. Build the SAME 0–100
    // `sleep_performance` series here, windowed to the trailing 14 calendar days ending on the selected
    // day (oldest → newest, nulls dropped, mirrors remember14's windowing of the DailyMetric series), and
    // feed it to the Rest tile instead. Now the sparkline tracks the Rest score. Empty until loaded.
    var restCompositeSpark by remember { mutableStateOf<List<Double>>(emptyList()) }
    LaunchedEffect(days, selectedDay, keyMetricsWindowDays) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = viewModel.activeStrapId)
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        val cutoff = selectedDay.minusDays((keyMetricsWindowDays - 1).toLong()).toString()
        val end = selectedDay.toString()
        restCompositeSpark = byDay.entries
            .filter { it.key in cutoff..end }
            .sortedBy { it.key }
            .map { it.value }
    }

    // Provenance (COMPONENT 4): the REAL per-metric merge winner for the selected day's three hero scores,
    // keyed by metric key ("recovery" / "strain" / "sleep_performance"); each value is the RAW source id the resolver
    // returned (e.g. "my-whoop", "my-whoop-noop", "apple-health"). resolvedSeries applies the SAME
    // imported-WHOOP > NOOP-computed > Apple-Health precedence the dashboard merge uses field-by-field
    // (WhoopRepository.mergeDaily), then computed rows resolve through durable input provenance so the
    // card-level badge names the sensor/import providers rather than where NOOP ran the math.
    var providerByMetric by remember { mutableStateOf<Map<String, ScoreInputProvider>>(emptyMap()) }
    LaunchedEffect(days, selectedDayKey, viewModel.activeStrapId) {
        val resolved = mutableMapOf<String, ScoreInputProvider>()
        for (key in listOf("recovery", "strain", "sleep_performance")) {
            val win = runCatching {
                viewModel.repo.resolvedSeries(key, "my-whoop", selectedDayKey, selectedDayKey,
                    strapDeviceId = viewModel.activeStrapId)
                    .points.lastOrNull { it.day == selectedDayKey }
            }.getOrNull()
            if (win != null) {
                viewModel.scoreInputProvider(win.source, win.day, key)?.let {
                    resolved[key] = it
                }
            }
        }
        providerByMetric = resolved
    }

    // LIVE in-progress Effort for TODAY (#402), mirrors the iOS TodayView live-Effort fix. The stored
    // `day?.strain` lags: early in the day it shows yesterday's completed Effort (or a stale 0.0) until the
    // heavy daily pass re-scores. So for offset 0 only, integrate today's raw HR over the SAME window the
    // HR trend uses (the logical day's local-midnight → now) through StrainScorer with the SAME params the
    // daily pass persists (Tanaka HR-max from age, or the manual override, the day's resting HR else the
    // default, profile sex), and prefer it on the Effort gauge. StrainScorer returns null below
    // `minReadings`, so before there's enough HR the gauge falls back to the stored value and never shows a
    // fabricated number. Any past day → null (the gauge uses the stored strain). Keyed on the same inputs
    // as the day-scoped loads so it reloads as the selector moves and as a sync/import grows the HR window.
    var liveTodayStrain by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, selectedDayKey, selectedDayOffset) {
        liveTodayStrain = if (selectedDayOffset == 0) {
            val zone = ZoneId.systemDefault()
            val start = selectedDay.atStartOfDay(zone).toEpochSecond()
            val now = System.currentTimeMillis() / 1000
            // #908: read the active strap ∪ canonical "my-whoop" union, NOT a hardcoded "my-whoop". A strap
            // re-added through the device manager banks its live HR under its own fresh id, so a pinned
            // "my-whoop" read returned nothing and Effort integrated to 0 off an empty series. Single-WHOOP
            // install resolves to "my-whoop" ⇒ one id ⇒ byte-identical read.
            val todayHr = runCatching { viewModel.repo.hrSamplesUnion(viewModel.activeStrapId, start, now) }
                .getOrDefault(emptyList())
            // effMaxHR resolution matches AnalyticsEngine: manual HR-max override first, else Tanaka from age.
            val effMaxHR = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble()
                ?: if (profileStore.age > 0) StrainScorer.tanakaHRmax(profileStore.age.toDouble()) else null
            StrainScorer.strain(
                hr = todayHr,
                maxHR = effMaxHR,
                restingHR = displayMetric?.restingHr?.toDouble() ?: StrainScorer.defaultRestingHR,
                method = NoopPrefs.effortMethod(context),
                sex = profileStore.sex,
            )
        } else {
            null
        }
    }

    // #1001: Effort resolved ONCE for the whole screen, so the Key Metrics tile and the HR chart's edge
    // badge show what the hero ring shows. Both used to read `displayMetric.strain` straight off the daily
    // row, which only refreshes when the heavy daily pass runs — so an active morning read 2.3 on the ring
    // and 0.5 in the other two. The ring resolves the same way from the same rule (see ScoreHeroRow).
    val effortForDay = StrainScorer.effectiveEffort(
        live = if (selectedDayOffset == 0) liveTodayStrain else null,
        stored = displayMetric?.strain,
    )

    // Recovery cold-start: recovery is null until the HRV baseline crosses the seed gate
    // (Baselines.minNightsSeed valid nights). Show honest "calibrating, N of 4 nights" progress
    // instead of a bare "No Data" so a new BLE-only user knows scores are coming, not broken. (PR #85)
    val recoveryCalibration: Int? = if (selectedDayOffset == 0) {
        // Thread the persisted "Recalibrate HRV baseline" epoch (0 = none) so N folds the SAME
        // epoch-aware history the recovery engine folds — otherwise a post-recalibration user's pre-epoch
        // nights inflate the count past the seed gate and the score side wrongly reads NeedsStrap (Bug B).
        val hrvEpoch = NoopPrefs.of(context).getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble()
        recoveryCalibrationNights(days, displayMetric?.recovery != null, hrvEpoch)
    } else {
        null
    }

    // The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    // been scored yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    // night isn't scored until you wear it tonight), so a baseline-established user, past calibration, so
    // recoveryCalibration is null, saw the WHOLE recovery side blank ("No Data" Charge AND blank HRV /
    // resting-HR / respiratory / SpO₂ tiles + Synthesis + Contributors) while live HR kept ticking, which
    // reads as broken. This is the ONE prior row every recovery-derived read-out carries over from, the
    // way WHOOP keeps showing last recovery until the new one lands, it NEVER fabricates a number for the
    // new day, each carried read shows the REAL prior value labelled as prior, and any metric the prior
    // row genuinely lacks still falls through to "No Data". Non-null only when: it's today, today has no
    // recovery, and we're not mid-calibration (calibration owns its own copy). days is oldest→newest;
    // exclude the (still-null) today key so we never echo "today". Mirrors iOS lastScoredRecoveryDay.
    // #547 carry-over upper bound: the LATER of the logical "today" (rolls at 04:00) and the local
    // calendar day. Using the later key means a legitimate just-after-midnight carry-over of yesterday's
    // logical day is NOT dropped, while any FUTURE-dated row (a bad strap clock) still sorts past it and
    // is excluded. ISO date strings compare chronologically.
    val carryOverTodayKey = remember(todayDate) {
        maxOf(todayDate.toString(), java.time.LocalDate.now().toString())
    }
    val lastScoredRecoveryDay: DailyMetric? = remember(days, selectedDayKey, recoveryCalibration, selectedDayOffset, displayMetric, carryOverTodayKey) {
        lastScoredRecoveryDay(
            days = days,
            selectedDayKey = selectedDayKey,
            isToday = selectedDayOffset == 0,
            todayScored = displayMetric?.recovery != null,
            isCalibrating = recoveryCalibration != null,
            today = carryOverTodayKey,
        )
    }
    // The freshest STRICTLY-PRIOR night carrying a real overnight VITAL (HRV / resting-HR / respiratory),
    // recovery-INDEPENDENT (#543 follow-up). HRV/RHR/resp exist without a recovery score, so a post-update
    // re-analysis that nulls last night's recovery while preserving its avgHrv/restingHr must NOT fall back
    // to an OLDER recovery-scored day for the vitals (that's the tile-vs-card mismatch: the per-field tiles
    // already keep last night's real value; the whole-row card was discarding it). The vitals read PER-FIELD
    // today-first with THIS carry as the fallback, kept separate from lastScoredRecoveryDay (Charge ring /
    // Synthesis / Contributors / Readiness stay recovery-gated). Future-clock-safe: the upper bound is the
    // LATER of the resolved today row's own key and carryOverTodayKey, mirroring lastScoredRecoveryDay's
    // #547 guard. Non-null only on today (offset 0). Mirrors iOS Repository.lastVitalsDay.
    val lastVitalsDay: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastVitalsRow(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    // PER-FIELD SpO₂ / skin-temp carries, the twin of lastVitalsDay for the two fields its predicate does
    // NOT check. The on-device engine writes spo2Pct = null (only raw spo2Red/spo2Ir), so every computed
    // "-noop" row lacks a percentage; only imported rows carry one. A whole-row carry (lastScoredRecoveryDay
    // or lastVitalsDay) therefore lands on a row with null spo2Pct/skinTempDevC and the Blood Oxygen /
    // Skin Temp cards read "No Data" even though an imported row holds a real reading. Resolving the two
    // fields independently (last strictly-prior row with the field non-null) mirrors iOS
    // TodayView.lastSpo2Day / lastSkinTempDay. Same #547 future-clock bound; non-null only on today.
    val lastSpo2Day: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastSpo2Row(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    val lastSkinTempDay: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastSkinTempRow(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    // PER-FIELD respiratory carry (#1331): the freshest strictly-prior row that actually HAS a breaths/min,
    // since lastVitalsDay can land on a night with HRV/RHR but no respiratory. Twin of lastSpo2Day.
    val lastRespDay: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastRespRow(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    // Carry-over Charge for TODAY, the prior scored row's recovery + its "Last night · <date>" caption.
    // Derived from lastScoredRecoveryDay so Charge and every other recovery tile carry the SAME prior day.
    val carriedChargeCaption = lastScoredRecoveryDay?.let { carriedCaption(it.day, carryOverTodayKey).localized() }
    val lastScoredCharge: LastCharge? = remember(lastScoredRecoveryDay, carriedChargeCaption) {
        lastScoredRecoveryDay?.let { prior ->
            prior.recovery?.let { LastCharge(it, carriedChargeCaption.orEmpty()) }
        }
    }
    var carriedRecoveryProvider by remember { mutableStateOf<ScoreInputProvider?>(null) }
    LaunchedEffect(lastScoredRecoveryDay?.day, viewModel.activeStrapId) {
        val carriedDay = lastScoredRecoveryDay?.day
        carriedRecoveryProvider = if (carriedDay == null) {
            null
        } else {
            runCatching {
                viewModel.repo.resolvedSeries("recovery", "my-whoop", carriedDay, carriedDay,
                    strapDeviceId = viewModel.activeStrapId)
                    .points.lastOrNull { it.day == carriedDay }
                    ?.let { viewModel.scoreInputProvider(it.source, it.day, "recovery") }
            }.getOrNull()
        }
    }

    // Explainability (COMPONENT 2): the honest state of the score side for TODAY, scored / calibrating /
    // carried-last-night / needs-strap. One state, never a bare blank, and never a fabricated number. Only
    // computed for today (offset 0); a past day shows its own row, not a "needs the strap" prompt.
    val scoreState: ScoreState = remember(displayMetric, recoveryCalibration, lastScoredRecoveryDay, selectedDayOffset, carryOverTodayKey) {
        if (selectedDayOffset == 0) {
            scoreStateForToday(
                todayRecovery = displayMetric?.recovery,
                calibratingNights = recoveryCalibration,
                carriedDay = lastScoredRecoveryDay,
                today = carryOverTodayKey,
            )
        } else {
            ScoreState.Scored(displayMetric?.recovery ?: 0.0)
        }
    }

    // One honest card-level badge, matching LiquidTodayView: identical winners collapse to one label;
    // mixed winners show at most two sources in Charge / Effort / Rest order so the pill stays compact.
    val heroSourceParts = remember(providerByMetric, carriedRecoveryProvider, displayMetric?.recovery, lastScoredCharge) {
        scoreHeroSourceLabel(
            providerByMetric = providerByMetric,
            carriedRecoveryProvider = carriedRecoveryProvider,
            usesCarriedRecovery = displayMetric?.recovery == null && lastScoredCharge != null,
        )
    }
    val heroSourceLabel = heroSourceParts.takeIf { it.isNotEmpty() }?.localizedSourceList()

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = rememberTrendWindow(days, selectedDay, keyMetricsWindowDays, spo2CandidateByDay)

    LaunchedEffect(days) {
        // #849: this footer pass is the heavy one. It derives HR per imported workout from raw strap samples
        // (fillWorkoutHrFromStrap = potentially hundreds of raw-HR reads) and counts every workout / Apple /
        // Health-Connect row across ALL history. A bare Today re-mount (tab-away + return, or an Apple-Health
        // import that recreates the screen) re-fires this LaunchedEffect with the screen's `remember` state
        // reset, so it re-ran the full pass for byte-identical data every time: the lag users see returning
        // to Today after an import. The signature is `days` (a `data class` list, so its structural
        // hashCode is a stable content signature) PLUS the 14-day cross-source workout union: `days`
        // alone missed workouts imported without touching the Whoop day summaries (e.g. a Health
        // Connect session recorded today), so the "Last Workouts" feed stayed stale until the next
        // Whoop cycle bumped `days`. The union is a cheap windowed SELECT; only the heavy strap-HR
        // derivation and all-history counts below are skipped on a signature match. The marker lives
        // on the long-lived ViewModel, so it survives the re-mount that reset the screen state. A real
        // data change bumps the signature and re-runs, so no real update is dropped.
        val now = System.currentTimeMillis() / 1000
        val recentCutoff = LocalDate.now()
            .minusDays(13)
            .atStartOfDay(ZoneId.systemDefault())
            .toEpochSecond()
        val recentUnion = viewModel.repo.workoutsAllSources(viewModel.deviceId, recentCutoff, now)
            .sortedByDescending { it.startTs }
        val sig = 31 * days.hashCode() + recentUnion.hashCode()
        if (viewModel.todayFooterLoadedSig == sig) return@LaunchedEffect
        // Union of the active strap id + legacy "my-whoop" (#814), NOT the literal id alone: after a
        // re-pair the fresh recordings live under "whoop-<id>", and a pinned read undercounted them
        // in the Whoop pill exactly like the feed dropped them from "Latest Workouts".
        val whoopWorkouts = viewModel.repo.workoutsUnion(viewModel.deviceId, 0L, now)
        // Apple Health and Health Connect are separate sources (since #34), keep them separate in the
        // provenance footer too, so Health Connect data isn't mislabelled under the "Apple Health" pill
        // (issue #53). The recent-workouts list below still unions all sources for a combined feed.
        val appleWorkouts = viewModel.repo.workouts("apple-health", 0L, now)
        val hcWorkouts = viewModel.repo.workouts("health-connect", 0L, now)
        val appleDaysCount = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        val hcDaysCount = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        footer = TodayFooterState(
            // fillWorkoutHrFromStrap: imported sessions carry no HR, derive it from strap samples (#77).
            // #510: strap-native rows now read HR under their OWN recording strap (inside the fill), so a 2nd
            // WHOOP's workouts reconcile Avg HR + Effort from their own trace; imported rows keep the default.
            // #1601: the ACTIVE strap id, not the "my-whoop" default — see the AppViewModel call site.
            // Left defaulted, an imported row on a non-canonical install reads only the canonical id here
            // while every other surface reads active ∪ canonical, so its Avg HR stays blank against a
            // populated graph.
            recentWorkouts = viewModel.repo.fillWorkoutHrFromStrap(
                recentUnion,
                strapDeviceId = viewModel.deviceId,
                effortMethod = NoopPrefs.effortMethod(context),
            ),
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
        // Cache the result + record the signature so a later re-mount with unchanged data restores the footer
        // and short-circuits the heavy reload above.
        viewModel.todayFooterCache = footer
        viewModel.todayFooterLoadedSig = sig
    }

    // #817 - horizontal swipe to change day, alongside the header chevrons. `detectHorizontalDragGestures`
    // only claims HORIZONTAL drags, so the LazyColumn keeps its vertical scroll; we accumulate the drag and
    // resolve the day ONCE on lift via the pure `dayNavSwipeTarget` (rightward = older, leftward = newer,
    // clamped at today). The threshold is density-scaled from DAY_NAV_SWIPE_THRESHOLD_DP so a small wobble
    // during a scroll doesn't flip the day. Mirrors the iOS day-nav swipe lane.
    val swipeThresholdPx = with(LocalDensity.current) { DAY_NAV_SWIPE_THRESHOLD_DP.dp.toPx() }
    val daySwipeModifier = Modifier.pointerInput(Unit) {
        var accumulatedX = 0f
        detectHorizontalDragGestures(
            onDragStart = { accumulatedX = 0f },
            onDragEnd = {
                selectedDayOffset = dayNavSwipeTarget(selectedDayOffset, accumulatedX, swipeThresholdPx)
            },
            onHorizontalDrag = { _, dragAmount -> accumulatedX += dragAmount },
        )
    }
    val canPullToSync = todayPullToSyncEnabled(liveSnap.connected, liveSnap.bonded, liveSnap.backfilling)
    // material3 1.2.1's rememberPullToRefreshState CAPTURES the `enabled` lambda ONCE (rememberSaveable,
    // no rememberUpdatedState), so `{ canPullToSync }` would freeze the plain Boolean from the FIRST
    // composition — and Today usually first composes before the strap has (re)connected, leaving the
    // gesture permanently disabled for the session. Read the stable `liveSnap` State live inside the lambda
    // instead, so each gesture check sees the current connected/bonded/backfilling. (syncNow is triple-gated
    // anyway; this just makes the gesture actually enable once the strap is ready.)
    val pullToSyncState = rememberPullToRefreshState(
        enabled = { todayPullToSyncEnabled(liveSnap.connected, liveSnap.bonded, liveSnap.backfilling) },
    )
    LaunchedEffect(pullToSyncState.isRefreshing, canPullToSync) {
        if (pullToSyncState.isRefreshing) {
            if (canPullToSync) viewModel.syncNow()
            // Historical offloads can run for a while; the existing sync chip/note owns ongoing progress.
            pullToSyncState.endRefresh()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .nestedScroll(pullToSyncState.nestedScrollConnection),
    ) {
    LazyScreenScaffold(
        modifier = daySwipeModifier,
        // title = null suppresses the big scaffold header (the nullable-title path); the compact
        // WHOOP-style top bar below replaces it, mirroring the iOS Today screen (todayTopBar).
        title = null,
        // Tighten the top inset now the big title is gone (Compose forbids negative padding, so this
        // expresses iOS's `.padding(top: -16)` as a smaller scaffold top padding).
        topPadding = 12.dp,
        // FIX 6 (compactness): the liquid Today matches the iOS Today's tight `VStack(spacing: 12)` section
        // rhythm rather than the app-wide 20dp row gap, so the whole screen reads as compact/slick as iOS.
        // Scoped to this scaffold — no other screen's rhythm changes.
        rowSpacing = 12.dp,
        // #today-layout (hold-to-drag): the hoisted list state the section drag reads (layoutInfo/scrollBy).
        listState = todayListState,
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky sits
        // behind the WHOLE top region, the liquid header + wordmark AND the hero vessels, full-bleed (full-width, up
        // behind the status bar via the scaffold's topBackground plumbing), top-aligned, settling into the
        // flat canvas over its lower half so the cards float OVER it on the theme surface. This is the
        // Android equivalent of the iOS `ScreenScaffold(topBackground: liquidScaffoldSky())`: it replaces
        // the classic day-cycle SceneScreenBackground with the liquid day-of-sky (LiquidSkyStatic — no
        // per-frame cost on this scroll-heavy screen). The other liquid screens drop in the SAME
        // LiquidScreenSky() slot verbatim.
        // #698, gated on the "Day-cycle background" setting (default ON). Off passes null, so the scaffold
        // paints the plain dark surface canvas instead, mirroring iOS's `showDayCycleBackground ? ... : nil`.
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down.
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        item {
        // LIQUID Today header (iOS LiquidTodayView.scene parity), a full structural rebuild to mirror the
        // iOS liquid Today element-for-element (NOT the old numeric-date + recording-light + bell header):
        //   LEFT  — a tappable title block: the big rounded-bold day title ("Today" / "Yesterday" / the
        //           weekday) over a human date line ("Friday, 3 July"). Tap opens the day picker.
        //   RIGHT — exactly the iOS four controls, in order: a filled HEART (→ Support), the PROFILE
        //           AVATAR (→ Settings), a "+" ADD button (→ quick actions), and the strap BATTERY RING.
        // The recording-status light and the notifications BELL are GONE from the header (iOS has neither);
        // the Updates inbox is relocated into the "+" quick-actions sheet (AppRoot), so the feature stays one
        // tap away without sitting in the Today header. Staggered in as the first section (index 0).
        val dayTitle = when (selectedDayOffset) {
            0 -> uiString(R.string.today_day_today)
            1 -> uiString(R.string.today_day_yesterday)
            else -> {
                val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
                keyDate.format(DateTimeFormatter.ofPattern("EEEE", Locale.getDefault()))
            }
        }
        // Human date line under the title — "Friday, 3 July" (weekday + day + month), NOT a numeric date.
        // Dated by the row ACTUALLY on screen (selectedDayKey follows the resolver at offset 0), matching
        // the iOS `dateLine` (EEEE, d MMMM). Mirrors iOS's date-under-title block.
        val humanDate = run {
            val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
            keyDate.format(DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale.getDefault()))
        }
        // #486: header + wordmark + Arrange fold into ONE compact top cluster. Previously the decorative
        // "N O O P" wordmark and the pinned "Arrange" affordance were each their own full-width list item,
        // so the scaffold's 12dp rowSpacing left two near-empty sky bands stacked under the header ("empty
        // space below NOOP"). Grouping them here removes those section gaps: the wordmark hangs 2dp under
        // the title, and Arrange rides the SAME row as the wordmark (wordmark dead-centre, Arrange trailing)
        // instead of claiming its own band.
        Column(
            modifier = Modifier.fillMaxWidth().staggeredAppear(0),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            LiquidTodayHeader(
                dayTitle = dayTitle,
                humanDate = humanDate,
                selectedDay = selectedDay,
                batteryPct = if (liveSnap.connected) liveSnap.batteryPct else null,
                backfilling = liveSnap.backfilling,
                syncChunksThisSession = liveSnap.syncChunksThisSession,
                lastSyncAt = liveSnap.lastSyncAt,
                historySyncExperimental = liveSnap.historySyncExperimental,
                onPickDay = { offset -> selectedDayOffset = offset },
                onQuickActions = onQuickActions,
                onOpenSettings = onOpenSettings,
                onOpenDevices = onOpenDevices,
            )
            // WORDMARK (iOS LiquidWordmark parity): a subtle centred "N O O P" @ ~50% opacity, with a
            // tap easter egg. Shares its row with the Arrange affordance — wordmark centred, Arrange
            // aligned to the trailing edge — so neither needs its own empty band.
            Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                LiquidWordmark()
                // One consistent customization affordance for section order and visibility.
                TextButton(
                    onClick = { showLayoutEditor = true },
                    colors = ButtonDefaults.textButtonColors(contentColor = Palette.textTertiary),
                    modifier = Modifier.align(Alignment.CenterEnd),
                ) {
                    Icon(
                        Icons.Filled.Tune,
                        contentDescription = stringResource(R.string.today_customize_title),
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                    Spacer(Modifier.width(Metrics.space4))
                    Text(stringResource(R.string.today_customize_action), style = NoopType.footnote)
                }
            }
        }
        }

        // A "workout in progress" indicator whenever a manual workout is active (iOS parity: the Today
        // ActiveWorkoutIndicator). A tap routes to Live and re-opens the in-exercise overlay. Gated purely on
        // `activeWorkout`, so it auto-appears/clears with no extra lifecycle wiring. Its per-second clock
        // ticks inside the card's own LaunchedEffect, never recomposing the Today body.
        activeWorkout?.let { w ->
            item {
                WorkoutInProgressCard(workout = w, onReturn = onOpenActiveWorkout)
            }
        }

        // Design Reset (iOS parity): the "New here?" first-run card is off the Today dashboard for the
        // clean look, the scoring guide stays reachable from the i on each score and in Settings.

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out. A small × dismisses it INTO
        // the Updates inbox (restorable from there). Only anchored to today (offset 0).
        if (displayMetric?.recovery == null) {
            item {
            // While the strap is mid-offload, say so, empty tiles read as final otherwise (#77).
            if (liveSnap.backfilling) SyncingHistoryNote(chunks = liveSnap.syncChunksThisSession)
            // Explained score state (COMPONENT 2): when there's no own number to show, say WHY and WHAT to
            // do. "Calibrating" (N more nights, no fake number), "Last night · <date>" (#802 carry-over)
            // or "Needs the strap" (no data overnight). The carried Charge now draws a dimmed filled ring on
            // the hero with NO in-ring caption, so its "Last night ..." note renders BELOW the rings here,
            // matching iOS explainedScoreNote. Today only; never a fabricated value.
            //
            // #827: NeedsStrap ALWAYS shows (a today-blocking state, not a recurring nag).
            if (selectedDayOffset == 0 && scoreState is ScoreState.NeedsStrap) {
                ScoreStateNote(scoreState)
            }
            // The carried "Latest sleep · <date>" / "Last night · <date>" note. iOS has NOTHING in this slot,
            // and the maintainer flagged it as breaking the compact liquid look sitting permanently above the
            // hero. So on Android it's dismissible-into-the-inbox (restorable) like the calibrating note: a
            // small × tucks it into Updates so it isn't a fixed fixture between the header and the hero.
            if (selectedDayOffset == 0 && scoreState is ScoreState.CarriedLastNight && !carriedSleepDismissed) {
                // Resolved HERE, not in the onClick below: dismissTodayCard runs from a non-composable
                // lambda, and what it stores is what the Updates inbox later shows. Passing the raw
                // `scoreState.title`/`.detail` filed the dismissed card in English while the card itself
                // rendered localized — the same strings reaching a second sink. (#612)
                val carriedTitle = scoreStateTitle(scoreState)
                val carriedDetail = scoreStateDetail(scoreState)
                Box(modifier = Modifier.fillMaxWidth()) {
                    ScoreStateNote(scoreState)
                    if (updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_CARRIED_SLEEP,
                                    carriedTitle,
                                    carriedDetail,
                                )
                            },
                        )
                    }
                }
            }
            // #827: the dismissible calibrating note. Hidden once dismissed into the inbox; a "Restore to
            // Today" tap there flips calibratingDismissed back via the shared restore path above.
            if (selectedDayOffset == 0 && scoreState is ScoreState.Calibrating && !calibratingDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    ScoreStateNote(
                        scoreState,
                        restartCause = ScoreState.calibrationRestartCause(
                            ScoreState.recalibrationDay(
                                NoopPrefs.of(context).getLong(Baselines.hrvBaselineEpochKey, 0L),
                            ),
                        )?.localized(),
                    )
                    if (updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_CALIBRATING,
                                    context.getString(R.string.today_update_building_baseline_title),
                                    context.getString(R.string.today_update_building_baseline_message),
                                )
                            },
                        )
                    }
                }
            }
            if (selectedDayOffset != 0 || !scoresBuildingDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    DataPendingNote(
                        title = uiString(R.string.l10n_today_screen_live_now_your_scores_are_building_cb05a4e8),
                        body = uiString(R.string.today_pending_scores_body),
                    )
                    // The × is only meaningful for today's card (a past day's note isn't dismissed).
                    if (selectedDayOffset == 0 && updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_SCORES_BUILDING,
                                    context.getString(R.string.today_update_scores_building_title),
                                    context.getString(R.string.today_update_scores_building_message),
                                )
                            },
                        )
                    }
                }
            }
            }
        }

        if (alert != null) item { IllnessBanner(alert!!) }

        // #486: the "Arrange" affordance moved UP into the header/wordmark cluster (see above) so it no
        // longer sits alone in its own full-width band here. It stays pinned; only its position changed.

        // #today-layout: EVERY Today section — including the Charge/Effort/Rest hero and the Start-session
        // entry — renders in the user's saved order (TodayLayoutPrefs); only the top bar + this Arrange
        // affordance stay pinned. Each section is ONE keyed item wrapped in [TodayReorderableSection]:
        // LONG-PRESS anywhere on a section and drag — it lifts (haptic), follows the finger, swaps
        // neighbours as it crosses their centres (the screen-level frame loop also auto-scrolls at the
        // viewport edges and keeps swapping while it does), and the order persists on drop. The stagger
        // index follows the section's live position.
        sectionOrder.filterNot { it in hiddenSections }.forEach { section ->
            // Entrance stagger keyed on the section's FIXED default position, not its live position: the
            // stagger only matters on first appearance (staggeredAppear latches), and a live-position
            // stagger changes every moved section's content lambda on every mid-drag swap — recomposing
            // the heavy sections (Key Metrics grid, HR chart) while the finger is down (drag jank).
            val stagger = TodaySection.defaultOrder.indexOf(section) + 1
            // A gated-off section (Start session outside today / beta-off; Your Cards outside today or
            // empty) emits NO item at all: an always-present zero-height item would double the 12dp row
            // gap around its slot — visible on the DEFAULT layout, where Start session sits right under
            // the hero and the beta flag is off for most users. The section keeps its place in the saved
            // order; its item simply reappears when eligible.
            val visibleDashboardCards = enabledDashboardCards.filter {
                it != DashboardCard.HYDRATION || hydrationEnabled
            }
            val sectionVisible = when (section) {
                TodaySection.LIVE_SESSION ->
                    selectedDayOffset == 0 && (liveSessionsEnabled || activeLiveSession != null)
                TodaySection.YOUR_CARDS ->
                    selectedDayOffset == 0 && visibleDashboardCards.isNotEmpty()
                TodaySection.MENSTRUAL_CYCLE ->
                    selectedDayOffset == 0 && !cycleHidden &&
                        (cycleOptInApplies(profileStore.sex) || cycleEnabled || periodStarts.isNotEmpty())
                TodaySection.JOURNAL ->
                    selectedDayOffset == 0 && journalReminderOn
                TodaySection.ADDED_CARDS ->
                    selectedDayOffset == 0 && enabledHostedCards.isNotEmpty()
                else -> true
            }
            if (!sectionVisible) return@forEach
            item(key = TODAY_SECTION_KEY_PREFIX + section.raw) {
                TodayReorderableSection(
                    section = section,
                    listState = todayListState,
                    drag = sectionDrag,
                    onDrop = { TodayLayoutPrefs.setOrder(context, sectionOrder) },
                ) {
                    when (section) {
                        // HERO, three equal Charge / Effort / Rest liquid vessels in the compact pinned-dark
                        // card used by LiquidTodayView. Effort prefers today's live in-progress strain and
                        // falls back to the stored value (#402); the floating badge names the real score
                        // sources. The honest "why is Effort 0?" caption (#482/#480) travels WITH the hero
                        // (folded into this section) so wherever the vessels sit, their explanation follows.
                        TodaySection.HERO -> Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            // The liquid hero CARD: a translucent near-black that floats over the day-of-sky
                            // so the vessels + white count-up numbers stay crisp. A rounded 26 corner + a
                            // faint white hairline give it the frosted-glass edge of the iOS liquid heroCard
                            // (heroFill = rgba(13,14,20,.80), stroke white@0.11).
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(
                                        Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity),
                                        RoundedCornerShape(LIQUID_HERO_RADIUS),
                                    )
                                    .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                                    .staggeredAppear(stagger),
                            ) {
                                ScoreHeroRow(
                                    day = displayMetric,
                                    restScore = restScoreForDay,
                                    recoveryCalibration = recoveryCalibration,
                                    lastScoredCharge = lastScoredCharge,
                                    effortScale = effortScale,
                                    liveTodayStrain = if (selectedDayOffset == 0) liveTodayStrain else null,
                                    heroSourceLabel = heroSourceLabel,
                                    onScoreInfo = openGuide,
                                    onChargeTap = { showChargeBreakdown = true },
                                )
                            }
                            // Honest "why is Effort 0?" caption — only when today's Effort is a real
                            // near-zero (HR present but never crossed the cardio zone). Effort accrues over
                            // a day and must never visibly drop: floor the in-progress value at the day's
                            // already-earned strain (#489/#506).
                            // #1001: the shared resolution, not a fourth hand-rolled copy of it. Stays null
                            // for a navigated past day so the caption is a TODAY-only explanation.
                            val todayEffort = if (selectedDayOffset == 0) effortForDay else null
                            if (todayEffort != null && todayEffort < 1.0) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 2.dp),
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.Top,
                                ) {
                                    Icon(
                                        Icons.Filled.Info,
                                        contentDescription = null,
                                        tint = Palette.effortColor,
                                        modifier = Modifier.size(Metrics.iconSmall),
                                    )
                                    Text(
                                        uiString(R.string.l10n_today_screen_no_cardio_load_yet_effort_builds_e952006c),
                                        style = NoopType.footnote,
                                        color = Palette.textTertiary,
                                    )
                                }
                            }
                        }
                        // LIVE SESSIONS (beta): the compact "Start session · BETA" entry. Today only
                        // (offset 0 — a session is a now-thing), gated on the Settings beta flag; a RUNNING
                        // session keeps the card visible regardless (it is the designed way back into the
                        // dismissed session dialog, see LiveSessionRunner's lifetime note). The gate lives
                        // at the loop level (sectionVisible) so a gated-off section emits no item.
                        TodaySection.LIVE_SESSION -> LiveSessionEntryCard(
                            onOpen = {
                                // Only BEGIN when nothing is in flight: an active runner (running, or ended
                                // and holding its unseen summary) is simply re-presented, never displaced —
                                // so a tap can't silently discard a running session or a summary awaiting
                                // its "Done".
                                if (LiveSessionRunner.active.value == null) {
                                    startOrResumeLiveSession(viewModel, context)
                                }
                                showLiveSession = true
                            },
                        )
                        // The plain-English read-out, the Charge-tinted Synthesis card. Mirrors the iOS
                        // Synthesis InsightCard; carries the last scored day's read at the rollover (#543).
                        TodaySection.SYNTHESIS -> Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                            SynthesisHeroCard(
                                day = displayMetric,
                                recoveryCalibration = recoveryCalibration,
                                carriedDay = lastScoredRecoveryDay,
                                days = days,
                                synthesisExpanded = synthesisExpanded,
                                onToggleSynthesis = { synthesisExpanded = !synthesisExpanded },
                                onOpenReadiness = { showChargeBreakdown = true },
                            )
                        }
                        // METRICS: header + Edit affordance (#251) + the tile grid. Previously two
                        // LazyColumn items; merged into ONE (a section must be a single keyed item for the
                        // drag), spaced by the scaffold's 12dp row gap so the rhythm is pixel-identical.
                        TodaySection.KEY_METRICS -> Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Row(verticalAlignment = Alignment.Top) {
                                Box(modifier = Modifier.weight(1f)) {
                                    SectionHeader(uiString(R.string.today_section_key_metrics), overline = dayLabel, trailing = trendWindowLabel(keyMetricsWindowDays))
                                }
                                TodayEditAction(
                                    onClick = { showMetricsEditor = true },
                                    contentDescription = uiString(R.string.l10n_today_screen_edit_key_metrics_f95e61a4),
                                    contentAlignment = Alignment.TopCenter,
                                )
                            }
                            Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                                MetricGrid(
                                    d = displayMetric,
                                    w = window,
                                    recoveryCalibration = recoveryCalibration,
                                    lastScoredCharge = lastScoredCharge,
                                    carriedDay = lastScoredRecoveryDay,
                                    spo2CarryDay = lastSpo2Day,
                                    respCarryDay = lastRespDay,
                                    spo2CandidateByDay = spo2CandidateByDay,
                                    unitSystem = unitSystem,
                                    effortScale = effortScale,
                                    effortForDay = effortForDay,   // #1001: same figure as the hero ring
                                    latestWeightKg = weightKg,
                                    profileWeightKg = profileWeightKg,
                                    importedStepsForDay = importedStepsForDay,
                                    estimatedStepsForDay = stepsEstForDay,
                                    caloriesForDay = caloriesByDay[selectedDayKey],   // #616: imported-first per day
                                    caloriesSpark = caloriesSpark,                    // #616: imported-first trend
                                    stepActivityClassForDay = stepActivityClassForDay,
                                    stepsEstimateCaption = stepsEstimateCaption(profileStore),
                                    // Resolve the semantic engine headline at the composable UI boundary.
                                    // This preference read is cheap and only feeds the otherwise-empty tile.
                                    stepsCalibrationPrompt = stepsCalibrationPrompt(context, profileStore),
                                    restScore = restScoreForDay,
                                    restSpark = restCompositeSpark,
                                    enabledMetrics = enabledKeyMetrics,
                                    isToday = selectedDayOffset == 0,
                                    onScoreInfo = openGuide,
                                    metricsExpanded = metricsExpanded,
                                    onToggleMetrics = { metricsExpanded = !metricsExpanded },
                                    detailed = keyMetricsDetailed,
                                    windowDays = keyMetricsWindowDays,
                                    onOpenMetric = onOpenMetric,
                                    onOpenStepsCalibration = onOpenStepsCalibration,
                                )
                            }
                        }
                        // #991: TodayWorkoutsSection emits header + card as two siblings; spaced Column.
                        TodaySection.WORKOUTS -> Column(
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            TodayWorkoutsSection(footer.recentWorkouts)
                        }
                        // HEART RATE, the live HR thread / trend card. #991: header + card in a Column.
                        TodaySection.HEART_RATE -> Column(
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            HeartRateTrendCard(viewModel, days, selectedDay, todayDate, displayMetric, effortScale, effortForDay)
                        }
                        // The three hero vitals, HRV / Resting HR / Respiratory. Carried day (#543).
                        TodaySection.RECOVERY_VITALS -> Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                            HeroMetricRows(day = displayMetric, carriedDay = lastScoredRecoveryDay, vitalsDay = lastVitalsDay)
                        }
                        // YOUR CARDS, the user-customisable dashboard (WHOOP "My Dashboard"). Hydration is
                        // hidden when its tracking is OFF (the editor still offers it, so the choice
                        // persists). Per-field carried-day fallbacks (#543) stop rollover "No Data" blanks.
                        // The today/non-empty gate lives at the loop level (sectionVisible) so a gated-off
                        // section emits no item; visibleDashboardCards is the loop-level filtered list.
                        TodaySection.YOUR_CARDS -> YourCardsSection(
                            cards = visibleDashboardCards,
                            day = displayMetric,
                            carriedDay = lastScoredRecoveryDay,
                            vitalsDay = lastVitalsDay,
                            spo2Day = lastSpo2Day,
                            skinTempDay = lastSkinTempDay,
                            respDay = lastRespDay,
                            stress = stressToday,
                            fitnessAge = fitnessAgeToday,
                            vo2max = vo2maxToday,
                            vitality = vitalityToday,
                            importedStepsForDay = importedStepsForDay,
                            estimatedStepsForDay = stepsEstForDay,
                            caloriesForDay = caloriesByDay[selectedDayKey],
                            hydrationTotalMl = hydrationTotalMl,
                            hydrationGoalMl = hydrationGoalMl,
                            onOpenHydration = onOpenHydration,
                            onOpenStress = onOpenStress,
                            onOpenMetric = onOpenMetric,
                            onOpenSleep = onOpenSleep,
                            onOpenCoupled = onOpenCoupled,
                            onCustomise = { showDashboardEditor = true },
                            spo2CandidateByDay = spo2CandidateByDay,
                        )
                        TodaySection.MENSTRUAL_CYCLE -> MenstrualCycleHomeCard(
                            enabled = cycleEnabled,
                            result = v5Signals?.cycle,
                            starts = periodStarts,
                            onSetUp = {
                                viewModel.setCycleTrackingEnabled(true)
                                showCycleTracker = true
                            },
                            onOpen = { showCycleTracker = true },
                            onLogToday = { viewModel.logPeriodStart() },
                        )
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — hold-drag or Arrange moves it. Today-only
                        // and enabled-gated at the loop level (sectionVisible) so it never leaves a blank
                        // draggable slot. Twin of iOS LiquidTodayView's `.journal` arm.
                        TodaySection.JOURNAL -> JournalReminderCard(
                            viewModel = viewModel,
                            days = days,
                            onOpenJournal = onOpenJournal,
                        )
                        // #today-hosted-cards: the Trends/Sleep cards the user pulled into Today, in
                        // arranged order. Each is the SAME card its home tab renders (a mirror).
                        TodaySection.ADDED_CARDS -> HostedCardsSection(
                            cards = enabledHostedCards,
                            days = days,
                            viewModel = viewModel,
                        )
                    }
                }
            }
        }
        // Auto-detect workouts (MVP, opt-in, default OFF), a NON-DESTRUCTIVE "looks like a workout?"
        // card that suggests logging a detected sustained-elevated-HR bout. Renders nothing when the
        // toggle is off or there's nothing to suggest. Save → a manual "Workout" row; × → dismissed forever.
        if (selectedDayOffset == 0) {
            item { AutoWorkoutNudgeCard(viewModel = viewModel, days = days) }
        }
        // Strap battery only while the link is up AND a real reading exists, a stale % from a
        // dropped connection must not present as live (#159).
        item {
            TodaySourcesSection(
                footer,
                strapBatteryPct = if (liveSnap.connected) liveSnap.batteryPct?.roundToInt() else null,
                strapBatteryEstimate = if (liveSnap.connected) batteryEstimateText else null,
                expanded = sourcesExpanded,
                onToggle = { sourcesExpanded = !sourcesExpanded },
            )
        }
    }
        // Material3's PullToRefreshContainer draws its indicator circle even at rest (progress 0, not
        // refreshing), so an idle Today showed a permanent grey dot at the top (#582). Compose it only
        // while a pull is in progress or a sync is running — the pull GESTURE flows through the Box's
        // nestedScroll above, not this container, so gating the visual can't disable pull-to-sync.
        if (pullToSyncState.progress > 0f || pullToSyncState.isRefreshing) {
            PullToRefreshContainer(
                state = pullToSyncState,
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }
    }

    if (showCycleTracker) {
        v5Signals?.cycle?.let { cycle ->
            CycleTrackerDialog(
                result = cycle,
                starts = periodStarts,
                onLog = viewModel::logPeriodStart,
                onDelete = viewModel::deletePeriodStart,
                onDeleteAll = viewModel::deleteAllPeriodStarts,
                onDismiss = { showCycleTracker = false },
            )
        }
    }

    // Scoring guide sheet, full-screen Dialog, mirroring Settings' What's-new presentation. Opened
    // by the per-score ⓘ (deep-linked via guideSection) and the first-run card (guideSection = null).
    if (showGuide) {
        Dialog(
            onDismissRequest = { showGuide = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                ScoringGuideScreen(
                    onClose = { showGuide = false },
                    initialSection = guideSection,
                )
            }
        }
    }

    // A1/S4: the Charge breakdown sheet, opened by tapping the hero Charge ring. A full-screen Dialog
    // (mirroring the scoring guide's presentation) hosting the existing What-shaped-it breakdown, the
    // Contributors bars and the Readiness card, built only when shown (#819 lazy). A calibrating night
    // (empty drivers) falls through to the existing countdown inside RecoveryDriversSection's own gate.
    if (showChargeBreakdown) {
        Dialog(
            onDismissRequest = { showChargeBreakdown = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ChargeBreakdownSheet(
                days = days,
                displayDay = displayMetric,
                carriedDay = lastScoredRecoveryDay,
                showReadiness = selectedDayOffset == 0,
                onClose = { showChargeBreakdown = false },
                // "How Charge is calculated" → close the breakdown and open the scoring guide at the Charge
                // section, the same target the per-ring ⓘ buttons use. Mirrors the iOS NavigationLink to
                // ScoringGuideView(initialSection: .charge) whose onClose dismisses the breakdown.
                onHowCalculated = {
                    showChargeBreakdown = false
                    openGuide(ScoreSection.CHARGE)
                },
            )
        }
    }

    // LIVE SESSIONS (beta): the full-screen session dialog — the same presentation the live-workout
    // overlay uses on Live (Dialog, usePlatformDefaultWidth = false). Dismissing it only HIDES the
    // screen: the runner (held in LiveSessionRunner.active, ticking on the app-wide viewModelScope)
    // keeps guarding, and the entry card above re-opens the same session. Only "End session" + the
    // summary's "Done" (inside the screen) actually finish and clear it.
    if (showLiveSession) {
        Dialog(
            onDismissRequest = { showLiveSession = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            LiveSessionScreen(vm = viewModel, onClose = { showLiveSession = false })
        }
    }

    // Key-Metrics layout editor (#251), a Today-local dialog (no new nav destination). Saves the layout
    // and re-reads it into local state so the grid updates immediately and survives relaunch.
    if (showMetricsEditor) {
        KeyMetricsEditorDialog(
            initial = enabledKeyMetrics,
            initialDetailed = keyMetricsDetailed,
            initialWindowDays = keyMetricsWindowDays,
            onDismiss = { showMetricsEditor = false },
            onSave = { metrics, detailed, windowDays ->
                KeyMetricPrefs.setEnabled(context, metrics)
                KeyMetricPrefs.setDetailed(context, detailed)
                KeyMetricPrefs.setDetailWindowDays(context, windowDays)
                enabledKeyMetrics = metrics
                keyMetricsDetailed = detailed
                keyMetricsWindowDays = windowDays
                showMetricsEditor = false
            },
        )
    }

    // "Your cards" uses the same shown/hidden editor pattern as Today and Key Metrics. Saves the
    // selection and re-reads it into local state so the dashboard updates immediately and survives relaunch.
    if (showDashboardEditor) {
        DashboardCardsEditorDialog(
            initial = enabledDashboardCards,
            onDismiss = { showDashboardEditor = false },
            onSave = { cards ->
                DashboardCardPrefs.setEnabled(context, cards)
                enabledDashboardCards = cards
                showDashboardEditor = false
            },
        )
    }

    // #today-hosted-cards: the add/remove/reorder editor for the Trends/Sleep cards hosted in Today. Saves
    // the selection and re-reads it into local state so the Added-cards section reflects it immediately.
    if (showHostedEditor) {
        HostedCardsEditorDialog(
            initial = enabledHostedCards,
            onDismiss = { showHostedEditor = false },
            onSave = { cards ->
                HostedCardPrefs.setEnabled(context, cards)
                enabledHostedCards = cards
                showHostedEditor = false
            },
        )
    }

    // #today-layout: the section-order editor (reorder the below-hero sections). Saves the order and
    // re-reads it into local state so Today re-lays-out immediately and survives relaunch. Its "Edit added
    // cards" button hands off to the hosted-cards editor above (#today-hosted-cards).
    if (showLayoutEditor) {
        TodayLayoutEditorDialog(
            initialOrder = sectionOrder,
            initialHidden = hiddenSections,
            onDismiss = { showLayoutEditor = false },
            onEditAdded = {
                showLayoutEditor = false
                showHostedEditor = true
            },
            onSave = { order, hidden ->
                TodayLayoutPrefs.setOrder(context, order)
                TodayLayoutPrefs.setHidden(context, hidden)
                sectionOrder = order
                hiddenSections = hidden
                showLayoutEditor = false
            },
        )
    }
}

/**
 * The accent quick-action "+" in the Today header's top-right. Moved off the bottom bar (now four clean
 * tabs) to balance the header and open the existing quick-action sheet. A small CONTAINED accent disc,  * the accented primary among an otherwise-neutral icon set, ~36dp, no float and no glow: a flat reset-blue
 * accent fill with a hairline rim, the "+" glyph in crisp white. Mirrors the iOS quick-action + (a glyph on
 * Circle().fill(StrandPalette.accent)).
 */
/**
 * Today "workout in progress" indicator (iOS parity: ActiveWorkoutIndicatorCard). A metricRose-tinted card
 * with a decorative live dot + "WORKOUT IN PROGRESS" overline, a live H:MM:SS clock, the sport label, and a
 * "Return to workout" button. The whole card is tappable; [onReturn] routes to Live and re-opens the
 * in-exercise overlay. The clock ticks in this card's OWN LaunchedEffect (reading [ActiveWorkout.startMs]),
 * so the per-second update recomposes only this card, never the Today body. Design tokens only, no glow.
 */
@Composable
private fun WorkoutInProgressCard(
    workout: AppViewModel.ActiveWorkout,
    onReturn: () -> Unit,
) {
    // Live clock: re-read wall-clock every second and recompute elapsed off the workout's start. Keyed on
    // startMs so a fresh session restarts the loop. Mirrors the iOS TimelineView(.periodic(by: 1)).
    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(workout.startMs) {
        while (true) {
            nowMs = System.currentTimeMillis()
            kotlinx.coroutines.delay(1000)
        }
    }
    val elapsedS = ((nowMs - workout.startMs) / 1000).coerceAtLeast(0)
    val elapsed = elapsedClock(elapsedS)
    val sportLabel = workout.sport.name

    // liquidPress on the whole tappable "return to workout" card (same interactionSource on clickable + press).
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        tint = Palette.metricRose,
        // Combine into ONE actionable element so TalkBack reads "Workout in progress, $sport, $elapsed,
        // Return to workout" as a single Button, not five stops; the decorative dot is omitted by clearing
        // child semantics. The whole card is the tap target.
        modifier = Modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onReturn)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_today_screen_workout_in_progress_sportlabel_elapsed_return_95ce4bda, sportLabel, elapsed)
            },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                // Decorative "live" dot, hidden from TalkBack (the merged card reads the full state).
                Box(
                    modifier = Modifier
                        .size(Metrics.space8)
                        .clip(CircleShape)
                        .background(Palette.metricRose)
                        .clearAndSetSemantics {},
                )
                Spacer(Modifier.width(Metrics.space8))
                Text(
                    uiString(R.string.l10n_today_screen_workout_in_progress_af2322c9),
                    style = NoopType.overline,
                    color = Palette.metricRose,
                )
                Spacer(Modifier.weight(1f))
                Text(elapsed, style = NoopType.number(15f), color = Palette.textPrimary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    sportLabel,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    // Take the free space (and ellipsize a long sport name) so the button stays its intrinsic
                    // width on the trailing edge, mirroring the iOS ViewThatFits label + trailing button.
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Metrics.space8))
                Button(
                    onClick = onReturn,
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) {
                    Text(uiString(R.string.l10n_today_screen_return_to_workout_30dc5509), style = NoopType.captionNumber)
                    Spacer(Modifier.width(Metrics.space6))
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
        }
    }
}

/**
 * The compact Live Sessions entry under the hero ("Start session · BETA"). Three honest states off the
 * process-wide [LiveSessionRunner.active]: no session → start affordance; session running → the way back
 * into the dismissed session dialog (with a live elapsed clock); session ended but its summary not yet
 * Done-dismissed → "See the summary". The runner's 1 Hz snapshot is collected INSIDE this card only, so
 * the per-second tick recomposes this card, never the Today body (the WorkoutInProgressCard idiom).
 * The whole card is one tap target; [onOpen] begins/re-presents the session dialog.
 */
@Composable
private fun LiveSessionEntryCard(onOpen: () -> Unit) {
    val active by LiveSessionRunner.active.collectAsStateWithLifecycle()
    val runner = active
    var running = false
    var summaryWaiting = false
    var elapsed = ""
    if (runner != null) {
        val snap by runner.snapshot.collectAsStateWithLifecycle()
        running = !snap.ended
        summaryWaiting = snap.ended
        elapsed = elapsedClock(snap.elapsedSec.toLong())
    }
    val teal = Palette.metricCyan
    val title = when {
        running -> uiString(R.string.today_live_session_running)
        summaryWaiting -> uiString(R.string.today_live_session_ended)
        else -> uiString(R.string.today_live_session_start)
    }
    val detail = when {
        running -> uiString(R.string.today_live_session_guarding)
        summaryWaiting -> uiString(R.string.today_live_session_summary)
        else -> uiString(R.string.today_live_session_explanation)
    }

    // liquidPress on the whole tappable card (same interactionSource on clickable + press), matching the
    // workout-in-progress card above. Merged semantics so TalkBack reads one Button, not four stops.
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        tint = teal,
        modifier = Modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onOpen)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_today_screen_title_beta_detail_6b39ae21, title, detail)
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(
                Icons.Filled.TrackChanges,
                contentDescription = null,
                tint = teal,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Text(title, style = NoopType.headline, color = Palette.textPrimary)
                    StatePill(uiString(R.string.today_beta), tone = StrandTone.Accent, showsDot = false)
                }
                Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
            }
            if (running) {
                Text(elapsed, style = NoopType.number(15f), color = Palette.textPrimary)
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
    }
}

/**
 * A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
 * [DataPendingNote]). Matches the "New here?" card's × styling. Dismisses the card into the inbox.
 */
@Composable
private fun TodayCardDismissButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(
        onClick = onClick,
        modifier = modifier
            .size(Metrics.iconButton)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_dismiss_to_updates_2c7915b8) },
    ) {
        Icon(
            Icons.Filled.Close,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun QuickActionDisc(onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            // Sit level with the avatar / battery ring in the liquid header cluster (shared size).
            .size(HeaderClusterControl)
            .liquidPress(interaction)
            .clip(CircleShape)
            // A translucent-white disc so the + reads on the day-of-sky like the rest of the liquid cluster,
            // with a crisp white glyph. Mirrors iOS LiquidAddButton (a "plus" on Circle().fill(.white@0.16)).
            .background(Color.White.copy(alpha = 0.16f))
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_quick_actions_e47e8042) },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Add,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
    }
}

// MARK: - Scoring-guide affordances (ⓘ + first-run card)

/**
 * The small ⓘ that opens the scoring guide. Used on the Charge ring and the Effort / Rest tiles.
 * [section] only tunes the accessibility label; the deep-link target is carried by [onClick]'s
 * call site. Icon-only, so it always carries a content description. [compact] shrinks the hit-target
 * for the tile headers (where a full 36dp button would crowd the fixed-height tile).
 */
@Composable
private fun ScoreInfoButton(
    section: ScoreSection?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val label = section?.let { uiString(R.string.today_how_score_named, uiString(it.labelRes)) }
        ?: uiString(R.string.today_how_score_generic)
    val button = if (compact) 24.dp else Metrics.iconButton
    val glyph = if (compact) 16.dp else Metrics.iconSmall
    IconButton(onClick = onClick, modifier = modifier.size(button)) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = label,
            tint = Palette.textTertiary,
            modifier = Modifier.size(glyph),
        )
    }
}

/**
 * One-time "New here?" card pointing first-run users at the scoring guide. A NoopCard in the Today
 * flow, never a dialog, with a primary "See how it works" action and a ✕ dismiss; both set the
 * seen-flag at the call site so the card never returns. Copy verbatim from the approved source.
 */
@Composable
private fun ScoringGuideIntroCard(onOpen: () -> Unit, onDismiss: () -> Unit) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(uiString(R.string.l10n_today_screen_new_here_b81f2e17), style = NoopType.headline, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = uiString(R.string.l10n_today_screen_dismiss_70afe9ef) },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
            Text(
                uiString(R.string.l10n_today_screen_see_how_charge_effort_and_rest_80243197),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onOpen) {
                    Text(uiString(R.string.l10n_today_screen_see_how_it_works_f7b38f07), style = NoopType.captionNumber, color = Palette.accent)
                }
            }
        }
    }
}

// MARK: - Liquid Today header (iOS LiquidTodayView.scene parity)
//
// A STRUCTURAL rebuild to mirror the iOS liquid Today header element-for-element (NOT the old numeric-date +
// recording-light + bell header). LEFT: a tappable title block — the big rounded-bold day title over a human
// date line ("Friday, 3 July"), tap opens the day picker. RIGHT: exactly the iOS four controls, in order —
// a filled HEART (→ Support), the PROFILE AVATAR (→ Settings), a "+" ADD button (→ quick actions), and the
// strap BATTERY RING (→ Devices). Each ~36dp, spacing ~8dp. There is no recording light and no bell here;
// iOS's Today header has neither, and the Updates inbox is relocated into the "+" quick-actions sheet.

/** The uniform diameter of the round Today-header controls — profile avatar, quick-add (+) and the strap
 *  battery ring — so they sit level in the liquid cluster (the sync chip beside them is content-sized).
 *  Single source of truth so a size tweak keeps all three in lockstep. */
private val HeaderClusterControl = 36.dp

@Composable
private fun LiquidTodayHeader(
    dayTitle: String,
    humanDate: String,
    selectedDay: LocalDate,
    batteryPct: Double?,
    // #245: sync state for the compact header chip (twin of iOS SyncStatusChip).
    backfilling: Boolean = false,
    syncChunksThisSession: Int = 0,
    lastSyncAt: Long? = null,
    historySyncExperimental: Boolean = false,
    onPickDay: (Int) -> Unit,
    onQuickActions: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDevices: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showPicker by remember { mutableStateOf(false) }
    if (showPicker) {
        val context = LocalContext.current
        DisposableEffect(selectedDay) {
            val cal = Calendar.getInstance().apply {
                set(selectedDay.year, selectedDay.monthValue - 1, selectedDay.dayOfMonth)
            }
            // Anchor the offset to the LOGICAL day (matches selectedDayOffset's anchor) so a picked date
            // resolves to the same row the header is labelling, never drifting against LocalDate.now().
            val anchor = logicalDayNow()
            val dialog = DatePickerDialog(
                context,
                { _, year, month, day ->
                    val picked = LocalDate.of(year, month + 1, day)
                    val offset = ChronoUnit.DAYS.between(picked, anchor).toInt().coerceAtLeast(0)
                    onPickDay(offset)
                    showPicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            ).apply {
                datePicker.maxDate = System.currentTimeMillis()
                setOnDismissListener { showPicker = false }
            }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // LEFT: the tappable title block — big rounded-bold day title over the human date line. Taps open the
        // day picker; a horizontal swipe across the dashboard still changes the day. weight(1f) so the title
        // claims the leading room and never pushes the trailing control cluster. Mirrors iOS's title Button.
        Column(
            modifier = Modifier
                .weight(1f)
                // #492: NO rounded clip here. With indication = null there's no ripple to shape, and the
                // rounded corners were clipping the title/date text's bottom-left (the "W" of "Wednesday").
                // iOS's title Button uses a plain contentShape(Rectangle()) with no clip — mirror that.
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClickLabel = uiString(R.string.today_action_change_day),
                    onClick = { showPicker = true },
                )
                .semantics { contentDescription = uiString(R.string.l10n_today_screen_daytitle_humandate_tap_to_pick_a_7e12ce96, dayTitle, humanDate) },
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                dayTitle,
                // ~28sp Bold rounded, matching iOS `StrandFont.rounded(28)`. A soft shadow so it reads on the
                // day-of-sky. NoopType.number is the house tabular sans; Bold at 28 is the display day title.
                style = NoopType.number(28f, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.4f), offset = Offset(0f, 1f), blurRadius = 10f)),
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                humanDate,
                style = NoopType.caption.copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.35f), offset = Offset(0f, 1f), blurRadius = 8f)),
                color = Color.White.copy(alpha = 0.78f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // RIGHT: the controls, in order — [sync chip] · avatar · + · battery ring. Each ~36dp, 8dp apart.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // #245: compact sync-status chip, shown for EVERY user — syncing / last-synced / experimental,
            // so the absence of active syncing reads as caught-up (the full SyncingHistoryNote is gated on
            // recovery == null). Twin of iOS SyncStatusChip.
            SyncStatusChip(
                backfilling = backfilling, chunks = syncChunksThisSession,
                lastSyncAt = lastSyncAt, historySyncExperimental = historySyncExperimental,
            )
            // (a) Profile avatar (the photo set in Settings, or the NOOP loop mark) → Settings. Mirrors iOS.
            Box(
                modifier = Modifier
                    .size(HeaderClusterControl)
                    .clip(CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenSettings,
                    )
                    .semantics { contentDescription = uiString(R.string.l10n_today_screen_profile_and_settings_9b3d12f2) },
                contentAlignment = Alignment.Center,
            ) {
                ProfileAvatar(size = HeaderClusterControl)
            }
            // (b) Quick-add (+), the accented primary. Mirrors iOS's LiquidAddButton (a glyph on a translucent
            // disc → the quick-actions menu). Sized to match the rest of the liquid cluster (shared HeaderClusterControl).
            QuickActionDisc(onClick = onQuickActions)
            // (c) Strap battery ring showing the % (iOS LiquidBatteryButton). Tap → Devices.
            LiquidBatteryRing(batteryPct = batteryPct, onClick = onOpenDevices)
        }
    }
}

/** #245: compact sync-status chip for the Today top bar, shown to EVERY user. The full-width
 *  SyncingHistoryNote is gated on `recovery == null`, so an established user (and especially a WHOOP 5/MG
 *  owner, whose history offloads are rare) saw no sync feedback on Today. THREE states so the ABSENCE of
 *  active syncing reads as "caught up", not "missing indicator" (the real #245 confusion): actively
 *  offloading → ⟳ N; idle with a known last-sync → ✓ Xm; a 5/MG whose history sync is experimental
 *  (live-connected, no completed offload yet) → ✓ live. Nothing shows only on a true cold start (the
 *  building-scores note owns that). Twin of iOS SyncStatusChip. DRAFT (#245): final styling/wording TBD. */
@Composable
private fun SyncStatusChip(
    backfilling: Boolean,
    chunks: Int,
    lastSyncAt: Long?,
    historySyncExperimental: Boolean,
) {
    // The clock and the translated "now" word are resolved HERE, in the composable that already depends
    // on both, and handed down — so `SyncChipState.resolve` stays a genuinely pure decision that a plain
    // JVM unit test can call with no attached Application. Reading the clock at composition time (rather
    // than snapshotting it) is unchanged behaviour: `shortSyncAgo` did exactly this on every recomposition.
    val state = SyncChipState.resolve(
        backfilling = backfilling,
        chunks = chunks,
        lastSyncAtSec = lastSyncAt,
        historySyncExperimental = historySyncExperimental,
        nowSec = System.currentTimeMillis() / 1000L,
    )
    when (state) {
        is SyncChipState.Syncing -> ChipCapsule(
            Icons.Filled.Autorenew, "${state.chunks}", Palette.accent,
            uiString(R.string.l10n_today_screen_sync_chip_syncing_desc_bfc290e7, state.chunks))
        is SyncChipState.Synced -> ChipCapsule(
            Icons.Filled.Check, state.agoText, Palette.textSecondary,
            uiString(R.string.l10n_today_screen_sync_chip_synced_desc_4d255944, state.agoText))
        SyncChipState.ExperimentalLive -> ChipCapsule(
            Icons.Filled.Check, uiString(R.string.l10n_today_screen_sync_chip_live_98aadb37), Palette.textSecondary,
            uiString(R.string.l10n_today_screen_sync_chip_experimental_desc_3de06a70))
        SyncChipState.Hidden -> Unit
        // cold start — render nothing; the building-scores note covers it.
    }
}

/** The shared sync-chip capsule (icon + terse label). Twin of the iOS `SyncStatusChip.chip`. */
@Composable
private fun ChipCapsule(icon: ImageVector, text: String, tint: Color, desc: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            // Match the round header controls' height so the pill sits the same size in the cluster
            // (#1207 follow-up); width stays content-driven. Content centres via the fixed height.
            .height(HeaderClusterControl)
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceInset)
            .padding(horizontal = 10.dp),
    ) {
        Icon(icon, contentDescription = desc, tint = tint, modifier = Modifier.size(14.dp))
        Text(text, style = NoopType.caption, color = tint)
    }
}

/** The liquid header strap-battery ring: when connected + a reading exists it draws a trimmed ring in
 *  the charge/warning/critical hue plus the % inside, else a
 *  bolt-slash glyph. Tap → Devices. Mirrors the iOS liquid header battery ring. */
@Composable
private fun LiquidBatteryRing(batteryPct: Double?, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val label = batteryPct?.let { uiString(R.string.today_strap_battery_percent, it.roundToInt()) }
        ?: uiString(R.string.today_strap_battery)
    Box(
        modifier = Modifier
            .size(HeaderClusterControl)
            .liquidPress(interaction)
            .clip(CircleShape)
            // A translucent near-black disc + faint white rim, matching iOS (rgba(10,11,16,.5) + white@.15).
            .background(Color(red = 10f / 255f, green = 11f / 255f, blue = 16f / 255f, alpha = 0.5f))
            .border(1.dp, Color.White.copy(alpha = 0.15f), CircleShape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        if (batteryPct != null) {
            val pct = batteryPct.coerceIn(0.0, 100.0)
            val ringColor = when {
                pct < 15 -> Palette.statusCritical
                pct < 35 -> Palette.statusWarning
                else -> Palette.chargeColor
            }
            Canvas(modifier = Modifier.size(HeaderClusterControl).padding(2.5.dp)) {
                val strokePx = 3.dp.toPx()
                val d = size.minDimension - strokePx
                val topLeft = Offset((size.width - d) / 2f, (size.height - d) / 2f)
                // Track.
                drawArc(
                    color = Color.White.copy(alpha = 0.10f),
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = Size(d, d),
                    style = Stroke(width = strokePx, cap = StrokeCap.Round),
                )
                // Fill arc (min 2% so a near-flat battery still shows a cap), clockwise from 12 o'clock.
                drawArc(
                    color = ringColor,
                    startAngle = -90f,
                    sweepAngle = (360f * (pct / 100.0).coerceIn(0.02, 1.0)).toFloat(),
                    useCenter = false,
                    topLeft = topLeft,
                    size = Size(d, d),
                    style = Stroke(width = strokePx, cap = StrokeCap.Round),
                )
            }
            Text(
                uiString(R.string.l10n_today_screen_pct_roundtoint_05ba4549, pct.roundToInt()),
                style = NoopType.number(9f, weight = FontWeight.Bold),
                color = Color.White.copy(alpha = 0.9f),
            )
        } else {
            Icon(
                Icons.AutoMirrored.Filled.BatteryUnknown,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.size(15.dp),
            )
        }
    }
}

// MARK: - NOOP wordmark (iOS LiquidWordmark parity — centred, with a tap easter egg)
//
// The subtle "N O O P" wordmark that sits on the sky between the header and the hero. Built as a row of
// letters (not one tracked string, which adds a trailing gap after the last glyph and pushes the word
// off-centre), so it sits DEAD centre, white @ ~50% opacity. A tap plays one of several random one-shot
// animations — wiggle / shake / flip / spin / bounce / jelly squash. Mirrors iOS LiquidWordmark.

@Composable
private fun LiquidWordmark() {
    val reduced = rememberReduceMotion()
    var rot by remember { mutableStateOf(0f) }        // z-rotation (wiggle / spin)
    var scaleX by remember { mutableStateOf(1f) }     // horizontal scale (jelly squash)
    var scaleY by remember { mutableStateOf(1f) }     // vertical scale (bounce / jelly)
    var dx by remember { mutableStateOf(0f) }         // horizontal offset (shake)
    var egg by remember { mutableIntStateOf(0) }      // which egg to play (drives the LaunchedEffect)

    val view = LocalView.current
    val animRot by animateFloatAsState(rot, tween(durationMillis = if (reduced) 0 else 520), label = uiString(R.string.l10n_today_screen_wordmark_rot_21de874b))
    val animScaleX by animateFloatAsState(scaleX, tween(durationMillis = if (reduced) 0 else 380), label = uiString(R.string.l10n_today_screen_wordmark_sx_68fa7b60))
    val animScaleY by animateFloatAsState(scaleY, tween(durationMillis = if (reduced) 0 else 380), label = uiString(R.string.l10n_today_screen_wordmark_sy_7b8bd743))
    val animDx by animateFloatAsState(dx, tween(durationMillis = if (reduced) 0 else 420), label = uiString(R.string.l10n_today_screen_wordmark_dx_d428284f))

    // On each tap, kick a value to an extreme then settle it back so the animateFloatAsState eases through
    // to rest — a natural wobble without hand-authored keyframes. Six variants, chosen at random per tap.
    LaunchedEffect(egg) {
        if (egg == 0) return@LaunchedEffect
        when ((0..5).random()) {
            0 -> { rot = -12f; kotlinx.coroutines.delay(90); rot = 0f }            // wiggle
            1 -> { dx = -12f; kotlinx.coroutines.delay(90); dx = 0f }              // shake
            2 -> { rot += 360f }                                                    // spin
            3 -> { scaleX = 1.28f; scaleY = 1.28f; kotlinx.coroutines.delay(90); scaleX = 1f; scaleY = 1f } // bounce
            4 -> { scaleX = 1.35f; scaleY = 0.7f; kotlinx.coroutines.delay(90); scaleX = 1f; scaleY = 1f }  // jelly
            else -> { rot += 360f }                                                 // flip (spin twin)
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) {
                egg += 1
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            }
            .graphicsLayer {
                rotationZ = animRot
                this.scaleX = animScaleX
                this.scaleY = animScaleY
                translationX = animDx
            }
            .clearAndSetSemantics {}, // decorative wordmark — invisible to TalkBack
        horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        "NOOP".forEach { ch ->
            Text(
                ch.toString(),
                style = NoopType.number(16f, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.25f), offset = Offset(0f, 1f), blurRadius = 6f)),
                color = Color.White.copy(alpha = 0.5f),
            )
        }
    }
}

// MARK: - Score hero row, three Charge / Effort / Rest score vessels
//
// The liquid Today hero: three equal daily-score vessels in Charge / Effort / Rest order, with a tappable
// label beneath each one and one card-level provenance badge aligned to the Rest vessel's trailing edge.

@Composable
private fun ScoreHeroRow(
    day: DailyMetric?,
    restScore: Double?,
    recoveryCalibration: Int?,
    lastScoredCharge: LastCharge? = null,
    effortScale: EffortScale,
    liveTodayStrain: Double? = null,
    // One card-level provenance label derived from the three REAL per-metric merge winners upstream.
    heroSourceLabel: String? = null,
    onScoreInfo: (ScoreSection) -> Unit,
    // A1 (#514/#706): tapping the Charge ring opens the breakdown sheet. A small chevron cue overlays the
    // ring's bottom edge INSIDE the ring frame, so it adds no stacked height (the #762 self-sizing parity).
    onChargeTap: (() -> Unit)? = null,
) {
    val recovery = day?.recovery
    // Prefer the live in-progress Effort for today, but never BELOW the day's already-earned strain
    // (#489/#506: a live under-read replaced today's real Effort with 0). The effective value drives the
    // gauge number AND the has-data / "No Data" branch, so the ring only reads "No Data" when neither
    // exists. Mirrors the iOS live-Effort gauge. (#402)
    // #1001: the shared rule, so this ring and the Key Metrics tile / chart badge cannot disagree.
    val strain = StrainScorer.effectiveEffort(live = liveTodayStrain, stored = day?.strain)
    // Effort honours the 0–100 / WHOOP-0–21 toggle (#313). The stored strain is on NOOP's 0–100 Effort
    // axis; render it on the user's selected scale so the arc and centre number match the app's Effort.
    val effortOutOf = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0
    val effortVal = strain?.let { UnitFormatter.effortValue(it, effortScale) } ?: 0.0

    // The vessels run LIVE (per-frame slosh + tilt) once the row has any real score to show; a wholly
    // empty/calibrating hero poses them static so a brand-new user's launch churn isn't fighting live
    // canvases (the Android equivalent of the iOS `dataLoaded` gate on HeroScoreCell). LiquidVessel + the
    // count-up both honour Reduce Motion internally, so this is purely a "don't animate an empty hero" cost
    // gate. A carried Charge counts as data (its dimmed vessel should slosh like the Rest one).
    val animated = recovery != null || strain != null || restScore != null || lastScoredCharge != null

    Box(
        modifier = Modifier
            .fillMaxWidth(),
    ) {
        // iOS parity: the hero rings float DIRECTLY on the SCREEN-level day-cycle scene (the scaffold's
        // topBackground), not on any per-hero atmosphere or the old scenic indigo gradient, matching
        // TodayView, which moved the scene to a screen-level SceneScreenBackground and dropped the
        // per-hero scene/ScenicHeroBackground.
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.gap, vertical = Metrics.space16),
        ) {
            // iOS parity (TodayView.scoreHeroRow): three EQUAL rings in CHARGE · EFFORT · REST order, no
            // enlarged centre, filling the width as one balanced row. Ring stroke 0.10 (WHOOP weight).
            val ringGap = 14.dp
            // #1502: ONE width for all three columns. Charge and Effort used to size to their own label
            // rows while Rest alone was pinned to `ring` (its box anchors the source badge), so the three
            // columns came out different widths — read as "the rings aren't the same size" — and Rest's
            // label had the least room of the three despite REST being the shortest word, which is why it
            // was the one ellipsising to "R…". Three of these plus two gaps is exactly maxWidth.
            val col = (maxWidth - ringGap * 2) / 3
            // The 90.dp floor can exceed `col` once the hero is under ~298.dp wide — a small phone, a
            // split-screen pane, a foldable's cover display. Unbounded, that overflowed the column; bounded,
            // the vessel simply shrinks with its column instead of spilling out of it.
            val ring = ((maxWidth - ringGap * 2) / 3.1f).coerceIn(90.dp, 112.dp).coerceAtMost(col)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(ringGap, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.Top,
            ) {
                // CHARGE, recovery 0–100, as a liquid VESSEL with the value counting up over it. Honest
                // empty / calibrating overlay; badges its recovery winner.
                HeroRingColumn(
                    modifier = Modifier.width(col),
                    domain = DomainTheme.Charge,
                    onInfo = { onScoreInfo(ScoreSection.CHARGE) },
                    onRingTap = onChargeTap,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        // #802: when today has no Charge yet but a prior night's value is carried, draw a
                        // DIMMED (0.8 opacity) REAL vessel filled to the carried value, matching the Rest
                        // vessel, rather than a bare number on an empty vessel (which read as broken). Same
                        // diameter so the self-sizing hero row is untouched; the dim + the carried "Last
                        // night · <date>" caption mark it as carried, not today's fresh score. Mirrors iOS.
                        val carried = if (recovery == null && recoveryCalibration == null) lastScoredCharge else null
                        if (carried != null) {
                            HeroScoreVessel(
                                modifier = Modifier.alpha(0.8f),
                                fraction = carried.value / 100.0,
                                value = carried.value,
                                tint = Palette.recoveryColor(carried.value),
                                diameter = ring,
                                animated = animated,
                                showsValue = true,
                            )
                        } else {
                            HeroScoreVessel(
                                fraction = (recovery ?: 0.0) / 100.0,
                                value = recovery ?: 0.0,
                                tint = Palette.recoveryColor(recovery ?: 0.0),
                                diameter = ring,
                                animated = animated,
                                showsValue = recovery != null,
                            )
                            // Empty vessel + calibrating / no-data overlay (the carried case is above).
                            if (recovery == null) RingEmptyOverlay(recoveryCalibration, diameter = ring)
                        }
                        // No in-vessel tap cue: the single tap affordance is the CHARGE-label chevron below
                        // the vessel (HeroRingColumn), matching iOS where the in-ring cue was removed.
                    }
                }
                // EFFORT, strain on the gauge, on the user's selected scale, as a liquid vessel.
                HeroRingColumn(
                    modifier = Modifier.width(col),
                    domain = DomainTheme.Effort,
                    onInfo = { onScoreInfo(ScoreSection.EFFORT) },
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        HeroScoreVessel(
                            fraction = if (effortOutOf > 0) effortVal / effortOutOf else 0.0,
                            value = effortVal,
                            tint = Palette.effortTint((strain ?: 0.0) / 100.0),
                            diameter = ring,
                            animated = animated,
                            showsValue = strain != null,
                            format = { if (effortScale == EffortScale.WHOOP) String.format(Locale.getDefault(), "%.1f", it) else it.toInt().toString() },
                        )
                        if (strain == null) RingNoData(diameter = ring)
                    }
                }
                // REST, sleep composite 0–100. Its fixed-width box also anchors the card-level source badge:
                // the badge may grow leftward, but its trailing edge always matches the Rest vessel.
                Box(modifier = Modifier.width(col)) {
                    HeroRingColumn(
                        modifier = Modifier.width(col),
                        domain = DomainTheme.Rest,
                        onInfo = { onScoreInfo(ScoreSection.REST) },
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            HeroScoreVessel(
                                fraction = (restScore ?: 0.0) / 100.0,
                                value = restScore ?: 0.0,
                                tint = Palette.recoveryColor(restScore ?: 0.0),
                                diameter = ring,
                                animated = animated,
                                showsValue = restScore != null,
                            )
                            // #898: an aggregate-import user (a daily HRV/RHR import, no in-bed session) gets a
                            // Charge from WatchRecovery but NO sleep_performance, so Rest used to read a bare
                            // "No Data" next to a lit Charge , reading as broken. When a Charge IS present for the
                            // day but Rest is absent, say WHY honestly ("Needs a tracked night") instead. We do
                            // NOT fabricate a Rest number , an aggregate genuinely has no scored night. A day with
                            // no Charge either (truly empty) keeps the plain "No Data". Mirrors iOS restRing.
                            if (restScore == null) {
                                if (recovery != null) RingNeedsTrackedNight() else RingNoData(diameter = ring)
                            }
                        }
                    }
                    if (heroSourceLabel != null) {
                        SourceBadge(
                            text = heroSourceLabel,
                            // #1160: the hero is theme-aware now, so its badge uses the flip-able text token.
                            tint = Palette.textSecondary,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                // Measure the full label even when it is wider than the Rest vessel, then
                                // let it overflow left while preserving the vessel-aligned trailing edge.
                                .wrapContentWidth(unbounded = true, align = Alignment.End)
                                // #1502: the box is now the shared column width rather than the vessel's,
                                // so inset by the slack to keep the badge's trailing edge on the VESSEL —
                                // the alignment this anchor exists for.
                                .padding(end = ((col - ring) / 2).coerceAtLeast(0.dp))
                                // Match iOS: centre the pill on the card border, aligned with the Rest vessel.
                                .offset(y = -(Metrics.space16 + Metrics.sourceBadgeHeight / 2))
                                .semantics { contentDescription = uiString(R.string.l10n_today_screen_source_herosourcelabel_d3363687, heroSourceLabel) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * One hero ring column: the ring, with a tappable UPPERCASE domain label + chevron beneath it (the
 * WHOOP affordance) that opens the matching scoring-guide section. Provenance belongs to the whole hero
 * card and is rendered once by [ScoreHeroRow], so this column only owns score content and navigation.
 */
@Composable
private fun HeroRingColumn(
    domain: DomainTheme,
    onInfo: () -> Unit,
    modifier: Modifier = Modifier,
    // A1: when non-null (Charge), the ring is tappable and opens the breakdown sheet. The chevron cue is
    // overlaid by the caller INSIDE the ring box so it adds no stacked height (#762 self-sizing parity).
    onRingTap: (() -> Unit)? = null,
    ring: @Composable () -> Unit,
) {
    val domainLabel = uiString(
        when (domain) {
            DomainTheme.Charge -> R.string.today_metric_charge
            DomainTheme.Effort -> R.string.today_metric_effort
            DomainTheme.Rest -> R.string.today_metric_rest
            DomainTheme.Stress -> R.string.today_card_stress
        },
    )
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (onRingTap != null) {
            // liquidPress on the tappable Charge vessel so it settles inward on press (the vessel itself
            // also splashes via LiquidVessel's own tap). Same interactionSource on the clickable + press.
            val ringInteraction = remember { MutableInteractionSource() }
            Box(
                modifier = Modifier
                    .liquidPress(ringInteraction)
                    .clip(CircleShape)
                    .clickable(
                        interactionSource = ringInteraction,
                        indication = null,
                        onClickLabel = uiString(R.string.today_action_see_what_shaped, domainLabel),
                        onClick = onRingTap,
                    ),
            ) { ring() }
        } else {
            ring()
        }
        // #937 wanted the WORD centred on the ring's axis, not the word-plus-chevron block, and got there
        // by balancing the row with an invisible LEADING twin of the chevron. That worked, but it spent a
        // second 14.dp slot plus its gap on nothing — and inside Rest's ring-width box that left the label
        // barely 50.dp on a compact screen, so "REST" ellipsised to "R…" at a larger font scale (#1502).
        //
        // Centring in a Box gets the same axis for free: the column is symmetric, so a centred word sits on
        // the ring's centre by construction, and the chevron floats at the trailing edge instead of paying
        // for a counterweight. The word reserves 16.dp each side so it can never run under the chevron
        // (which needs 14.dp), keeping the layout honest at any label length, and the whole box is the tap
        // target. RTL still mirrors: Box alignments and the AutoMirrored icon both flip.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(50))
                .clickable { onInfo() }
                .padding(vertical = Metrics.space2),
            contentAlignment = Alignment.Center,
        ) {
            // Keep the word centred on the vessel independently of the trailing chevron. Giving the label
            // the complete fixed score-column width prevents longer translations (for example ERHOLUNG)
            // from pushing the third column right or being clipped at the screen edge.
            AutoSizeValue(
                text = domainLabel.uppercase(),
                style = NoopType.overline,
                color = Palette.textSecondary,
                modifier = Modifier
                    .fillMaxWidth()
                    // Keep almost the complete width available on the leading side. The larger trailing
                    // inset reserves space for the chevron without shifting or clipping longer labels.
                    .padding(start = Metrics.space2, end = Metrics.space18),
                minScale = 0.7f,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = uiString(R.string.l10n_today_screen_how_domain_label_is_calculated_8897768c, domainLabel),
                tint = Palette.textSecondary.copy(alpha = 0.6f),
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .size(Metrics.space14),
            )
        }
    }
}

/**
 * One hero score as a liquid VESSEL with the value counting up over it — the signature liquid Today hero
 * element. A [LiquidVessel] (Compose primitive, LiquidPrimitives.kt) fills to [fraction] (0..1) in the
 * domain [tint], sized to [diameter]; over it a [CountUpText] rolls the number up to [value] (white,
 * tabular, a soft shadow so it reads on the vessel), matching the iOS `HeroScoreCell` (a count-up number
 * over a filling vessel). The number is hit-transparent (clearAndSetSemantics + no clickable) so a tap
 * falls THROUGH to the vessel — LiquidVessel owns its own tap→splash+haptic; the enclosing HeroRingColumn
 * adds the Charge breakdown tap. When [showsValue] is false (no score yet) the vessel draws empty and the
 * caller overlays the calibrating / No-Data text, so the number is simply omitted here.
 *
 * The number size tracks the diameter (≈ 0.27×, capped) so the three equal vessels stay balanced; it
 * mirrors the iOS 96dp-vessel → 26pt-number ratio. Values/bindings are UNCHANGED from the GlowRing this
 * replaced — same fraction, same value, same value-sampled tint.
 */
@Composable
private fun HeroScoreVessel(
    fraction: Double,
    value: Double,
    tint: Color,
    diameter: Dp,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
    showsValue: Boolean = true,
    format: (Double) -> String = { it.roundToInt().toString() },
) {
    Box(modifier = modifier.size(diameter), contentAlignment = Alignment.Center) {
        LiquidVessel(
            value = fraction.coerceIn(0.0, 1.0),
            tint = tint,
            animated = animated,
            modifier = Modifier.size(diameter),
        )
        if (showsValue) {
            // Count-up number over the vessel — white, tabular, a soft shadow for legibility, hit-transparent
            // so the tap reaches the vessel (splash). Size ≈ diameter × 0.27 (iOS 96→26 ratio), capped.
            val numberSp = (diameter.value * 0.27f).coerceIn(20f, 30f)
            CountUpText(
                value = value,
                format = format,
                style = NoopType.number(numberSp, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                color = Color.White,
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
    }
}

/**
 * The plain-English Synthesis card, the Charge-tinted [InsightCard] read-out under the ring hero, with a
 * WHITE headline (the key iOS Design-Reset change, `statusColor: textPrimary`, not the recovery/charge
 * colour), carrying the greeting + the SOLID / CALIBRATING data-confidence pill in its top-right. Mirrors
 * the iOS Synthesis InsightCard (which moved here when the big RecoveryRing hero that owned the pill went).
 */
@Composable
private fun SynthesisHeroCard(
    day: DailyMetric?,
    recoveryCalibration: Int?,
    carriedDay: DailyMetric? = null,
    // S4: the day history (for the one-word readiness read), whether the Synthesis card is expanded, and the
    // taps to toggle it / open the Charge breakdown (where the full Readiness card lives). Defaults keep old
    // call sites compiling; the Today call site supplies them.
    days: List<DailyMetric> = emptyList(),
    synthesisExpanded: Boolean = true,
    onToggleSynthesis: () -> Unit = {},
    onOpenReadiness: () -> Unit = {},
) {
    // The row the synthesis reads from: today's own when it carries recovery, else the carried-over last
    // scored day (#543) so the card mirrors the carried Charge ring instead of blanking to "No Data". When
    // carrying, the detail line gets a "Last night · <date>" provenance so the prior read isn't passed off
    // as today's. today's own read wins the instant tonight is scored.
    val readDay = carriedDay ?: day
    val recovery = readDay?.recovery
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // The greeting + SOLID/CALIBRATING data-confidence pill ride in their OWN header row ABOVE the
        // card, not as a top-end overlay over it (#527). The old overlay sat over the card's "SYNTHESIS"
        // overline + big status word and, on a narrow phone, collided with them, and squeezing the
        // status into the leftover width force-broke a single word ("Calibrating" → "Calibrati/ng").
        // A separate row CAN'T overlap, and the card keeps its FULL width so the status stays one line.
        // Mirrors the iOS Synthesis header-row layout (TodayView heroSection).
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The greeting yields/ellipsises first; the pill keeps its full width (#527).
            Text(
                greetingWord(),
                style = NoopType.subhead,
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.weight(1f))
            // S4 (#205): the one-word readiness read kept on the hero now the full Readiness card folded
            // into the Charge-ring tap. Push / Maintain / Rest; hidden when there isn't enough history.
            // Tapping it opens the Charge breakdown, where the full Readiness card now lives.
            val readinessLevel = remember(days) {
                if (days.isEmpty()) ReadinessEngine.Level.INSUFFICIENT
                else ReadinessEngine.evaluate(days, today = logicalDayKeyNow()).level
            }
            readinessWord(readinessLevel)?.let { wordRes ->
                ReadinessHeroPill(word = uiString(wordRes), level = readinessLevel, onTap = onOpenReadiness)
            }
            // SOLID only when TODAY's own row carries a settled recovery, a carried prior-day read is
            // honestly still CALIBRATING for today, matching the iOS pill (keyed on displayDay.recovery).
            val todayRecovery = day?.recovery
            StatePill(
                title = if (todayRecovery != null) uiString(R.string.today_score_solid)
                else uiString(R.string.score_state_title_calibrating).uppercase(),
                tone = if (todayRecovery != null) StrandTone.Accent else StrandTone.Neutral,
            )
        }
        // S4: the Synthesis card collapses to a one-liner that expands on tap. The headline (the status) is
        // the SAME in both states, only the detail body and chrome fold, never the read (#506).
        val status = if (recoveryCalibration != null) uiString(R.string.score_state_title_calibrating)
        else synthesisWord(recovery)
        val detail = if (recoveryCalibration != null) {
            // #612: if the baseline aged out silently — connected, but no new night for > staleDays — say WHY
            // it's calibrating instead of only "learning your baseline". `stale` is always > staleDays (14).
            val stale = Baselines.nightsSinceNewestValidNight(days.map { it.day }, days.map { it.avgHrv }, logicalDayKeyNow())
            if (stale != null && stale > Baselines.staleDays) {
                uiString(R.string.l10n_today_screen_no_new_nights_from_your_strap_for_stale_days_8863bcfe, stale)
            } else {
                // Comma (not the old em-dash) to match the Swift canonical synthesis copy VERBATIM
                // (TodayView "Learning your baseline, N of M nights.") and the no-em-dash standing rule.
                uiString(R.string.today_synthesis_learning_baseline, recoveryCalibration, Baselines.minNightsSeed)
            }
        } else if (carriedDay != null) {
            // Carried prior-day read, summarise that day + stamp it so it isn't passed off as today's.
            uiString(
                R.string.today_synthesis_carried_detail,
                synthesisDetail(carriedDay), carriedCaption(carriedDay.day).localized(),
            )
        } else {
            synthesisDetail(day)
        }
        if (synthesisExpanded) {
            val expandedInteraction = remember { MutableInteractionSource() }
            Box(
                modifier = Modifier
                    .liquidPress(expandedInteraction)
                    .clickable(
                        interactionSource = expandedInteraction,
                        indication = null,
                        onClickLabel = uiString(R.string.today_action_collapse),
                        onClick = onToggleSynthesis,
                    ),
            ) {
                InsightCard(
                    modifier = Modifier.fillMaxWidth(),
                    category = uiString(R.string.today_section_synthesis),
                    status = status,
                    detail = detail,
                    // The SYNTHESIS headline reads WHITE (textPrimary), not the recovery/charge colour, the
                    // key iOS Design-Reset change (TodayView.synthesisSection passes statusColor textPrimary).
                    statusColor = Palette.textPrimary,
                    // FLAT card to match iOS (no navy-bevel gradient / border): identity comes from the white
                    // headline alone. tint = null routes to the neutral FLAT surfaceRaised + hairline path.
                    tint = null,
                )
            }
        } else {
            // Collapsed: a one-liner with the SYNTHESIS overline, the status headline and a down-chevron.
            val collapsedInteraction = remember { MutableInteractionSource() }
            NoopCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidPress(collapsedInteraction)
                    .clickable(
                        interactionSource = collapsedInteraction,
                        indication = null,
                        onClickLabel = uiString(R.string.today_action_expand_full_read),
                        onClick = onToggleSynthesis,
                    ),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_today_screen_synthesis_876bc749), style = NoopType.overline, color = Palette.textTertiary)
                        Text(
                            status,
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * S4 (#205): the one-word readiness pill on the hero (Push / Maintain / Rest). A small tinted capsule
 * matching the score-pill chrome, coloured by the readiness level; tapping opens the Charge breakdown sheet
 * where the full Readiness card lives. Mirrors the iOS readinessHeroPill.
 */
@Composable
private fun ReadinessHeroPill(word: String, level: ReadinessEngine.Level, onTap: () -> Unit) {
    val tone = readinessColor(level)
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tone.copy(alpha = 0.12f))
            .border(1.dp, tone.copy(alpha = 0.32f), RoundedCornerShape(50))
            .clickable(onClickLabel = uiString(R.string.today_action_full_readiness), onClick = onTap)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_readiness_word_749b3330, word) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(word.uppercase(), style = NoopType.overline, color = tone)
    }
}

/** Honest overlay shown over the Charge ring when today's recovery is null: either the calibrating count
 *  or No data. The carried last-scored Charge case is NOT handled here anymore: it's intercepted earlier
 *  and drawn as a dimmed FILLED ring in the carried branch (matching iOS chargeRing), so this overlay only
 *  covers the calibrating and no-data cases. Mirrors iOS TodayView.ringEmptyOverlay. */
@Composable
@Suppress("UNUSED_PARAMETER")
private fun RingEmptyOverlay(
    calibratingNights: Int?,
    diameter: Dp,
) {
    if (calibratingNights != null) {
        // AutoSizeValue shrink-to-fit + the centring Column, same as RingNeedsTrackedNight (#1168): a longer
        // localized "N of M nights" would otherwise fill the narrow ring and left-align/clip like the Rest tile.
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            AutoSizeValue(
                uiString(R.string.l10n_today_screen_calibrating_37c2c9bd),
                style = NoopType.headline,
                color = Palette.textTertiary,
                minScale = 0.7f,
            )
            AutoSizeValue(
                uiString(R.string.l10n_today_screen_calibratingnights_of_baselines_minnightsseed_3b76e55c, calibratingNights, Baselines.minNightsSeed),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
    } else {
        RingNoData(diameter = diameter)
    }
}

@Composable
private fun RingNoData(diameter: Dp) {
    Box(modifier = Modifier.size(diameter), contentAlignment = Alignment.Center) {
        Text(
            text = uiString(R.string.today_no_data),
            style = NoopType.headline,
            color = Palette.textTertiary,
            modifier = Modifier.width(diameter * 0.78f),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            maxLines = 2,
            softWrap = true,
            overflow = TextOverflow.Clip,
        )
    }
}

/** #898: the Rest ring's overlay when a Charge exists for the day but there's no scored sleep (the
 *  aggregate-import case , a daily HRV/RHR import carries no in-bed session). Says WHY Rest is blank
 *  instead of a bare "No Data", without fabricating a number. Mirrors iOS restRing's needs-a-night branch. */
@Composable
private fun RingNeedsTrackedNight() {
    // AutoSizeValue (not plain Text): the subtext "needs a tracked night" is wider than the narrow ring,
    // so a maxLines=1 Text filled the width and left-aligned + clipped the tail (#1168). Shrink-to-fit and
    // let the centering Column place the content-sized line — the Android mirror of iOS ringNeedsTrackedNight's
    // .minimumScaleFactor + centred VStack.
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        AutoSizeValue(
            uiString(R.string.l10n_today_screen_calibrating_37c2c9bd),
            style = NoopType.headline,
            color = Palette.textTertiary,
            minScale = 0.7f,
        )
        AutoSizeValue(
            uiString(R.string.l10n_today_screen_needs_a_tracked_night_ccfd532a),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
    }
}

// MARK: - Hero vitals metric rows, HRV / Resting HR / Respiratory, re-homed below the ring hero
//
// The WHOOP-style redesign (#23) dropped the big gold RecoveryRing hero that used to carry these; the
// three vitals now read directly below the three-ring hero + Synthesis card. [HeroMetricRows] is the
// README "Metric row" card; the SOLID/CALIBRATING pill + Synthesis insight moved into [SynthesisHeroCard].

/** The three hero vitals as README metric rows, HRV (teal) · Resting HR (rose) · Respiratory (blue).
 *  Reads PER-FIELD today-first with a recovery-INDEPENDENT vitals carry ([vitalsDay]) as the fallback
 *  (#543 follow-up), so a night whose recovery was nulled post-update still shows its OWN preserved HRV /
 *  RHR / respiratory rather than an older recovery-scored day's numbers (or "No Data"). This aligns the
 *  card to the Key-Metrics tiles, which already read per-field. Each row still falls through to "No Data"
 *  for a vital neither today nor the carry supplies. */
@Composable
@Suppress("UNUSED_PARAMETER")
private fun HeroMetricRows(day: DailyMetric?, carriedDay: DailyMetric? = null, vitalsDay: DailyMetric? = null) {
    // Per-field, today-first: today's own value wins; the vitals carry only fills a field today lacks.
    val hrv = day?.avgHrv ?: vitalsDay?.avgHrv
    val rhr = day?.restingHr ?: vitalsDay?.restingHr
    val resp = day?.respRateBpm ?: vitalsDay?.respRateBpm
    // The caption reflects the row the shown vitals actually came from: if today supplied ANY of them the
    // values are today's own, so don't stamp them as a prior "Last night · <date>"; only when EVERY shown
    // vital is carried do we stamp the carry's date (relabelled "Latest sleep · <date>" when weeks-old).
    val carriedFromVitals = day?.avgHrv == null && day?.restingHr == null && day?.respRateBpm == null &&
        (hrv != null || rhr != null || resp != null) && vitalsDay != null
    // iOS `recoveryVitalsSection`: a frosted card with a "RECOVERY VITALS" header + a "last night · <date>"
    // on the right, then three `vitalRow`s (26dp mini LIQUID VESSEL + label + value). NoopCard supplies the
    // same neutral surfaceRaised + hairline as iOS's frosted card. Inner spacing 12, matching iOS.
    NoopCard(padding = Metrics.space16) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(uiString(R.string.today_section_recovery_vitals), modifier = Modifier.weight(1f))
                // iOS `lastNightLine` — today's own "Last night · <date>" unless the shown vitals are a carry.
                Text(
                    if (carriedFromVitals) carriedCaption(vitalsDay!!.day).localized() else heroVitalsLastNightLine(),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_heart_rate_variability_a137586d),
                value = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                tint = Palette.metricCyan,
                fraction = hrv?.let { (it / 120.0).coerceIn(0.0, 1.0) },
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_resting_heart_rate_348928d6),
                value = rhr?.let { "$it bpm" } ?: NO_DATA,
                tint = Palette.metricRose,
                fraction = rhr?.let { (it / 100.0).coerceIn(0.0, 1.0) },
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_breaths_per_minute_2b197c54),
                value = resp?.let { String.format(Locale.getDefault(), "%.1f rpm", it) } ?: NO_DATA,
                tint = Palette.accent,
                fraction = resp?.let { (it / 24.0).coerceIn(0.0, 1.0) },
            )
        }
    }
}

/** iOS `lastNightLine` — "Last night · <date>" where <date> is yesterday in "d MMM" form. */
@Composable
private fun heroVitalsLastNightLine(): String {
    val d = LocalDate.now().minusDays(1)
    return uiString(R.string.today_last_night_date, d.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())))
}

/** One iOS `vitalRow`: a 26dp mini liquid VESSEL filled to [fraction] in [tint], the label (subhead,
 *  secondary), a spacer, and the value (number 15, primary). Replaces the old flat-Material-icon row. */
@Composable
private fun HeroVitalRow(label: String, value: String, tint: Color, fraction: Double?) {
    val hasValue = value != NO_DATA
    val displayValue = localizedMetricValue(value)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_label_value_b781d590, label, displayValue) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        LiquidVessel(
            value = fraction,
            tint = tint,
            animated = false,
            modifier = Modifier.size(26.dp),
        )
        Text(label, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(
            displayValue,
            style = NoopType.number(15f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
        )
    }
}

// MARK: - "Your cards" dashboard (WHOOP "My Dashboard"), iOS yourCardsSection parity
//
// A persisted, reorderable selection of metric cards surfaced on Today as flat WHOOP metric ROWS. The
// section header carries the "Your cards" overline + a right-aligned BLUE "CUSTOMISE" text action; each row
// is a leading tinted icon tile + UPPERCASE tracked label over a grey baseline caption on the left, and the
// big white value + small unit + chevron on the right. A card with no value yet renders a dash rather than
// vanishing. Mirrors iOS TodayView.yourCardsSection / pinnedCardRow / dashboardValue / dashboardTint.

/** Shared Today section edit affordance. The 48dp box keeps the whole control easy to tap while its
 *  visible content stays pinned to the overline instead of centring against a two-line header. */
@Composable
private fun TodayEditAction(
    contentDescription: String,
    onClick: () -> Unit,
    contentAlignment: Alignment = Alignment.Center,
) {
    Box(
        modifier = Modifier
            .height(48.dp)
            .clickable(onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = Metrics.space12),
    ) {
        Row(
            modifier = Modifier.align(contentAlignment),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Tune,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(Metrics.space4))
            Text(
                uiString(R.string.l10n_today_screen_edit_5301648d).uppercase(Locale.getDefault()),
                style = NoopType.overline.copy(letterSpacing = 0.4.sp),
                color = Palette.accent,
            )
        }
    }
}

/**
 * #today-hosted-cards render: the Trends/Sleep cards hosted in Today, in arranged order. Each case renders
 * the SAME card its home tab uses (a mirror, not a copy) so the two never diverge. P0 hosts only Sleep
 * marks; its logging callback mirrors the Sleep tab's exactly (external log + metric-series upsert +
 * confirmation toast). Renders nothing when [cards] is empty. Twin of the iOS `hostedCardsSection`.
 */
@Composable
private fun HostedCardsSection(cards: List<HostedCard>, days: List<DailyMetric>, viewModel: AppViewModel) {
    if (cards.isEmpty()) return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // #today-hosted-cards: the SleepModel-backed hosted sleep cards (Stages vs typical today; more to
    // follow). Build the shared model ONCE, and only when at least one such card is actually hosted, so a
    // Today hosting none pays no cost. Same inputs + builder as the Sleep tab (buildHostedSleepModel), so
    // hosted numbers match the Sleep tab. Reused by every model-backed card. Twin of the iOS hostedSleepModel.
    val modelBackedHosted = setOf(HostedCard.STAGES_VS_TYPICAL, HostedCard.NIGHT_DETAIL, HostedCard.SLEEP_DEBT, HostedCard.STAGES, HostedCard.HOURS_VS_NEEDED, HostedCard.CONSISTENCY)
    val needsSleepModel = cards.any { it in modelBackedHosted }
    var hostedSleepModel by remember { mutableStateOf<SleepModel?>(null) }
    LaunchedEffect(needsSleepModel, days, viewModel.activeStrapId) {
        hostedSleepModel = if (needsSleepModel) {
            buildHostedSleepModel(viewModel.repo, viewModel.activeStrapId, days)
        } else {
            null
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
        cards.forEach { card ->
            when (card) {
                HostedCard.SLEEP_MARKS -> SleepMarkCard(
                    onMark = { type ->
                        val mark = SleepMark.now(type)
                        viewModel.ble.externalLog(mark.logLine())
                        scope.launch {
                            runCatching {
                                viewModel.repo.upsertMetricSeries(listOf(mark.metricPoint("my-whoop")))
                            }
                        }
                        Toast.makeText(context, mark.confirmation(), Toast.LENGTH_SHORT).show()
                    }
                )
                // #today-hosted-cards P1: the hours-asleep trend, built pure from `days` (no nap/debt) so
                // it matches the Sleep tab's hours chart. The card composable lives in SleepScreen.kt
                // (internal) where its ChartCard/BarChart siblings are in-file.
                HostedCard.ASLEEP_DURATION -> {
                    val (hours, dates) = sleepDurationTrend(days)
                    AsleepDurationHostCard(hours = hours, dates = dates)
                }
                // #today-hosted-cards: last night's stages vs the wearer's personal per-stage means, rendered
                // from the SAME shared SleepModel the Sleep tab uses (mirror, not copy). Until the async build
                // lands — or on a device with no stage data — the model is null and the slot renders nothing
                // this frame, matching how the Sleep tab guards the section on a null model.
                HostedCard.STAGES_VS_TYPICAL -> hostedSleepModel?.let { StagesVsTypicalHostCard(it) }
                // #today-hosted-cards: the Night-detail metric grid, rendered from the SAME shared SleepModel
                // the Sleep tab uses (mirror, not copy). Null until the async build lands / no stage data —
                // the slot renders nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.NIGHT_DETAIL -> hostedSleepModel?.let { NightDetailHostCard(it) }
                // #today-hosted-cards: the Sleep-debt ledger, rendered from the SAME shared SleepModel the
                // Sleep tab uses (mirror, not copy). Null until the async build lands / no stage data — the
                // slot renders nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.SLEEP_DEBT -> hostedSleepModel?.let { SleepDebtLedgerHostCard(it) }
                // #today-hosted-cards: the READ-ONLY latest-night stage chart + breakdown, rendered from the
                // SAME shared SleepModel the Sleep tab uses (mirror, not copy) — none of the hero's nav/edit/
                // nap interaction. Null until the async build lands / no stage data — the slot renders nothing
                // this frame, matching the Sleep tab's null-model guard.
                HostedCard.STAGES -> hostedSleepModel?.let { StagesHostCard(it) }
                // #today-hosted-cards: the single hours-vs-need % metric, rendered from the SAME shared
                // SleepModel the Sleep tab uses (mirror, not copy) via the existing standalone
                // HoursVsNeededCard. Null until the async build lands / no stage data — the slot renders
                // nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.HOURS_VS_NEEDED -> hostedSleepModel?.let { HoursVsNeededCard(it) }
                // #today-hosted-cards: the single sleep-consistency % metric, rendered from the SAME shared
                // SleepModel the Sleep tab uses (mirror, not copy) via the simple standalone
                // ConsistencyHostCard. Null until the async build lands / no stage data — the slot renders
                // nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.CONSISTENCY -> hostedSleepModel?.let { ConsistencyHostCard(it) }
            }
        }
    }
}

@Composable
private fun YourCardsSection(
    cards: List<DashboardCard>,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    onOpenHydration: () -> Unit,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenCoupled: () -> Unit,
    onCustomise: () -> Unit,
    spo2CandidateByDay: Map<String, Double> = emptyMap(),
) {
    // #1331 parity: honor the °C/°F preference on the Skin Temp card, the way Health / Compare (and the
    // Swift twin) do. The classic dashboard hardcoded Celsius here alone, so a °F user saw °C on this
    // screen only.
    val fahrenheit = UnitPrefs.temperature(LocalContext.current) == TemperatureUnit.FAHRENHEIT
    Box(modifier = Modifier.fillMaxWidth().staggeredAppear(2)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: "YOUR CARDS" overline + a right-aligned blue EDIT action (the WHOOP ✎ affordance).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(uiString(R.string.today_section_your_cards), modifier = Modifier.weight(1f))
                TodayEditAction(
                    onClick = onCustomise,
                    contentDescription = uiString(R.string.l10n_today_screen_customise_your_cards_2428d761),
                )
            }
            cards.forEach { card ->
                DashboardCardRow(
                    card = card,
                    value = dashboardCardValue(
                        card = card,
                        day = day,
                        carriedDay = carriedDay,
                        vitalsDay = vitalsDay,
                        spo2Day = spo2Day,
                        skinTempDay = skinTempDay,
                        respDay = respDay,
                        fahrenheit = fahrenheit,
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vo2max = vo2max,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                        caloriesForDay = caloriesForDay,
                        hydrationTotalMl = hydrationTotalMl,
                        hydrationGoalMl = hydrationGoalMl,
                        spo2CandidateByDay = spo2CandidateByDay,
                    ),
                    // The mini liquid vessel's fill — the SAME per-card fraction iOS `liquidCard` uses.
                    fraction = dashboardCardFraction(
                        card = card,
                        day = day,
                        carriedDay = carriedDay,
                        vitalsDay = vitalsDay,
                        respDay = respDay,
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vo2max = vo2max,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                    ),
                    tint = dashboardCardTint(card),
                    // #110: label the sleep row with its source + night (this section renders at offset 0
                    // only, so it IS last night), so a WHOOP-imported figure is never silently shown as
                    // "last night" with no provenance. iOS TodayView.sleepSourceSubtitle twin.
                    subtitleOverride = sleepSourceSubtitle(card, day),
                    // #706/#684: every card now opens its OWN detail, matching iOS. The Stress card -> Stress;
                    // the overnight vitals (HRV / Resting HR / Respiratory / SpO₂ / Skin Temp) + Fitness age /
                    // Vitality / Steps / Calories -> each metric's focused trend (vital_detail/<key>, the iOS
                    // metricDetail twin); Sleep -> Sleep; Hydration -> Hydration. Whole row is the button.
                    onClick = dashboardCardDestination(
                        card = card,
                        onOpenStress = onOpenStress,
                        onOpenMetric = onOpenMetric,
                        onOpenSleep = onOpenSleep,
                        onOpenHydration = onOpenHydration,
                        onOpenCoupled = onOpenCoupled,
                    ),
                )
            }
        }
    }
}

/** #110: the sleep row's value is `totalSleepMin` — WHOOP's imported TST, which can legitimately differ
 *  from the Sleep tab's on-device re-staged night (WHOOP CSV + Apple Health both imported). Label the row
 *  with its source (the SAME `daySourceBadge` winner the Sleep tab's `MainSleepFooter` uses) + "last
 *  night" — `YourCardsSection` renders at offset 0 only, so the row IS last night — so a WHOOP figure is
 *  never silently shown as "last night" with no provenance. null → the card keeps its static subtitle
 *  (not the sleep card, or no banked sleep). Twin of iOS `TodayView.sleepSourceSubtitle`; the source
 *  mechanism differs per platform (Android keys on the day's session source, iOS on `importedSleep`),
 *  exactly as the two Sleep-tab badges already do, so the label — not the wiring — is what stays in parity. */
@Composable
private fun sleepSourceSubtitle(card: DashboardCard, day: DailyMetric?): String? {
    if (card != DashboardCard.SLEEP) return null
    val d = day ?: return null
    if (d.totalSleepMin == null) return null
    val source = daySourceBadge(d.deviceId).first
    return uiString(R.string.today_sleep_source_last_night, source)
}

/** The `vital_detail/<key>` key a metric/vital card opens, or null when the card has its OWN dedicated
 *  screen (Stress / Sleep / Hydration / Coupled) rather than a metric-detail trend. Mirrors the iOS
 *  `liquidCard` switch, where every metric/vital card opens `metricDetail(key)` (its own focused trend),
 *  NOT the shared Health hub (2026-07-03). Keys are the Android VitalDetailScreen keys. */
private fun dashboardCardMetricKey(card: DashboardCard): String? = when (card) {
    DashboardCard.HRV -> "hrv"
    DashboardCard.RESTING_HR -> "rhr"
    DashboardCard.RESPIRATORY -> "resp"
    DashboardCard.BLOOD_OXYGEN -> "spo2"
    DashboardCard.SKIN_TEMP -> "skin"
    DashboardCard.FITNESS_AGE -> "fitness_age"
    DashboardCard.VO2MAX -> "vo2max_est"
    DashboardCard.VITALITY -> "vitality"
    DashboardCard.STEPS -> "steps_est"
    DashboardCard.CALORIES -> "active_kcal"
    // These carry their own full screen, not a per-metric trend.
    DashboardCard.STRESS, DashboardCard.SLEEP, DashboardCard.HYDRATION, DashboardCard.COUPLED -> null
}

/** The destination callback a dashboard card opens when tapped. Mirrors the iOS dashboardCardRow switch:
 *  Stress -> Stress; Sleep -> Sleep; Hydration -> Hydration; Coupled -> the WHOOP-style day screen; every
 *  metric/vital card -> its OWN focused trend (`vital_detail/<key>` via [onOpenMetric]), matching the iOS
 *  `metricDetail(key)`. Every card resolves to a destination, so the chevron is always honest (#706/#684). */
private fun dashboardCardDestination(
    card: DashboardCard,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenHydration: () -> Unit,
    onOpenCoupled: () -> Unit,
): () -> Unit = when (card) {
    DashboardCard.STRESS -> onOpenStress
    DashboardCard.SLEEP -> onOpenSleep
    DashboardCard.HYDRATION -> onOpenHydration
    // The Coupled view card (#43) taps through to the full WHOOP-style day screen.
    DashboardCard.COUPLED -> onOpenCoupled
    // Every overnight vital + Fitness age / Vitality / Steps / Calories opens its own metric-detail trend.
    else -> {
        val key = dashboardCardMetricKey(card)
        if (key != null) ({ onOpenMetric(key) }) else ({})
    }
}

/** A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals take
 *  their biometric hue; everything else the blue accent. No gold (WHOOP), tokens only. Mirrors iOS
 *  dashboardTint. This drives the mini liquid vessel's tint on each row, so it follows the iOS `liquidCard`
 *  per-card tints exactly: Stress=accent, Fitness age=charge-green, Vitality=liquid-purple, HRV=cyan,
 *  Resting HR=rose, Respiratory=accent, Steps=cyan, Sleep=rest, Coupled=charge. */
private fun dashboardCardTint(card: DashboardCard): Color = when (card) {
    // iOS `liquidCard`: stress → StrandPalette.accent (blue), not the Effort orange.
    DashboardCard.STRESS -> Palette.accent
    DashboardCard.FITNESS_AGE -> Palette.chargeColor
    DashboardCard.VO2MAX -> Palette.chargeColor
    // iOS vitality → liquidPurple (#9b7bff).
    DashboardCard.VITALITY -> LIQUID_PURPLE
    // iOS hrv → metricCyan (this theme's metricPurple is a blue, cyan reads as the iOS HRV teal).
    DashboardCard.HRV -> Palette.metricCyan
    DashboardCard.RESTING_HR -> Palette.metricRose
    DashboardCard.RESPIRATORY -> Palette.accent
    DashboardCard.BLOOD_OXYGEN -> Palette.metricCyan
    DashboardCard.SKIN_TEMP -> Palette.metricAmber
    DashboardCard.SLEEP -> Palette.restColor
    DashboardCard.STEPS -> Palette.metricCyan
    DashboardCard.CALORIES -> Palette.metricAmber
    DashboardCard.HYDRATION -> Palette.metricCyan
    DashboardCard.COUPLED -> Palette.chargeColor
}

/**
 * A dashboard card's mini-vessel fill fraction (0..1), or null for an empty (no-reading) vessel. Mirrors the
 * iOS `liquidCard` `frac:` argument exactly, per card:
 *   Stress = stress/3 · Fitness age = 0.5 (fixed) · Vitality = vitality/100 · HRV = avgHrv/120 ·
 *   Resting HR = restingHr/100 · Respiratory = respRate/24 · Steps = steps/10000 · Sleep = totalSleepMin/480 ·
 *   Coupled = 0.6 (fixed) · Blood oxygen / Skin temp / Calories / Hydration = null (empty, not half-full).
 * The three overnight vitals (HRV / Resting HR / Respiratory) read PER-FIELD today-first with the
 * recovery-INDEPENDENT [vitalsDay] carry, matching the row VALUE, so the vessel fill and the number agree
 * (and a recovery-nulled night keeps its OWN preserved vitals). Sleep keeps the recovery-gated
 * `carriedDay ?: day` carry.
 */
private fun dashboardCardFraction(
    card: DashboardCard,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
): Double? {
    fun over(v: Double?, ceiling: Double): Double? = v?.let { (it / ceiling).coerceIn(0.0, 1.0) }
    val vd = carriedDay ?: day
    return when (card) {
        DashboardCard.STRESS -> over(stress, 3.0)
        DashboardCard.FITNESS_AGE -> if (fitnessAge != null) 0.5 else null
        DashboardCard.VO2MAX -> if (vo2max != null) 0.5 else null
        DashboardCard.VITALITY -> over(vitality, 100.0)
        DashboardCard.HRV -> over(day?.avgHrv ?: vitalsDay?.avgHrv, 120.0)
        DashboardCard.RESTING_HR -> over((day?.restingHr ?: vitalsDay?.restingHr)?.toDouble(), 100.0)
        // PER-FIELD carry: today → the STALENESS-BOUNDED prior night (`respDay` = lastRespRow). The
        // unbounded `vitalsDay?.respRateBpm` is dropped on purpose — it picks the newest row with ANY
        // vital regardless of age and printed one CSV import's 15.6 as today's rate for a fortnight
        // (#1331). Byte-twin of the Swift `lastRespDay` card.
        DashboardCard.RESPIRATORY -> over(day?.respRateBpm ?: respDay?.respRateBpm, 24.0)
        DashboardCard.STEPS -> {
            val steps = (day?.steps ?: importedStepsForDay ?: estimatedStepsForDay)?.toDouble()
            over(steps, 10000.0)
        }
        DashboardCard.SLEEP -> over(vd?.totalSleepMin, 480.0)
        DashboardCard.COUPLED -> 0.6
        // Not wired to a real read yet — an EMPTY vessel (not half-full) so it doesn't imply a reading.
        DashboardCard.BLOOD_OXYGEN, DashboardCard.SKIN_TEMP, DashboardCard.CALORIES,
        DashboardCard.HYDRATION -> null
    }
}

/**
 * Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
 * suffix appended. Returns a dash when the value isn't available yet, never a fabricated number. Reuses
 * the SAME reads the rest of Today uses (displayMetric vitals, the pinned Stress / Fitness age / Vitality,
 * steps, calories, sleep duration). Mirrors iOS dashboardValue.
 *
 * The three overnight vitals (HRV / Resting HR / Respiratory) read PER-FIELD today-first with the
 * recovery-INDEPENDENT [vitalsDay] carry (#543 follow-up), so a night whose recovery was nulled post-update
 * still shows its OWN preserved value rather than an older recovery-scored day's (the tile-vs-card fix).
 * SpO₂ / Skin Temp / Sleep keep the recovery-gated `carriedDay ?: day` carry. Steps / Calories stay on
 * today's own row (they accrue through the day, never a carry). Stress / Fitness age / Vitality come from
 * their own resolved loads.
 */
private fun dashboardCardValue(
    card: DashboardCard,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    spo2CandidateByDay: Map<String, Double> = emptyMap(),
    fahrenheit: Boolean = false,
): String {
    fun withUnit(s: String): String =
        if (s == NO_DATA) NO_DATA else if (card.unit.isEmpty()) s else "$s ${card.unit}"

    // SpO₂ / Skin Temp / Sleep carry over from the last scored night; today's accruing totals do not.
    val vd = carriedDay ?: day

    return when (card) {
        DashboardCard.HRV ->
            withUnit((day?.avgHrv ?: vitalsDay?.avgHrv)?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.RESTING_HR ->
            withUnit((day?.restingHr ?: vitalsDay?.restingHr)?.toString() ?: NO_DATA)
        DashboardCard.RESPIRATORY ->
            // PER-FIELD carry: today → the STALENESS-BOUNDED `respDay` (lastRespRow). The unbounded
            // `vitalsDay?.respRateBpm` is dropped on purpose (see the gauge site + Swift `lastRespDay`):
            // it had no age bound and showed a fortnight-old imported 15.6 as today's rate (#1331). A gap
            // past the window now reads NO_DATA — the truthful answer when nobody measured.
            withUnit((day?.respRateBpm ?: respDay?.respRateBpm)?.let { String.format(Locale.getDefault(), "%.1f", it) } ?: NO_DATA)
        DashboardCard.BLOOD_OXYGEN ->
            // PER-FIELD carry: the whole-row carries (vd) land on rows whose spo2Pct is null (the engine
            // writes spo2Pct = null on computed rows), so fall through to the last row that HAS one.
            // #103/queue-11a: when no calibrated spo2Pct exists, fall back to the spo2_candidate strap
            // estimate (WHOOP @82 or Oura ceiling@100, from metricSeries) when the experimental display
            // toggle is ON. Labelled "estimate" in the Health vitals screen; here it just fills the card
            // so it's not blank.
            (vd?.spo2Pct ?: spo2Day?.spo2Pct)?.let { String.format(Locale.getDefault(), "%.0f%%", it) }
                ?: (vd?.day ?: day?.day)?.let { spo2CandidateByDay[it] }?.let { String.format(Locale.getDefault(), "%.0f%%", it) }
                ?: NO_DATA
        DashboardCard.SKIN_TEMP -> {
            // #622: bimodal field — absolute °C (import) vs signed Δ°C vs baseline (live).
            // Always label the scale; bare "−0.1°" next to a 34° deep-timeline chart looked broken.
            val v = vd?.skinTempDevC ?: skinTempDay?.skinTempDevC
            if (v == null) NO_DATA
            else com.noop.analytics.SkinTempDisplay.format(v, fahrenheit = fahrenheit)
        }
        DashboardCard.SLEEP -> sleepValue(vd)
        DashboardCard.STEPS -> {
            val real = day?.steps?.let { intStringGrouped(it.toDouble()) }
                ?: importedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            val est = estimatedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            real ?: est ?: NO_DATA
        }
        DashboardCard.CALORIES ->
            withUnit(caloriesForDay?.let { intStringGrouped(it) } ?: NO_DATA)
        DashboardCard.STRESS ->
            // #706/#684: Stress is baseline-relative, so until the strap has banked enough worn nights to
            // seed the 30-day RHR/HRV baseline StressScreen reads, the front card has no number to show. The
            // old `?: NO_DATA` rendered a bare dash that read like a broken card; show the honest calibrating
            // state instead, matching the owner's reply on #706 and the StressScreen empty/calibrating copy.
            stress?.let { it.roundToInt().toString() } ?: STRESS_CALIBRATING
        DashboardCard.FITNESS_AGE ->
            withUnit(fitnessAge?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.VO2MAX ->
            vo2max?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.VITALITY ->
            vitality?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.HYDRATION ->
            // "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L". Always shows a value (a fresh
            // day reads "0.0 / 3.2 L"), since the goal is always derivable from the profile.
            String.format(
                Locale.getDefault(), "%.1f / %.1f L",
                hydrationTotalMl / 1000.0, hydrationGoalMl / 1000.0,
            )
        DashboardCard.COUPLED ->
            // A tap-through row with no metric value of its own, the row shows just the chevron. An empty
            // string (not NO_DATA) renders no number and leaves it un-dimmed. Mirrors iOS dashboardValue.
            ""
    }
}

/**
 * One WHOOP "My Dashboard" metric row: a thin-line tinted icon tile, an UPPERCASE tracked label over a grey
 * baseline caption, the big white value + small unit, and a chevron, on the flat frosted card surface (no
 * glow), tokens only. Mirrors iOS pinnedCardRow. The whole row is the tap target: when [onClick] is set it
 * pushes that card's detail (the chevron is the hint), matching iOS (#706/#684).
 */
@Composable
private fun DashboardCardRow(
    card: DashboardCard,
    value: String,
    fraction: Double?,
    tint: Color,
    // #110: a per-card dynamic subtitle (currently the sleep row's source + night); null keeps the
    // card's static description.
    subtitleOverride: String? = null,
    onClick: (() -> Unit)? = null,
) {
    // A real number renders white; a placeholder (No Data, or the Stress calibrating state) renders dimmed.
    val hasValue = value != NO_DATA && value != STRESS_CALIBRATING
    val displayValue = localizedMetricValue(value)
    // iOS `cardLink` corner is 20 (a touch rounder than the app-wide 18dp card), with the SAME neutral
    // surfaceRaised fill + plain hairline the frosted neutral surface already draws.
    val rowShape = RoundedCornerShape(20.dp)
    // liquidPress: the tappable card settles inward on press (the iOS LiquidPressStyle feel). The SAME
    // interactionSource feeds the clickable and the press modifier, so it responds to the actual touch.
    // It is applied OUTSIDE the frosted surface so the whole card (surface + content) scales/dims as one.
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onClick != null) it.liquidPress(interaction) else it }
            .clip(rowShape)
            .frostedCardSurface(cornerRadius = 20.dp)
            .let {
                if (onClick != null) {
                    it.clickable(interactionSource = interaction, indication = null, onClick = onClick)
                } else it
            }
            // iOS row padding: 14h / 11v (tighter than the old 13/11 icon-box row).
            .padding(horizontal = 14.dp, vertical = 11.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_card_title_value_e4bb76b3, uiString(card.titleRes), displayValue) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // THE fix: a 30dp mini LIQUID VESSEL filled to this card's fraction, tinted its domain colour — the
        // "small liquid circle per icon" iOS shows and Android was missing (a flat Material-icon square).
        // Static (animated=false) so the many small gauges cost nothing per frame, matching iOS `cardLink`.
        LiquidVessel(
            value = fraction,
            tint = tint,
            animated = false,
            modifier = Modifier.size(30.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            // iOS: overline 11 / +1.0 tracking, textPrimary.
            Text(
                uiString(card.titleRes).uppercase(),
                style = NoopType.overline.copy(fontSize = 11.sp, letterSpacing = 1.0.sp),
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitleOverride ?: uiString(card.subtitleRes),
                style = NoopType.caption,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // iOS value = number(17), textPrimary.
        Text(
            displayValue,
            style = NoopType.number(17f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
            maxLines = 1,
        )
        // iOS chevron = 12.
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(12.dp),
        )
    }
}

/** #1491: the blank-Steps-tile line for a strap that ESTIMATES steps, or null when the prompt does not
 *  apply. A WHOOP 4.0 sends no step count, so NOOP fits an estimate from motion against a phone-counted
 *  reference and withholds it until it has one — and until #1491 the tile just went blank, with no
 *  explanation and no route to the sheet where a coefficient can be set by hand.
 *
 *  Keyed on the persisted model NAME rather than [DeviceFamily.forRegistryModel]: that resolver maps
 *  REGISTRY labels ("4.0", "WHOOP 4.0") and answers WHOOP5 for everything else, including the enum names
 *  this preference actually stores — so routing through it would classify every 4.0 as a 5 and this would
 *  silently never appear. A null preference (no model ever selected) also yields null, so a user with no
 *  strap is never told to calibrate one. Mirrors the iOS `stepsPipelineActive` gate.
 *
 *  The wording is the engine's own [StepsEstimateEngine.CalibrationStatus.headline], which already says
 *  "connect your phone's step count" when NO day has both motion and a phone total, rather than a
 *  countdown that would never advance. */
@Composable
private fun stepsCalibrationPrompt(context: Context, profileStore: ProfileStore): String? {
    val model = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        .getString("noop.selectedWhoopModel", null) ?: return null
    if (model != WhoopModel.WHOOP4.name) return null
    // Already calibrated? Then a blank day is just a quiet one — the estimate exists, this day simply did
    // not move enough to earn a number, and there is nothing for the user to go and do. Saying otherwise
    // would render "Need 0 more days where your phone also counted steps", because the headline's
    // countdown is max(0, need - have) and a calibrated user is already past `need`.
    // All three, because the first two are ENGINE outputs — written on the next analyze pass — while
    // [ProfileStore.stepsManualCoefficient] is what the user just typed. Checking only the outputs told
    // someone who had hand-set a coefficient to go connect a phone step source, for up to a scoring cycle
    // afterwards. That is the same shape as the bug this whole prompt exists to fix (#1491): gating on
    // evidence the app produces later, rather than on what the user has already done.
    if (profileStore.stepsCalibrationCoefficient > 0.0 ||
        profileStore.stepsCalibrationManual ||
        profileStore.stepsManualCoefficient > 0.0
    ) {
        return null
    }
    val headline = StepsEstimateEngine.CalibrationStatus.NeedsMoreDays(
        have = profileStore.stepsCalibrationSampleDays,
        need = StepsEstimateEngine.MIN_CALIBRATION_DAYS,
    ).headline
    return when (headline) {
        StepsEstimateEngine.CalibrationStatus.Headline.Manual -> uiString(R.string.today_steps_headline_manual)
        is StepsEstimateEngine.CalibrationStatus.Headline.Calibrated ->
            uiString(R.string.today_steps_headline_calibrated, headline.sampleDays)
        StepsEstimateEngine.CalibrationStatus.Headline.ConnectPhoneSteps ->
            uiString(R.string.today_steps_headline_connect_phone)
        is StepsEstimateEngine.CalibrationStatus.Headline.NeedMoreDays ->
            uiString(R.string.today_steps_headline_more_days, headline.remaining)
    }
}

/** #760/#792: the caption under an ESTIMATED Steps tile: "est. · <status detail>", where the detail is the
 *  engine's own STATUS line (manual k, or k=… from N days + confidence tier) built from the SAME persisted
 *  calibration the estimate used. So a WHOOP 4.0 user can see WHY the number reads as it does (and why it may
 *  look frozen at low confidence) right where they notice the "est." flag. Falls back to a bare "est." when no
 *  coefficient is recorded yet. Mirrors iOS `stepsEstimateCaption`. */
@Composable
private fun stepsEstimateCaption(profileStore: ProfileStore): String {
    if (profileStore.stepsCalibrationCoefficient <= 0.0) return uiString(R.string.today_steps_estimated_short)
    val status: StepsEstimateEngine.CalibrationStatus = if (profileStore.stepsCalibrationManual) {
        StepsEstimateEngine.CalibrationStatus.Manual(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
        )
    } else {
        StepsEstimateEngine.CalibrationStatus.Calibrated(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
            confidence = profileStore.stepsCalibrationConfidence,
        )
    }
    return uiString(R.string.today_steps_estimated_detail, stepsCalibrationDetail(status.detail))
}

@Composable
private fun stepsCalibrationDetail(detail: StepsEstimateEngine.CalibrationStatus.Detail): String = when (detail) {
    is StepsEstimateEngine.CalibrationStatus.Detail.Manual ->
        uiString(R.string.today_steps_manual_coefficient, String.format(Locale.getDefault(), "%.1f", detail.coefficient))
    is StepsEstimateEngine.CalibrationStatus.Detail.Calibrated -> {
        val confidence = when (detail.confidenceTier) {
            StepsEstimateEngine.ConfidenceTier.LOW -> uiString(R.string.today_steps_confidence_low)
            StepsEstimateEngine.ConfidenceTier.MEDIUM -> uiString(R.string.today_steps_confidence_medium)
            StepsEstimateEngine.ConfidenceTier.HIGH -> uiString(R.string.today_steps_confidence_high)
        }
        uiString(
            R.string.today_steps_calibrated_detail,
            String.format(Locale.getDefault(), "%.1f", detail.coefficient), detail.sampleDays, confidence,
        )
    }
    is StepsEstimateEngine.CalibrationStatus.Detail.Calibrating ->
        uiString(R.string.today_steps_calibrating_detail, detail.have, detail.need)
}

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. A
 *  file-internal twin of the private [intString] so the dashboard rows format steps/calories identically. */
private fun intStringGrouped(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.getDefault(), "%,d", n) else "$n"
}

// MARK: - Shared Shown / Hidden editor rows

/**
 * The common editor body used by Today sections, Key Metrics and Your Cards. Items are never deleted:
 * remove moves one from Shown to Hidden, add restores it at the end of Shown, and the arrow controls use
 * the same ordering behavior in every editor. SnapshotStateList callers recompose on these mutations.
 */
@Composable
internal fun <T> EditableVisibilityRows(
    shown: MutableList<T>,
    hidden: MutableList<T>,
    itemTitle: (T) -> String,
    modifier: Modifier = Modifier,
    // Whether the Shown list may go EMPTY. Default false — the last shown item can't be hidden, so
    // surfaces needing >=1 item can't be emptied. The hosted-cards editor (#today-hosted-cards) passes
    // true (opt-in: un-hosting the last card is valid).
    allowEmpty: Boolean = false,
    // Optional grouping key for the Hidden ("Available") list. When set (the hosted-cards editor passes the
    // card's origin, e.g. "Sleep" / "Trends"), the Available items render under one sub-header per group so
    // a user browses by origin. null (Today sections, Key Metrics, Your Cards) keeps the flat list. The
    // Shown list stays flat — it is the user's own cross-origin order. Twin of the Swift EditableLayoutList.
    hiddenGroup: ((T) -> String)? = null,
) {
    val minShown = if (allowEmpty) 0 else 1
    Column(
        modifier = modifier
            .heightIn(max = Metrics.editorListMaxHeight)
            .verticalScroll(rememberScrollState()),
    ) {
        Text(stringResource(R.string.today_customize_shown), style = NoopType.overline, color = Palette.textTertiary)
        shown.forEachIndexed { index, item ->
            val title = itemTitle(item)
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = Metrics.space6),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(title, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                IconButton(
                    onClick = {
                        if (index > 0) shown.add(index - 1, shown.removeAt(index))
                    },
                    enabled = index > 0,
                    modifier = Modifier.size(Metrics.iconButton),
                ) {
                    Icon(
                        Icons.Filled.KeyboardArrowUp,
                        contentDescription = stringResource(R.string.today_customize_move_up, title),
                        tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
                IconButton(
                    onClick = {
                        if (index < shown.lastIndex) shown.add(index + 1, shown.removeAt(index))
                    },
                    enabled = index < shown.lastIndex,
                    modifier = Modifier.size(Metrics.iconButton),
                ) {
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = stringResource(R.string.today_customize_move_down, title),
                        tint = if (index < shown.lastIndex) Palette.textSecondary else Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
                IconButton(
                    onClick = {
                        if (shown.size > minShown) hidden.add(shown.removeAt(index))
                    },
                    enabled = shown.size > minShown,
                    modifier = Modifier.size(Metrics.iconButton),
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = stringResource(R.string.today_customize_hide, title),
                        tint = if (shown.size > minShown) Palette.textSecondary else Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
            if (index < shown.lastIndex) {
                HorizontalDivider(color = Palette.hairline, thickness = Metrics.divider)
            }
        }

        Spacer(Modifier.height(Metrics.space16))
        Text(stringResource(R.string.today_customize_hidden), style = NoopType.overline, color = Palette.textTertiary)
        if (hidden.isEmpty()) {
            Text(
                stringResource(R.string.today_customize_nothing_hidden),
                style = NoopType.body,
                color = Palette.textTertiary,
                modifier = Modifier.padding(vertical = Metrics.space12),
            )
        } else if (hiddenGroup != null) {
            // Grouped Available list: one sub-header per origin ("Sleep", "Trends"). Remove by identity
            // (items are unique) so the move is index-free across the regrouped display.
            val buckets = LinkedHashMap<String, MutableList<T>>()
            hidden.forEach { item -> buckets.getOrPut(hiddenGroup(item)) { ArrayList() }.add(item) }
            buckets.keys.toList().forEachIndexed { gi, groupName ->
                Text(
                    groupName,
                    style = NoopType.overline,
                    color = Palette.textTertiary,
                    modifier = Modifier.padding(top = if (gi == 0) Metrics.space4 else Metrics.space12),
                )
                val itemsIn = buckets.getValue(groupName)
                itemsIn.forEachIndexed { ii, item ->
                    val title = itemTitle(item)
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = Metrics.space6),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(title, style = NoopType.body, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                        IconButton(
                            onClick = { hidden.remove(item); shown.add(item) },
                            modifier = Modifier.size(Metrics.iconButton),
                        ) {
                            Icon(
                                Icons.Filled.Add,
                                contentDescription = stringResource(R.string.today_customize_show, title),
                                tint = Palette.accent,
                                modifier = Modifier.size(Metrics.iconSmall),
                            )
                        }
                    }
                    if (ii < itemsIn.lastIndex) {
                        HorizontalDivider(color = Palette.hairline, thickness = Metrics.divider)
                    }
                }
            }
        } else {
            hidden.forEachIndexed { index, item ->
                val title = itemTitle(item)
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = Metrics.space6),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(title, style = NoopType.body, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                    IconButton(
                        onClick = { shown.add(hidden.removeAt(index)) },
                        modifier = Modifier.size(Metrics.iconButton),
                    ) {
                        Icon(
                            Icons.Filled.Add,
                            contentDescription = stringResource(R.string.today_customize_show, title),
                            tint = Palette.accent,
                            modifier = Modifier.size(Metrics.iconSmall),
                        )
                    }
                }
                if (index < hidden.lastIndex) {
                    HorizontalDivider(color = Palette.hairline, thickness = Metrics.divider)
                }
            }
        }
    }
}

// MARK: - "Your cards" dashboard editor (WHOOP "My Dashboard" ✎)
//
// A Today-local dialog for choosing which dashboard cards show and in what order. Display-only: it edits the
// persisted selection, never any stored metric. Shown cards retain their saved order; Hidden contains the
// canonical remainder, and restoring a card appends it to Shown. At least one card must stay enabled.

@Composable
private fun DashboardCardsEditorDialog(
    initial: List<DashboardCard>,
    onDismiss: () -> Unit,
    onSave: (List<DashboardCard>) -> Unit,
) {
    val titles = DashboardCard.entries.associateWith { uiString(it.titleRes) }
    val shown = remember { mutableStateListOf<DashboardCard>().apply { addAll(initial) } }
    val hidden = remember {
        mutableStateListOf<DashboardCard>().apply {
            addAll(DashboardCard.canonicalOrder.filter { it !in initial })
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_today_screen_my_dashboard_a7a19e72), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.today_dashboard_editor_description),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                EditableVisibilityRows(
                    shown = shown,
                    hidden = hidden,
                    itemTitle = { titles.getValue(it) },
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            shown.clear()
                            shown.addAll(DashboardCard.defaultSelection)
                            hidden.clear()
                            hidden.addAll(DashboardCard.canonicalOrder.filter { it !in shown })
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(shown.toList()) },
                        enabled = shown.isNotEmpty(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}

/**
 * #today-hosted-cards: the add/remove/reorder editor for the Trends/Sleep cards hosted in Today. Clone of
 * [DashboardCardsEditorDialog] over [HostedCard], with ONE difference — Done is always enabled, because an
 * EMPTY hosted set is valid (the feature is opt-in; hosting nothing simply hides the Added-cards section).
 * Reuses the shared [EditableVisibilityRows]. Twin of the iOS `HostedCardsCustomizationPage`.
 */
@Composable
private fun HostedCardsEditorDialog(
    initial: List<HostedCard>,
    onDismiss: () -> Unit,
    onSave: (List<HostedCard>) -> Unit,
) {
    val shown = remember { mutableStateListOf<HostedCard>().apply { addAll(initial) } }
    val hidden = remember {
        mutableStateListOf<HostedCard>().apply {
            addAll(HostedCard.canonicalOrder.filter { it !in initial })
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(color = Palette.surfaceOverlay, shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.today_hosted_editor_title), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.today_hosted_editor_desc),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                // Resolve the localized title/origin per card up front (composable-only calls can't run
                // inside the plain itemTitle/hiddenGroup lambdas). The enum's raw title/origin stay the
                // English source of truth; the UI shows the translated text.
                val titleFor = HostedCard.entries.associateWith { it.localizedTitle() }
                val originFor = HostedCard.entries.associateWith { it.localizedOrigin() }
                EditableVisibilityRows(
                    shown = shown,
                    hidden = hidden,
                    itemTitle = { titleFor.getValue(it) },
                    allowEmpty = true,   // hosting is opt-in: un-hosting the last card is valid
                    hiddenGroup = { originFor.getValue(it) },   // group the Available list by origin tab ("Sleep", "Trends")
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            shown.clear()
                            shown.addAll(HostedCard.defaultSelection)
                            hidden.clear()
                            hidden.addAll(HostedCard.canonicalOrder.filter { it !in shown })
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(shown.toList()) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}

// #today-layout (hold-to-drag): LazyColumn key prefix for the reorderable section items, so the drag can
// tell a section item from the pinned rows around it.
private const val TODAY_SECTION_KEY_PREFIX = "todaySection:"

/**
 * Live drag state for the Today hold-to-drag section reorder (#today-layout). One instance per screen.
 * `key`/`distance` are snapshot state (they drive the lifted card's translation each frame); the rest are
 * plain fields written by the gesture and read on the same (main) thread.
 */
private class TodaySectionDragState {
    /** LazyColumn key of the section being dragged; null when idle. */
    var key by mutableStateOf<String?>(null)

    /** Accumulated finger travel since pickup (px). */
    var distance by mutableFloatStateOf(0f)

    /** The dragged item's viewport offset at pickup (px) — with [distance], the finger-anchored position. */
    var pickedUpAt = 0f

    /** Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time, so the speed is
     *  identical on 60/90/120 Hz displays), set by onDrag from edge proximity; 0 outside the edge zones. */
    var autoScrollPxPerSecond = 0f
}

/** This order with [section] moved to [target]'s position (the classic list move). */
private fun List<TodaySection>.movedTodaySection(section: TodaySection, target: TodaySection): List<TodaySection> {
    val from = indexOf(section)
    val to = indexOf(target)
    if (from == -1 || to == -1 || from == to) return this
    return toMutableList().apply { add(to, removeAt(from)) }
}

/**
 * The (dragged, target) pair to swap right now, or null. The lifted card's finger-anchored middle
 * (`pickedUpAt + distance + size/2`, viewport space) must sit over another section item AND have crossed
 * that item's CENTRE in the direction of travel — the centre gate stops a tall card over a short one from
 * ping-ponging (an immediate swap-back would require crossing back over the centre).
 *
 * The direction is derived from [order] (the section list, the source of truth), NOT from layout offsets:
 * after a swap the state updates immediately but layoutInfo lags one frame, and an offset-derived direction
 * on that stale frame re-derives the SAME swap and undoes it (a visible oscillation). Order-derived
 * direction flips with the swap, so the stale re-check fails the centre gate and the move sticks; a
 * genuine user reversal still passes once the finger crosses back over the centre. Pure read; the caller
 * applies the move.
 */
private fun swapTargetForDraggedSection(
    listState: LazyListState,
    drag: TodaySectionDragState,
    order: List<TodaySection>,
): Pair<TodaySection, TodaySection>? {
    val key = drag.key ?: return null
    val info = listState.layoutInfo
    val current = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return null
    val middle = drag.pickedUpAt + drag.distance + current.size / 2f
    val target = info.visibleItemsInfo.firstOrNull { item ->
        item.key != key && (item.key as? String)?.startsWith(TODAY_SECTION_KEY_PREFIX) == true &&
            middle >= item.offset && middle <= item.offset + item.size
    } ?: return null
    val dragged = TodaySection.fromRaw(key.removePrefix(TODAY_SECTION_KEY_PREFIX)) ?: return null
    val tgt = TodaySection.fromRaw((target.key as String).removePrefix(TODAY_SECTION_KEY_PREFIX)) ?: return null
    val targetCentre = target.offset + target.size / 2f
    val movingDown = order.indexOf(tgt) > order.indexOf(dragged)
    if (movingDown && middle < targetCentre) return null
    if (!movingDown && middle > targetCentre) return null
    return dragged to tgt
}

/**
 * #today-layout (hold-to-drag): the per-section drag wrapper. LONG-PRESS anywhere on the section lifts it
 * (haptic; the card raises + follows the finger via graphicsLayer, translation computed against the item's
 * CURRENT layout offset so a mid-drag reorder or auto-scroll can't teleport it). onDrag only accumulates
 * finger travel + the edge auto-scroll velocity — the screen-level frame loop owns the swap + scroll, one
 * code path whether the finger is moving or parked at an edge. Taps/scrolls pass through untouched (the
 * detector waits for a long press), so every card keeps its own tap behaviour. No reorder library.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LazyItemScope.TodayReorderableSection(
    section: TodaySection,
    listState: LazyListState,
    drag: TodaySectionDragState,
    onDrop: () -> Unit,
    content: @Composable () -> Unit,
) {
    val key = TODAY_SECTION_KEY_PREFIX + section.raw
    val isDragging = drag.key == key
    val haptics = LocalHapticFeedback.current
    // Drop SETTLE: on release the lifted card is usually mid-air between slots; killing the translation
    // outright snapped it into place (part of the on-device "not smooth" report). Instead the residual
    // offset animates to 0 so the card glides into its slot. `settling` keeps the lifted chrome (zIndex)
    // during the glide; a new pickup cancels it.
    val settleScope = rememberCoroutineScope()
    val settle = remember { Animatable(0f) }
    var settling by remember { mutableStateOf(false) }
    fun releaseWithSettle() {
        val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key }
        val residual = if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
        onDrop()
        drag.key = null
        drag.distance = 0f
        drag.autoScrollPxPerSecond = 0f
        if (residual != 0f) {
            settling = true
            settleScope.launch {
                settle.snapTo(residual)
                settle.animateTo(0f, tween(durationMillis = 220, easing = FastOutSlowInEasing))
                settling = false
            }
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .zIndex(if (isDragging || settling) 1f else 0f)
            .then(
                if (isDragging || settling) {
                    Modifier.graphicsLayer {
                        translationY = if (isDragging) {
                            // Finger-anchored viewport position minus wherever layout currently placed it.
                            val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key }
                            if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
                        } else {
                            settle.value
                        }
                        shadowElevation = if (isDragging) 12f else 6f
                        scaleX = 1.01f
                        scaleY = 1.01f
                    }
                } else {
                    // Non-dragged sections animate to their new slot as the lifted card crosses them — a
                    // calm, deterministic ease (the default placement spring read abrupt when a tall card
                    // displaced a short one; first on-device feedback).
                    Modifier.animateItemPlacement(tween(durationMillis = 260, easing = FastOutSlowInEasing))
                },
            )
            .pointerInput(key) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        settling = false
                        drag.key = key
                        drag.distance = 0f
                        drag.pickedUpAt = listState.layoutInfo.visibleItemsInfo
                            .firstOrNull { it.key == key }?.offset?.toFloat() ?: 0f
                        drag.autoScrollPxPerSecond = 0f
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    onDragEnd = { releaseWithSettle() },
                    onDragCancel = {
                        // The list already reordered live; persist what the user sees rather than
                        // silently reverting on a system-cancelled gesture.
                        releaseWithSettle()
                    },
                    onDrag = onDrag@{ change, amount ->
                        change.consume()
                        drag.distance += amount.y
                        val info = listState.layoutInfo
                        val current = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return@onDrag
                        // Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time)
                        // from the lifted card's proximity to the viewport edges; ramps linearly across the
                        // zone with an eased-in feel via the squared fraction, so entering the zone starts
                        // gently instead of at speed.
                        val zone = 112.dp.toPx()
                        val maxV = 620.dp.toPx()
                        val top = drag.pickedUpAt + drag.distance
                        val bottom = top + current.size
                        drag.autoScrollPxPerSecond = when {
                            bottom > info.viewportEndOffset - zone -> {
                                val f = ((bottom - (info.viewportEndOffset - zone)) / zone).coerceAtMost(1f)
                                maxV * f * f
                            }
                            top < info.viewportStartOffset + zone -> {
                                val f = (((info.viewportStartOffset + zone) - top) / zone).coerceAtMost(1f)
                                -maxV * f * f
                            }
                            else -> 0f
                        }
                    },
                )
            },
    ) { content() }
}

/**
 * Today section editor. Uses the same Shown / Hidden rows as the Key Metrics and Your Cards editors.
 * Hiding is reversible and persists separately from the full order registry.
 */
@Composable
private fun TodayLayoutEditorDialog(
    initialOrder: List<TodaySection>,
    initialHidden: List<TodaySection>,
    onDismiss: () -> Unit,
    onEditAdded: () -> Unit,
    onSave: (List<TodaySection>, List<TodaySection>) -> Unit,
) {
    val hiddenSet = remember(initialHidden) { initialHidden.toSet() }
    val shown = remember {
        mutableStateListOf<TodaySection>().apply { addAll(initialOrder.filterNot { it in hiddenSet }) }
    }
    val hidden = remember {
        mutableStateListOf<TodaySection>().apply { addAll(initialOrder.filter { it in hiddenSet }) }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(color = Palette.surfaceOverlay, shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.today_customize_title), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.today_customize_description),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                EditableVisibilityRows(
                    shown = shown,
                    hidden = hidden,
                    itemTitle = { uiString(it.titleRes) },
                )

                // #today-hosted-cards: hand-off to the editor that chooses WHICH Trends/Sleep cards the
                // "Added Cards" section hosts (the section row above only reorders/hides the section).
                TextButton(
                    onClick = onEditAdded,
                    colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(Metrics.iconSmall))
                    Spacer(Modifier.width(Metrics.space6))
                    Text(stringResource(R.string.today_customize_edit_added_cards), style = NoopType.body)
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            shown.clear()
                            shown.addAll(TodaySection.defaultOrder)
                            hidden.clear()
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(shown.toList() + hidden.toList(), hidden.toList()) },
                        enabled = shown.isNotEmpty(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}

/**
 * A1/S4: the Charge breakdown sheet opened by tapping the hero Charge ring. A full-screen surface with a
 * titled top bar (Close) and a scrollable body hosting the existing What-shaped-it breakdown, the
 * Contributors bars and (S4) the folded Readiness card. Built only when shown (the caller gates on
 * showChargeBreakdown), so the heavy rows materialise on tap (#819). Nothing is recomputed here, it reuses
 * the existing sections, which read the SAME carried/today row the ring shows. Mirrors iOS chargeBreakdownSheet.
 * `internal` (not private) so the Coupled view's hero ring (task #43) opens THIS same sheet, one breakdown,
 * never a duplicate.
 */
@Composable
internal fun ChargeBreakdownSheet(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric?,
    showReadiness: Boolean,
    onClose: () -> Unit,
    onHowCalculated: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding, vertical = Metrics.gap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    uiString(R.string.l10n_today_screen_what_shaped_your_charge_9f53a2b3),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_today_screen_close_bbfa773e), tint = Palette.textSecondary)
                }
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Metrics.screenPadding)
                    .padding(bottom = Metrics.sectionGap),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                // The breakdown self-gates: a calibrating night (empty drivers) renders nothing here, the
                // Contributors + Readiness below still give an honest read, never a blank sheet.
                RecoveryDriversSection(days = days, displayDay = displayDay, carriedDay = carriedDay)
                RecoveryContributorsSection(day = displayDay, carriedDay = carriedDay)
                // S4: the SEPARATE Readiness block now lives here behind the Charge-ring tap (today-only,
                // matching the old inline gate). A one-word read (Push / Maintain / Rest) stays on the hero.
                if (showReadiness) ReadinessSection(days, carriedDay = carriedDay)
                // Everything above is what shaped YOUR Charge today; this opens the general METHOD behind the
                // score, so the two are clearly separated, not conflated. Opens the scoring guide at the
                // Charge section, the same target the per-ring ⓘ buttons use. Mirrors the iOS chargeBreakdown
                // "How Charge is calculated" NavigationLink to ScoringGuideView(initialSection: .charge).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable(
                            onClickLabel = uiString(R.string.today_action_how_charge),
                            onClick = onHowCalculated,
                        )
                        .background(Palette.surfaceInset)
                        .padding(14.dp)
                        .semantics {
                            contentDescription = uiString(R.string.l10n_today_screen_how_charge_is_calculated_the_method_3ea7548b)
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        Icons.Filled.Functions,
                        contentDescription = null,
                        tint = DomainTheme.Charge.color,
                        modifier = Modifier.size(14.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        Text(
                            uiString(R.string.l10n_today_screen_how_charge_is_calculated_142d5e8e),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.l10n_today_screen_the_method_behind_the_score_not_5bc68508),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }
    }
}

// MARK: - "What shaped it" the engine-computed Charge driver breakdown
//
// The SHARED-CONTRACT driver rows under the Charge ring: one row per REAL term the recovery scorer used,
// each carrying its signed point contribution (deltaPoints), the night's value, the personal baseline it
// was scored against, and a short plain-English verdict. Computed by RecoveryDrivers.chargeDrivers from
// the SAME inputs the Charge ring reads, so a row can never describe a term the score did not use; a
// missing input yields NO row (never a faked zero). The confidence dot + tier tag SURFACE the existing
// ScoreConfidence.forCharge: they are read, not recomputed. Hidden entirely when the day can't score
// (cold-start / no drivers). Byte-aligned with the iOS "What shaped it" section. No em-dashes.

@Composable
private fun RecoveryDriversSection(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric? = null,
) {
    // Read the row the Charge ring itself reads: today's own when scored, else the carried last-scored
    // day (#543) so the breakdown matches the carried ring instead of vanishing at the rollover.
    val readDay = carriedDay ?: displayDay
    val drivers = remember(days, readDay) { recoveryChargeDrivers(days, readDay) }
    if (drivers.isEmpty()) return

    val tier = remember(days, readDay) { chargeConfidenceTier(days, readDay) }
    val overline = carriedDay?.let { uiString(R.string.today_charge_carried, carriedCaption(it.day).localized()) }
        ?: uiString(R.string.trends_charge)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Header row: section title + the SURFACED confidence pill (dot + tier tag) on the right.
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader(uiString(R.string.today_what_shaped_it), overline = overline, trailing = uiString(R.string.today_vs_your_baseline))
            }
            ChargeConfidencePill(tier)
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                drivers.forEach { DriverRow(it) }
                Text(
                    uiString(R.string.today_charge_driver_guidance),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The SURFACED Charge confidence pill (dot + tier tag). Reads the existing ScoreConfidence, never
 *  recomputes it. SOLID = gold/accent, BUILDING = the blue warning tone, CALIBRATING = neutral slate. */
@Composable
private fun ChargeConfidencePill(tier: ScoreConfidence) {
    val (label, tone) = when (tier) {
        ScoreConfidence.SOLID -> uiString(R.string.today_confidence_solid) to StrandTone.Accent
        ScoreConfidence.BUILDING -> uiString(R.string.today_confidence_building) to StrandTone.Warning
        ScoreConfidence.CALIBRATING -> uiString(R.string.today_confidence_calibrating) to StrandTone.Neutral
    }
    StatePill(title = label, tone = tone)
}

/** One "What shaped it" driver row: an up/down delta chip (signed points, green up / red down),
 *  the label + verdict, and the value over its baseline. Mirrors the iOS driver row layout. */
@Composable
private fun DriverRow(driver: ChargeDriver) {
    val positive = driver.deltaPoints >= 0
    // A zero delta reads neutral (no green/red), not a misleading "good".
    val tone = when {
        driver.deltaPoints > 0 -> Palette.statusPositive
        driver.deltaPoints < 0 -> Palette.statusCritical
        else -> Palette.textTertiary
    }
    val signed = if (driver.deltaPoints > 0) "+${driver.deltaPoints}" else "${driver.deltaPoints}"
    val label = when (driver.label) {
        ChargeDriverLabel.HEART_RATE_VARIABILITY -> uiString(R.string.today_driver_hrv)
        ChargeDriverLabel.RESTING_HEART_RATE -> uiString(R.string.today_driver_resting_hr)
        ChargeDriverLabel.SLEEP_QUALITY -> uiString(R.string.today_driver_sleep_quality)
        ChargeDriverLabel.RESPIRATORY_RATE -> uiString(R.string.today_driver_respiratory)
        ChargeDriverLabel.SKIN_TEMPERATURE -> uiString(R.string.today_driver_skin_temperature)
    }
    val valueText = when (driver.unit) {
        ChargeDriverUnit.MILLISECONDS -> uiString(R.string.today_driver_value_ms, driver.value.roundToInt())
        ChargeDriverUnit.BEATS_PER_MINUTE -> uiString(R.string.today_driver_value_bpm, driver.value.roundToInt())
        ChargeDriverUnit.PERCENT -> uiString(R.string.today_driver_value_percent, driver.value.roundToInt())
        ChargeDriverUnit.BREATHS_PER_MINUTE -> uiString(
            R.string.today_driver_value_br_min, String.format(Locale.getDefault(), "%.1f", driver.value),
        )
        ChargeDriverUnit.CELSIUS_DEVIATION -> uiString(
            R.string.today_driver_value_temp_deviation,
            String.format(Locale.getDefault(), "%+.1f", driver.value),
        )
    }
    val baselineText = driver.baseline?.let { baseline -> when (driver.unit) {
        ChargeDriverUnit.MILLISECONDS -> uiString(R.string.today_driver_baseline_ms, baseline.roundToInt())
        ChargeDriverUnit.BEATS_PER_MINUTE -> uiString(R.string.today_driver_baseline_bpm, baseline.roundToInt())
        ChargeDriverUnit.BREATHS_PER_MINUTE -> uiString(
            R.string.today_driver_baseline_br_min, String.format(Locale.getDefault(), "%.1f", baseline),
        )
        ChargeDriverUnit.PERCENT, ChargeDriverUnit.CELSIUS_DEVIATION -> ""
    } } ?: ""
    val verdict = when (driver.verdict) {
        ChargeDriverVerdict.ABOVE_BASELINE_SUPPORTING -> uiString(R.string.today_driver_above_supporting)
        ChargeDriverVerdict.BELOW_BASELINE_SUPPORTING -> uiString(R.string.today_driver_below_supporting)
        ChargeDriverVerdict.ABOVE_BASELINE_LIMITING -> uiString(R.string.today_driver_above_limiting)
        ChargeDriverVerdict.BELOW_BASELINE_LIMITING -> uiString(R.string.today_driver_below_limiting)
        ChargeDriverVerdict.AT_BASELINE -> uiString(R.string.today_driver_at_baseline)
        ChargeDriverVerdict.HRV_SATURATION_LIMITING -> uiString(R.string.today_driver_hrv_saturation)
        ChargeDriverVerdict.STRONG_NIGHT_SUPPORTING -> uiString(R.string.today_driver_strong_night)
        ChargeDriverVerdict.BELOW_GOOD_NIGHT_LIMITING -> uiString(R.string.today_driver_below_good_night)
        ChargeDriverVerdict.TYPICAL_NIGHT -> uiString(R.string.today_driver_typical_night)
        ChargeDriverVerdict.NEAR_BASELINE -> uiString(R.string.today_driver_near_baseline)
        ChargeDriverVerdict.WARMER_THAN_BASELINE_LIMITING -> uiString(R.string.today_driver_warmer_limiting)
        ChargeDriverVerdict.COOLER_THAN_BASELINE_LIMITING -> uiString(R.string.today_driver_cooler_limiting)
    }
    val driverA11y = uiString(R.string.today_driver_a11y, label, valueText, baselineText, signed, verdict)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.semantics { contentDescription = driverA11y },
    ) {
        // Signed-point delta chip with a direction glyph.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(tone.copy(alpha = 0.12f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            if (driver.deltaPoints != 0) {
                Icon(
                    if (positive) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    tint = tone,
                    modifier = Modifier.size(14.dp),
                )
            }
            Text(uiString(R.string.l10n_today_screen_signed_pts_5ea85678, signed), style = NoopType.captionNumber, color = tone)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.headline, color = Palette.textPrimary)
            Text(verdict, style = NoopType.footnote, color = Palette.textSecondary)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(valueText, style = NoopType.captionNumber, color = Palette.textPrimary)
            Text(baselineText, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - Recovery contributors (README screen #5), labelled progress bars
//
// "CONTRIBUTORS", what drove today's Charge, each as a labelled progress bar in the shared stage/zone
// bar style (inset track, round-capped metric-hue fill, right-aligned read-out). Design-Reset tokens
// (iOS RecoveryContributorsSection parity): HRV reads teal (metricCyan), Resting HR the recovery/Charge
// world (chargeColor), Sleep and Respiratory the blue sleep world. Each bar's fraction is a
// presentation-only normalisation of the day's value to a typical adult span, no scoring/logic change.
// Suppressed entirely until at least one contributor has a value.

@Composable
private fun RecoveryContributorsSection(day: DailyMetric?, carriedDay: DailyMetric? = null) {
    // The row the contributors read from: today's own when it carries recovery, else the carried last
    // scored day (#543) so the bars don't all read "No Data" at the rollover while live HR ticks. The
    // overline stamps "Last night · <date>" when carrying so the prior read isn't passed off as today's.
    val cd = carriedDay ?: day
    val hrv = cd?.avgHrv
    val rhr = cd?.restingHr?.toDouble()
    val sleepMin = cd?.totalSleepMin
    val resp = cd?.respRateBpm
    if (hrv == null && rhr == null && sleepMin == null && resp == null) return

    val overline = carriedDay?.let { uiString(R.string.today_recovery_carried, carriedCaption(it.day).localized()) }
        ?: uiString(R.string.l10n_today_screen_recovery_ea924f72)
    SectionHeader(uiString(R.string.today_contributors), overline = overline, trailing = uiString(R.string.today_what_drove_charge))
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            // HRV, higher is better; map a typical 20–120 ms span. Teal (its biometric hue; iOS metricCyan).
            ContributorBar(
                label = uiString(R.string.today_metric_hrv),
                readout = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                fraction = hrv?.let { ((it - 20.0) / 100.0) },
                color = Palette.metricCyan,
            )
            // Resting HR, lower is better, so invert a typical 40–80 bpm span. Charge/recovery world (iOS
            // chargeColor, the recovery contributor reads on the WHOOP-green Charge world, not gold).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_resting_hr_26677094),
                readout = rhr?.let { "${it.roundToInt()} bpm" } ?: NO_DATA,
                fraction = rhr?.let { 1.0 - ((it - 40.0) / 40.0) },
                color = Palette.chargeColor,
            )
            // Sleep, hours in bed against an 8h target. Blue (sleep world).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_sleep_3cac34e6),
                readout = sleepMin?.let { sleepValue(cd) } ?: NO_DATA,
                fraction = sleepMin?.let { (it / 60.0) / 8.0 },
                color = Palette.sleepLight,
            )
            // Respiratory, stability around a typical 12–20 rpm span. Deep blue (sleep world).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_respiratory_1cd8c175),
                readout = resp?.let { String.format(Locale.getDefault(), "%.1f rpm", it) } ?: NO_DATA,
                fraction = resp?.let { 1.0 - ((it - 12.0) / 8.0) },
                color = Palette.sleepDeep,
            )
            Text(
                uiString(R.string.l10n_today_screen_baselines_learned_on_device_over_14_359f6812) +
                    "signal against a typical adult range, not medical advice.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** One labelled contributor bar: a label + right-aligned read-out over a liquid TUBE filled to [fraction].
 *  These ARE genuine single-value progress bars (each signal against a typical adult span), so the liquid
 *  finish reads well here (matching how the iOS liquid Today draws its single-value goal/strain bars as
 *  tubes). Static (not per-frame) — they sit in the tapped-open Charge breakdown, not a live surface, so
 *  `animated = false` keeps the sheet cheap. A null fraction renders an empty tube. */
@Composable
private fun ContributorBar(label: String, readout: String, fraction: Double?, color: Color) {
    val fillFrac = fraction?.coerceIn(0.0, 1.0) ?: 0.0
    val displayReadout = localizedMetricValue(readout)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(displayReadout, style = NoopType.captionNumber, color = Palette.textPrimary)
        }
        LiquidTube(
            frac = fillFrac,
            tint = color,
            height = Metrics.progressHeight,
            animated = false,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = uiString(R.string.l10n_today_screen_label_readout_3f166607, label, displayReadout) },
        )
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// Explainability layer, COMPONENTS 2, 3, 4 (spec: 2026-06-20-sleep-guidance-explainability.md)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Every uncertain or derived read-out on
// Today gets a clear state, a plain-English reason and a next step, and we NEVER fabricate a number:
// calibrating / needs-strap show NO value, carried values are always stamped with their date, and the
// provenance badge reflects the REAL per-day merge winner. The copy here is VERBATIM and must match the
// Swift today lane word-for-word (ScoreState / RecordingState). No em-dashes anywhere.
// ════════════════════════════════════════════════════════════════════════════════════════════════════

// ── COMPONENT 2, explained score states ─────────────────────────────────────────────────────────────

/** The score-state title, LOCALIZED — same split as [recordingTitle] and for the same reason:
 *  [ScoreState.title] is the English parity contract asserted verbatim against Swift in
 *  `TodayExplainabilityTest`, so the resource lookup lives here rather than in the pure mapper. */
@Composable
private fun scoreStateTitle(state: ScoreState): String = when (state) {
    is ScoreState.Scored -> ""
    is ScoreState.Calibrating -> uiString(state.titleRes!!)
    is ScoreState.CarriedLastNight ->
        uiString(state.titleRes!!, state.dateLabel)
    ScoreState.NeedsStrap -> uiString(state.titleRes!!)
}

/** The score-state detail line, LOCALIZED.
 *
 *  The calibrating countdown becomes a real `<plurals>`. Kotlin picked the noun with
 *  `if (nightsRemaining == 1) "night" else "nights"`, which bakes in English's TWO categories — the
 *  exact hand-rolling [uiPlural]'s doc warns about. `getQuantityString` applies the LOCALE's own rules
 *  instead. (Swift splits the same sentence into two catalogue keys, so it shares the assumption; both
 *  values here come from those keys. The one-forms carry `%1$d` where the Swift copy spelled the number
 *  out — pt-PT said "mais uma noite" — because `i18n_audit` requires every quantity form of a plural to
 *  share its siblings' placeholders, the check that catches a `%1$d` dropped from just one form.) */
@Composable
private fun scoreStateDetail(state: ScoreState): String = when (state) {
    is ScoreState.Scored -> ""
    is ScoreState.Calibrating ->
        uiPlural(R.plurals.score_state_detail_calibrating, state.nightsRemaining, state.nightsRemaining)
    is ScoreState.CarriedLastNight ->
        if (state.stale) uiString(R.string.score_state_detail_carried_stale)
        else uiString(R.string.score_state_detail_carried_fresh)
    ScoreState.NeedsStrap -> uiString(R.string.score_state_detail_needs_strap)
}

/** The honest score-state note shown in the Today flow when there is no own number to render, the
 *  state title + one what-to-do line, no fabricated value. [ScoreState.Scored] renders nothing (the
 *  tiles carry the real number). The whole card is the spec's "never a bare blank". Mirrors the iOS
 *  ScoreStateNote. */
@Composable
private fun ScoreStateNote(state: ScoreState, restartCause: String? = null) {
    if (state is ScoreState.Scored) return
    val icon = when (state) {
        is ScoreState.Calibrating -> Icons.Filled.Tune
        is ScoreState.CarriedLastNight -> Icons.Filled.History
        ScoreState.NeedsStrap -> Icons.Filled.Warning
        is ScoreState.Scored -> Icons.Filled.Info
    }
    val tint = when (state) {
        ScoreState.NeedsStrap -> Palette.statusWarning
        else -> Palette.textTertiary
    }
    // Resolved before the Row: `semantics { }` is not a composable scope, so uiString/uiPlural cannot be
    // called inside it, and reading them once keeps the card and its a11y label on one string.
    val title = scoreStateTitle(state)
    val detail = scoreStateDetail(state)
    val noteA11y = uiString(R.string.l10n_today_screen_state_title_state_detail_f5380609, title, detail)
    NoopCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = noteA11y },
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier
                    .padding(top = 1.dp)
                    .size(Metrics.iconSmall),
            )
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(detail, style = NoopType.subhead, color = Palette.textSecondary)
                // #731: when the countdown restarted because the user tapped "Recalibrate
                // baseline", say so - otherwise the natural response to a fresh countdown is to
                // tap it again, resetting it once more. null (no line) if never recalibrated.
                restartCause?.let {
                    Text(it, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }
        }
    }
}

// ── COMPONENT 3, recording status ───────────────────────────────────────────────────────────────────

/** The chip's status word, LOCALIZED.
 *
 *  [RecordingState.title] stays the English parity contract — it is asserted verbatim against the Swift
 *  twin in `TodayExplainabilityTest` and must not become resource-backed, which would drag a `Context`
 *  into a pure mapper and break those tests. So the resource lookup lives HERE, at the render site,
 *  exactly like the Swift side: `RecordingState.label` is a `LocalizedStringKey`, so its literals are
 *  catalogue KEYS that SwiftUI resolves. Kotlin's are plain `String`, so rendering `state.title`
 *  directly shipped English to every locale — the chip read "Not recording. Strap not connected."
 *  on a German phone while the iPhone read "Strap nicht verbunden. Tippe zum Verbinden."
 *
 *  Invisible to `i18n_audit`: the literals sit in a sealed-class getter, not a Compose call argument,
 *  so the scanner never saw them. Translations here are the Swift catalogue's own, copied 1:1.
 */
@Composable
private fun recordingTitle(state: RecordingState): String = when (state) {
    RecordingState.Recording -> uiString(state.titleRes)
    is RecordingState.LastSynced -> uiString(state.titleRes, state.minutesAgo)
    RecordingState.NotRecording -> uiString(state.titleRes)
    // Both connected states share the same word, as they do on Swift.
    RecordingState.HistoryExperimental, RecordingState.ConnectedNoData ->
        uiString(state.titleRes)
}

/** The chip's one-line detail, LOCALIZED. Same split as [recordingTitle]. */
@Composable
private fun recordingDetail(state: RecordingState): String = when (state) {
    RecordingState.Recording -> uiString(state.detailRes)
    is RecordingState.LastSynced -> uiString(state.detailRes)
    RecordingState.NotRecording -> uiString(state.detailRes)
    RecordingState.HistoryExperimental -> uiString(state.detailRes)
    RecordingState.ConnectedNoData -> uiString(state.detailRes)
}

/** The Today/Live recording chip: a tinted StatePill with the status word (a pulsing dot while live),
 *  plus the one-line what-it-means below. Honest, never claims "Recording" without a live stream.
 *  Tapping a not-recording chip routes to connect (Settings). Mirrors the iOS RecordingStatusChip. */
@Composable
private fun RecordingStatusChip(state: RecordingState, onConnect: () -> Unit) {
    val clickable = state is RecordingState.NotRecording || state is RecordingState.LastSynced
    // Resolved BEFORE the Row: `semantics { }` is not a composable scope, so uiString cannot be called
    // inside it. Reading them once also keeps the pill, the detail line and the a11y label on one string.
    val title = recordingTitle(state)
    val detail = recordingDetail(state)
    val chipA11y = uiString(R.string.l10n_today_screen_state_title_state_detail_f5380609, title, detail)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (clickable) {
                    Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onConnect,
                    )
                } else {
                    Modifier
                },
            )
            .semantics { contentDescription = chipA11y },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatePill(
            title = title,
            tone = state.tone,
            showsDot = true,
            pulsing = state is RecordingState.Recording,
        )
        Text(
            detail,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ── COMPONENT 4, provenance badge ───────────────────────────────────────────────────────────────────

// NOTE: the blanket day-level `TodayProvenanceBadge` was removed. Today provenance now resolves the real
// per-metric field-by-field winners, deduplicates them, and renders one card-level SourceBadge aligned to
// the Rest vessel (see heroSourceLabel + ScoreHeroRow). The pure `dayOwnerSource` /
// `provenanceBadgeLabel` By-Day mappers are kept (Intelligence/Trends + tests still use that vocabulary).

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Charge, Effort, Rest, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
@Suppress("UNUSED_PARAMETER")
private fun MetricGrid(
    d: DailyMetric?,
    w: Window,
    recoveryCalibration: Int? = null,
    lastScoredCharge: LastCharge? = null,
    carriedDay: DailyMetric? = null,
    // PER-FIELD SpO₂ carry (see lastSpo2Row): carriedDay is recovery-gated and lands on rows whose
    // spo2Pct is null (computed rows never carry one), so the Blood Oxygen tile falls through to the
    // last row that actually has a reading. Mirrors iOS TodayView.lastSpo2Day (carriedVital's per-field fallback).
    spo2CarryDay: DailyMetric? = null,
    // PER-FIELD respiratory carry (#1331): same reason as spo2CarryDay — respiratory needs a longer
    // clean sleep R-R segment than HRV, so carriedDay can land on a night with HRV but no breaths/min.
    respCarryDay: DailyMetric? = null,
    // #1599: the same candidate map the tile's sparkline is built from, so the number and the line under
    // it draw on one source rather than two. They are not guaranteed EQUAL — the value carries from
    // outside the window and the line cannot — but neither can now show data the other has no access to,
    // which is what made this tile render a number above a blank panel.
    spo2CandidateByDay: Map<String, Double> = emptyMap(),
    unitSystem: UnitSystem = UnitSystem.METRIC,
    effortScale: EffortScale = EffortScale.HUNDRED,
    // #1001: the day's resolved Effort (live-preferring for today, floored at the stored row). Threaded
    // like caloriesForDay/importedStepsForDay because, like those, it is not simply the DailyMetric column
    // — reading `d.strain` here is what left this tile behind the hero ring on an active morning.
    effortForDay: Double? = null,
    latestWeightKg: Double? = null,
    profileWeightKg: Double = 75.0,
    importedStepsForDay: Int? = null,
    estimatedStepsForDay: Int? = null,
    // #616: the selected day's calorie value resolved imported-first (imported Apple/Health-Connect
    // activeKcal ?: NOOP's on-device estimate), so the Calories tile matches the card + detail instead of
    // reading the on-device estimate alone (which left it NO_DATA / inconsistent). Mirrors the steps params.
    caloriesForDay: Double? = null,
    // #616: the Calories tile's imported-first 14-day trend (see caloriesSpark above) — threaded like
    // restSpark because it isn't a plain DailyMetric column (it unions the imported + on-device series).
    caloriesSpark: List<Double> = emptyList(),
    // #316 / @63, the selected day's representative activity class (0=still, 1=walk, 2=run), shown as a small
    // still/walk/run glyph on a REAL (measured) Steps tile. null hides the icon (no classed sample for the day).
    stepActivityClassForDay: Int? = null,
    // #760/#792: the caption under an ESTIMATED Steps tile: the engine's STATUS line (manual k, or
    // k=… from N days + confidence tier) so a frozen-looking estimate self-explains. Built from the SAME
    // persisted calibration the estimate used; defaults to a bare "est." for callers that don't supply it.
    stepsEstimateCaption: String = "est.",
    // #1491: the blank-tile line for a strap that ESTIMATES steps — null for a 5/MG (its strap reports a
    // real count) and for a user who has never selected a model, so neither is told to calibrate anything.
    stepsCalibrationPrompt: String? = null,
    restScore: Double? = null,
    // The Rest tile's sparkline: the trailing-window Rest composite (0–100, `sleep_performance`), so the
    // mini-graph tracks the Rest SCORE rather than raw sleep minutes (#614 follow-up). Other tiles still
    // read their series off `w` (the DailyMetric windows).
    restSpark: List<Double> = emptyList(),
    enabledMetrics: List<KeyMetric> = KeyMetric.defaultOrder,
    isToday: Boolean = false,
    onScoreInfo: (ScoreSection) -> Unit = {},
    // S5: cap the grid to the first METRICS_COLLAPSED_CAP tiles behind a "Show all metrics" expander,
    // collapsing OVERFLOW only (never dropping or reordering a user-selected tile, #251). Defaults keep the
    // grid fully expanded for any caller that doesn't opt into the cap.
    metricsExpanded: Boolean = true,
    onToggleMetrics: () -> Unit = {},
    // Detailed tiles (the #251 editor's switch): squarer tiles with a trend graph under the bar, drawn
    // over the editor's chosen window (7 / 14 / 30 days).
    detailed: Boolean = false,
    // The editor's trailing-window choice (7 / 14 / 30). Caps each tile's sparkline to that many trailing
    // points so "1 month" draws its full span instead of a fixed 14 (matches the iOS windowedSpark cutoff).
    windowDays: Int = 14,
    // Tile drill-ins: every tile opens its focused trend timeline (vital_detail/<key>, the Sleep
    // night-detail pattern) via [onOpenMetric].
    onOpenMetric: (String) -> Unit = {},
    // Exception for the actionable blank WHOOP 4.0 state: it opens the canonical calibration screen.
    onOpenStepsCalibration: () -> Unit = {},
) {
    val realStepsForDay = d?.steps ?: importedStepsForDay
    val stepsOpenCalibration = stepsTileShouldOpenCalibration(
        realSteps = realStepsForDay,
        estimatedSteps = estimatedStepsForDay,
        calibrationPrompt = stepsCalibrationPrompt,
    )

    // FIX 3 (iOS `keyMetricsSection` parity): a 3-COLUMN grid of COMPACT liquid tiles, each an iOS `ktile`
    // — a 9sp/+1.2 overline label, a value + small unit, and a thin 8dp LiquidTube fill bar — REPLACING the
    // old 2-column large sparkline cards. One descriptor per KeyMetric, carrying the SAME value/tint reads
    // the old builders used PLUS the tile's LiquidTube fraction (mirroring the iOS ktile frac). The #251
    // editor + enabled-order + collapse expander are all preserved; only the tile look changes.
    val descriptors: Map<KeyMetric, KeyTileData> = mapOf(
        KeyMetric.CHARGE to run {
            val v = d?.recovery ?: lastScoredCharge?.value
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_recovery_ea924f72),
                value = d?.recovery?.let { "${it.roundToInt()}" }
                    ?: recoveryCalibration?.let { "$it/${Baselines.minNightsSeed}" }
                    ?: lastScoredCharge?.let { "${it.value.roundToInt()}" } ?: NO_DATA,
                unit = if (d?.recovery != null || lastScoredCharge != null) "%" else "",
                tint = v?.let { Palette.recoveryColor(it) } ?: Palette.chargeColor,
                frac = v?.let { (it / 100.0).coerceIn(0.0, 1.0) },
                spark = w.recovery,
            )
        },
        KeyMetric.EFFORT to KeyTileData(
            label = uiString(R.string.l10n_today_screen_strain_79fe380e),
            // #1001: the resolved Effort, falling back to the stored column only when the caller passes
            // none (previews/tests). Reading `d.strain` here is what left this tile behind the hero ring.
            value = (effortForDay ?: d?.strain)?.let { UnitFormatter.effortDisplay(it, effortScale) } ?: NO_DATA,
            // #492: Strain/Effort is a load index (0–21 WHOOP / 0–100 NOOP), NOT a percentage — the "%"
            // was wrong (esp. on the 0–21 scale). Recovery/Rest ARE 0–100 % and keep it. iOS shows the
            // strain axis as an "of 21"/"of 100" caption with no % (TodayView effort tile); match that.
            unit = "",
            tint = (effortForDay ?: d?.strain)?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.effortColor,
            frac = (effortForDay ?: d?.strain)?.let { (it / 100.0).coerceIn(0.0, 1.0) },
            spark = w.strain,
        ),
        KeyMetric.REST to KeyTileData(
            label = uiString(R.string.l10n_today_screen_rest_b79e5f48),
            value = restScore?.let { "${it.roundToInt()}" } ?: NO_DATA,
            unit = if (restScore != null) "%" else "",
            tint = restScore?.let { Palette.recoveryColor(it) } ?: Palette.restColor,
            frac = restScore?.let { (it / 100.0).coerceIn(0.0, 1.0) },
            spark = restSpark,
        ),
        KeyMetric.HRV to run {
            val v = d?.avgHrv ?: carriedDay?.avgHrv
            KeyTileData(
                label = "HRV",
                value = v?.let { "${it.roundToInt()}" } ?: NO_DATA,
                unit = if (v != null) "ms" else "",
                tint = Palette.metricCyan,
                frac = v?.let { (it / 120.0).coerceIn(0.0, 1.0) },
                spark = w.hrv,
            )
        },
        KeyMetric.RESTING_HR to run {
            val v = d?.restingHr ?: carriedDay?.restingHr
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_rest_hr_04005617),
                value = v?.toString() ?: NO_DATA,
                unit = if (v != null) "bpm" else "",
                tint = Palette.metricRose,
                frac = v?.let { (it / 100.0).coerceIn(0.0, 1.0) },
                spark = w.rhr,
            )
        },
        KeyMetric.BLOOD_OXYGEN to run {
            // Candidate LAST, after the carries — the exact precedence the dashboard Blood Oxygen card
            // uses two sections down this same screen, and the one the Apple tile uses. The candidate is
            // a fallback for having nothing, never an override for having something stale.
            //
            // For the strap-only install this issue is about there are no calibrated readings at all, so
            // both carries are null and every surface resolves to the candidate regardless.
            val calibrated = d?.spo2Pct ?: carriedDay?.spo2Pct ?: spo2CarryDay?.spo2Pct
            val candidateToday = d?.day?.let { spo2CandidateByDay[it] }
            val onCandidate = spo2UsingCandidate(calibrated, candidateToday)
            val v = calibrated ?: candidateToday
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_blood_oxygen_a8ad9ff5),
                value = v?.let { String.format(Locale.getDefault(), "%.0f", it) } ?: NO_DATA,
                unit = if (v != null) "%" else "",
                tint = Palette.metricCyan,
                frac = v?.let { (it / 100.0).coerceIn(0.0, 1.0) },
                // Say WHOSE number this is. The Apple tile has carried this caption all along; Android
                // showed an unlabelled figure, which is the harder of the two to argue with.
                caption = if (onCandidate) uiString(R.string.spo2_strap_estimate_caption) else null,
                spark = spo2SparkSeries(w.spo2, w.spo2Candidate),
            )
        },
        KeyMetric.RESPIRATORY to run {
            val v = d?.respRateBpm ?: carriedDay?.respRateBpm ?: respCarryDay?.respRateBpm
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_respiratory_1cd8c175),
                value = v?.let { String.format(Locale.getDefault(), "%.1f", it) } ?: NO_DATA,
                unit = if (v != null) "rpm" else "",
                tint = Palette.accent,
                frac = v?.let { (it / 24.0).coerceIn(0.0, 1.0) },
                spark = w.resp,
            )
        },
        KeyMetric.STEPS to run {
            // Steps precedence (unchanged): on-device count → imported → estimate. (#107/#150)
            val steps = realStepsForDay ?: estimatedStepsForDay
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_steps_cdde4f20),
                value = steps?.let { intString(it.toDouble()) } ?: NO_DATA,
                unit = "",
                tint = Palette.metricCyan,
                frac = steps?.let { (it / 10000.0).coerceIn(0.0, 1.0) },
                spark = w.steps,   // #616: was missing → no trend line under the tile
                // A measured count needs no explanation; an ESTIMATE says what it was fitted from
                // (#760/#792); a BLANK tile on a strap that estimates says what would unblock it (#1491).
                caption = when {
                    realStepsForDay != null -> null
                    estimatedStepsForDay != null -> stepsEstimateCaption
                    else -> stepsCalibrationPrompt
                },
            )
        },
        KeyMetric.WEIGHT to run {
            val weight = weightTile(latestWeightKg, profileWeightKg, unitSystem)
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_weight_69c0b815),
                value = weight.value,
                unit = "",
                tint = Palette.accent,
                frac = null,
            )
        },
        KeyMetric.CALORIES to run {
            // #616: the per-day resolved calorie value (caloriesForDay = imported Apple/Health-Connect
            // first, else NOOP's on-device estimate) — one number across tile, card and detail.
            val kcal = caloriesForDay
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_calories_3e62ecfe),
                value = kcal?.let { intString(it) } ?: NO_DATA,
                unit = if (kcal != null) "kcal" else "",
                tint = Palette.metricAmber,
                frac = kcal?.let { (it / 800.0).coerceIn(0.0, 1.0) },
                spark = caloriesSpark,   // #616: imported-first trend (was missing → no trend line)
            )
        },
    )

    // Resolve the enabled tiles to their descriptors (keeping the metric for the tap mapping), dropping
    // any unknown key defensively.
    val allTiles = enabledMetrics.mapNotNull { m -> descriptors[m]?.let { m to it } }
    // Tile tap -> its focused trend TIMELINE (the Sleep night-detail pattern), uniformly for every tile
    // with a windowed series: Recovery/Effort/Rest open their new trend details; the vitals +
    // Steps/Calories open the same vital_detail trends the Health cards use. Today's Charge DRIVERS stay
    // on the hero ring's breakdown sheet (its existing home) — the tile is the history view.
    // Weight has no windowed detail yet -> not tappable (null keeps the tile inert rather than lying).
    fun tapFor(metric: KeyMetric): (() -> Unit)? = when (metric) {
        KeyMetric.CHARGE -> ({ onOpenMetric("recovery") })
        KeyMetric.EFFORT -> ({ onOpenMetric("strain") })
        KeyMetric.REST -> ({ onOpenMetric("rest") })
        KeyMetric.HRV -> ({ onOpenMetric("hrv") })
        KeyMetric.RESTING_HR -> ({ onOpenMetric("rhr") })
        KeyMetric.BLOOD_OXYGEN -> ({ onOpenMetric("spo2") })
        KeyMetric.RESPIRATORY -> ({ onOpenMetric("resp") })
        KeyMetric.STEPS -> if (stepsOpenCalibration) onOpenStepsCalibration else ({ onOpenMetric("steps_est") })
        KeyMetric.CALORIES -> ({ onOpenMetric("active_kcal") })
        KeyMetric.WEIGHT -> null
    }
    // S5: slice from the FRONT of the saved order so a pinned/selected tile is never dropped or reordered
    // (#251); only the tail folds behind the expander. Mirrors the iOS visibleKeyMetrics prefix(cap).
    val hasOverflow = allTiles.size > METRICS_COLLAPSED_CAP
    val tiles = if (metricsExpanded || !hasOverflow) allTiles else allTiles.take(METRICS_COLLAPSED_CAP)

    // iOS `keyMetricsSection` LazyVGrid: 3 columns, spacing 8. Build from rows so tile heights tile uniformly
    // and a partial last row pads with empty weight so the columns stay aligned.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(3).forEach { rowTiles ->
            // Detailed rows equalise heights (IntrinsicSize.Max + fillMaxHeight, the #399 idiom): a
            // graph-less tile (Steps/Weight/Calories) sharing a row with graphed neighbours must not
            // shrink its card. Compact rows keep the plain layout, byte-identical to before.
            Row(
                modifier = if (detailed) Modifier.height(IntrinsicSize.Max) else Modifier,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                rowTiles.forEach { (metric, tile) ->
                    LiquidKeyTile(
                        tile,
                        icon = keyMetricIcon(metric),
                        detailed = detailed,
                        windowDays = windowDays,
                        onClick = tapFor(metric),
                        modifier = Modifier.weight(1f).then(if (detailed) Modifier.fillMaxHeight() else Modifier),
                    )
                }
                repeat(3 - rowTiles.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        // S5: the "Show all metrics" / "Show fewer" expander — a centered link like iOS. Toggles visibility
        // only, never WHICH tiles are enabled or their order (that stays the #251 editor's job).
        if (hasOverflow) {
            val hidden = allTiles.size - METRICS_COLLAPSED_CAP
            TextButton(
                onClick = onToggleMetrics,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
            ) {
                Text(
                    if (metricsExpanded) uiString(R.string.today_show_fewer_metrics)
                    else uiString(R.string.today_show_all_metrics, hidden),
                    style = NoopType.subhead,
                )
                Spacer(Modifier.width(4.dp))
                Icon(
                    if (metricsExpanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

/** True only for the actionable #1515 state: the tile has no measured/imported count, no estimate, and
 *  carries the WHOOP 4.0 calibration prompt. Real or estimated Steps always retain their trend drill-in;
 *  a blank 5/MG or already-calibrated quiet day has no prompt and retains it too. */
internal fun stepsTileShouldOpenCalibration(
    realSteps: Int?,
    estimatedSteps: Int?,
    calibrationPrompt: String?,
): Boolean = realSteps == null && estimatedSteps == null && calibrationPrompt != null

/** One compact Key-Metrics tile's data: iOS `ktile`(label, value, unit, tint, frac). [spark] is the
 *  trailing trend series (oldest→newest) the DETAILED tile style graphs, capped at render to the editor's
 *  chosen window; empty hides the graph (a metric with no windowed series — Steps/Weight/Calories —
 *  stays tube-only even in detailed mode). */
private data class KeyTileData(
    val label: String,
    val value: String,
    val unit: String,
    val tint: Color,
    val frac: Double?,
    /** #1491: an optional one-line subtitle under the value. Only the Steps tile sets one today — the
     *  estimate's calibration status, or why a blank tile is blank. Null leaves the tile exactly as it was. */
    val caption: String? = null,
    val spark: List<Double> = emptyList(),
)

/** The per-metric glyph shown beside a Key-Metric tile's label — the Android twin of iOS
 *  `LiquidTodayView.keyMetricIcon`, using Material equivalents of its SF Symbols: heart / bolt / moon /
 *  trend line / heart-monitor / drop / air (≈lungs) / walk / scale / flame. Tinted to the tile colour at
 *  render, so the icon reads as the same signal as the bar. */
private fun keyMetricIcon(metric: KeyMetric): ImageVector = when (metric) {
    KeyMetric.CHARGE -> Icons.Filled.Favorite
    KeyMetric.EFFORT -> Icons.Filled.Bolt
    KeyMetric.REST -> Icons.Filled.Bedtime
    KeyMetric.HRV -> Icons.Filled.Timeline
    KeyMetric.RESTING_HR -> Icons.Filled.MonitorHeart
    KeyMetric.BLOOD_OXYGEN -> Icons.Filled.WaterDrop
    KeyMetric.RESPIRATORY -> Icons.Filled.Air
    KeyMetric.STEPS -> Icons.AutoMirrored.Filled.DirectionsWalk
    KeyMetric.WEIGHT -> Icons.Filled.MonitorWeight
    KeyMetric.CALORIES -> Icons.Filled.LocalFireDepartment
}

/**
 * One iOS `ktile`: a compact 3-column tile — a 9sp / +1.2 overline label, the value (number 17) + small
 * unit (caption), and a thin 8dp [LiquidTube] fill bar tinted [KeyTileData.tint] to [KeyTileData.frac].
 * Flat surfaceRaised fill + a 16dp-corner hairline (iOS ktile background), padding 12h / 11v. Replaces the
 * old tall 2-column SparkStatTile. A No-Data value dims and the tube reads empty.
 *
 * [detailed] (the #251 editor's "Detailed tiles" switch): the tile grows a trend [Sparkline] in the
 * metric's tint under the fill bar — taller/squarer, per the tester mock — over the editor's [windowDays]
 * window (7 / 14 / 30). A metric with no windowed series (Steps/Weight/Calories) or fewer than two points
 * stays tube-only, so no tile ever draws a fake flat line.
 */
@Composable
private fun LiquidKeyTile(
    data: KeyTileData,
    icon: ImageVector,
    detailed: Boolean = false,
    windowDays: Int = 14,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val hasValue = data.value != NO_DATA
    val displayValue = localizedMetricValue(data.value)
    // Tap -> the tile's focused trend detail (the Sleep night-detail tile idiom): liquidPress on the
    // tappable tile, indication = null so only the liquid settle shows. A null onClick keeps the tile
    // inert with zero modifier overhead (byte-identical to before).
    val interaction = remember { MutableInteractionSource() }
    val base = if (onClick != null) {
        modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    } else {
        modifier
    }
    Column(
        modifier = base
            .clip(RoundedCornerShape(16.dp))
            .frostedCardSurface(cornerRadius = 16.dp)
            .padding(horizontal = 12.dp, vertical = 11.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_data_label_data_value_data_unit_27f6fd6b, data.label, displayValue, data.unit).trim() },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // iOS ktile parity: a small metric glyph before the overline label, tinted to the tile colour at
        // 0.72 opacity (LiquidTodayView `Image(systemName:).foregroundStyle(tint.opacity(0.72))`). Decorative
        // — the tile's own semantics already announce the label/value, so the icon is contentDescription-null.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = data.tint.copy(alpha = 0.72f),
                modifier = Modifier.size(12.dp),
            )
            Text(
                data.label.uppercase(),
                style = NoopType.overline.copy(fontSize = 9.sp, letterSpacing = 1.2.sp),
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                displayValue,
                style = NoopType.number(17f),
                color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
                maxLines = 1,
            )
            if (data.unit.isNotEmpty() && hasValue) {
                Text(
                    uiString(R.string.l10n_today_screen_data_unit_c768ef8c, data.unit),
                    style = NoopType.caption,
                    color = Palette.textPrimary,
                    maxLines = 1,
                )
            }
        }
        // #1491: the Steps subtitle — the calibration status behind an estimate (#760/#792, computed and
        // then dropped on the floor until now: `stepsEstimateCaption` was passed into this grid and never
        // read), or, on a blank tile, what actually unblocks it. One line, ellipsised, and only rendered
        // when a tile supplies one, so every other tile keeps its current height.
        data.caption?.let { cap ->
            Text(
                cap,
                style = NoopType.caption,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // Detailed rows are height-equalised (fillMaxHeight): pin the bar + graph to the bottom edge so a
        // graph-less tile's bar lines up with its neighbours' bars rather than floating mid-card.
        if (detailed) Spacer(Modifier.weight(1f))
        LiquidTube(
            frac = data.frac ?: 0.0,
            tint = data.tint,
            height = 8.dp,
            animated = false,
            modifier = Modifier.fillMaxWidth(),
        )
        // Detailed tiles: the windowed trend graph under the bar (same Sparkline leaf the Sleep tiles use,
        // at the shared tile spark height), tinted to the metric so the graph reads as the same signal.
        // Cap to the editor's chosen window (7 / 14 / 30) so "1 month" draws its full span; the w-based
        // series is already windowed, but calories/rest sparks run longer, so this trims them to match.
        if (detailed) {
            val tail = data.spark.takeLast(windowDays)
            if (tail.size >= 2) {
                Sparkline(
                    values = tail,
                    color = data.tint,
                    modifier = Modifier
                        .fillMaxWidth()
                        // A touch more air between the fill bar and the graph (tester feedback: the two
                        // read as one element when they nearly touch).
                        .padding(top = 6.dp)
                        .height(Metrics.sparkHeight),
                )
            }
        }
    }
}

// Workouts across every recorded + imported source over [from, to]. Recorded sessions live under
// the ACTIVE strap id — "whoop-<id>" after a re-pair — unioned with the canonical legacy "my-whoop"
// via [WhoopRepository.workoutsUnion] (#814): this read was pinned to the literal "my-whoop", which
// stranded a re-paired strap's fresh recordings, so the "Latest Workouts" feed and the HR-graph
// glyphs silently dropped the newest sessions while the Workouts screen (already on the union, #28)
// still showed them. Apple Health and Health Connect imports are stored under their own device ids
// (since #34/#53). Both the "Last Workouts" feed and the HR-graph sport glyphs need the SAME union,
// or Health-Connect-imported sessions get no glyph on the Today trend, so they share this one seam.
// Deduped here (not per-consumer) with the Workouts screen's #687 semantics: a live strap recording
// and its thin Health Connect import collapse to the richer row, so neither the feed shows a
// duplicate card nor the HR trend a doubled sport glyph. dropDetectedShadows/filterDismissed are
// deliberately absent: `detected` rows live under `<deviceId>-noop`, which this union never queries.
private suspend fun WhoopRepository.workoutsAllSources(
    activeDeviceId: String,
    from: Long,
    to: Long,
): List<WorkoutRow> =
    WorkoutEditing.dedupCrossSource(
        workoutsUnion(activeDeviceId, from, to) +
            workouts("apple-health", from, to) +
            workouts("health-connect", from, to)
    )

// MARK: - Heart-rate trend (today's continuous HR off the strap's own ~1Hz history)
//
// A full-width 24h HR trend, plotted from 5-minute bucket means of the strap's hrSample history
// (offloaded even while the app was closed, so the day reads continuously). Hidden until there are at
// least two buckets, so a strap-only user with no wear today sees nothing rather than an empty chart.
// Mirrors the macOS TodayView.heartRateTrendSection. LineChart spaces points by index (no time axis),
// so the buckets, being uniform 5-min means in time order, read as an even left-to-right day curve.

/** The HR-window selector row, reusing the app's ONE SegmentedPillControl (house chrome, not the PR's
 *  bespoke control). Shared by the empty and populated card branches so the pills stay put whether or
 *  not the chosen window has data. */
@Composable
private fun HrWindowPills(selection: HrWindow, onSelect: (HrWindow) -> Unit) {
    SegmentedPillControl(
        items = HrWindow.entries.toList(),
        selection = selection,
        label = { uiString(it.labelRes) },
        onSelect = onSelect,
    )
}

@Composable
private fun HeartRateTrendCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    selectedDay: LocalDate,
    today: LocalDate,
    displayMetric: DailyMetric? = null,
    effortScale: EffortScale = EffortScale.HUNDRED,
    // #1001: the day's resolved Effort for the chart's edge badge. It read `displayMetric.strain` — the
    // daily row — so on an active morning the badge trailed the hero ring by the whole morning's load.
    effortForDay: Double? = null,
) {
    // "Today" here is the LOGICAL day (rolls at 04:00 local), so in the small hours after midnight the
    // trend keeps the evening's curve, window start at the logical day's own midnight, "since midnight"
    // subtitle, "Today" label, rather than blanking to an empty new-calendar-day axis (#144).
    var buckets by remember { mutableStateOf<List<HrBucket>>(emptyList()) }
    // The night's sleep session overlapping the HR window + the day's workouts, the Overview-HR
    // marker layers (sleep band, Charge at wake, sport glyphs at HR peaks). Loaded off the main
    // thread alongside the buckets; each marker self-hides when its data is absent. (PR #285)
    var sleepToday by remember { mutableStateOf<SleepSession?>(null) }
    var workoutsToday by remember { mutableStateOf<List<WorkoutRow>>(emptyList()) }
    // #985: the selected HR window. rememberSaveable ordinal so the choice survives rotation / process
    // death and feels sticky like a preference; 0 = TODAY, the unchanged full-day default. Forced to
    // TODAY on a past day (no "now" to anchor a rolling window — the pills don't render there either).
    // VIEW-ONLY (see HrWindow): it narrows the rendered buckets below; the LaunchedEffect read is untouched.
    var hrWindowOrdinal by rememberSaveable { mutableIntStateOf(0) }
    val hrWindow = if (selectedDay == today) HrWindow.entries[hrWindowOrdinal] else HrWindow.TODAY
    // #829 Android parity - the Today HR pinch/drag zoom window (unix seconds), null = the full loaded
    // day. Mirrors iOS TodayView.hrZoomDomain: VIEW-ONLY (it narrows which of the already-loaded buckets
    // render, never re-queries the DB), keyed on the selected day so stepping days always opens at full
    // scale, while a same-day live reload keeps the window (fresh buckets only ever extend the loaded
    // extent, so an existing window stays valid). Reset by double-tap on the chart or the Reset link.
    // Also keyed on the #985 window: changing the window re-frames the chart, so a pinch-zoom made
    // inside the old frame resets with it rather than surviving as a stale sub-range.
    var hrZoom by remember(selectedDay, hrWindowOrdinal) { mutableStateOf<LongRange?>(null) }
    // #605: a WHOOP-4.0 offload banks raw HR samples straight into the hr-sample store WITHOUT touching
    // any DailyMetric row, so a sync that only adds today's HR curve never changes `days`, and keying the
    // reload on `days` alone left this chart frozen on the pre-sync window until something unrelated
    // recomposed it. Re-key on the live sync tokens too: `lastSyncAt` ticks the moment an offload reaches
    // HISTORY_COMPLETE (the banked samples are now final → reload the buckets), and `syncChunksThisSession`
    // advances through a long backfill so the curve fills in progressively rather than only at the end.
    // (No "show a past day curve" fallback, rejected behaviour change; this only re-queries the SAME
    // selected-day window when fresh samples land.) Mirrors the iOS Today HR lane keying off the sync state.
    val live by viewModel.live.collectAsStateWithLifecycle()
    // Re-load when the day list changes (an import updates it), when the day selector moves, and, via the
    // sync tokens, when a strap offload banks fresh HR samples for the current window. Also on first compose.
    LaunchedEffect(days, selectedDay, today, live.lastSyncAt, live.syncChunksThisSession) {
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDay == today) now else (nextStart - 1)
        // #908: the Today HR curve reads the active strap ∪ canonical "my-whoop" union, NOT a hardcoded
        // "my-whoop". A strap re-added via the device manager banks live HR under its own fresh id, so a
        // pinned read showed the "no heart rate banked yet today" empty state. Single-WHOOP ⇒ one id ⇒ same.
        buckets = viewModel.repo.hrBucketsUnion(viewModel.activeStrapId, start, end, 300L)
        // The sleep that ended within the chart window (the night before / this morning), anchors
        // the band + the Charge-at-wake marker. A wide lower bound catches an onset before midnight.
        // Resolves the day's bridged MAIN-night span via `mainSleepSpan` (the SAME resolver the Sleep
        // tab hero and AnalyticsEngine's daily total use), not an ad hoc "freshest-ending block" pick --
        // that could disagree with the Sleep tab and the Coupled view's bed-wake read for a night stored
        // as more than one block (#294).
        sleepToday = runCatching {
            // #1304/#512: union across the active strap (like the hrBucketsUnion read just above) — a 2nd
            // strap's night is banked under "whoop-<uuid>" and a raw "my-whoop" read misses it, so the
            // hero showed no sleep band. Single-WHOOP collapses to "my-whoop", byte-identical.
            val overlapping = viewModel.repo.sleepSessionsUnion(viewModel.activeStrapId, start - 18 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }   // overlaps the window
            val habitualMidsleepSec = viewModel.repo.habitualMidsleepSec(viewModel.activeStrapId)
            mainSleepSpan(overlapping, habitualMidsleepSec)?.let { (spanStart, spanEnd) ->
                SleepSession(deviceId = "my-whoop", startTs = spanStart, endTs = spanEnd)
            }
        }.getOrNull()
        // Workouts overlapping the window, each gets a sport glyph at its in-window HR peak.
        // Union every source (not just "my-whoop"): Health-Connect-imported sessions are stored
        // under their own device id, so a strap-only query left them glyph-less here while the
        // "Last Workouts" feed below showed them (#34/#53). The glyph self-hides when no strap HR
        // overlaps, so an import with no matching strap curve simply draws nothing.
        workoutsToday = runCatching {
            viewModel.repo.workoutsAllSources(viewModel.deviceId, start - 6 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }
        }.getOrDefault(emptyList())
    }
    val selectedLabel = when (selectedDay) {
        today -> uiString(R.string.today_day_today)
        today.minusDays(1) -> uiString(R.string.today_day_yesterday)
        else -> selectedDay.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
    }

    // #985 view-only narrowing (the #829 rule): the selected window filters the loaded 5-minute buckets,
    // anchored at the wall clock when the inputs change. A live reload refreshes `buckets`, so the anchor
    // tracks the sync cadence — plenty for a card whose buckets are 5 minutes wide.
    val winBuckets = remember(buckets, hrWindow) {
        val now = System.currentTimeMillis() / 1000
        if (hrWindow == HrWindow.TODAY) buckets else buckets.filter { hrWindowKeeps(it.bucket, hrWindow, now) }
    }

    // #863: a sparse/empty selected day used to `return` here and render NOTHING, which read as "the graph
    // froze". Show an explicit calibrating/empty card instead so the user knows the curve is still filling in
    // (a calibrating 4.0 banks HR slowly) rather than that the screen broke. We intentionally do NOT silently
    // swap in a different day's curve here (that day-swap reload behaviour was rejected in #605, see above);
    // the honest empty state is the parity-matched fix. Mirrors the iOS Today HR card's empty branch.
    // #985: the check reads the WINDOWED subset, and the pills stay visible in the empty state, so a
    // too-narrow rolling window (say 1h with no recent offload) is never a dead end — the user widens it
    // or steps back to Today, and the message says which window came up empty.
    if (winBuckets.size < 2) {
        SectionHeader(uiString(R.string.today_section_heart_rate), overline = selectedLabel)
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Overline(uiString(R.string.today_hr_beats_per_minute))
                if (selectedDay == today) {
                    HrWindowPills(hrWindow) { hrWindowOrdinal = it.ordinal }
                }
                Text(
                    when {
                        selectedDay != today ->
                            uiString(R.string.today_hr_empty_selected_day)
                        hrWindow != HrWindow.TODAY && buckets.size >= 2 ->
                            uiString(R.string.today_hr_empty_window, uiString(hrWindow.labelRes))
                        else ->
                            uiString(R.string.today_hr_calibrating)
                    },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
        return
    }

    // #985: everything below (read-outs, zoom bounds, chart, footer) renders the WINDOWED subset — for
    // TODAY that is the identical full-buckets list, so the default path is byte-for-byte the old one.
    val bpm = remember(winBuckets) { winBuckets.map { it.avgBpm } }
    val latest = bpm.last().roundToInt()
    val min = bpm.min().roundToInt()
    val max = bpm.max().roundToInt()
    val avg = bpm.average().roundToInt()

    // #829 - the RENDERED subset: the zoom window narrows which of the loaded buckets draw (the gesture
    // handler only commits windows keeping >= 2 buckets, and the full-buckets fallback covers a same-day
    // reload reshaping the data underneath an open window, so the curve always stays drawable). Bounds =
    // the SELECTED window's bucket extent (#985) — the same full view the un-zoomed chart renders — so a
    // pinch-zoom pans within the chosen window, not out into buckets the window has hidden.
    val zoomBounds = winBuckets.first().bucket..winBuckets.last().bucket
    val visBuckets = remember(winBuckets, hrZoom) {
        val sub = hrZoom?.let { w -> winBuckets.filter { it.bucket in w } } ?: winBuckets
        if (sub.size >= 2) sub else winBuckets
    }
    val visBpm = remember(visBuckets) { visBuckets.map { it.avgBpm } }
    // The left y-rail tracks the RENDERED window (LineChart normalises to what it draws, the Deep
    // Timeline idiom), so a zoomed curve keeps honest max/avg/min beside it; the footer Min/Avg/Max row
    // below reads the whole SELECTED window (#985) — the full day for Today, or the rolling last-N-hours
    // span — so it matches the subtitle and stays stable while you pinch around within that window.
    val visMax = visBpm.max().roundToInt()
    val visAvg = visBpm.average().roundToInt()
    val visMin = visBpm.min().roundToInt()

    // Round wall-clock ticks for the RENDERED extent, shared by the gridlines (drawn inside
    // OverviewHRChart) and the axis-label strip below so they align.
    val timeTicks = remember(visBuckets) {
        chartTimeTicks(visBuckets.first().bucket, visBuckets.last().bucket, ZoneId.systemDefault())
    }
    val visTimestamps = remember(visBuckets) { visBuckets.map { it.bucket } }

    SectionHeader(uiString(R.string.today_section_heart_rate), overline = selectedLabel)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header, mirrors the macOS ChartCard (title + subtitle, trailing read-out).
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(uiString(R.string.today_hr_beats_per_minute))
                    // #985: the buckets stay the same 5-minute means whatever the window (view-only
                    // narrowing, no re-read), so the resolution half of the label never changes — only
                    // the span half tells the truth about what's on screen.
                    val subtitle = when {
                        selectedDay != today -> uiString(R.string.today_hr_average_selected_day)
                        hrWindow == HrWindow.TODAY -> uiString(R.string.today_hr_average_since_midnight)
                        else -> uiString(R.string.today_hr_average_last_window, uiString(hrWindow.labelRes))
                    }
                    Text(
                        subtitle,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text(uiString(R.string.l10n_today_screen_latest_bpm_e7bec767, latest), style = NoopType.chartValueLarge, color = Palette.metricRose)
            }
            // #985: the window selector, current day only — Today (since midnight, the default) or a
            // rolling last-N-hours cut of the same loaded buckets. A past day has no "now" → no selector.
            if (selectedDay == today) {
                HrWindowPills(hrWindow) { hrWindowOrdinal = it.ordinal }
            }
            // Chart with a max/avg/min Y-axis label column on the left and an HH:mm X-axis row below.
            // The line spaces points by index, but the X labels read each bucket's REAL timestamp in
            // local time (see below) so the axis reads true wall-clock even when the day has gaps (#544).
            Row(
                modifier = Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Column(
                    modifier = Modifier.height(Metrics.chartHeight),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(uiString(R.string.l10n_today_screen_vismax_80b2c2fc, visMax), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_today_screen_visavg_8c9a4746, visAvg), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_today_screen_vismin_5d665ceb, visMin), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                // The HR line, with the Overview marker layers (sleep band · Charge · Effort · sport
                // glyphs) overlaid on top, markers are positioned by mapping each event's wall-clock
                // time onto the line's index spacing, so they sit on the same curve. (PR #285)
                // #829 - renders the zoom window's subset, with the pinch/pan/double-tap transform
                // detector attached (keyed on the #985-windowed buckets so its captured bounds track
                // both a reload and a window change — the pinch operates INSIDE the selected window).
                // The chart and its axis-label strip share this Column so both span exactly the
                // plot width (not the card width, which includes the y-rail) — a label centred at
                // a tick fraction lands under its gridline.
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    OverviewHRChart(
                        buckets = visBuckets,
                        bpm = visBpm,
                        sleep = sleepToday,
                        workouts = workoutsToday,
                        recovery = displayMetric?.recovery,
                        strain = effortForDay ?: displayMetric?.strain,   // #1001
                        effortScale = effortScale,
                        timeTicks = timeTicks,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(Metrics.chartHeight)
                            .pointerInput(winBuckets) {
                                hrChartTransformGestures(
                                    buckets = winBuckets,
                                    bounds = zoomBounds,
                                    window = { hrZoom },
                                    onWindow = { hrZoom = it },
                                )
                            },
                    )
                    // X-axis: labels use the SAME timestamp interpolation as the line and markers,
                    // so the axis agrees with the curve even when the day has gaps (#544). "Now"
                    // only on the un-zoomed live day — a zoomed window's right edge is wherever
                    // the user panned it (#829).
                    HrTimeAxisLabels(
                        ticks = timeTicks,
                        timestamps = visTimestamps,
                        showNow = selectedDay == today && hrZoom == null,
                    )
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.divider)
                    .background(Palette.hairline),
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    uiString(R.string.today_hr_min) to min,
                    uiString(R.string.today_hr_avg) to avg,
                    uiString(R.string.today_hr_max) to max,
                ).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text(uiString(R.string.l10n_today_screen_value_bpm_8f3a90c3, value), style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }
            }
            // #829 - the pinch/drag affordance + Reset, mirroring the iOS hrZoomHint row: teaches the
            // gesture, and once zoomed shows a Reset link that mirrors the chart's own double-tap reset.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (hrZoom == null) uiString(R.string.timeline_pinch_to_zoom)
                    else uiString(R.string.today_hr_zoomed_hint),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                if (hrZoom != null) {
                    Text(
                        uiString(R.string.l10n_today_screen_reset_44c57abd),
                        style = NoopType.footnote,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .clickable(onClickLabel = uiString(R.string.today_action_reset_hr_zoom)) { hrZoom = null }
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
        }
    }
}

// The Today HR x-axis label strip: one Text per round-time tick, centred under its gridline via
// the SAME per-bucket timestamp interpolation the chart uses (timestampFraction, Charts.kt) and
// clamped into the strip. "Now" keeps its right-edge slot; a tick label that would collide with
// it (or with its left neighbour) is skipped rather than overlapped.
@Composable
private fun HrTimeAxisLabels(
    ticks: List<Pair<Long, String>>,
    timestamps: List<Long>,
    showNow: Boolean,
) {
    Layout(
        modifier = Modifier.fillMaxWidth(),
        content = {
            ticks.forEach { (_, label) ->
                Text(label, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
            if (showNow) {
                Text(uiString(R.string.l10n_today_screen_now_e3b82040), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
        },
    ) { measurables, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val placeables = measurables.map { it.measure(loose) }
        val width = constraints.maxWidth
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(width, height) {
            val nowPlaceable = if (showNow) placeables.last() else null
            val nowLeft = nowPlaceable?.let { width - it.width } ?: Int.MAX_VALUE
            nowPlaceable?.place(width - nowPlaceable.width, 0)
            var lastRight = Int.MIN_VALUE
            ticks.forEachIndexed { i, (ts, _) ->
                val p = placeables[i]
                val frac = timestampFraction(timestamps, ts) ?: return@forEachIndexed
                val x = (frac * width - p.width / 2f).roundToInt().coerceIn(0, (width - p.width).coerceAtLeast(0))
                // Skip a label that would overlap its neighbour or the "Now" marker.
                if (x > lastRight && x + p.width <= nowLeft - 8) {
                    p.place(x, 0)
                    lastRight = x + p.width + 8
                }
            }
        }
    }
}

// #829 Android parity - the Today HR chart's transform detector. The Deep Timeline's own
// detectTransformGestures claims EVERY drag on the chart, fine on its dedicated screen but here it would
// eat the Today feed's vertical scroll AND the LineChart's scrub-to-inspect. This detector reuses the
// Deep Timeline's pure window math (zoomedWindow / pannedWindow, Charts.kt) but watches the INITIAL
// pointer pass and claims only:
//   (a) any multi-finger gesture (pinch zooms about the centroid), always, and
//   (b) a single-finger HORIZONTAL-dominant drag while ZOOMED (pan). Un-zoomed, a horizontal drag stays
//       the LineChart's scrub-to-inspect exactly as before, matching iOS where an un-zoomed pan is a
//       visual no-op anyway.
// A vertical-dominant drag is never claimed, so the feed keeps scrolling over the chart. Claimed events
// are consumed in the Initial pass, which cancels the child scrub AND the page-level day-swipe for that
// gesture, the same chart-owns-its-frame exclusivity the iOS Today chart gets from masking the day-swipe
// over the chart frame. A motionless double tap resets to the full day, mirroring the iOS double-tap
// reset. Windows only commit when they keep >= 2 buckets visible (the curve stays drawable), and a
// window grown back to the full bounds normalises to null (un-zoomed), so the hint/Reset row recovers by
// pinching out too.
private suspend fun PointerInputScope.hrChartTransformGestures(
    buckets: List<HrBucket>,
    bounds: LongRange,
    window: () -> LongRange?,
    onWindow: (LongRange?) -> Unit,
) {
    // Two 5-minute buckets: the tightest window that still draws a line segment.
    val minSpanSeconds = 600L
    var lastTapAtMs = 0L
    var lastTapPos = Offset.Zero
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        var claimed = false   // ours: a pinch, or a horizontal pan while zoomed
        var ceded = false     // vertical-dominant: the feed's scroll owns it, just watch for the lift
        var moved = false
        var totalX = 0f
        var totalY = 0f
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.changes.none { it.pressed }) {
                // Lift-off. A short motionless single tap feeds the double-tap reset, only meaningful
                // while zoomed (the un-zoomed chart has nothing to reset, mirroring the iOS isZoomed
                // guard), and never consumed, so the LineChart's single-tap inspect keeps working.
                val up = event.changes.first()
                if (!claimed && !ceded && !moved && window() != null) {
                    val upAtMs = up.uptimeMillis
                    val isDoubleTap = upAtMs - lastTapAtMs <= viewConfiguration.doubleTapTimeoutMillis &&
                        (up.position - lastTapPos).getDistance() <= viewConfiguration.touchSlop * 4
                    if (isDoubleTap) {
                        onWindow(null)
                        lastTapAtMs = 0L
                    } else {
                        lastTapAtMs = upAtMs
                        lastTapPos = up.position
                    }
                }
                break
            }
            if (ceded) continue
            if (!claimed) {
                if (event.changes.count { it.pressed } > 1) {
                    claimed = true
                } else {
                    val pan = event.calculatePan()
                    totalX += pan.x
                    totalY += pan.y
                    if (abs(totalY) > viewConfiguration.touchSlop && abs(totalY) > abs(totalX)) {
                        ceded = true
                        moved = true
                        continue
                    }
                    if (abs(totalX) > viewConfiguration.touchSlop) {
                        moved = true
                        if (window() != null) claimed = true
                    }
                }
            }
            if (!claimed) continue
            val zoomChange = event.calculateZoom()
            val panChange = event.calculatePan()
            val width = size.width.toFloat().coerceAtLeast(1f)
            var w = window() ?: bounds
            if (zoomChange != 1f) {
                val frac = (event.calculateCentroid().x / width).coerceIn(0f, 1f)
                w = zoomedWindow(w, zoomChange, frac, bounds, minSpan = minSpanSeconds)
            }
            if (panChange.x != 0f) {
                val secPerPx = (w.last - w.first).toDouble() / width
                w = pannedWindow(w, (-panChange.x * secPerPx).toLong(), bounds)
            }
            if (buckets.count { it.bucket in w } >= 2) {
                onWindow(if (w.first <= bounds.first && w.last >= bounds.last) null else w)
            }
            event.changes.forEach { if (it.positionChanged()) it.consume() }
        }
    }
}

// MARK: - Overview HR chart (WHOOP-style day-in-review annotations)
//
// The 24h HR line, the shared index-spaced [LineChart], with marker layers drawn ON TOP:
//   (a) a sleep band shading the night's sleep span (indigo, behind the line conceptually but
//       drawn under the marker chrome so labels stay legible),
//   (b) a dashed Charge rule + label at wake time (sleep end), hidden while recovery calibrates,
//   (c) a dashed Effort rule + label at "now" (the latest sample), routed through the SAME
//       UnitFormatter.effortDisplay the Effort tile uses so it honours the 0–100 / 0–21 toggle (#268),
//   (d) a small sport glyph at each workout's in-window HR peak.
//
// LineChart plots points by LIST INDEX (evenly spaced, no time axis), so each marker's wall-clock
// time is mapped to a fractional list index by interpolating against the buckets' own timestamps, // markers then sit exactly on the rendered curve even when the strap history has gaps. Every layer
// self-hides when its data is absent (no sleep, calibrating Charge, no workouts). Mirrors the macOS
// OverviewHRChart (Packages/StrandDesign) in NOOP's own colour language. (PR #285)

@Composable
private fun OverviewHRChart(
    buckets: List<HrBucket>,
    bpm: List<Double>,
    sleep: SleepSession?,
    workouts: List<WorkoutRow>,
    recovery: Double?,
    strain: Double?,
    effortScale: EffortScale,
    modifier: Modifier,
    // Round wall-clock (epochSec, "HH:mm") ticks, each drawn as a dotted gridline under the curve.
    // The matching labels render OUTSIDE this plot-height composable (HrTimeAxisLabels), sharing
    // the same tick list + timestamp mapping so they align. Empty = no gridlines.
    timeTicks: List<Pair<Long, String>> = emptyList(),
) {
    // The line itself stays the existing shared component, unchanged, markers are a sibling overlay.
    val bucketTimestamps = remember(buckets) { buckets.map { it.bucket } }
    val minV = bpm.min()
    val maxV = bpm.max()
    val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
    val n = bpm.size

    // Geometry constants copied verbatim from LineChart/pointsFor so overlay positions land on the curve.
    val strokePx = 2.5f
    val topPad = strokePx + 4f
    val bottomPad = strokePx + 4f

    // Plot pixel size, captured from the Box that wraps both the line and the overlay.
    var plotW by remember { mutableStateOf(0f) }
    var plotH by remember { mutableStateOf(0f) }
    val density = LocalDensity.current

    // ── time → x helpers ──
    // Fractional list index for a wall-clock unix-seconds time, interpolating between bucket
    // timestamps; null when the time falls outside the loaded buckets.
    fun fracIndexFor(ts: Long): Float? {
        if (n < 2) return null
        val first = buckets.first().bucket
        val last = buckets.last().bucket
        if (ts <= first) return 0f
        if (ts >= last) return (n - 1).toFloat()
        val hi = buckets.indexOfFirst { it.bucket >= ts }
        if (hi <= 0) return 0f
        val lo = hi - 1
        val t0 = buckets[lo].bucket
        val t1 = buckets[hi].bucket
        val f = if (t1 > t0) (ts - t0).toFloat() / (t1 - t0).toFloat() else 0f
        return lo + f
    }
    fun xFor(ts: Long): Float? {
        val fi = fracIndexFor(ts) ?: return null
        return if (n > 1) plotW * fi / (n - 1) else null
    }
    // Strict variant for POINT markers (charge pill, peak, effort-now rule): null when the time
    // falls outside the RENDERED buckets, so a zoomed window hides out-of-window marks exactly like
    // iOS clips them, instead of pinning them to the window edge. The sleep BAND keeps the clamping
    // xFor: clamping a range to the visible window is the correct behaviour for a span.
    fun xForStrict(ts: Long): Float? {
        if (n < 2) return null
        if (ts < buckets.first().bucket || ts > buckets.last().bucket) return null
        return xFor(ts)
    }
    fun yForBpm(v: Double): Float {
        val usableH = (plotH - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((v - minV) / span).toFloat().coerceIn(0f, 1f)
        return topPad + (1f - norm) * usableH
    }

    // ── derived marker model (self-hiding) ──
    // Sleep band span clamped to the window; only drawn when it overlaps a visible stretch. Uses the
    // EFFECTIVE onset so a hand-edited bedtime moves the band. (PR #395)
    val sleepStartX = sleep?.let { xFor(it.effectiveStartTs) }
    val sleepEndX = sleep?.let { xFor(it.endTs) }
    // Charge marker sits at wake (sleep end), else the window start; hidden while recovery is null.
    val chargeX = recovery?.let { sleep?.let { s -> xForStrict(s.endTs) } }
    // Effort marker pinned to the latest sample (right edge) when a strain exists.
    val effortX = strain?.let { if (n > 1) plotW else null }

    // One combined TalkBack description for the overlay layers, so the markers (which are otherwise
    // small decorative pills) are announced. Only mentions the layers actually present.
    val markerDescription = run {
        buildList {
            add(uiString(R.string.today_hr_a11y_24_hour))
            if (sleep != null) add(uiString(R.string.today_hr_a11y_sleep_band, hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())))
            if (recovery != null) add(uiString(R.string.today_hr_a11y_charge_at_wake, recovery.roundToInt()))
            if (strain != null) add(uiString(R.string.today_hr_a11y_effort_now, UnitFormatter.effortDisplay(strain, effortScale)))
            if (workouts.isNotEmpty()) add(uiPlural(R.plurals.today_hr_a11y_workouts_marked, workouts.size, workouts.size))
        }.joinToString(uiString(R.string.today_a11y_separator))
    }

    Box(
        modifier = modifier
            .clipToBounds()
            .onSizeChanged { plotW = it.width.toFloat(); plotH = it.height.toFloat() }
            .semantics { contentDescription = markerDescription },
    ) {
        // #765 (z-order / background layering): the sleep band must sit BEHIND the HR curve, matching the
        // iOS OverviewHRChart whose RectangleMark is "drawn first so the HR line/area sit on top". Android
        // previously drew the band in the SAME Canvas as the dashed rules, AFTER the LineChart, so the
        // translucent indigo region washed OVER the HR line + its value markers (the reported "text behind
        // the chart" / muddied curve). Splitting the band into its OWN Canvas placed BEFORE the LineChart
        // puts it under the curve, exactly like iOS; the wake divider, Charge/Effort rules and glow end-cap
        // stay in the Canvas AFTER the line (iOS draws those marks after the LineMark too, so they read on
        // top). Only the fill moved; same geometry, same colours.
        // Dotted round-time gridlines, FIRST so everything (band, curve, markers) reads over them.
        if (plotW > 0f && plotH > 0f && timeTicks.isNotEmpty()) {
            val gridDash = remember { PathEffect.dashPathEffect(floatArrayOf(4f, 6f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                timeTicks.forEach { (ts, _) ->
                    val frac = timestampFraction(bucketTimestamps, ts) ?: return@forEach
                    val x = frac * size.width
                    drawLine(
                        color = Palette.hairline,
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1f,
                        pathEffect = gridDash,
                    )
                }
            }
        }
        if (plotW > 0f && plotH > 0f &&
            sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawRect(
                    color = Palette.sleepDeep.copy(alpha = 0.30f),
                    topLeft = Offset(sleepStartX, 0f),
                    size = Size(sleepEndX - sleepStartX, size.height),
                )
            }
        }

        // 1) The HR line (unchanged shared component, tap-to-inspect intact). Sits OVER the sleep band
        // (above) and UNDER the dashed rules + glow end-cap + marker pills (below), mirroring iOS.
        LineChart(
            values = bpm,
            modifier = Modifier.fillMaxSize(),
            color = Palette.metricRose,
            fill = true,
            selectionEnabled = true,
            // Scrub read-out: the timestamps prefix the sample's local clock time and the #463
            // formatter carries the unit — "14:32 · 87 bpm" instead of a bare "87".
            formatValue = { "${it.roundToInt()} bpm" },
            timestamps = bucketTimestamps,
        )

        // 2) Wake divider + dashed rules + glow end-cap, drawn in one Canvas ON TOP of the line.
        if (plotW > 0f && plotH > 0f) {
            val dash = remember { PathEffect.dashPathEffect(floatArrayOf(8f, 8f), 0f) }
            val wakeDash = remember { PathEffect.dashPathEffect(floatArrayOf(3f, 3f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                // Wake divider: the sleep-to-day boundary, so the band reads even before Charge calibrates.
                // On top of the line (matching iOS's wake RuleMark after the LineMark).
                if (sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX &&
                    sleepEndX > 0f && sleepEndX < size.width) {
                    drawLine(
                        color = Palette.sleepLight.copy(alpha = 0.5f),
                        start = Offset(sleepEndX, 0f),
                        end = Offset(sleepEndX, size.height),
                        strokeWidth = 1f,
                        pathEffect = wakeDash,
                    )
                }
                // Charge rule at wake.
                if (chargeX != null) {
                    drawLine(
                        color = Palette.recoveryColor(recovery).copy(alpha = 0.85f),
                        start = Offset(chargeX.coerceIn(0f, size.width), 0f),
                        end = Offset(chargeX.coerceIn(0f, size.width), size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }
                // Effort rule at now.
                if (effortX != null) {
                    val x = (size.width - 1f).coerceIn(0f, size.width)
                    drawLine(
                        color = Palette.effortTint(strain / StrainScorer.maxStrain).copy(alpha = 0.85f),
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }

                // Glowing endpoint at the latest HR sample (right edge), a Bevel chart end-cap:
                // a soft rose halo + white core sitting on the line's final point.
                if (n >= 2) {
                    val lastX = size.width
                    val lastY = yForBpm(bpm.last())
                    val end = Offset(lastX.coerceIn(0f, size.width), lastY)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.30f), radius = 9f, center = end)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.65f), radius = 5.5f, center = end)
                    drawCircle(color = Palette.tipCore, radius = 2.4f, center = end)
                }
            }

            // 3) Marker labels + sport glyphs, positioned composables (crisp text/icons vs Canvas).
            val topPadDp = 10.dp
            // Sleep duration pill at the band's leading edge.
            if (sleepStartX != null && (sleepEndX ?: 0f) > (sleepStartX)) {
                val durLabel = hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())
                ChartMarkerPill(
                    text = durLabel,
                    color = Palette.sleepLight,
                    leadingIcon = Icons.Filled.Bedtime,
                    modifier = Modifier.markerOffset(sleepStartX, density, topPadDp),
                )
            }
            if (chargeX != null) {
                ChartMarkerPill(
                    text = uiString(R.string.l10n_today_screen_recovery_roundtoint_charge_92fbaa5e, recovery.roundToInt()),
                    color = Palette.recoveryColor(recovery),
                    modifier = Modifier.markerOffset(chargeX, density, topPadDp),
                )
            }
            if (effortX != null) {
                ChartMarkerPill(
                    text = uiString(R.string.l10n_today_screen_unitformatter_effortdisplay_strain_effortscale_effort_53dbd951, UnitFormatter.effortDisplay(strain, effortScale)),
                    color = Palette.effortTint(strain / StrainScorer.maxStrain),
                    modifier = Modifier.markerOffset(plotW, density, topPadDp, alignEnd = true),
                )
            }
            // Sport glyph at each workout's in-window HR peak.
            workouts.forEach { w ->
                val peak = hrPeakIn(buckets, w.startTs, w.endTs)
                if (peak != null) {
                    val px = xForStrict(peak.bucket)
                    if (px != null) {
                        val py = yForBpm(peak.avgBpm)
                        WorkoutGlyph(
                            icon = sportIcon(w.sport),
                            modifier = Modifier.glyphOffset(px, py, plotW, plotH, density),
                        )
                    }
                }
            }
        }
    }
}

/** "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06"). Mirrors TodayView.hoursMinutes. */
private fun hrHoursMinutes(seconds: Int): String {
    val h = (if (seconds < 0) 0 else seconds) / 3600
    val m = ((if (seconds < 0) 0 else seconds) % 3600) / 60
    return "$h:${m.toString().padStart(2, '0')}"
}

/** The peak HR bucket whose timestamp falls inside [start, end]; null when none overlap. */
private fun hrPeakIn(buckets: List<HrBucket>, start: Long, end: Long): HrBucket? =
    buckets.filter { it.bucket in start..end }.maxByOrNull { it.avgBpm }

/** Offset a marker pill near plot-x [x] (px). End-aligned markers (Effort) tuck under the right
 *  edge; the rest centre roughly on their anchor. Coerced to ≥ 0 so a pill never starts off-screen. */
private fun Modifier.markerOffset(
    x: Float,
    density: androidx.compose.ui.unit.Density,
    topPad: androidx.compose.ui.unit.Dp,
    alignEnd: Boolean = false,
): Modifier = this.offset(
    x = with(density) {
        // Approx pill half-width for edge clamping (footnote ≈ 7px/char + chrome).
        val xDp = x.toDp()
        if (alignEnd) (xDp - 70.dp).coerceAtLeast(0.dp) else (xDp - 36.dp).coerceAtLeast(0.dp)
    },
    y = topPad,
)

/** Position a 22dp sport glyph centred on a plot point (px), clamped inside the plot. */
private fun Modifier.glyphOffset(
    x: Float,
    y: Float,
    plotW: Float,
    plotH: Float,
    density: androidx.compose.ui.unit.Density,
): Modifier = this.offset(
    x = with(density) { (x.toDp() - 11.dp).coerceIn(0.dp, (plotW.toDp() - 22.dp).coerceAtLeast(0.dp)) },
    y = with(density) { (y.toDp() - 26.dp).coerceIn(0.dp, (plotH.toDp() - 22.dp).coerceAtLeast(0.dp)) },
)

/** Small caps read-out pill for the Charge / Effort / sleep-duration markers. */
@Composable
private fun ChartMarkerPill(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.surfaceOverlay.copy(alpha = 0.92f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = color, modifier = Modifier.size(10.dp))
        }
        Text(text, style = NoopType.footnote, color = color, maxLines = 1)
    }
}

/** Sport glyph in a tinted badge, anchored above a workout's HR peak. */
@Composable
private fun WorkoutGlyph(icon: ImageVector, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(22.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.strain033),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(13.dp),
        )
    }
}

// MARK: - Today footer sections

@Composable
private fun TodayWorkoutsSection(workouts: List<WorkoutRow>) {
    // Single column, newest first: the 2x2 grid truncated durations on narrow phones and read as
    // unrelated stat tiles rather than a chronological feed. Full-width tiles have room for the
    // kcal chip, so the #332 compactDelta workaround is no longer needed here.
    val feed = lastWorkoutsFeed(workouts)
    if (feed.isEmpty()) return

    // "Latest Workouts", not "Last": "Last" read as "final". Mirrored on iOS (TodayView). Lives in
    // strings.xml (values + values-de) so the header is localizable like the nav labels.
    SectionHeader(stringResource(R.string.today_latest_workouts), overline = uiString(R.string.today_workouts_activity), trailing = uiString(R.string.today_workouts_14_days))
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        feed.forEach { workout ->
            StatTile(
                modifier = Modifier.fillMaxWidth(),
                label = WorkoutEditing.displaySport(workout.sport),
                value = localizedMetricValue(workoutDuration(workout)),
                caption = workoutCaption(workout),
                accent = workout.strain?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.textPrimary,
                delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                deltaColor = Palette.metricAmber,
            )
        }
    }
}

@Composable
private fun TodaySourcesSection(
    footer: TodayFooterState,
    strapBatteryPct: Int? = null,
    strapBatteryEstimate: String? = null,
    // S5: collapse to a single "Synced from: ..." summary line by default; tapping expands the full
    // per-source rows + strap battery inline. Nothing is removed, only folded behind a tap.
    expanded: Boolean = true,
    onToggle: () -> Unit = {},
) {
    SectionHeader(uiString(R.string.today_data_sources), overline = uiString(R.string.today_provenance))
    Spacer(Modifier.height(Metrics.gap))
    val whoopPresent = (footer.whoopDays ?: 0) > 0 || strapBatteryPct != null
    val applePresent = (footer.appleDays ?: 0) > 0 || (footer.appleWorkouts ?: 0) > 0
    val hcPresent = (footer.hcDays ?: 0) > 0 || (footer.hcWorkouts ?: 0) > 0
    if (!expanded) {
        // Collapsed: one tappable "Synced from: ..." line. Each source is named for what it is —
        // Health Connect must NOT fold under "Apple Watch" (issue #176: Health-Connect-only users
        // saw "Synced from: Apple Watch"); the expanded card lists every source by name too.
        val collapsedInteraction = remember { MutableInteractionSource() }
        NoopCard(
            modifier = Modifier
                .fillMaxWidth()
                .liquidPress(collapsedInteraction)
                .clickable(
                    interactionSource = collapsedInteraction,
                    indication = null,
                    onClickLabel = uiString(R.string.today_action_show_sources),
                    onClick = onToggle,
                ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    syncedFromSummary(hasWhoop = whoopPresent, hasApple = applePresent, hasHealthConnect = hcPresent, hasXiaomi = false)
                        .let { names ->
                            if (names.isEmpty()) uiString(R.string.today_no_sources_yet)
                            else uiString(R.string.today_synced_from, names.localizedSourceList())
                        },
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        return
    }
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // A header row to collapse it back, an obvious "less" cue on the expanded card.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = uiString(R.string.today_action_hide_sources), onClick = onToggle),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(uiString(R.string.l10n_today_screen_synced_from_2aa7258b), style = NoopType.overline, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                Icon(
                    Icons.Filled.KeyboardArrowUp,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
            Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            SourceRow(
                badge = uiString(R.string.today_source_whoop),
                tint = Palette.accent,
                // A live battery reading means the strap IS connected, even before the first banked
                // night, don't contradict it with "Not connected" (#159).
                present = whoopPresent,
                detail = countDetail(footer.whoopDays, footer.whoopWorkouts),
                batteryPct = strapBatteryPct,
                batteryEstimate = strapBatteryEstimate,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = uiString(R.string.today_source_apple_health),
                tint = Palette.metricCyan,
                present = applePresent,
                detail = countDetail(footer.appleDays, footer.appleWorkouts),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = uiString(R.string.today_source_health_connect),
                tint = Palette.metricPurple,
                present = hcPresent,
                detail = countDetail(footer.hcDays, footer.hcWorkouts),
            )
        }
    }
}

@Composable
private fun SourceRow(
    badge: String,
    tint: Color,
    present: Boolean,
    detail: String,
    batteryPct: Int? = null,
    batteryEstimate: String? = null,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
        // Compact strap-battery readout beside the source badge, same pill + tone bands as the
        // Settings Strap section; absent entirely when there's no live reading (#159).
        batteryPct?.let { pct ->
            Spacer(Modifier.width(8.dp))
            StatePill(title = uiString(R.string.l10n_today_screen_pct_ee63e247, pct), tone = batteryPillTone(pct), showsDot = false)
            // The "~X left" runtime estimate sits beside the %, dimmer, only when we have a trusted one (#713).
            batteryEstimate?.let { est ->
                Spacer(Modifier.width(6.dp))
                Text(
                    text = est,
                    style = NoopType.captionNumber,
                    color = Palette.textTertiary,
                    maxLines = 1,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Text(
            text = if (present) detail else uiString(R.string.today_not_connected),
            style = NoopType.captionNumber,
            color = if (present) Palette.textSecondary else Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Readiness card (ported from TodayView.swift readinessSection)
//
// On-device training-readiness synthesis. Calls the analytics ReadinessEngine over the
// view model's day history and renders the macOS card: a colored level dot + headline,
// an optional acute:chronic "load X.XX" read-out, the plain-English summary, then one
// row per driving signal (a small flag-colored dot + label + detail). The whole card is
// suppressed until there is enough history (level == INSUFFICIENT), matching macOS.

@Composable
private fun readinessEvidenceText(evidence: ReadinessEngine.Evidence): String {
    fun number(value: Double, decimals: Int): String = if (decimals == 0) {
        Math.round(value).toString()
    } else {
        String.format(Locale.getDefault(), "%.${decimals}f", value)
    }
    return when (evidence) {
        is ReadinessEngine.Evidence.MetricVsBaseline -> {
            val unit = when (evidence.unit) {
                ReadinessEngine.MetricUnit.MS -> uiString(R.string.today_unit_ms)
                ReadinessEngine.MetricUnit.BPM -> uiString(R.string.today_unit_bpm)
                ReadinessEngine.MetricUnit.RPM -> uiString(R.string.today_unit_rpm)
            }
            uiString(
                R.string.today_readiness_evidence_metric,
                number(evidence.value, evidence.decimals), number(evidence.baseline, evidence.decimals), unit,
            )
        }
        is ReadinessEngine.Evidence.Monotony ->
            uiString(R.string.today_readiness_evidence_monotony, number(evidence.value, 1))
        is ReadinessEngine.Evidence.TrainingLoad ->
            uiString(
                R.string.today_readiness_evidence_load,
                number(evidence.acute, 1), number(evidence.chronic, 1),
            )
    }
}

@Composable
private fun readinessCopy(copy: ReadinessEngine.Copy): String = uiString(
    when (copy) {
        ReadinessEngine.Copy.TODAY_READINESS_BALANCED -> R.string.today_readiness_balanced
        ReadinessEngine.Copy.TODAY_READINESS_BALANCED_SUMMARY -> R.string.today_readiness_balanced_summary
        ReadinessEngine.Copy.TODAY_READINESS_HRV_BAD -> R.string.today_readiness_hrv_bad
        ReadinessEngine.Copy.TODAY_READINESS_HRV_GOOD -> R.string.today_readiness_hrv_good
        ReadinessEngine.Copy.TODAY_READINESS_HRV_WATCH -> R.string.today_readiness_hrv_watch
        ReadinessEngine.Copy.TODAY_READINESS_LOAD_BUILDING_FAST -> R.string.today_readiness_load_building_fast
        ReadinessEngine.Copy.TODAY_READINESS_LOAD_RAMPING_DOWN -> R.string.today_readiness_load_ramping_down
        ReadinessEngine.Copy.TODAY_READINESS_LOAD_SPIKING -> R.string.today_readiness_load_spiking
        ReadinessEngine.Copy.TODAY_READINESS_LOAD_SWEET_SPOT -> R.string.today_readiness_load_sweet_spot
        ReadinessEngine.Copy.TODAY_READINESS_MONOTONY_WATCH -> R.string.today_readiness_monotony_watch
        ReadinessEngine.Copy.TODAY_READINESS_MORE_NIGHTS -> R.string.today_readiness_more_nights
        ReadinessEngine.Copy.TODAY_READINESS_NORMAL_RANGE -> R.string.today_readiness_normal_range
        ReadinessEngine.Copy.TODAY_READINESS_PRIMED -> R.string.today_readiness_primed
        ReadinessEngine.Copy.TODAY_READINESS_PRIMED_SUMMARY -> R.string.today_readiness_primed_summary
        ReadinessEngine.Copy.TODAY_READINESS_RESP_BAD -> R.string.today_readiness_resp_bad
        ReadinessEngine.Copy.TODAY_READINESS_RESP_WATCH -> R.string.today_readiness_resp_watch
        ReadinessEngine.Copy.TODAY_READINESS_RHR_BAD -> R.string.today_readiness_rhr_bad
        ReadinessEngine.Copy.TODAY_READINESS_RHR_GOOD -> R.string.today_readiness_rhr_good
        ReadinessEngine.Copy.TODAY_READINESS_RHR_WATCH -> R.string.today_readiness_rhr_watch
        ReadinessEngine.Copy.TODAY_READINESS_RUN_DOWN -> R.string.today_readiness_run_down
        ReadinessEngine.Copy.TODAY_READINESS_RUN_DOWN_SUMMARY -> R.string.today_readiness_run_down_summary
        ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_HRV -> R.string.today_readiness_signal_hrv
        ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_RESPIRATORY -> R.string.today_readiness_signal_respiratory
        ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_RESTING_HR -> R.string.today_readiness_signal_resting_hr
        ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_TRAINING_LOAD -> R.string.today_readiness_signal_training_load
        ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_TRAINING_VARIETY -> R.string.today_readiness_signal_training_variety
        ReadinessEngine.Copy.TODAY_READINESS_STRAINED -> R.string.today_readiness_strained
        ReadinessEngine.Copy.TODAY_READINESS_STRAINED_SUMMARY -> R.string.today_readiness_strained_summary
        ReadinessEngine.Copy.TODAY_READINESS_TITLE -> R.string.today_readiness_title
        ReadinessEngine.Copy.TODAY_READINESS_WEAR_FOR_NIGHTS -> R.string.today_readiness_wear_for_nights
    },
)

@Composable
private fun readinessSignalDetail(signal: ReadinessEngine.Signal): String {
    val load = signal.evidence as? ReadinessEngine.Evidence.TrainingLoad
    return if (load != null && load.chronic > 0.0) {
        uiString(
            when (signal.detailRes) {
                ReadinessEngine.Copy.TODAY_READINESS_LOAD_RAMPING_DOWN -> R.string.today_readiness_load_ramping_down
                ReadinessEngine.Copy.TODAY_READINESS_LOAD_SWEET_SPOT -> R.string.today_readiness_load_sweet_spot
                ReadinessEngine.Copy.TODAY_READINESS_LOAD_BUILDING_FAST -> R.string.today_readiness_load_building_fast
                ReadinessEngine.Copy.TODAY_READINESS_LOAD_SPIKING -> R.string.today_readiness_load_spiking
                else -> error("Training-load evidence requires a training-load detail")
            },
            String.format(Locale.getDefault(), "%.2f", load.acute / load.chronic),
        )
    } else {
        readinessCopy(signal.detailRes)
    }
}

@Composable
private fun ReadinessSection(days: List<DailyMetric>, carriedDay: DailyMetric? = null) {
    // Logical day (rolls at 04:00 local), so readiness keeps reading the evening's row in the small
    // hours instead of an empty new-calendar-day row (#144). Mirrors the Today-row resolution.
    //
    // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Right after the
    // rollover today has no scored row, so `evaluate` would read INSUFFICIENT and the whole card would
    // VANISH while live HR ticks, the same blank the carried Charge/Synthesis avoid. So when carrying,
    // anchor on the last scored day's key instead, and stamp the overline "Last night · <date>". Honest:
    // it's the real prior read; today's own readiness wins the instant tonight is scored.
    val anchorKey = carriedDay?.day ?: logicalDayKeyNow()
    val readiness = remember(days, anchorKey) { ReadinessEngine.evaluate(days, today = anchorKey) }
    if (readiness.level == ReadinessEngine.Level.INSUFFICIENT) return

    val overline = carriedDay?.let { carriedCaption(it.day).localized() }
        ?: uiString(R.string.today_should_you_push)
    SectionHeader(uiString(R.string.today_readiness_title), overline = overline)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Headline row: level dot + headline, then the ACWR load read-out.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(readinessColor(readiness.level)),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    readinessCopy(readiness.headlineRes),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                readiness.acwr?.let { acwr ->
                    Text(
                        uiString(R.string.today_load_ratio, String.format(Locale.getDefault(), "%.2f", acwr)),
                        style = NoopType.captionNumber,
                        color = Palette.textTertiary,
                    )
                }
            }

            // #1405: mark this card as a DIFFERENT axis from the home Synthesis word (which bands the
            // Charge %). Stated at the point the two get compared, so "Primed" here vs "Steady" there
            // doesn't read as one value contradicting itself. Raw string, matching this card's copy.
            Text(
                uiString(R.string.today_training_read_explanation),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )

            // Plain-English summary.
            Text(
                readinessCopy(readiness.summaryRes),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            // Per-signal rows: flag dot + fixed-width label + detail.
            if (readiness.signals.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Palette.hairline),
                )
                readiness.signals.forEach { signal ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(
                            modifier = Modifier
                                .padding(top = 5.dp)
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(flagColor(signal.flag)),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            readinessCopy(signal.labelRes),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.width(104.dp),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(1.dp),
                        ) {
                            Text(
                                readinessSignalDetail(signal),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                            // The numbers behind the read (e.g. "48 vs 55 ms"), as a small mono caption,                             // mirrors the macOS readiness card and the "load X.XX" numeric readout above.
                            signal.evidence?.let { evidence ->
                                Text(
                                    readinessEvidenceText(evidence),
                                    style = NoopType.captionNumber,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Level → color, mirroring TodayView.readinessColor. */
private fun readinessColor(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

/** Flag → color, mirroring TodayView.flagColor. */
private fun flagColor(flag: ReadinessEngine.Flag): Color = when (flag) {
    ReadinessEngine.Flag.GOOD -> Palette.accent
    ReadinessEngine.Flag.NEUTRAL -> Palette.textTertiary
    ReadinessEngine.Flag.WATCH -> Palette.statusWarning
    ReadinessEngine.Flag.BAD -> Palette.metricRose
}

/**
 * #316 / @63, map a step-sample activity class (0=still, 1=walk, 2=run) to the still/walk/run icon + an
 * accessibility label. Mirrors the iOS Steps-tile glyph set (figure.stand / figure.walk / figure.run) and
 * semantics exactly (cross-platform parity). Returns (null, "") for any other code so an unmapped value
 * shows nothing rather than a wrong glyph.
 */
private fun stepActivityIconFor(activityClass: Int): Pair<ImageVector?, Int?> = when (activityClass) {
    0 -> Icons.Filled.Accessibility to R.string.today_steps_activity_still
    1 -> Icons.AutoMirrored.Filled.DirectionsWalk to R.string.today_steps_activity_walking
    2 -> Icons.AutoMirrored.Filled.DirectionsRun to R.string.today_steps_activity_running
    else -> null to null
}

// MARK: - SparkStatTile
//
// A fixed-height metric tile: overline label, big value + caption, and a 14-day
// Sparkline anchored along the bottom edge. Mirrors the macOS StatTile-with-sparkline
// while reusing the locked surfaces/typography (NoopCard, Overline, NoopType). Built
// here rather than mutating the shared StatTile so other screens keep the plain tile.

@Composable
private fun SparkStatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    spark: List<Double> = emptyList(),
    sparkColor: Color = Palette.accent,
    onInfo: (() -> Unit)? = null,
    badge: String? = null,
    // #316 / @63, an optional activity-class code (0=still, 1=walk, 2=run) rendered as a small still/walk/run
    // glyph in the label row, tinted with the tile accent. null = no icon. Used by the Steps tile.
    trailingIcon: Int? = null,
) {
    val displayValue = localizedMetricValue(value)
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Label row carries the overline, an optional low-confidence [badge] (H9, e.g. "Estimated"
            // stages), an optional activity glyph ([trailingIcon], #316), and, for the three headline scores
            // only, a trailing ⓘ that opens the scoring guide at this score. Other tiles render as before.
            if (onInfo != null || badge != null || trailingIcon != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline(label)
                    if (badge != null) {
                        Spacer(Modifier.width(Metrics.space6))
                        // A tertiary-tinted pill, honest "this is estimated, not measured" signal, the same
                        // muted treatment as a provenance badge so it informs without alarming. (H9)
                        SourceBadge(badge, tint = Palette.textTertiary)
                    }
                    Spacer(Modifier.weight(1f))
                    // #316, still/walk/run glyph, before the optional ⓘ. Self-hides for an unknown code.
                    if (trailingIcon != null) {
                        val (vector, descRes) = stepActivityIconFor(trailingIcon)
                        if (vector != null && descRes != null) {
                            Icon(
                                vector,
                                contentDescription = uiString(descRes),
                                tint = accent,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    if (onInfo != null) ScoreInfoButton(section = null, onClick = onInfo, compact = true)
                }
            } else {
                Overline(label)
            }
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    // Shrink-to-fit (down to 0.6×) so a value never ellipsizes to "100%"→"10…" /
                    // "15.5"→"15…" next to the inline sparkline, matching the Swift tile's
                    // minimumScaleFactor (#332). fillMaxWidth() is load-bearing: AutoSizeValue only
                    // shrinks when its Text is given a hard width to overflow against, without it the
                    // single-line Text takes its intrinsic width, `didOverflowWidth` never trips, and
                    // the value silently truncates at full size. The plain StatTile worked because it
                    // passes weight(1f) (a hard width); this column-child needs fillMaxWidth instead.
                    AutoSizeValue(
                        displayValue,
                        style = NoopType.tileValueLarge,
                        color = accent,
                        modifier = Modifier.fillMaxWidth(),
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
                if (spark.size >= 2) {
                    // Sparkline forces fillMaxWidth + a fixed height internally, so we
                    // bound it in a sized Box to keep it a compact inline trend.
                    SparkTailBox(wide = true) {
                        Sparkline(values = spark, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Illness banner (ported from HealthAlertBanner.swift)

@Composable
private fun IllnessBanner(message: String) {
    // Frosted Bevel warning card (amber tint), matches the Swift HealthAlertBanner.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(tint = Palette.statusWarning, cornerRadius = Metrics.cardRadius)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Palette.statusWarning.copy(alpha = StrandAlpha.warningFill)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning)
        }
        Text(message, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

// MARK: - 14-day sparkline windows (built from recentDays)

/** The trailing-window series for each tile, oldest → newest. */
private data class Window(
    val recovery: List<Double>,
    val strain: List<Double>,
    val sleepMin: List<Double>,
    val hrv: List<Double>,
    val rhr: List<Double>,
    val spo2: List<Double>,
    /** #1599: the strap-estimate trend, kept separate from [spo2] so the tile can swap rather than mix. */
    val spo2Candidate: List<Double> = emptyList(),
    val resp: List<Double>,
    // #616: the Steps tile carried no `spark` series, so it drew no trend line while every other tile did.
    // On-device DailyMetric.steps (the strap @57 count) — the same signal the Steps tile VALUE reads
    // (on-device-first), matching iOS kSparks "steps". (Calories is imported-first, so its spark is threaded
    // separately as caloriesSpark, not read off a DailyMetric column here.)
    val steps: List<Double>,
)

/**
 * Build the trailing trend windows from `recentDays` over the chosen span (7 / 14 / 30 calendar days —
 * the editor's detailed-graph window). Each series drops null days from the trailing calendar window
 * only, so stale imports do not draw a current-day trend.
 */
@Composable
private fun rememberTrendWindow(
    days: List<com.noop.data.DailyMetric>,
    anchorDay: LocalDate,
    windowDays: Int,
    // #1599: the SpO2 candidate per day, so the Blood Oxygen tile has a series to draw at all.
    // `AnalyticsEngine` writes `spo2Pct = null` on every computed day — a calibrated reading only ever
    // arrives from an IMPORT — so on a strap-only install `series { it.spo2Pct }` is empty by
    // construction and the tile rendered a value above blank space where every neighbour had a line.
    // Already empty when the display toggle is off (the flow returns emptyMap), so reading it here needs
    // no second gate.
    spo2Candidate: Map<String, Double> = emptyMap(),
): Window =
    androidx.compose.runtime.remember(days, anchorDay, windowDays, spo2Candidate) {
        // Trailing CALENDAR days ending today, NOT the last N stored rows, which on an old import
        // were months-old data shown as a fresh trend (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = anchorDay.minusDays((windowDays - 1).toLong()).toString()
        val end = anchorDay.toString()
        val recent = days.filter { it.day >= cutoff && it.day <= end }
        fun series(pick: (DailyMetric) -> Double?): List<Double> = recent.mapNotNull(pick)
        Window(
            recovery = series { it.recovery },
            strain = series { it.strain },
            sleepMin = series { it.totalSleepMin },
            hrv = series { it.avgHrv },
            rhr = series { it.restingHr?.toDouble() },
            spo2 = series { it.spo2Pct },
            // #1599: the strap estimate as its OWN series, not merged into the one above. The tile swaps
            // wholesale between them so a single caption can describe every point on the line.
            spo2Candidate = recent.mapNotNull { spo2Candidate[it.day] },
            resp = series { it.respRateBpm },
            steps = series { it.steps?.toDouble() },   // #616
        )
    }

// MARK: - Derived text (ported from TodayView.swift)

@Composable
private fun greetingWord(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when {
        h < 12 -> uiString(R.string.today_greeting_morning)
        h < 17 -> uiString(R.string.today_greeting_afternoon)
        else -> uiString(R.string.today_greeting_evening)
    }
}

@Composable
private fun synthesisWord(score: Double?): String {
    if (score == null) return uiString(R.string.today_no_data)
    // #1405: these are CHARGE/recovery-level words, a different axis from the ReadinessEngine training
    // verdict (Run down / Strained / Balanced / Primed). They must NOT share a word, or the Synthesis
    // card ("Steady") and the Charge-breakdown Readiness card ("Primed") read as the same thing
    // contradicting itself. So the [70,88) band is "Strong" (which also matches this card's own "Charge is
    // strong" detail copy), leaving "Primed" exclusively to the readiness engine. Keep parity with Swift.
    return when {
        score < 25 -> uiString(R.string.today_synthesis_depleted)
        score < 50 -> uiString(R.string.today_synthesis_low)
        score < 70 -> uiString(R.string.today_synthesis_steady)
        score < 88 -> uiString(R.string.today_synthesis_strong)
        else -> uiString(R.string.today_synthesis_peak)
    }
}

@Composable
private fun synthesisDetail(d: DailyMetric?): String {
    val rec = d?.recovery
        ?: return uiString(R.string.today_synthesis_no_metrics)
    val res = when {
        rec < 50 && d.totalSleepMin == null -> R.string.today_synthesis_charge_low
        rec < 50 && d.totalSleepMin!! / 60.0 >= 7 -> R.string.today_synthesis_charge_low_sleep_consistent
        rec < 50 -> R.string.today_synthesis_charge_low_sleep_short
        rec < 70 && d.totalSleepMin == null -> R.string.today_synthesis_charge_steady
        rec < 70 && d.totalSleepMin!! / 60.0 >= 7 -> R.string.today_synthesis_charge_steady_sleep_consistent
        rec < 70 -> R.string.today_synthesis_charge_steady_sleep_short
        d.totalSleepMin == null -> R.string.today_synthesis_charge_strong
        d.totalSleepMin!! / 60.0 >= 7 -> R.string.today_synthesis_charge_strong_sleep_consistent
        else -> R.string.today_synthesis_charge_strong_sleep_short
    }
    return uiString(res)
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/**
 * The Rest tile's caption, hours-in-bed for the day, the figure that used to be the tile's VALUE
 * before #248 moved the Rest score there. Falls back to the efficiency read-out when no duration is
 * banked, and to null so the tile shows no caption line when neither exists. Mirrors macOS restCaption.
 */
private fun restCaption(d: DailyMetric?): String? = when {
    d?.totalSleepMin != null -> sleepValue(d)
    d?.efficiency != null -> String.format(Locale.getDefault(), "%.0f%% eff", d.efficiency)
    else -> null
}

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. */
private fun intString(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.getDefault(), "%,d", n) else "$n"
}

private const val NO_DATA = "noop:no-data"

/** The dashboard-card placeholder for a baseline-relative metric (Stress) that is still seeding its window,  *  an honest "building your baseline" state rather than a bare dash (#706/#684). Rendered dimmed like NO_DATA. */
private const val STRESS_CALIBRATING = "noop:calibrating"

@Composable
private fun localizedMetricValue(value: String): String = when (value) {
    NO_DATA -> uiString(R.string.today_no_data)
    STRESS_CALIBRATING -> uiString(R.string.today_calibrating)
    else -> value
}

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()).withZone(ZoneId.systemDefault())
private val workoutTimeFmt: DateTimeFormatter =
    // Respect the device's 12-/24-hour locale (#337): "7:10 AM" where 12-hour is preferred, "19:10"
    // where 24-hour is, instead of forcing 24-hour on everyone.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

@Composable
private fun countDetail(days: Int?, workouts: Int?): String {
    if (days == null || workouts == null) return uiString(R.string.today_source_counting)
    return uiString(
        R.string.today_source_count_joiner,
        uiPlural(R.plurals.today_source_days, days, grouped(days)),
        uiPlural(R.plurals.today_source_workouts, workouts, grouped(workouts)),
    )
}

/** Same bands as the Settings Strap battery pill, so the % reads the same colour everywhere (#159). */
private fun batteryPillTone(pct: Int): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
}

private fun workoutDuration(row: WorkoutRow): String {
    val seconds = row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0L).toDouble()
    if (seconds <= 0.0) return NO_DATA
    val totalMinutes = (seconds / 60.0).roundToInt()
    return if (totalMinutes >= 60) {
        "${totalMinutes / 60}h ${totalMinutes % 60}m"
    } else {
        "${totalMinutes}m"
    }
}

/** "d MMM · HH:mm–HH:mm" (#157); start-only when the end isn't after the start (zero/unknown span). */
private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    val start = workoutTimeFmt.format(Instant.ofEpochSecond(row.startTs))
    return if (row.endTs > row.startTs) {
        "$date · $start - ${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun grouped(value: Int): String =
    String.format(Locale.getDefault(), "%,d", value)

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local dialog (no new nav destination, another lane owns the nav graph) for choosing which
// Key-Metric tiles show on the Control Center and in what order. Display-only: it edits the persisted
// `today.keyMetrics` layout, never any stored metric. Uses the shared Shown / Hidden editor rows.

/** The Key-Metrics header's trailing label for the chosen detailed-graph window. */
@Composable
private fun trendWindowLabel(days: Int): String = when (days) {
    7 -> uiString(R.string.today_trend_7_days)
    30 -> uiString(R.string.today_trend_30_days)
    else -> uiString(R.string.today_trend_14_days)
}

@Composable
private fun KeyMetricsEditorDialog(
    initial: List<KeyMetric>,
    initialDetailed: Boolean = false,
    initialWindowDays: Int = 14,
    onDismiss: () -> Unit,
    onSave: (List<KeyMetric>, Boolean, Int) -> Unit,
) {
    val context = LocalContext.current
    val titles = KeyMetric.entries.associateWith { uiString(it.titleRes) }
    // Detailed tiles: taller/squarer with a trend graph under the fill bar (display-only), over the
    // chosen trailing window (1 week / 2 weeks / 1 month).
    var detailed by remember { mutableStateOf(initialDetailed) }
    var windowDays by remember { mutableStateOf(initialWindowDays) }
    val shown = remember { mutableStateListOf<KeyMetric>().apply { addAll(initial) } }
    val hidden = remember {
        mutableStateListOf<KeyMetric>().apply {
            addAll(KeyMetric.defaultOrder.filter { it !in initial })
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_today_screen_edit_key_metrics_f95e61a4), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_today_screen_choose_which_tiles_show_on_your_a4e3acfb),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                // Detailed tiles: the tile-style option (compact ktile vs squarer tile + 14-day graph).
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_today_screen_detailed_tiles_0801721b), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_today_screen_squarer_tiles_with_a_trend_graph_3c297dec),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    }
                    Switch(
                        checked = detailed,
                        onCheckedChange = { detailed = it },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_today_screen_detailed_tiles_0801721b) },
                    )
                }
                // The detailed graphs' trailing window — 1 week / 2 weeks / 1 month (the NOOP signature
                // segmented pill, same control the trend screens use). Only shown while Detailed is on.
                if (detailed) {
                    SegmentedPillControl(
                        items = listOf(7, 14, 30),
                        selection = windowDays,
                        label = { when (it) {
                            7 -> context.getString(R.string.today_range_1_week)
                            14 -> context.getString(R.string.today_range_2_weeks)
                            else -> context.getString(R.string.today_range_1_month)
                        } },
                        onSelect = { windowDays = it },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                HorizontalDivider(color = Palette.hairline, thickness = 1.dp)

                EditableVisibilityRows(
                    shown = shown,
                    hidden = hidden,
                    itemTitle = { titles.getValue(it) },
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            shown.clear()
                            shown.addAll(KeyMetric.defaultOrder)
                            hidden.clear()
                            detailed = false
                            windowDays = 14
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(shown.toList(), detailed, windowDays) },
                        enabled = shown.isNotEmpty(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}
