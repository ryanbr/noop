package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Hexagon
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.noop.R
import com.noop.analytics.FusionSource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController

// MARK: - Navigation model
//
// Android mirrors the iOS shell: three primary roots in a split glass bottom bar, with every secondary
// destination grouped in the adjacent Quick Launch panel. Routes remain stable and unlocalized.
// Routes whose screens belong to later waves point at a ComingSoon placeholder so the app compiles today.

/** A navigation destination: stable route, localized display title, and reusable icon. */
internal enum class Destination(
    val route: String,
    @StringRes val titleRes: Int,
    val icon: ImageVector,
) {
    // Group: Today
    Today("today", R.string.nav_today, Icons.Filled.Home),
    Intelligence("intelligence", R.string.nav_intelligence, Icons.Filled.Psychology),
    // Optional, default-OFF (task #43): the Coupled view (WHOOP-style day read). Reached ONLY via the
    // Today dashboard "Coupled view" card tap-through, so it is deliberately NOT in any [DrawerGroup].
    CoupledView("coupled_view", R.string.nav_coupled_view, Icons.Filled.Hexagon),

    // Group: Live
    Live("live", R.string.nav_live, Icons.Filled.FavoriteBorder),
    Intervals("intervals", R.string.nav_intervals, Icons.Filled.Timeline),

    // Group: Recovery
    Sleep("sleep", R.string.nav_sleep, Icons.Filled.Bedtime),
    Breathe("breathe", R.string.nav_breathe, Icons.Filled.Air),
    Stress("stress", R.string.nav_stress, Icons.Filled.Spa),

    // Group: Activity
    Workouts("workouts", R.string.nav_workouts, Icons.Filled.FitnessCenter),
    Trends("trends", R.string.nav_trends, Icons.AutoMirrored.Filled.TrendingUp),

    // Group: Insight
    Coach("coach", R.string.nav_coach, Icons.Filled.AutoAwesome),
    InsightsHub("insights_hub", R.string.nav_insights_hub, Icons.Filled.Insights),
    Insights("insights", R.string.nav_insights, Icons.Filled.Insights),
    Explore("explore", R.string.nav_explore, Icons.Filled.Explore),
    Compare("compare", R.string.nav_compare, Icons.AutoMirrored.Filled.CompareArrows),

    // Group: Health
    Health("health", R.string.nav_health, Icons.Filled.MonitorHeart),
    Hydration("hydration", R.string.nav_hydration, Icons.Filled.WaterDrop),
    VitalSigns("vital_signs", R.string.nav_vital_signs, Icons.Filled.HealthAndSafety),
    VitalSignsDetail("vital_detail/{key}", R.string.nav_vital_signs, Icons.Filled.HealthAndSafety),
    LabBook("lab_book", R.string.nav_lab_book, Icons.Filled.HealthAndSafety),
    Rhythm("rhythm", R.string.nav_rhythm, Icons.Filled.MonitorHeart),
    AppleHealth("apple_health", R.string.nav_apple_health, Icons.Filled.HealthAndSafety),

    // Group: System
    Automations("automations", R.string.nav_automations, Icons.Filled.Bolt),
    // "Alarms" is the ONE alarm surface (#766): the phone-based Wake Window (light-sleep detection with a
    // guaranteed OS backup), the strap's own firmware wake-alarm, and the wind-down reminder, all in one
    // place. Previously "Wake Window" (#730), but the strap alarm moved in from Automations so the broader
    // name fits. Route id stays "smart_alarm" (display string only).
    SmartAlarm("smart_alarm", R.string.nav_alarms, Icons.Filled.Alarm),
    Devices("devices", R.string.nav_devices, Icons.Filled.Sensors),
    DataSources("data_sources", R.string.nav_data_sources, Icons.Filled.Storage),
    BackupSync("backup_sync", R.string.nav_backup_sync, Icons.Filled.CloudSync),
    FusedRecord("fused_record", R.string.nav_fused_record, Icons.AutoMirrored.Filled.CompareArrows),
    Notifications("notifications", R.string.nav_notifications, Icons.Filled.Notifications),
    Settings("settings", R.string.nav_settings, Icons.Filled.Settings),
    TestCentre("test_centre", R.string.nav_test_centre, Icons.Filled.BugReport);

    companion object {
        /** Resolve the destination owning the current back-stack route (defaults to Today). */
        fun forRoute(route: String?): Destination =
            entries.firstOrNull {
                // Match parameterised routes (e.g. "vital_detail/rhr" vs "vital_detail/{key}") by
                // base path so the top-bar title resolves correctly on a detail screen, not "Today".
                it.route == route || it.route.substringBefore('/') == route?.substringBefore('/')
            } ?: Today
    }
}

