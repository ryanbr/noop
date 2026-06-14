package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Battery5Bar
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.ReadinessEngine
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.HrBucket
import com.noop.data.SleepSession
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Control Center — the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics — each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the my-whoop source). Missing current-day values render as explicit
 * "No Data" states instead of raw dashes, so old imports do not look like today.
 */
@Composable
fun TodayScreen(viewModel: AppViewModel, onSupport: () -> Unit = {}) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val live by viewModel.live.collectAsStateWithLifecycle()
    var footer by remember { mutableStateOf(TodayFooterState()) }
    var selectedDayOffset by remember { mutableIntStateOf(0) }
    // Anchor offset-0 to the LOGICAL day (rolls at 04:00 local), so between midnight and 4am "Today"
    // still resolves to the prior calendar day's banked row instead of an empty new-calendar-day row
    // that blanks the dashboard (#144). Past offsets count back from this anchor. Presentation-only.
    val todayDate = logicalDayNow()
    val selectedDay = remember(selectedDayOffset, todayDate) { todayDate.minusDays(selectedDayOffset.toLong()) }
    val selectedDayKey = remember(selectedDay) { selectedDay.toString() }
    val historicalMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val displayMetric = remember(today, historicalMetric, selectedDayOffset) {
        if (selectedDayOffset == 0) today ?: historicalMetric else historicalMetric
    }
    // Keep the explicit calendar date visible alongside Today/Yesterday so the logical-day remap stays
    // honest — between midnight and 04:00 "Today" still points at the prior calendar date, and showing
    // that date makes it obvious which day's row is on screen (#144).
    val dayLabel = remember(selectedDayOffset, selectedDay) {
        val date = selectedDay.format(DateTimeFormatter.ofPattern("EEE, d MMM", Locale.US))
        when (selectedDayOffset) {
            0 -> "Today · $date"
            1 -> "Yesterday · $date"
            else -> date
        }
    }
    val synthesisTitle = remember(selectedDayOffset) {
        when (selectedDayOffset) {
            0 -> "Today's Synthesis"
            1 -> "Yesterday's Synthesis"
            else -> "Synthesis"
        }
    }

    // Display-only unit system + the SI profile weight, read once like every other Settings-backed
    // preference (SharedPreferences isn't reactive — a Settings write triggers recomposition).
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    val effortScale = UnitPrefs.effortScale(context)
    val profileWeightKg = remember { ProfileStore.from(context).weightKg }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showMetricsEditor by remember { mutableStateOf(false) }
    var enabledKeyMetrics by remember { mutableStateOf(KeyMetricPrefs.enabled(context)) }

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
    var scoringCardSeen by remember { mutableStateOf(ScoringGuidePrefs.cardSeen(context)) }
    val dismissScoringCard: () -> Unit = {
        ScoringGuidePrefs.setCardSeen(context)
        scoringCardSeen = true
    }

    // The newest Apple Health / Health Connect body weight, loaded off the main thread. Null until the
    // load runs or when neither source carries a weight — the Weight tile then falls back to the profile.
    var weightKg by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        weightKg = latestWeightKg(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
        )
    }

    // Steps for the selected day from imported Apple Health / Health Connect data — the Today Steps
    // tile's fallback when the strap itself didn't bank an on-device count. A WHOOP 4.0 DOES count
    // steps (in the official WHOOP app), but NOOP can't yet read them off the strap over Bluetooth, so
    // on a 4.0 the tile shows your imported steps instead of "No Data". Reloads as the day selector
    // moves. On-device WHOOP 5/MG steps still take precedence. (#150)
    var importedStepsForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        // Today's steps keep moving after the manual one-shot HC import, so the stored row goes
        // stale within minutes — top it up with ONE live StepsRecord read before the stored-row
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

    // The Rest SCORE (0–100) for the selected day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series. The Key-Metrics "Rest" tile shows THIS, with hours-in-bed kept
    // as the caption; the tile previously showed hours where the score belonged (#248). resolvedSeries
    // merges imported + computed sleep_performance (imported-wins), so an importer sees the export's
    // figure and a Bluetooth-only user sees the on-device composite. Null until loaded / no night yet.
    var restScoreForDay by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99")
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        restScoreForDay = byDay[selectedDayKey] ?: byDay.entries.maxByOrNull { it.key }?.value
    }

    // Recovery cold-start: recovery is null until the HRV baseline crosses the seed gate
    // (Baselines.minNightsSeed valid nights). Show honest "calibrating — N of 4 nights" progress
    // instead of a bare "No Data" so a new BLE-only user knows scores are coming, not broken. (PR #85)
    val recoveryCalibration: Int? = if (selectedDayOffset == 0) {
        recoveryCalibrationNights(days, displayMetric?.recovery != null)
    } else {
        null
    }

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = remember14(days, selectedDay)

    LaunchedEffect(days) {
        val now = System.currentTimeMillis() / 1000
        val recentCutoff = LocalDate.now()
            .minusDays(13)
            .atStartOfDay(ZoneId.systemDefault())
            .toEpochSecond()
        val whoopWorkouts = viewModel.repo.workouts("my-whoop", 0L, now)
        // Apple Health and Health Connect are separate sources (since #34) — keep them separate in the
        // provenance footer too, so Health Connect data isn't mislabelled under the "Apple Health" pill
        // (issue #53). The recent-workouts list below still unions all sources for a combined feed.
        val appleWorkouts = viewModel.repo.workouts("apple-health", 0L, now)
        val hcWorkouts = viewModel.repo.workouts("health-connect", 0L, now)
        val appleDaysCount = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        val hcDaysCount = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        footer = TodayFooterState(
            // fillWorkoutHrFromStrap: imported sessions carry no HR — derive it from strap samples (#77).
            recentWorkouts = viewModel.repo.fillWorkoutHrFromStrap(
                (viewModel.repo.workouts("my-whoop", recentCutoff, now) +
                    viewModel.repo.workouts("apple-health", recentCutoff, now) +
                    viewModel.repo.workouts("health-connect", recentCutoff, now))
                    .sortedByDescending { it.startTs }
            ),
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
    }

    // Consecutive run of nights with a banked sleep total, counting back from the logical day —
    // a small "kept the strap on" streak shown beside the live battery in the header. Honest: it
    // counts only days that actually recorded sleep, and tolerates today not being scored yet by
    // starting from yesterday. Recomputes when the history window changes.
    val nightStreakLen = remember(days, todayDate) { nightStreak(days, todayDate) }

    ScreenScaffold(title = "Control Center", subtitle = "Your day, read in full") {
        // Live battery (when connected) + the recorded-nights streak, right-aligned above the day
        // selector. Both icons carry a spoken contentDescription so the row reads cleanly aloud.
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (live.connected && live.batteryPct != null) {
                val batteryPct = live.batteryPct!!.roundToInt()
                Icon(
                    Icons.Filled.Battery5Bar,
                    contentDescription = "Strap battery $batteryPct percent",
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    "$batteryPct%",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.padding(start = Metrics.space2, end = Metrics.space12),
                )
            }
            if (nightStreakLen > 0) {
                val streakColor = if (nightStreakLen >= 2) Palette.statusCritical else Palette.textTertiary
                Icon(
                    Icons.Filled.LocalFireDepartment,
                    contentDescription = "$nightStreakLen night recording streak",
                    tint = streakColor,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    "$nightStreakLen",
                    style = NoopType.footnote,
                    color = streakColor,
                    modifier = Modifier.padding(start = Metrics.space2),
                )
            }
        }

        // One-time "New here?" card pointing at the scoring guide — dismissible, shown until the
        // user opens the guide OR closes it, after which ScoringGuidePrefs keeps it gone for good.
        if (!scoringCardSeen) {
            ScoringGuideIntroCard(
                onOpen = {
                    dismissScoringCard()
                    openGuide(null)
                },
                onDismiss = dismissScoringCard,
            )
        }

        DaySelectorBar(selectedOffset = selectedDayOffset, onSelect = { selectedDayOffset = it })

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out.
        if (displayMetric?.recovery == null) {
            // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
            if (live.backfilling) SyncingHistoryNote(chunks = live.syncChunksThisSession)
            DataPendingNote(
                title = "Live now. Your scores are building.",
                body = "Your live heart rate is working from the strap, and recovery, strain " +
                    "and sleep build from it over your next few nights of wear, sharpening as it " +
                    "learns your baseline. Want your full history instantly? Import your WHOOP " +
                    "export in Data Sources and it backfills in about a minute.",
            )
        }

        if (alert != null) IllnessBanner(alert!!)

        // HERO — three Charge / Effort / Rest ring scores over a scenic backdrop, then the
        // green-tinted Synthesis coaching card. Bevel layout. The support affordance stays in
        // the section header.
        Row(verticalAlignment = Alignment.Top) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader(synthesisTitle, overline = "At a glance", trailing = greetingWord())
            }
            IconButton(
                onClick = onSupport,
                modifier = Modifier.size(Metrics.iconButton),
            ) {
                Icon(
                    Icons.Filled.Favorite,
                    contentDescription = "Support NOOP",
                    tint = Palette.metricRose,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
            }
        }

        // The three daily scores as layered ring gauges over a scenic Charge-tinted backdrop.
        ScoreHeroRow(
            day = displayMetric,
            restScore = restScoreForDay,
            recoveryCalibration = recoveryCalibration,
            onScoreInfo = openGuide,
        )

        // The plain-English read-out — a green-tinted Synthesis coaching card under the rings.
        InsightCard(
            modifier = Modifier.fillMaxWidth(),
            category = "Synthesis",
            status = if (recoveryCalibration != null) "Calibrating" else synthesisWord(displayMetric?.recovery),
            detail = if (recoveryCalibration != null) {
                "Learning your baseline — $recoveryCalibration of ${Baselines.minNightsSeed} nights."
            } else {
                synthesisDetail(displayMetric)
            },
            statusColor = displayMetric?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
            tint = Palette.chargeColor,
        )

        // READINESS — on-device training-readiness synthesis (HRV / resting-HR / load).
        // Mirrors the macOS readinessSection: rendered only once there's enough history.
        if (selectedDayOffset == 0) ReadinessSection(days)

        // METRICS — uniform tile grid (two columns), each tile with a 14-day sparkline.
        Spacer(Modifier.height(Metrics.selectorTopUp))
        // Section header + an Edit affordance to open the local layout editor (#251). No new nav
        // destination — a dialog over Today. The Box lets the SectionHeader keep its trailing label while
        // the Edit control sits to its right.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("Key Metrics", overline = dayLabel, trailing = "14-day trend")
            }
            TextButton(
                onClick = { showMetricsEditor = true },
                colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
            ) {
                Icon(
                    Icons.Filled.Tune,
                    contentDescription = "Edit Key Metrics",
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Spacer(Modifier.width(4.dp))
                Text("Edit", style = NoopType.footnote)
            }
        }
        MetricGrid(
            d = displayMetric,
            w = window,
            recoveryCalibration = recoveryCalibration,
            unitSystem = unitSystem,
            effortScale = effortScale,
            latestWeightKg = weightKg,
            profileWeightKg = profileWeightKg,
            importedStepsForDay = importedStepsForDay,
            restScore = restScoreForDay,
            enabledMetrics = enabledKeyMetrics,
            onScoreInfo = openGuide,
        )
        HeartRateTrendCard(viewModel, days, selectedDay, todayDate, displayMetric, effortScale)
        TodayWorkoutsSection(footer.recentWorkouts)
        // Honest, dismissible 12-hourly donation ask — a card in the flow, never a dialog.
        DonationNudgeCard()
        // Strap battery only while the link is up AND a real reading exists — a stale % from a
        // dropped connection must not present as live (#159).
        TodaySourcesSection(footer, strapBatteryPct = if (live.connected) live.batteryPct?.roundToInt() else null)
    }

    // Scoring guide sheet — full-screen Dialog, mirroring Settings' What's-new presentation. Opened
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

    // Key-Metrics layout editor (#251) — a Today-local dialog (no new nav destination). Saves the layout
    // and re-reads it into local state so the grid updates immediately and survives relaunch.
    if (showMetricsEditor) {
        KeyMetricsEditorDialog(
            initial = enabledKeyMetrics,
            onDismiss = { showMetricsEditor = false },
            onSave = { metrics ->
                KeyMetricPrefs.setEnabled(context, metrics)
                enabledKeyMetrics = metrics
                showMetricsEditor = false
            },
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
    val label = section?.let { "How ${it.label} is calculated" } ?: "How this score is calculated"
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
 * flow — never a dialog — with a primary "See how it works" action and a ✕ dismiss; both set the
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
                Text("New here?", style = NoopType.headline, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = "Dismiss" },
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
                "See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onOpen) {
                    Text("See how it works", style = NoopType.captionNumber, color = Palette.accent)
                }
            }
        }
    }
}

