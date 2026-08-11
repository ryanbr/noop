package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Coupled view (task #43) — Kotlin twin of CoupledView.swift
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0-21 / Sleep, for users who came across from another band and want the old
// glance back. NOOP's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Effort-scale toggle. It reads the SAME values Today already computes (recovery
// / Rest composite / Effort strain / readiness) and re-presents them in the coupled layout. The only new
// mapping is the OPTIMAL strain band, a pure display-only read of today's recovery to a suggested strain
// range (never fed back into scoring) that is byte-identical to the Swift [CoupledView.optimalStrainRange].
//
// Every colour routes through the [Palette] ramps, so the Classic / Titanium appearance carries automatically.
// The brand word never appears in a shipped UI string (legal posture); the screen is called "Coupled view".

/** The 0-21 Day-Strain axis the coupled read always uses, regardless of the user's #268 display toggle. */
private const val COUPLED_STRAIN_OUT_OF = 21.0

/** The missing-value placeholder, matching the app's shipped "No Data" token (TodayScreen.COUPLED_NO_DATA is
 *  file-private, so the coupled screen carries its own copy of the same string). */
private const val COUPLED_NO_DATA = "No Data"

// The liquid hero-card wrapper values, byte-identical to the liquid Today pilot (TodayScreen's
// LIQUID_HERO_FILL / LIQUID_HERO_RADIUS are file-private, so the coupled screen carries its own copy):
// a translucent near-black that floats over the day-of-sky so the vessel + white count-up numbers stay
// crisp — the card does the contrast work, not a muted sky. heroFill = rgba(13,14,20,.80), stroke
// white@0.11, radius 26. Mirrors the iOS LiquidTodayView heroCard.
private val LIQUID_HERO_RADIUS: Dp = 26.dp

@Composable
fun CoupledScreen(
    vm: AppViewModel,
    onOpenSleep: () -> Unit = {},
) {
    val today by vm.today.collectAsStateWithLifecycle()
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // #614: the Workouts stat must match the Workouts screen, not DailyMetric.exerciseCount (which counts
    // only strap-DETECTED bouts — a Health-Connect import with auto-detect off read as 0 while the Workouts
    // screen showed it). vm.workouts is the SAME deduped, dismissed-filtered, all-source list the Workouts
    // screen renders; loadWorkouts() isn't triggered by opening Coupled, so kick it here (idempotent,
    // mirrors InsightsScreen).
    LaunchedEffect(Unit) { vm.loadWorkouts() }
    val allWorkouts by vm.workouts.collectAsStateWithLifecycle()

    // Last night's sleep sessions (imported + computed-only), the SAME resolution SleepScreen uses, keyed on
    // `days` so a sync/import reloads. Only needed for the bed-wake span footnote.
    var sleeps by remember { mutableStateOf<List<SleepSession>>(emptyList()) }
    LaunchedEffect(days) {
        sleeps = runCatching {
            val now = System.currentTimeMillis() / 1000L
            val imported = vm.repo.sleepSessions("my-whoop", 0L, now)
            val computed = vm.repo.sleepSessions(vm.repo.computedDeviceId("my-whoop"), 0L, now)
            val importedEnds = imported.map { it.endTs }.toHashSet()
            (imported + computed.filter { it.endTs !in importedEnds }).sortedBy { it.effectiveStartTs }
        }.getOrDefault(emptyList())
    }

    // The learned habitual midsleep the Sleep tab hero threads into its main-night pick, so the bed-wake
    // span below resolves the IDENTICAL block (#294) instead of a screen-local heuristic.
    var habitualMidsleepSec by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(days) {
        habitualMidsleepSec = runCatching { vm.repo.habitualMidsleepSec("my-whoop") }.getOrNull()
    }

    // Imported export-verbatim sleep figures (sleep_performance / need), preferred over the on-device
    // approximation, mirroring SleepScreen. Keyed on `days` (metricSeries has no Flow).
    var importedPerf by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var importedNeed by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    LaunchedEffect(days) {
        suspend fun load(key: String) = runCatching {
            vm.repo.metricSeries("my-whoop", key, "0000-00-00", "9999-99-99")
        }.getOrDefault(emptyList()).associate { it.day to it.value }
        importedPerf = load("sleep_performance")
        importedNeed = load("sleep_need_min")
    }

    // The day the coupled read describes: today's resolved row, else the carried last-scored prior day, so a
    // just-rolled-over morning carries yesterday's read rather than blanking (mirrors Swift + widgetAnchor).
    val logicalKey = remember { logicalDayKeyNow() }
    val localKey = remember { java.time.LocalDate.now().toString() }
    val todayRow = remember(today, days, logicalKey, localKey) {
        resolveTodayRow(days, logicalKey, localKey) ?: today
    }
    val todayKey = todayRow?.day ?: logicalKey
    // #614: count TODAY's workouts by their START's logical day (the SAME 04:00-rollover key DailyMetric.day
    // uses), so the Coupled stat equals the Workouts overview for today.
    val workoutsToday = remember(allWorkouts, todayKey) {
        allWorkouts.count {
            logicalDay(java.time.Instant.ofEpochSecond(it.startTs).atZone(java.time.ZoneId.systemDefault()))
                .toString() == todayKey
        }
    }
    val carriedRecoveryDay = remember(days, todayKey) {
        days.lastOrNull { it.recovery != null && it.day < todayKey }
    }
    val recovery = todayRow?.recovery ?: carriedRecoveryDay?.recovery
    val isCarrying = todayRow?.recovery == null && carriedRecoveryDay?.recovery != null

    // Effort strain on NOOP's 0-100 axis (stored row), mapped to the 0-21 coupled axis via the shipped
    // formatter, so the number matches every other Effort read-out's conversion factor.
    val dayStrain21 = todayRow?.strain?.let { UnitFormatter.effortValue(it, EffortScale.WHOOP) }

    // Sleep performance %: the imported figure when the export carried one, else the resolved Rest composite
    // (RestScorer.restFromDaily), the SAME single source of truth the Today Rest score + Sleep graph read.
    val sleepPerformance = todayRow?.let { d ->
        importedPerf[d.day] ?: RestScorer.restFromDaily(d)
    }

    // On-device readiness, computed EXACTLY as Today does, so the one-word pill matches the home screen.
    // The carried anchor is gated on isCarrying (Today's !todayScored gate): on a normal scored day today's
    // own key wins, so Coupled's pill can't diverge from Today's onto yesterday (#787).
    val readinessLevel = remember(days, carriedRecoveryDay, todayRow, isCarrying) {
        val anchor = (if (isCarrying) carriedRecoveryDay?.day else todayRow?.day) ?: logicalKey
        ReadinessEngine.evaluate(days, anchor).level
    }

    // Recovery cold-start nights (the SAME pure helper Today's ring reads), for the honest calibrating
    // caption + accessibility copy while the HRV baseline still seeds. Threads the persisted
    // "Recalibrate HRV baseline" epoch so N folds the SAME epoch-aware history the engine folds (Bug B).
    val context = LocalContext.current
    val hrvEpoch = remember { NoopPrefs.of(context).getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble() }
    val calibrationNights = remember(days, todayRow, hrvEpoch) {
        recoveryCalibrationNights(days, hasRecovery = todayRow?.recovery != null, hrvBaselineEpoch = hrvEpoch)
    }

    // The Charge breakdown (the hero's tap target, the EXISTING Today sheet) + the scoring guide it
    // links on to. Both are full-screen Dialogs, TodayScreen's own presentation, built only when shown
    // (#819 lazy). Not persisted, so a return visit reopens closed.
    var showChargeBreakdown by remember { mutableStateOf(false) }
    var showGuide by remember { mutableStateOf(false) }

    // Day-cycle sky + sky-behind-cards: the SAME two Appearance gates every other screen honours.
    // (This screen previously drew the sky unconditionally - it now matches Today/Trends/Sleep,
    // including turning OFF with the day-cycle setting.) Read once; SharedPreferences isn't reactive.
    val skyCtx = androidx.compose.ui.platform.LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(skyCtx) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(skyCtx) }
    ScreenScaffold(
        title = uiString(R.string.l10n_coupled_screen_day_987b9ced),
        subtitle = subtitleToday(),
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the reusable time-of-day liquid sky
        // sits behind the top region, full-bleed up behind the status bar via the scaffold's topBackground
        // plumbing, top-aligned, settling into the flat canvas over its lower half so the cards float OVER it.
        // The Android equivalent of the iOS `ScreenScaffold(topBackground: liquidScaffoldSky())`; it replaces
        // the classic flat-canvas backdrop with the liquid day-of-sky (LiquidSkyStatic — no per-frame cost on
        // this scrolling column). The other liquid screens drop in the SAME LiquidScreenSky() slot verbatim.
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        HeroCard(
            recovery = recovery,
            isCarrying = isCarrying,
            carriedDay = carriedRecoveryDay,
            todayKey = todayKey,
            calibrationNights = calibrationNights,
            readinessLevel = readinessLevel,
            onTap = { showChargeBreakdown = true },
        )
        StrainCard(
            dayStrain21 = dayStrain21,
            recovery = recovery,
            calories = todayRow?.activeKcalEst,
            workouts = workoutsToday,   // #614: real workout count (all sources), not exerciseCount
        )
        SleepCard(
            sleepPerformance = sleepPerformance,
            asleepMin = todayRow?.totalSleepMin,
            needMin = sleepNeedForDay(todayRow, days, importedNeed),
            bedWakeSpan = bedWakeSpan(sleeps, habitualMidsleepSec),
            onOpenSleep = onOpenSleep,
        )
        Text(
            // The brief quotes the footer with the brand word, but the hard legal / anonymity rule wins over
            // the illustrative copy: this keeps the exact intent without the branding word. Byte-identical to
            // the Swift footer caption.
            "A classic one-glance read of NOOP's own scores. Same data, different lens.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
            modifier = Modifier.padding(top = 4.dp),
        )
    }

    // The hero's tap target: the EXISTING Today Charge breakdown sheet (What shaped it + Contributors +
    // the folded Readiness card), reading the SAME carried/today row the hero ring shows, so the two
    // screens can never disagree. Same full-screen Dialog presentation TodayScreen uses.
    if (showChargeBreakdown) {
        Dialog(
            onDismissRequest = { showChargeBreakdown = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ChargeBreakdownSheet(
                days = days,
                displayDay = todayRow,
                carriedDay = carriedRecoveryDay,
                showReadiness = true,
                onClose = { showChargeBreakdown = false },
                onHowCalculated = {
                    showChargeBreakdown = false
                    showGuide = true
                },
            )
        }
    }
    // "How Charge is calculated" from the breakdown opens the scoring guide at the Charge section, the
    // same target the Today per-ring info buttons use.
    if (showGuide) {
        Dialog(
            onDismissRequest = { showGuide = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                ScoringGuideScreen(
                    onClose = { showGuide = false },
                    initialSection = ScoreSection.CHARGE,
                )
            }
        }
    }
}

// MARK: 1. HERO — the recovery ring, coupled read (tap = the Charge breakdown)

@Composable
private fun HeroCard(
    recovery: Double?,
    isCarrying: Boolean,
    carriedDay: DailyMetric?,
    todayKey: String,
    calibrationNights: Int?,
    readinessLevel: ReadinessEngine.Level,
    onTap: () -> Unit,
) {
    val a11y = when {
        recovery != null -> "Recovery ${recovery.roundToInt()} percent. See what shaped your Charge"
        calibrationNights != null ->
            "Recovery calibrating, $calibrationNights of ${Baselines.minNightsSeed} nights"
        else -> "Recovery, no data yet"
    }
    // The vessel runs LIVE (per-frame slosh + tilt) once there's a real value to show; an empty/calibrating
    // hero poses it static so a brand-new user's launch churn isn't fighting a live canvas (the Today
    // `dataLoaded` gate on HeroScoreVessel). A carried Charge counts as data (its dimmed vessel should slosh).
    val animated = recovery != null
    // The whole hero is the breakdown's tap target, mirroring Today's Charge-vessel tap (A1). The SAME
    // interactionSource drives the clickable + the liquidPress so the card settles inward on press.
    val interaction = remember { MutableInteractionSource() }
    // The liquid hero CARD: a translucent near-black that floats over the day-of-sky so the vessel + white
    // count-up number stay crisp — the card does the contrast work, not a muted sky. A rounded 26 corner + a
    // faint white hairline give it the frosted-glass edge of the iOS liquid heroCard. Mirrors the pilot.
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .liquidPress(interaction)
            .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
            .background(Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity))
            .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClickLabel = "See what shaped your Charge",
                onClick = onTap,
            )
            .semantics { contentDescription = a11y },
    ) {
        Box(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(modifier = Modifier.size(232.dp), contentAlignment = Alignment.Center) {
                    // The recovery ring becomes a liquid VESSEL filled to the recovery fraction in the sampled
                    // recovery colour, with the number counting up over it (the Today HeroScoreVessel idiom).
                    // A carried (not-yet-rescored) morning reads dimmed, the Today #802 idiom. Empty (no score)
                    // draws an empty vessel and the centre stack shows the "No Data" token instead of a number.
                    LiquidVessel(
                        value = ((recovery ?: 0.0) / 100.0).coerceIn(0.0, 1.0),
                        tint = if (recovery != null) Palette.recoveryColor(recovery) else Palette.chargeColor,
                        animated = animated,
                        modifier = Modifier
                            .size(232.dp)
                            .alpha(if (isCarrying) 0.8f else 1f),
                    )
                    HeroCentre(recovery = recovery, readinessLevel = readinessLevel)
                }
                // The honest state line under the ring: the "Last night · <date>" stamp when carrying a
                // prior score (#543/#779, the SAME caption Today uses), or the calibrating progress while
                // the baseline seeds. Nothing when today's own score is showing.
                if (isCarrying && carriedDay != null) {
                    Text(
                        carriedCaption(carriedDay.day, today = todayKey),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                } else if (recovery == null && calibrationNights != null) {
                    Text(
                        uiString(R.string.l10n_coupled_screen_calibrating_calibrationnights_of_baselines_minnightsseed_nights_1a7e8f8e, calibrationNights, Baselines.minNightsSeed),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun HeroCentre(recovery: Double?, readinessLevel: ReadinessEngine.Level) {
    val sampled = recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (recovery != null) {
            // Count-up number over the vessel — white, tabular, a soft shadow for legibility, hit-transparent
            // (clearAndSetSemantics + no clickable) so the tap reaches the vessel (splash) and the enclosing
            // hero card. The Today HeroScoreVessel idiom, sized to this larger 232dp coupled hero.
            CountUpText(
                value = recovery,
                format = { "${it.roundToInt()}%" },
                style = NoopType.number(56f, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                color = Color.White,
                modifier = Modifier.clearAndSetSemantics {},
            )
        } else {
            // The honest empty read at the ring-label size (never the 56sp numeral, "No Data" would
            // overflow the ring interior), matching the Today hero rings' RingNoData idiom.
            Text(COUPLED_NO_DATA, style = NoopType.headline, color = Palette.textSecondary)
        }
        Text(uiString(R.string.l10n_coupled_screen_recovery_b668d988), style = NoopType.overline, color = sampled)
        val word = readinessWord(readinessLevel)
        if (word != null) ReadinessPill(word = word, level = readinessLevel)
    }
}

@Composable
private fun ReadinessPill(word: String, level: ReadinessEngine.Level) {
    val tint = readinessTint(level)
    Text(
        word.uppercase(),
        style = NoopType.overline,
        color = tint,
        modifier = Modifier
            .padding(top = 2.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(tint.copy(alpha = 0.12f))
            .border(1.dp, tint.copy(alpha = 0.32f), RoundedCornerShape(999.dp))
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}

/** Level -> tint, the SAME mapping TodayScreen.readinessColor uses (that one is private, so mirror it). */
private fun readinessTint(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

// MARK: 2. STRAIN ROW — the effort gauge + coupled stat stack

@Composable
private fun StrainCard(dayStrain21: Double?, recovery: Double?, calories: Double?, workouts: Int) {
    NoopCard(padding = 20.dp, tint = Palette.effortColor) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Left: the effort gauge on the 0-21 axis as a liquid VESSEL (the Today HeroScoreVessel idiom),
            // with the band word as an overline above it (the Swift StrainGauge's LIGHT/MODERATE/STRENUOUS/
            // HIGH overline). Same fraction (strain / 21) and effort tint as the Today hero effort vessel.
            Column(
                modifier = Modifier.size(168.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (dayStrain21 != null) {
                    val strainFrac = (dayStrain21 / COUPLED_STRAIN_OUT_OF).coerceIn(0.0, 1.0)
                    Text(strainBandWord(dayStrain21 / COUPLED_STRAIN_OUT_OF), style = NoopType.overline, color = Palette.effortColor)
                    Spacer(Modifier.size(4.dp))
                    Box(modifier = Modifier.size(148.dp), contentAlignment = Alignment.Center) {
                        LiquidVessel(
                            value = strainFrac,
                            tint = Palette.effortTint(strainFrac),
                            animated = true,
                            modifier = Modifier.size(148.dp),
                        )
                        CountUpText(
                            value = dayStrain21,
                            format = { String.format(Locale.US, "%.1f", it) },
                            style = NoopType.number(30f, weight = FontWeight.Bold)
                                .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                            color = Color.White,
                            modifier = Modifier.clearAndSetSemantics {},
                        )
                    }
                } else {
                    // No scored effort yet: an empty (posed) vessel so the card never reads as broken, with
                    // the honest caption below it, mirroring the empty-hero treatment on Today.
                    LiquidVessel(
                        value = 0.0,
                        tint = Palette.effortColor,
                        animated = false,
                        modifier = Modifier.size(148.dp),
                    )
                    Text(uiString(R.string.l10n_coupled_screen_no_effort_yet_f622f99d), style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.padding(top = 6.dp))
                }
            }

            // Right: the coupled stat stack.
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                HeroStat("Day Strain", dayStrain21?.let { String.format(Locale.US, "%.1f", it) } ?: COUPLED_NO_DATA, Palette.effortColor)
                HeroStat("Optimal", optimalStrainRangeText(recovery), Palette.chargeColor)
                HeroStat("Calories", calories?.let { "${it.roundToInt()} kcal" } ?: COUPLED_NO_DATA, Palette.metricAmber)
                HeroStat("Workouts", workouts.toString(), Palette.textPrimary)
            }
        }
    }
}

/** The heroStat idiom (an UPPERCASE overline over a big tinted number), mirroring WorkoutsScreen/iOS heroStat. */
@Composable
private fun HeroStat(title: String, value: String, tint: Color) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(title.uppercase(), style = NoopType.overline, color = Palette.textSecondary)
        Text(value, style = NoopType.number(20f), color = tint)
    }
}

// MARK: 3. SLEEP ROW — the sleep-performance ring + hours-vs-need read (tap = Sleep)

@Composable
private fun SleepCard(
    sleepPerformance: Double?,
    asleepMin: Double?,
    needMin: Double,
    bedWakeSpan: String?,
    onOpenSleep: () -> Unit,
) {
    // liquidPress on the whole tappable card (the SAME interactionSource drives the clickable + the press),
    // so it settles inward on press, mirroring the Today liquid cards.
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        padding = 20.dp,
        tint = Palette.restColor,
        modifier = Modifier
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClickLabel = "Open Sleep",
                onClick = onOpenSleep,
            )
            .liquidPress(interaction),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(modifier = Modifier.size(96.dp), contentAlignment = Alignment.Center) {
                // The sleep-performance ring becomes a liquid VESSEL filled to the performance fraction in the
                // rest tint, with the number counting up over it (the Today HeroScoreVessel idiom). Empty draws
                // a posed empty vessel, no number.
                LiquidVessel(
                    value = ((sleepPerformance ?: 0.0) / 100.0).coerceIn(0.0, 1.0),
                    tint = Palette.restColor,
                    animated = sleepPerformance != null,
                    modifier = Modifier.size(96.dp),
                )
                if (sleepPerformance != null) {
                    CountUpText(
                        value = sleepPerformance,
                        format = { it.roundToInt().toString() },
                        style = NoopType.number(26f, weight = FontWeight.Bold)
                            .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                        color = Color.White,
                        modifier = Modifier.clearAndSetSemantics {},
                    )
                }
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(uiString(R.string.l10n_coupled_screen_sleep_performance_4611539f), style = NoopType.overline, color = Palette.textSecondary)
                if (asleepMin != null && asleepMin > 0) {
                    Text(uiString(R.string.l10n_coupled_screen_hoursminutes_asleepmin_slept_732a5b21, hoursMinutes(asleepMin)), style = NoopType.headline, color = Palette.textPrimary)
                    Text(uiString(R.string.l10n_coupled_screen_hoursminutes_needmin_needed_7fc1eb15, hoursMinutes(needMin)), style = NoopType.subhead, color = Palette.textSecondary)
                } else {
                    Text(uiString(R.string.l10n_coupled_screen_no_sleep_tracked_last_night_cd0dd79e), style = NoopType.subhead, color = Palette.textSecondary)
                }
                if (bedWakeSpan != null) {
                    Text(bedWakeSpan, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// MARK: - Pure helpers (byte-identical formatting to the Swift CoupledView)

/** The header subtitle "Today, d MMM". */
private fun subtitleToday(): String =
    "Today, " + SimpleDateFormat("d MMM", Locale.getDefault()).format(Date())

/** "6h 42m" from a minutes count, for the slept-vs-needed read. Mirrors CoupledView.hoursMinutes EXACTLY. */
internal fun hoursMinutes(minutes: Double): String {
    val total = minutes.roundToInt().coerceAtLeast(0)
    return "${total / 60}h ${total % 60}m"
}

/**
 * The strain band word for a 0..1 fill fraction, byte-identical to the Swift StrandDesign StrainGauge bands
 * (LIGHT/MODERATE/STRENUOUS/HIGH/ALL-OUT at 6/10/14/18 of 21). The Android StrainGauge has no internal state
 * word, so the coupled strain card computes it for the overline.
 */
internal fun strainBandWord(fraction: Double): String = when {
    fraction < 6.0 / 21 -> "LIGHT"
    fraction < 10.0 / 21 -> "MODERATE"
    fraction < 14.0 / 21 -> "STRENUOUS"
    fraction < 18.0 / 21 -> "HIGH"
    else -> "ALL-OUT"
}

/**
 * The night's need (minutes): the imported per-day figure when the export carried one, else the shared
 * >= 7.5h personal-mean floor (matches SleepScreen needMin / SleepView.sleepNeedMin).
 */
private fun sleepNeedForDay(day: DailyMetric?, days: List<DailyMetric>, importedNeed: Map<String, Double>): Double {
    day?.day?.let { key -> importedNeed[key]?.takeIf { it > 0 }?.let { return it } }
    val banked = days.mapNotNull { it.totalSleepMin }.filter { it > 0 }
    val mean = if (banked.isEmpty()) null else banked.sum() / banked.size
    return maxOf(450.0, mean ?: 450.0) // 450 min = 7.5h
}

/**
 * Last night's bed -> wake span, from the day's bridged MAIN-night span ([mainSleepSpan], the SAME
 * resolver the Sleep tab hero and the daily total use), only when that night actually touches the last
 * 36h (a days-old import is not "last night"). Was previously this screen's own "freshest-ending
 * session" pick, which could name a different block -- and so a different span -- than the Sleep tab and
 * Today's HR graph for a night stored as more than one block (#294).
 */
private fun bedWakeSpan(sleeps: List<SleepSession>, habitualMidsleepSec: Long?): String? {
    val windowStart = System.currentTimeMillis() / 1000L - 36 * 3600L // within the last 36h counts as last night
    val candidates = sleeps.filter { it.endTs > windowStart }
    val span = mainSleepSpan(candidates, habitualMidsleepSec) ?: return null
    val fmt = SimpleDateFormat("HH:mm", Locale.getDefault())
    return "${fmt.format(Date(span.first * 1000L))} - ${fmt.format(Date(span.second * 1000L))}"
}

// MARK: - OPTIMAL strain range (task #43) — pure display-only recovery->strain mapping
//
// The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
// higher optimal band, a red day a lower one. PRESENTATION ONLY, never fed back into any score. These are
// the APPROVED bands and MUST stay byte-identical to the Swift CoupledView.optimalStrainRange:
//   recovery >= 67 (green)        -> 14-18 of 21
//   34 <= recovery <= 66 (yellow) -> 10-14
//   recovery < 34 (red)           -> 4-10
// null recovery (calibrating / unscored day) -> null, the caller renders the no-data token, never a
// guessed band.

internal data class OptimalStrainRange(val low: Int, val high: Int)

/** The pure recovery->optimal-strain band, or null when recovery is unknown. */
internal fun optimalStrainRange(recovery: Double?): OptimalStrainRange? {
    val r = recovery ?: return null
    return when {
        r >= 67 -> OptimalStrainRange(14, 18)
        r >= 34 -> OptimalStrainRange(10, 14)
        else -> OptimalStrainRange(4, 10)
    }
}

/** The optimal band as display text ("14 to 18" / the no-data token). Byte-identical to the Swift twin. */
internal fun optimalStrainRangeText(recovery: Double?): String {
    val band = optimalStrainRange(recovery) ?: return COUPLED_NO_DATA
    return "${band.low} to ${band.high}"
}