/**
 * App shell: a three-tab floating bar plus the modal Quick Launch replacement for More. Quick Launch
 * preserves every former More destination and adds persistent, rearrangeable favourites.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(viewModel: AppViewModel = viewModel()) {
    val nav = rememberNavController()

    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val current = Destination.forRoute(currentRoute)
    var showQuickLaunch by remember { mutableStateOf(false) }
    // The process singleton keeps Today cards and imports posting to the same Updates inbox that
    // Quick Launch presents.
    val context = androidx.compose.ui.platform.LocalContext.current
    val updateStore = remember { UpdateStore.from(context) }
    var showUpdatesInbox by remember { mutableStateOf(false) }
    // #984: the changelog sheet a What's New inbox row opens. Held here (not inside the inbox) so it
    // survives the inbox sheet closing — the tap dismisses the inbox and presents this over the app.
    var showWhatsNewFromInbox by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = Palette.surfaceBase,
            bottomBar = {
                GlassBottomBar(
                    current = current,
                    panelOpen = showQuickLaunch,
                    onTabSelected = { dest ->
                        if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)
                    },
                    onTogglePanel = { showQuickLaunch = !showQuickLaunch },
                    onOpenCoach = {
                        showQuickLaunch = false
                        if (Destination.Coach.route != currentRoute) {
                            nav.navigateTopLevel(Destination.Coach.route)
                        }
                    },
                )
            },
        ) { inner ->
            NavHost(
                navController = nav,
                startDestination = Destination.Today.route,
                modifier = Modifier.padding(inner),
                // README motion: top-level destinations crossfade (~240ms) on the calm,
                // decelerating global easing — nothing slides or bounces between tabs. The
                // same fade is used for back (pop) so the bar never feels jerky. Drill-ins
                // (e.g. vital_detail) are pushed by the same NavHost, so they inherit the
                // same restrained crossfade rather than a hard cut.
                enterTransition = { fadeIn(navFadeSpec) },
                exitTransition = { fadeOut(navFadeSpec) },
                popEnterTransition = { fadeIn(navFadeSpec) },
                popExitTransition = { fadeOut(navFadeSpec) },
            ) {
                // --- Live, working screens (existing waves) ---
                composable(Destination.Today.route) {
                    TodayScreen(
                        viewModel = viewModel,
                        updateStore = updateStore,
                        // The opt-in Hydration card (only shown when Hydration tracking is on) pushes its
                        // detail. A normal push so the back-stack returns to Today.
                        onOpenHydration = { nav.navigate(Destination.Hydration.route) },
                        // #706/#684: the dashboard cards draw a tappable chevron; wire each to its detail,
                        // matching iOS. Stress + the vitals are pushes; Sleep is a top-level tab switch.
                        onOpenStress = { nav.navigate(Destination.Stress.route) },
                        onOpenHealth = { nav.navigate(Destination.Health.route) },
                        // Every metric/vital card opens its OWN focused detail trend (vital_detail/<key>),
                        // not the shared Health hub (2026-07-03). Mirrors the iOS liquidCard metricDetail.
                        onOpenMetric = { key -> nav.navigate("vital_detail/$key") },
                        onOpenSleep = { nav.navigateTopLevel(Destination.Sleep.route) },
                        // Optional Coupled view card (task #43): a normal push so back returns to Today.
                        onOpenCoupled = { nav.navigate(Destination.CoupledView.route) },
                        // The "workout in progress" indicator: raise the one-shot the Live screen consumes to
                        // re-open the in-exercise overlay, then route to Live. One tap from Today (iOS parity).
                        onOpenActiveWorkout = {
                            viewModel.openActiveWorkout()
                            nav.navigate(Destination.Live.route)
                        },
                        // The liquid header's strap battery ring taps through to Devices (iOS parity: the
                        // battery ring → router.openDevices()).
                        onOpenDevices = { nav.navigateTopLevel(Destination.Devices.route) },
                        // #627: the journal-reminder card opens the journal (hosted in Insights), same
                        // destination the Sleep screen's morning sheet uses.
                        onOpenJournal = { nav.navigateTopLevel(Destination.Insights.route) },
                    )
                }
                composable(Destination.Live.route) {
                    LiveScreen(
                        viewModel = viewModel,
                        onManageDevices = { nav.navigateTopLevel(Destination.Devices.route) },
                    )
                }
                composable(Destination.Sleep.route) {
                    SleepScreen(
                        vm = viewModel,
                        onOpenJournal = { nav.navigateTopLevel(Destination.Insights.route) },
                    )
                }
                composable(Destination.CoupledView.route) {
                    CoupledScreen(
                        vm = viewModel,
                        // Tapping Sleep in the coupled read opens the full Sleep screen (iOS parity).
                        onOpenSleep = { nav.navigateTopLevel(Destination.Sleep.route) },
                    )
                }
                composable(Destination.Intervals.route) { IntervalsScreen(viewModel) }
                composable(Destination.Breathe.route) { BreatheScreen(viewModel) }
                composable(Destination.Coach.route) { CoachScreen() }
                composable(Destination.Explore.route) { TrendsExploreScreen(viewModel) }
                composable(Destination.Automations.route) { AutomationsScreen(viewModel) }
                composable(Destination.SmartAlarm.route) { SmartAlarmScreen(viewModel) }
                composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }
                composable(Destination.Intelligence.route) { IntelligenceScreen(viewModel) }

                // --- Placeholder routes (later waves fill these in) ---
                composable(Destination.Stress.route) {
                    StressScreen(
                        vm = viewModel,
                        onBreathe = { nav.navigateTopLevel(Destination.Breathe.route) },
                    )
                }
                composable(Destination.Trends.route) { TrendsScreen(viewModel) }
                composable(Destination.Insights.route) { InsightsScreen(viewModel, onOpenInsightsHub = { nav.navigateTopLevel(Destination.InsightsHub.route) }) }
                composable(Destination.Compare.route) { CompareScreen(viewModel) }
                composable(Destination.Health.route) {
                    HealthScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                        onOpenLabBook = { nav.navigateTopLevel(Destination.LabBook.route) },
                        onOpenFusedRecord = { nav.navigateTopLevel(Destination.FusedRecord.route) },
                    )
                }
                composable(Destination.Hydration.route) { HydrationScreen(viewModel) }
                composable(Destination.VitalSigns.route) {
                    VitalSignsScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                    )
                }
                composable(Destination.VitalSignsDetail.route) { backStackEntry ->
                    VitalDetailScreen(
                        vm = viewModel,
                        key = backStackEntry.arguments?.getString("key").orEmpty(),
                    )
                }
                // --- v5 pillar screens (Wave 3 wiring) ---
                composable(Destination.InsightsHub.route) { InsightsHubScreen(viewModel) }
                composable(Destination.LabBook.route) { LabBookScreen(viewModel) }
                composable(Destination.Rhythm.route) {
                    // EXPERIMENTAL: self-gates on its own consent clickwrap (default OFF). The night
                    // summary + per-window Poincaré results land with the rhythm capture pipeline; until
                    // then it renders its honest "no clear reading yet" empty state behind the gate.
                    RhythmScreen(night = null, windows = emptyList())
                }
                composable(Destination.FusedRecord.route) { FusedRecordRoute(viewModel) }
                composable(Destination.AppleHealth.route) { AppleHealthScreen(viewModel) }
                composable(Destination.Devices.route) {
                    DevicesScreen(
                        viewModel,
                        onUseFileImport = { nav.navigateTopLevel(Destination.DataSources.route) },
                    )
                }
                composable(Destination.DataSources.route) { DataSourcesScreen(viewModel) }
                composable(Destination.BackupSync.route) { BackupSyncScreen() }
                composable(Destination.Notifications.route) { NotificationsSettingsScreen(viewModel) }
                composable(Destination.Settings.route) {
                    SettingsScreen(
                        viewModel,
                        onOpenTestCentre = { nav.navigate(Destination.TestCentre.route) },
                        onOpenBackupSync = { nav.navigate(Destination.BackupSync.route) },
                    )
                }
                composable(Destination.TestCentre.route) { TestCentreScreen(viewModel) }
            }
        }

        // This full-screen layer is deliberately above both Scaffold content and the bottom bar. It makes
        // every outside tap dismiss Quick Launch and prevents accidental navigation through the backdrop.
        if (showQuickLaunch) {
            val closeDescription = stringResource(R.string.quick_launch_close_menu)
            val panelBottomClearance = Metrics.quickLaunchPanelBottomClearance +
                Metrics.quickLaunchBottomBarFontExpansion *
                (LocalDensity.current.fontScale - 1f).coerceAtLeast(0f)
            Dialog(
                onDismissRequest = { showQuickLaunch = false },
                properties = DialogProperties(
                    dismissOnClickOutside = false,
                    usePlatformDefaultWidth = false,
                ),
            ) {
                Box(Modifier.fillMaxSize()) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Palette.surfaceBase.copy(alpha = 0.02f))
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { showQuickLaunch = false },
                            )
                            .semantics { contentDescription = closeDescription },
                    )
                    QuickLaunchPanel(
                        onDismiss = { showQuickLaunch = false },
                        onLaunch = { item ->
                            showQuickLaunch = false
                            when (item.action) {
                                QuickLaunchAction.Updates -> showUpdatesInbox = true
                                null -> item.destination?.let { destination ->
                                    if (destination.route != currentRoute) {
                                        nav.navigateTopLevel(destination.route)
                                    }
                                }
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .navigationBarsPadding()
                            .padding(horizontal = Metrics.quickLaunchPanelHorizontalInset)
                            .padding(bottom = panelBottomClearance),
                    )
                }
            }
        }

        // The Updates inbox (opened from Quick Launch). Presented here so it has the nav for
        // deep-links — a row's "trends" key switches the bottom tab, mirroring the iOS NavRouter route.
        if (showUpdatesInbox) {
            ModalBottomSheet(
                onDismissRequest = { showUpdatesInbox = false },
                // Open full-height (no half-pull) so it reads like the iOS Updates sheet, and use the
                // BEIGE surfaceBase so the white NoopCards POP — surfaceRaised made white cards sit on a
                // white sheet (no contrast), which is why the Android inbox looked flat vs iOS.
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = Palette.surfaceBase,
                contentColor = Palette.textPrimary,
            ) {
                UpdatesInboxScreen(
                    store = updateStore,
                    onClose = { showUpdatesInbox = false },
                    onDeepLink = { key ->
                        // Map the inbox deep-link key to a route (only known keys route); unknown keys
                        // just close the sheet.
                        //
                        // #984: What's New is NOT a nav destination — it is a full-screen sheet, the same
                        // one Settings › About opens — so it gets handled here rather than through the
                        // route table. Before this it fell to `else` and the tap did nothing at all.
                        if (key == UpdateStore.WHATS_NEW_DEEP_LINK) {
                            showWhatsNewFromInbox = true
                        } else {
                            val route = when (key) {
                                "trends" -> Destination.Trends.route
                                else -> null
                            }
                            if (route != null && route != currentRoute) nav.navigateTopLevel(route)
                        }
                    },
                    onRestore = { cardId ->
                        // Flip the shared dismissed flag back off so the card reappears, and signal a
                        // mounted Today to re-read it immediately (SharedPreferences isn't reactive).
                        TodayCardDismissal.setDismissed(context, cardId, false)
                        updateStore.restoreRequest = cardId
                    },
                )
            }
        }

        // #984: the changelog a What's New inbox row opens. Full-screen Dialog, the same idiom
        // Settings > About uses for this sheet — What's New is not a nav destination, so it cannot be
        // reached through the route table the other deep-link keys use.
        if (showWhatsNewFromInbox) {
            Dialog(
                onDismissRequest = { showWhatsNewFromInbox = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                    WhatsNewSheet(onClose = { showWhatsNewFromInbox = false })
                }
            }
        }
    }
}

// MARK: - Glass bottom bar
//
// iOS parity: a three-tab glass pill and a separate circular Quick Launch control. Both islands use the
// same material, border and elevation so the control reads as part of the navigation bar.

/** A single bottom-bar nav slot: the destination it switches to, plus the bar-specific icon/label. */
private data class BarTab(val dest: Destination, val icon: ImageVector, @StringRes val labelRes: Int)