@Composable
private fun DaySelectorBar(selectedOffset: Int, onSelect: (Int) -> Unit) {
    DayNavBar(selectedOffset = selectedOffset, onSelect = onSelect)
}

// MARK: - Score hero row (Bevel) — three Charge / Effort / Rest ring gauges over a scenic backdrop
//
// The three daily scores as layered [BevelGauge]s, side by side, each in its own colour world,
// floated over a Charge-tinted [ScenicHeroBackground]. Each cell is a frosted tinted card carrying
// the gauge, a domain label and the per-score ⓘ. Honest empty / calibrating overlays when a score is
// null. Mirrors the macOS TodayView.scoreHeroRow. Data wiring is unchanged — presentation only.

@Composable
private fun ScoreHeroRow(
    day: DailyMetric?,
    restScore: Double?,
    recoveryCalibration: Int?,
    onScoreInfo: (ScoreSection) -> Unit,
) {
    val recovery = day?.recovery
    val strain = day?.strain
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius)),
    ) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Charge)
        Row(
            modifier = Modifier.fillMaxWidth().padding(Metrics.gap),
            horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
        ) {
            // CHARGE — recovery 0–100. Honest empty / calibrating overlay when null. The ring
            // diameter is supplied by the cell so three gauges always fit a phone width.
            HeroScoreCell(
                modifier = Modifier.weight(1f),
                domain = DomainTheme.Charge,
                onInfo = { onScoreInfo(ScoreSection.CHARGE) },
            ) { ringDiameter ->
                Box(contentAlignment = Alignment.Center) {
                    RecoveryRing(
                        score = recovery ?: 0.0,
                        diameter = ringDiameter,
                        lineWidth = ringDiameter * 0.10f,
                        showsLabel = recovery != null,
                    )
                    if (recovery == null) RingEmptyOverlay(recoveryCalibration)
                }
            }
            // EFFORT — strain on the 0–21 gauge. The stored strain is on NOOP's 0–100 Effort axis,
            // so map it back down to the gauge's 0–21 span for the arc + number.
            HeroScoreCell(
                modifier = Modifier.weight(1f),
                domain = DomainTheme.Effort,
                onInfo = { onScoreInfo(ScoreSection.EFFORT) },
            ) { ringDiameter ->
                Box(contentAlignment = Alignment.Center) {
                    StrainGauge(
                        strain = strain?.let { (it / 100.0) * 21.0 } ?: 0.0,
                        diameter = ringDiameter,
                        lineWidth = ringDiameter * 0.10f,
                        showsLabel = strain != null,
                    )
                    if (strain == null) RingNoData()
                }
            }
            // REST — sleep composite 0–100, reusing the recovery ring's scale.
            HeroScoreCell(
                modifier = Modifier.weight(1f),
                domain = DomainTheme.Rest,
                onInfo = { onScoreInfo(ScoreSection.REST) },
            ) { ringDiameter ->
                Box(contentAlignment = Alignment.Center) {
                    RecoveryRing(
                        score = restScore ?: 0.0,
                        diameter = ringDiameter,
                        lineWidth = ringDiameter * 0.10f,
                        showsLabel = restScore != null,
                    )
                    if (restScore == null) RingNoData()
                }
            }
        }
    }
}

/**
 * One score-ring cell: a frosted tinted card carrying the ring + a domain label + the ⓘ. The cell
 * measures its own width (via [BoxWithConstraints]) and passes the ring a diameter that fits, so the
 * three gauges never overflow on a narrow phone (the macOS adaptive grid reflows to a column instead).
 */
@Composable
private fun HeroScoreCell(
    domain: DomainTheme,
    onInfo: () -> Unit,
    modifier: Modifier = Modifier,
    ring: @Composable (ringDiameter: androidx.compose.ui.unit.Dp) -> Unit,
) {
    NoopCard(modifier = modifier, padding = Metrics.space12, tint = domain.color) {
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            // Fill most of the cell's inner width (a little inset so the ring doesn't touch the
            // card edge), capped so a wide tablet column doesn't blow the ring up.
            val ringDiameter = (maxWidth - 4.dp).coerceIn(56.dp, 120.dp)
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Text(
                    text = domain.label,
                    style = NoopType.overline,
                    color = domain.color,
                )
                ring(ringDiameter)
            }
            ScoreInfoButton(
                section = null,
                onClick = onInfo,
                compact = true,
                modifier = Modifier.align(Alignment.TopEnd),
            )
        }
    }
}

/** Honest overlay shown over the Charge ring when recovery is null: calibrating count or No data. */
@Composable
private fun RingEmptyOverlay(calibratingNights: Int?) {
    if (calibratingNights != null) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Calibrating", style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
            Text(
                "$calibratingNights of ${Baselines.minNightsSeed}",
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 1,
            )
        }
    } else {
        RingNoData()
    }
}