/** The three persistent navigation roots, in iOS order. */
private val barTabs = listOf(
    BarTab(Destination.Today, Icons.Outlined.GridView, R.string.nav_today),
    BarTab(Destination.Trends, Icons.AutoMirrored.Filled.TrendingUp, R.string.nav_trends),
    BarTab(Destination.Sleep, Icons.Filled.Bedtime, R.string.nav_sleep),
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GlassBottomBar(
    current: Destination,
    panelOpen: Boolean,
    onTabSelected: (Destination) -> Unit,
    onTogglePanel: () -> Unit,
    onOpenCoach: () -> Unit,
) {
    val barShape = RoundedCornerShape(Metrics.cornerPill)
    val materialColor = Palette.surfaceRaised.copy(alpha = Metrics.quickLaunchGlassAlpha)
    val haptics = LocalHapticFeedback.current
    val controlDescription = stringResource(
        if (panelOpen) R.string.quick_launch_close_menu else R.string.quick_launch_open_menu,
    )
    Box(
        modifier = Modifier
            .fillMaxWidth()
            // Clear the gesture-nav bar (home indicator) first, then add breathing room so the capsule
            // floats free of the bottom edge rather than jamming against it — iOS clears the home-indicator
            // safe area + 4pt; here navigationBarsPadding + 12dp gives the same lift.
            .navigationBarsPadding()
            .padding(horizontal = Metrics.quickLaunchPanelHorizontalInset)
            .padding(top = Metrics.space4, bottom = Metrics.space12),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = Metrics.quickLaunchPanelMaxWidth),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        ) {
            Surface(
                shape = barShape,
                color = materialColor,
                tonalElevation = Metrics.quickLaunchGlassTonalElevation,
                shadowElevation = Metrics.quickLaunchGlassShadowElevation,
                modifier = Modifier
                    .weight(1f)
                    .border(Metrics.divider, Palette.hairlineStrong, barShape),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = Metrics.space8,
                            vertical = Metrics.quickLaunchBottomBarVerticalPadding,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    barTabs.forEach { tab ->
                        BarSlot(
                            icon = tab.icon,
                            label = stringResource(tab.labelRes),
                            active = current == tab.dest,
                            modifier = Modifier.weight(1f),
                            onClick = { onTabSelected(tab.dest) },
                        )
                    }
                }
            }
            Surface(
                shape = CircleShape,
                color = materialColor,
                tonalElevation = Metrics.quickLaunchGlassTonalElevation,
                shadowElevation = Metrics.quickLaunchGlassShadowElevation,
                modifier = Modifier
                    .size(Metrics.quickLaunchBottomBarButton)
                    .border(Metrics.divider, Palette.hairlineStrong, CircleShape)
                    .clip(CircleShape)
                    .combinedClickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        role = Role.Button,
                        onClick = onTogglePanel,
                        onLongClickLabel = stringResource(R.string.nav_coach),
                        onLongClick = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            onOpenCoach()
                        },
                    )
                    .semantics { contentDescription = controlDescription },
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        if (panelOpen) Icons.Filled.Close else Icons.Filled.Add,
                        contentDescription = null,
                        tint = if (panelOpen) Palette.accent else Palette.textSecondary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
        }
    }
}