@Composable
private fun RingNoData() {
    Text(NO_DATA, style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
}

/**
 * Recent nights carrying a usable nightly HRV — the signal that seeds the recovery baseline. While
 * recovery is still null and this count is in [1, seed), it is the honest "calibrating N of <seed>"
 * progress shown in place of "No Data"; null once recovery exists or no night has data yet. Pure +
 * unit-tested (RecoveryCalibrationTest). Mirrors Baselines.minNightsSeed as the seed gate. (PR #85)
 */
internal fun recoveryCalibrationNights(
    days: List<DailyMetric>,
    hasRecovery: Boolean,
    seed: Int = Baselines.minNightsSeed,
): Int? {
    if (hasRecovery) return null
    // Match the baseline's validity predicate, not just non-null: Baselines.update only advances the
    // recovery seed (nValid) for nights whose avgHrv is within the HRV config bounds, so an implausible
    // out-of-range night must NOT be counted here either — else the displayed N could over-state nValid.
    val cfg = Baselines.hrvCfg
    return days.count { val v = it.avgHrv; v != null && v in cfg.minVal..cfg.maxVal }
        .takeIf { it in 1 until seed }
}

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Charge, Effort, Rest, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
private fun MetricGrid(
    d: DailyMetric?,
    w: Window,
    recoveryCalibration: Int? = null,
    unitSystem: UnitSystem = UnitSystem.METRIC,
    effortScale: EffortScale = EffortScale.HUNDRED,
    latestWeightKg: Double? = null,
    profileWeightKg: Double = 75.0,
    importedStepsForDay: Int? = null,
    restScore: Double? = null,
    enabledMetrics: List<KeyMetric> = KeyMetric.defaultOrder,
    onScoreInfo: (ScoreSection) -> Unit = {},
) {
    // One builder per tile, keyed by KeyMetric so the grid can be filtered + reordered per the saved
    // layout (#251). Each builder is byte-for-byte the tile that used to be hard-coded in the list — the
    // refactor only changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    val builders: Map<KeyMetric, @Composable (Modifier) -> Unit> = mapOf(
        KeyMetric.CHARGE to { m ->
            SparkStatTile(
                modifier = m,
                label = "Charge",
                value = d?.recovery?.let { "${it.roundToInt()}%" }
                    ?: recoveryCalibration?.let { "$it/${Baselines.minNightsSeed}" } ?: NO_DATA,
                caption = d?.recovery?.let {
                    Palette.recoveryState(it).lowercase().replaceFirstChar { c -> c.uppercase() }
                } ?: recoveryCalibration?.let { "Calibrating" },
                accent = d?.recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
                spark = w.recovery,
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.EFFORT to { m ->
            SparkStatTile(
                modifier = m,
                label = "Effort",
                value = d?.strain?.let { UnitFormatter.effortDisplay(it, effortScale) } ?: NO_DATA,
                caption = d?.strain?.let { "of ${UnitFormatter.effortScaleMax(effortScale)}" },
                accent = d?.strain?.let { Palette.strainColor(it) } ?: Palette.textTertiary,
                spark = w.strain,
                sparkColor = Palette.strain066,
                onInfo = { onScoreInfo(ScoreSection.EFFORT) },
            )
        },
        KeyMetric.REST to { m ->
            SparkStatTile(
                modifier = m,
                label = "Rest",
                value = restScore?.let { "${it.roundToInt()}%" } ?: NO_DATA,
                caption = restCaption(d),
                accent = restScore?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
                spark = w.sleepMin,
                sparkColor = Palette.metricPurple,
                onInfo = { onScoreInfo(ScoreSection.REST) },
            )
        },
        KeyMetric.HRV to { m ->
            SparkStatTile(
                modifier = m,
                label = "HRV",
                value = d?.avgHrv?.let { "${it.roundToInt()}" } ?: NO_DATA,
                caption = d?.avgHrv?.let { "ms" },
                accent = d?.avgHrv?.let { Palette.metricPurple } ?: Palette.textTertiary,
                spark = w.hrv,
                sparkColor = Palette.metricPurple,
            )
        },
        KeyMetric.RESTING_HR to { m ->
            SparkStatTile(
                modifier = m,
                label = "Resting HR",
                value = d?.restingHr?.toString() ?: NO_DATA,
                caption = d?.restingHr?.let { "bpm" },
                accent = d?.restingHr?.let { Palette.metricRose } ?: Palette.textTertiary,
                spark = w.rhr,
                sparkColor = Palette.metricRose,
            )
        },
        KeyMetric.BLOOD_OXYGEN to { m ->
            SparkStatTile(
                modifier = m,
                label = "Blood Oxygen",
                value = d?.spo2Pct?.let { String.format(Locale.US, "%.0f%%", it) } ?: NO_DATA,
                caption = d?.spo2Pct?.let { "SpO₂" },
                accent = d?.spo2Pct?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = w.spo2,
                sparkColor = Palette.metricCyan,
            )
        },
        KeyMetric.RESPIRATORY to { m ->
            SparkStatTile(
                modifier = m,
                label = "Respiratory",
                value = d?.respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                caption = d?.respRateBpm?.let { "rpm" },
                accent = d?.respRateBpm?.let { Palette.accent } ?: Palette.textTertiary,
                spark = w.resp,
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.STEPS to { m ->
            // Steps: prefer the on-device WHOOP 5/MG @57 counter (DailyMetric.steps); if the strap
            // didn't supply one — e.g. a WHOOP 4.0, which counts steps in the official WHOOP app but
            // doesn't expose them to NOOP over Bluetooth — fall back to the steps imported from Apple
            // Health / Health Connect for the day, instead of "No Data". (#107, #150)
            val steps = d?.steps ?: importedStepsForDay
            SparkStatTile(
                modifier = m,
                label = "Steps",
                value = steps?.let { intString(it.toDouble()) } ?: NO_DATA,
                caption = steps?.let { "steps" }, // neutral: the day selector can show past days
                accent = steps?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricCyan,
            )
        },
        KeyMetric.WEIGHT to { m ->
            // Latest Apple Health / Health Connect body weight, else the SI profile weight (#107). The
            // caption stays honest — "from profile" only when we fell back. Always shown in the user's
            // chosen units via the shared UnitFormatter (matches AppleHealthScreen's weight tile).
            val weight = weightTile(latestWeightKg, profileWeightKg, unitSystem)
            SparkStatTile(
                modifier = m,
                label = "Weight",
                value = weight.value,
                caption = weight.caption,
                accent = Palette.accent,
                spark = emptyList(),
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.CALORIES to { m ->
            // On-device APPROXIMATE whole-day active+resting energy from HR alone (DailyMetric
            // .activeKcalEst). A heart-rate estimate, not cloud/clinical parity — shown rounded. (#107)
            SparkStatTile(
                modifier = m,
                label = "Calories",
                value = d?.activeKcalEst?.let { "${intString(it)} kcal" } ?: NO_DATA,
                caption = d?.activeKcalEst?.let { "active · est." },
                accent = d?.activeKcalEst?.let { Palette.metricAmber } ?: Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricAmber,
            )
        },
    )

    // Resolve the enabled tiles to their builders, dropping any unknown key defensively.
    val tiles = enabledMetrics.mapNotNull { builders[it] }

    // Two-column grid built from rows so tile heights stay uniform (mirrors the
    // macOS adaptive grid; a fixed 2-up layout reads well on phone widths).
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - Heart-rate trend (today's continuous HR off the strap's own ~1Hz history)
//
// A full-width 24h HR trend, plotted from 5-minute bucket means of the strap's hrSample history
// (offloaded even while the app was closed, so the day reads continuously). Hidden until there are at
// least two buckets, so a strap-only user with no wear today sees nothing rather than an empty chart.
// Mirrors the macOS TodayView.heartRateTrendSection. LineChart spaces points by index (no time axis),
// so the buckets — being uniform 5-min means in time order — read as an even left-to-right day curve.

@Composable
private fun HeartRateTrendCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    selectedDay: LocalDate,
    today: LocalDate,
    displayMetric: DailyMetric? = null,
    effortScale: EffortScale = EffortScale.HUNDRED,
) {
    // "Today" here is the LOGICAL day (rolls at 04:00 local), so in the small hours after midnight the
    // trend keeps the evening's curve — window start at the logical day's own midnight, "since midnight"
    // subtitle, "Today" label — rather than blanking to an empty new-calendar-day axis (#144).
    var buckets by remember { mutableStateOf<List<HrBucket>>(emptyList()) }
    // The night's sleep session overlapping the HR window + the day's workouts — the Overview-HR
    // marker layers (sleep band, Charge at wake, sport glyphs at HR peaks). Loaded off the main
    // thread alongside the buckets; each marker self-hides when its data is absent. (PR #285)
    var sleepToday by remember { mutableStateOf<SleepSession?>(null) }
    var workoutsToday by remember { mutableStateOf<List<WorkoutRow>>(emptyList()) }
    // Re-load when the day list changes (a sync/import updates it), and on first composition.
    LaunchedEffect(days, selectedDay, today) {
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDay == today) now else (nextStart - 1)
        buckets = viewModel.repo.hrBuckets("my-whoop", start, end, 300L)
        // The sleep that ended within the chart window (the night before / this morning) — anchors
        // the band + the Charge-at-wake marker. A wide lower bound catches an onset before midnight.
        sleepToday = runCatching {
            viewModel.repo.sleepSessions("my-whoop", start - 18 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }   // overlaps the window
                .maxByOrNull { it.endTs }
        }.getOrNull()
        // Workouts overlapping the window — each gets a sport glyph at its in-window HR peak.
        workoutsToday = runCatching {
            viewModel.repo.workouts("my-whoop", start - 6 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }
        }.getOrDefault(emptyList())
    }
    if (buckets.size < 2) return

    val bpm = remember(buckets) { buckets.map { it.avgBpm } }
    val latest = bpm.last().roundToInt()
    val min = bpm.min().roundToInt()
    val max = bpm.max().roundToInt()
    val avg = bpm.average().roundToInt()

    val selectedLabel = when (selectedDay) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> selectedDay.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }

    SectionHeader("Heart Rate", overline = selectedLabel)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header — mirrors the macOS ChartCard (title + subtitle, trailing read-out).
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Beats per minute")
                    val subtitle = if (selectedDay == today) {
                        "5-minute average | since midnight"
                    } else {
                        "5-minute average | selected day"
                    }
                    Text(
                        subtitle,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text("$latest bpm", style = NoopType.chartValueLarge, color = Palette.metricRose)
            }
            // Chart with a max/avg/min Y-axis label column on the left and an HH:mm X-axis row
            // below — the strap-history buckets are uniform 5-minute means from the selected day's
            // midnight, so an index→time mapping reads as a real wall-clock day axis.
            Row(
                modifier = Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Column(
                    modifier = Modifier.height(Metrics.chartHeight),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("$max", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("$avg", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("$min", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                // The HR line, with the Overview marker layers (sleep band · Charge · Effort · sport
                // glyphs) overlaid on top — markers are positioned by mapping each event's wall-clock
                // time onto the line's index spacing, so they sit on the same curve. (PR #285)
                OverviewHRChart(
                    buckets = buckets,
                    bpm = bpm,
                    sleep = sleepToday,
                    workouts = workoutsToday,
                    recovery = displayMetric?.recovery,
                    strain = displayMetric?.strain,
                    effortScale = effortScale,
                    modifier = Modifier.weight(1f).height(Metrics.chartHeight),
                )
            }
            // X-axis: start (midnight) / midpoint / end of the selected day's window. Each bucket
            // is 5 minutes from the selected day's midnight, so the index maps straight to HH:mm.
            Row(modifier = Modifier.fillMaxWidth()) {
                val bucketToTime = { idx: Int ->
                    val m = idx * 5
                    String.format(Locale.US, "%02d:%02d", m / 60, m % 60)
                }
                val xLabels = if (buckets.size >= 3) {
                    listOf(
                        "00:00",
                        bucketToTime(buckets.size / 2),
                        if (selectedDay == today) "Now" else bucketToTime(buckets.size - 1),
                    )
                } else listOf("Start", "", "Now")
                xLabels.forEach { lbl ->
                    Text(lbl, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.divider)
                    .background(Palette.hairline),
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf("Min" to min, "Avg" to avg, "Max" to max).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text("$value bpm", style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

// MARK: - Overview HR chart (WHOOP-style day-in-review annotations)
//
// The 24h HR line — the shared index-spaced [LineChart] — with marker layers drawn ON TOP:
//   (a) a sleep band shading the night's sleep span (indigo, behind the line conceptually but
//       drawn under the marker chrome so labels stay legible),
//   (b) a dashed Charge rule + label at wake time (sleep end), hidden while recovery calibrates,
//   (c) a dashed Effort rule + label at "now" (the latest sample), routed through the SAME
//       UnitFormatter.effortDisplay the Effort tile uses so it honours the 0–100 / 0–21 toggle (#268),
//   (d) a small sport glyph at each workout's in-window HR peak.
//
// LineChart plots points by LIST INDEX (evenly spaced, no time axis), so each marker's wall-clock
// time is mapped to a fractional list index by interpolating against the buckets' own timestamps —
// markers then sit exactly on the rendered curve even when the strap history has gaps. Every layer
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
) {
    // The line itself stays the existing shared component, unchanged — markers are a sibling overlay.
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
    fun yForBpm(v: Double): Float {
        val usableH = (plotH - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((v - minV) / span).toFloat().coerceIn(0f, 1f)
        return topPad + (1f - norm) * usableH
    }

    // ── derived marker model (self-hiding) ──
    // Sleep band span clamped to the window; only drawn when it overlaps a visible stretch.
    val sleepStartX = sleep?.let { xFor(it.startTs) }
    val sleepEndX = sleep?.let { xFor(it.endTs) }
    // Charge marker sits at wake (sleep end), else the window start; hidden while recovery is null.
    val chargeX = recovery?.let { sleep?.let { s -> xFor(s.endTs) } ?: 0f }
    // Effort marker pinned to the latest sample (right edge) when a strain exists.
    val effortX = strain?.let { if (n > 1) plotW else null }

    // One combined TalkBack description for the overlay layers, so the markers (which are otherwise
    // small decorative pills) are announced. Only mentions the layers actually present.
    val markerDescription = remember(sleep, recovery, strain, workouts, effortScale) {
        buildList {
            add("24-hour heart rate")
            if (sleep != null) add("sleep band ${hrHoursMinutes((sleep.endTs - sleep.startTs).toInt())}")
            if (recovery != null) add("${recovery.roundToInt()} percent Charge at wake")
            if (strain != null) add("${UnitFormatter.effortDisplay(strain, effortScale)} Effort now")
            if (workouts.isNotEmpty()) add("${workouts.size} workout${if (workouts.size == 1) "" else "s"} marked")
        }.joinToString(", ")
    }

    Box(
        modifier = modifier
            .clipToBounds()
            .onSizeChanged { plotW = it.width.toFloat(); plotH = it.height.toFloat() }
            .semantics { contentDescription = markerDescription },
    ) {
        // 1) The HR line — unchanged shared component, tap-to-inspect intact.
        LineChart(
            values = bpm,
            modifier = Modifier.fillMaxSize(),
            color = Palette.metricRose,
            fill = true,
            selectionEnabled = true,
        )

        // 2) Band + dashed rules, drawn in one Canvas above the line.
        if (plotW > 0f && plotH > 0f) {
            val dash = remember { PathEffect.dashPathEffect(floatArrayOf(8f, 8f), 0f) }
            val wakeDash = remember { PathEffect.dashPathEffect(floatArrayOf(3f, 3f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                // Sleep band — a translucent indigo region across the sleep span.
                if (sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX) {
                    drawRect(
                        color = Palette.sleepDeep.copy(alpha = 0.30f),
                        topLeft = Offset(sleepStartX, 0f),
                        size = Size(sleepEndX - sleepStartX, size.height),
                    )
                    // Wake divider — the sleep→day boundary, so the band reads even before Charge calibrates.
                    if (sleepEndX > 0f && sleepEndX < size.width) {
                        drawLine(
                            color = Palette.sleepLight.copy(alpha = 0.5f),
                            start = Offset(sleepEndX, 0f),
                            end = Offset(sleepEndX, size.height),
                            strokeWidth = 1f,
                            pathEffect = wakeDash,
                        )
                    }
                }
                // Charge rule at wake.
                if (chargeX != null && recovery != null) {
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
                if (effortX != null && strain != null) {
                    val x = (size.width - 1f).coerceIn(0f, size.width)
                    drawLine(
                        color = Palette.strainColor(strain).copy(alpha = 0.85f),
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }

                // Glowing endpoint at the latest HR sample (right edge) — a Bevel chart end-cap:
                // a soft rose halo + white core sitting on the line's final point.
                if (n >= 2) {
                    val lastX = size.width
                    val lastY = yForBpm(bpm.last())
                    val end = Offset(lastX.coerceIn(0f, size.width), lastY)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.30f), radius = 9f, center = end)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.65f), radius = 5.5f, center = end)
                    drawCircle(color = Color.White, radius = 2.4f, center = end)
                }
            }

            // 3) Marker labels + sport glyphs — positioned composables (crisp text/icons vs Canvas).
            val topPadDp = 10.dp
            // Sleep duration pill at the band's leading edge.
            if (sleepStartX != null && sleep != null && (sleepEndX ?: 0f) > (sleepStartX)) {
                val durLabel = hrHoursMinutes((sleep.endTs - sleep.startTs).toInt())
                ChartMarkerPill(
                    text = durLabel,
                    color = Palette.sleepLight,
                    leadingIcon = Icons.Filled.Bedtime,
                    modifier = Modifier.markerOffset(sleepStartX, density, topPadDp),
                )
            }
            if (chargeX != null && recovery != null) {
                ChartMarkerPill(
                    text = "${recovery.roundToInt()}% Charge",
                    color = Palette.recoveryColor(recovery),
                    modifier = Modifier.markerOffset(chargeX, density, topPadDp),
                )
            }
            if (effortX != null && strain != null) {
                ChartMarkerPill(
                    text = "${UnitFormatter.effortDisplay(strain, effortScale)} Effort",
                    color = Palette.strainColor(strain),
                    modifier = Modifier.markerOffset(plotW, density, topPadDp, alignEnd = true),
                )
            }
            // Sport glyph at each workout's in-window HR peak.
            workouts.forEach { w ->
                val peak = hrPeakIn(buckets, w.startTs, w.endTs)
                if (peak != null) {
                    val px = xFor(peak.bucket)
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

private data class TodayFooterState(
    val recentWorkouts: List<WorkoutRow> = emptyList(),
    val whoopDays: Int? = null,
    val whoopWorkouts: Int? = null,
    val appleDays: Int? = null,
    val appleWorkouts: Int? = null,
    val hcDays: Int? = null,
    val hcWorkouts: Int? = null,
)

@Composable
private fun TodayWorkoutsSection(workouts: List<WorkoutRow>) {
    if (workouts.isEmpty()) return

    SectionHeader("Last Workouts", overline = "Activity", trailing = "14 days")
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        workouts.take(4).chunked(2).forEach { rowWorkouts ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowWorkouts.forEach { workout ->
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = WorkoutEditing.displaySport(workout.sport),
                        value = workoutDuration(workout),
                        caption = workoutCaption(workout),
                        accent = workout.strain?.let { Palette.strainColor(it) } ?: Palette.textPrimary,
                        delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                        deltaColor = Palette.metricAmber,
                    )
                }
                if (rowWorkouts.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TodaySourcesSection(footer: TodayFooterState, strapBatteryPct: Int? = null) {
    SectionHeader("Data Sources", overline = "Provenance")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SourceRow(
                badge = "Whoop",
                tint = Palette.accent,
                // A live battery reading means the strap IS connected, even before the first banked
                // night — don't contradict it with "Not connected" (#159).
                present = (footer.whoopDays ?: 0) > 0 || strapBatteryPct != null,
                detail = countDetail(footer.whoopDays, footer.whoopWorkouts, "workouts"),
                batteryPct = strapBatteryPct,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Apple Health",
                tint = Palette.metricCyan,
                present = (footer.appleDays ?: 0) > 0 || (footer.appleWorkouts ?: 0) > 0,
                detail = countDetail(footer.appleDays, footer.appleWorkouts, "workouts"),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Health Connect",
                tint = Palette.metricPurple,
                present = (footer.hcDays ?: 0) > 0 || (footer.hcWorkouts ?: 0) > 0,
                detail = countDetail(footer.hcDays, footer.hcWorkouts, "workouts"),
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
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
        // Compact strap-battery readout beside the source badge — same pill + tone bands as the
        // Settings Strap section; absent entirely when there's no live reading (#159).
        batteryPct?.let { pct ->
            Spacer(Modifier.width(8.dp))
            StatePill(title = "$pct%", tone = batteryPillTone(pct), showsDot = false)
        }
        Spacer(Modifier.weight(1f))
        Text(
            text = if (present) detail else "Not connected",
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
private fun ReadinessSection(days: List<DailyMetric>) {
    // Logical day (rolls at 04:00 local), so readiness keeps reading the evening's row in the small
    // hours instead of an empty new-calendar-day row (#144). Mirrors the Today-row resolution.
    val todayKey = logicalDayKeyNow()
    val readiness = remember(days, todayKey) { ReadinessEngine.evaluate(days, today = todayKey) }
    if (readiness.level == ReadinessEngine.Level.INSUFFICIENT) return

    SectionHeader("Readiness", overline = "Should you push today?")
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
                    readiness.headline,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                readiness.acwr?.let { acwr ->
                    Text(
                        "load ${String.format(Locale.US, "%.2f", acwr)}",
                        style = NoopType.captionNumber,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Plain-English summary.
            Text(
                readiness.summary,
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
                            signal.label,
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.width(104.dp),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(1.dp),
                        ) {
                            Text(
                                signal.detail,
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                            // The numbers behind the read (e.g. "48 vs 55 ms"), as a small mono caption —
                            // mirrors the macOS readiness card and the "load X.XX" numeric readout above.
                            signal.evidence?.let { evidence ->
                                Text(
                                    evidence,
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
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Label row carries the overline and, for the three headline scores only, a trailing ⓘ
            // that opens the scoring guide at this score. Other tiles render exactly as before.
            if (onInfo != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline(label, modifier = Modifier.weight(1f))
                    ScoreInfoButton(section = null, onClick = onInfo, compact = true)
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
                    Text(
                        value,
                        style = NoopType.tileValueLarge,
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
    val shape = RoundedCornerShape(Metrics.cornerSm)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = StrandAlpha.warningFill), shape)
            .border(Metrics.divider, Palette.statusWarning.copy(alpha = StrandAlpha.warningBorder), shape)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning)
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
    val resp: List<Double>,
)

/**
 * Build the 14-day windows from `recentDays`. Each series drops null days from the
 * trailing calendar window only, so stale imports do not draw a current-day trend.
 */
@Composable
private fun remember14(days: List<com.noop.data.DailyMetric>, anchorDay: LocalDate): Window =
    androidx.compose.runtime.remember(days, anchorDay) {
        // Trailing 14 CALENDAR days ending today — NOT the last 14 stored rows, which on an old import
        // were months-old data shown as a "14-day trend" (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = anchorDay.minusDays(13).toString()
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
            resp = series { it.respRateBpm },
        )
    }

// MARK: - Derived text (ported from TodayView.swift)

private fun greetingWord(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when {
        h < 12 -> "Good morning"
        h < 17 -> "Good afternoon"
        else -> "Good evening"
    }
}

private fun synthesisWord(score: Double?): String {
    if (score == null) return "No Data"
    return when {
        score < 25 -> "Depleted"
        score < 50 -> "Low"
        score < 70 -> "Steady"
        score < 88 -> "Primed"
        else -> "Peak"
    }
}

private fun synthesisDetail(d: DailyMetric?): String {
    val rec = d?.recovery
        ?: return "No metrics yet. Import your WHOOP export or wear the strap to begin."
    val recPart = when {
        rec < 50 -> "Charge is low"
        rec < 70 -> "Charge is steady"
        else -> "Charge is strong"
    }
    val sleepPart = d.totalSleepMin?.let { mins ->
        if (mins / 60.0 >= 7) " and sleep was consistent" else " but sleep ran short"
    } ?: ""
    return "$recPart$sleepPart."
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/**
 * The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's VALUE
 * before #248 moved the Rest score there. Falls back to the efficiency read-out when no duration is
 * banked, and to null so the tile shows no caption line when neither exists. Mirrors macOS restCaption.
 */
private fun restCaption(d: DailyMetric?): String? = when {
    d?.totalSleepMin != null -> sleepValue(d)
    d?.efficiency != null -> String.format(Locale.US, "%.0f%% eff", d.efficiency)
    else -> null
}

// MARK: - Steps / Weight / Calories tile logic (issue #107)
//
// Steps and Calories read straight off today's DailyMetric (the on-device WHOOP5 derivations); the
// pure helpers below back the Weight tile, which has no daily strap source and instead falls back to
// the user's profile weight. Kept pure + file-internal so TodayMetricTilesTest is the oracle.

/** The Weight tile's display string and an honest caption ("from profile" only on fallback). */
internal data class WeightTileText(val value: String, val caption: String?)

/**
 * The newest body weight across the two Apple-side sources (apple-health + health-connect), or null
 * when neither carries one. Days are ISO `yyyy-MM-dd`, which sorts chronologically, so the lexically
 * greatest day with a non-null `weightKg` is the most recent — no date parsing needed. (#107)
 */
internal fun latestWeightKg(apple: List<AppleDaily>, healthConnect: List<AppleDaily>): Double? =
    (apple + healthConnect)
        .filter { it.weightKg != null }
        .maxByOrNull { it.day }
        ?.weightKg

/**
 * Steps for [dayKey] from the imported Apple Health / Health Connect daily aggregates, or null when
 * neither source carries a step total for that day. Backs the Today Steps-tile fallback for straps
 * NOOP can't read steps off over Bluetooth — notably the WHOOP 4.0, which DOES count steps (in the
 * official WHOOP app) but doesn't expose them to NOOP — so on a 4.0 the tile shows imported steps
 * rather than "No Data". On-device WHOOP 5/MG steps (DailyMetric.steps) still take precedence at the
 * call site. When both sources report the same day, the larger (most-complete) total wins so we never
 * sum and double-count. Mirrors the macOS TodayView, which already falls back to imported steps. (#150)
 */
internal fun stepsForDay(apple: List<AppleDaily>, healthConnect: List<AppleDaily>, dayKey: String): Int? =
    (apple + healthConnect)
        .filter { it.day == dayKey }
        .mapNotNull { it.steps }
        .maxOrNull()

/**
 * Resolve the Weight tile text: prefer the latest Apple/Health-Connect weight, else fall back to the
 * SI profile weight with a "from profile" caption so the source stays honest. Both are formatted
 * through the shared [UnitFormatter] so the Imperial/Metric toggle reaches this tile too. (#107)
 */
internal fun weightTile(latestWeightKg: Double?, profileWeightKg: Double, system: UnitSystem): WeightTileText =
    if (latestWeightKg != null) {
        WeightTileText(UnitFormatter.massFromKilograms(latestWeightKg, system), "latest")
    } else {
        WeightTileText(UnitFormatter.massFromKilograms(profileWeightKg, system), "from profile")
    }

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. */
private fun intString(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

private const val NO_DATA = "No Data"

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.US).withZone(ZoneId.systemDefault())
private val workoutTimeFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("HH:mm", Locale.US).withZone(ZoneId.systemDefault())

private fun countDetail(days: Int?, workouts: Int?, workoutLabel: String): String {
    if (days == null || workouts == null) return "Counting..."
    return "${grouped(days)} days · ${grouped(workouts)} $workoutLabel"
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
        "$date · $start–${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun grouped(value: Int): String =
    String.format(Locale.US, "%,d", value)

/**
 * Length of the current run of consecutive nights (ending at [anchor]) that banked a sleep total.
 * If [anchor] itself has no recorded sleep yet — common before the morning offload — the count
 * starts from the previous day so the streak doesn't read 0 mid-morning. Returns 0 when neither
 * the anchor nor the day before it recorded sleep.
 */
internal fun nightStreak(days: List<DailyMetric>, anchor: LocalDate): Int {
    val recorded = days.filter { (it.totalSleepMin ?: 0.0) > 0.0 }.map { it.day }.toHashSet()
    if (recorded.isEmpty()) return 0
    var cursor = if (anchor.toString() in recorded) anchor else anchor.minusDays(1)
    var streak = 0
    while (cursor.toString() in recorded) {
        streak++
        cursor = cursor.minusDays(1)
    }
    return streak
}

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local dialog (no new nav destination — another lane owns the nav graph) for choosing which
// Key-Metric tiles show on the Control Center and in what order. Display-only: it edits the persisted
// `today.keyMetrics` layout, never any stored metric. A switch hides/shows a tile and the up/down arrows
// reorder it — explicit arrows rather than drag so it behaves the same on every device. Mirrors the macOS
// KeyMetricsEditorSheet.

/** One editor row: a tile with its current enabled flag. The working list is rebuilt on each edit. */
private data class EditableMetric(val metric: KeyMetric, val enabled: Boolean)

@Composable
private fun KeyMetricsEditorDialog(
    initial: List<KeyMetric>,
    onDismiss: () -> Unit,
    onSave: (List<KeyMetric>) -> Unit,
) {
    // Working copy: enabled tiles first (saved order), then the disabled remainder in the default order —
    // so toggling one on drops it at the end of the visible set, and every known tile is listed once.
    val items = remember {
        val enabledSet = initial.toHashSet()
        mutableStateListOf<EditableMetric>().apply {
            initial.forEach { add(EditableMetric(it, true)) }
            KeyMetric.defaultOrder.filter { it !in enabledSet }.forEach { add(EditableMetric(it, false)) }
        }
    }

    fun move(from: Int, to: Int) {
        if (from in items.indices && to in items.indices) {
            val item = items.removeAt(from)
            items.add(to, item)
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
                    Text("Edit Key Metrics", style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        "Choose which tiles show on your Control Center and reorder them with the arrows.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                Column(
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    items.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Switch(
                                checked = item.enabled,
                                onCheckedChange = { items[index] = item.copy(enabled = it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = Palette.surfaceBase,
                                    checkedTrackColor = Palette.accent,
                                    uncheckedThumbColor = Palette.textSecondary,
                                    uncheckedTrackColor = Palette.surfaceInset,
                                    uncheckedBorderColor = Palette.hairline,
                                ),
                                modifier = Modifier.semantics { contentDescription = "Show ${item.metric.title}" },
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                item.metric.title,
                                style = NoopType.body,
                                color = if (item.enabled) Palette.textPrimary else Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { move(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowUp,
                                    contentDescription = "Move ${item.metric.title} up",
                                    tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                            IconButton(
                                onClick = { move(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowDown,
                                    contentDescription = "Move ${item.metric.title} down",
                                    tint = if (index < items.lastIndex) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline, thickness = 1.dp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            // Reset to the canonical default: every tile enabled, original order.
                            items.clear()
                            KeyMetric.defaultOrder.forEach { items.add(EditableMetric(it, true)) }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text("Reset", style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.filter { it.enabled }.map { it.metric }) },
                        // At least one tile must stay visible — an empty grid reads as a bug, not a choice.
                        enabled = items.any { it.enabled },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Done", style = NoopType.captionNumber) }
                }
            }
        }
    }
}