/** One nav slot: an icon over a small label. Active = gold accent (semibold), inactive = textSecondary.
 *  No selection pill, no glow — just the colour swap, matching the iOS bar. */
@Composable
private fun BarSlot(
    icon: ImageVector,
    label: String,
    active: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tint = if (active) Palette.accent else Palette.textSecondary
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(vertical = Metrics.space2)
            .semantics { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space2),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(Metrics.iconSmall))
        Text(
            label,
            style = NoopType.footnote.copy(
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
        )
    }
}

// MARK: - Navigation motion (README §Motion)
//
// The global easing is the calm, decelerating cubic-bezier(0.22, 1, 0.36, 1) — nothing
// bounces or overshoots. Top-level destination switches crossfade over ~240ms (README
// "Tab crossfade"); the same spec drives back navigation so the bar never feels jerky.

/** The calm global easing curve from the handoff (cubic-bezier 0.22, 1, 0.36, 1). */
private val NavEasing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

/** ~240ms crossfade on the calm easing — the README "Tab crossfade" between roots. */
private val navFadeSpec = tween<Float>(durationMillis = 240, easing = NavEasing)

/**
 * BrandMark — the NOOP logo glyph at a small in-app size: an OPEN recovery ring (≈80%
 * arc, round caps, starting at −90° / 12 o'clock, clockwise) in the gold gradient with a
 * solid gold core dot at the centre. This is the same brand glyph the RecoveryRing hero
 * carries (the "O" of NOOP), shrunk for the top bar / drawer header so the logo reads in
 * app. CLEAN/flat per the v3 restraint brief — no bloom, no halo, just the gradient ring.
 * Token-only (gold gradient + hairline track); decorative, so it carries no content label.
 */
@Composable
internal fun BrandMark(size: Dp = 22.dp) {
    Canvas(modifier = Modifier.size(size)) {
        val stroke = this.size.minDimension * 0.13f          // ~2px-equivalent at 22dp
        val radius = (this.size.minDimension - stroke) / 2f
        val topLeft = Offset(center.x - radius, center.y - radius)
        val arcSize = Size(radius * 2f, radius * 2f)
        val capStroke = Stroke(width = stroke, cap = StrokeCap.Round)

        // Faint full-ring track (navy hairline) behind the open arc.
        drawCircle(
            color = Palette.hairline.copy(alpha = 0.5f),
            radius = radius,
            center = center,
            style = capStroke,
        )
        // Open recovery-ring arc: ~80% (288°), −90° start (12 o'clock), clockwise.
        drawArc(
            color = Palette.chargeColor,
            startAngle = -90f,
            sweepAngle = 288f,
            useCenter = false,
            topLeft = topLeft,
            size = arcSize,
            style = capStroke,
        )
        // Solid WHITE "on-device core" dot at the centre (green ring + white core — iOS parity, no gold).
        drawCircle(color = Color.White, radius = stroke * 0.62f, center = center)
    }
}

/** Navigate to a top-level destination with single-top + state save/restore. */
private fun NavHostController.navigateTopLevel(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

/**
 * Loader for the v5 "Your Data, Fused" screen: assembles today's [FusedRecord] off the repository via
 * [AppViewModel.fusedRecordForToday] (the pure FusionResolver per metric) and hands the pure
 * [FusedRecordScreen] its read-model. Keeps the screen itself I/O-free + previewable. Re-loads on entry.
 */
@Composable
private fun FusedRecordRoute(viewModel: AppViewModel) {
    var record by remember {
        mutableStateOf(FusedRecord(rows = emptyList(), dayOwner = null as FusionSource?, contributingSourceCount = 0))
    }
    LaunchedEffect(Unit) {
        record = runCatching { viewModel.fusedRecordForToday() }.getOrDefault(record)
    }
    FusedRecordScreen(record = record)
}

/**
 * Placeholder screen for routes later waves will build. Uses [ScreenScaffold] so the
 * dark, instrument-grade chrome is already correct when a real screen replaces it.
 */
@Composable
fun ComingSoon(text: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        NoopCard(padding = 28.dp) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Filled.Sensors,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                )
                Spacer(Modifier.height(4.dp))
                Text(text, style = NoopType.title2, color = Palette.textPrimary, textAlign = TextAlign.Center)
                Overline("Coming soon", color = Palette.textSecondary)
                Text(
                    uiString(R.string.l10n_app_root_this_section_is_on_the_way_ca7c4a32),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
