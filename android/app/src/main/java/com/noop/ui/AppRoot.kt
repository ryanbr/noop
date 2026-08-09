package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Hexagon
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.automirrored.filled.Rule
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController

// MARK: - Navigation model
//
// The macOS app's sidebar holds many sections; on Android (mirroring the iOS RootTabView) we surface
// them through a unified floating "glass" bottom bar (Today · Trends · Sleep · More) for the everyday
// screens, with a "More" sheet that lists the full grouped set — so every destination is one tap away
// without a global hamburger/drawer. Destinations are grouped exactly as the sidebar groups them.
// Routes whose screens belong to later waves point at a ComingSoon placeholder so the app compiles today.

/** A single drawer destination: stable route, display title (localized via [titleRes]), sidebar icon. */
private enum class Destination(
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
    // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap vs import-only.
    NoopLimitations("noop_limitations", R.string.nav_noop_limitations, Icons.AutoMirrored.Filled.Rule),
    DataSources("data_sources", R.string.nav_data_sources, Icons.Filled.Storage),
    BackupSync("backup_sync", R.string.nav_backup_sync, Icons.Filled.CloudSync),
    FusedRecord("fused_record", R.string.nav_fused_record, Icons.AutoMirrored.Filled.CompareArrows),
    Notifications("notifications", R.string.nav_notifications, Icons.Filled.Notifications),
    Settings("settings", R.string.nav_settings, Icons.Filled.Settings),
    TestCentre("test_centre", R.string.nav_test_centre, Icons.Filled.BugReport),

    // The "More" tab: its own navigated page (mirroring the iOS More tab) that hosts the full
    // grouped destination list. It is NOT itself in any [DrawerGroup] — it's the door to them.
    More("more", R.string.nav_more, Icons.Filled.MoreHoriz);

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

/** More-page groups, mirroring the iOS More tab exactly: Insights · Body · Data · App. `defaultExpanded`
 *  mirrors the iOS S2 default: Insights + Body open at rest, Data + App collapsed to just their header. */
// [header] is the STABLE persistence key (stored in SharedPreferences and kept byte-identical to iOS's
// `more.expandedSections` CSV — see [MoreSectionPrefs]); it must NEVER be localized. [headerRes] is the
// localized DISPLAY label the More page shows. Decoupling the two lets the label translate without
// touching the persisted open/closed state or the iOS parity of the stored string.
private data class DrawerGroup(
    val header: String,
    @StringRes val headerRes: Int,
    val items: List<Destination>,
    val defaultExpanded: Boolean,
)

// Mirrors the iOS RootTabView `moreTab` grouping + order one-for-one. Today / Trends / Sleep are NOT
// listed (they're bottom-bar tabs, exactly as on iOS). Android-only screens (Vital Signs, Wake Window,
// Notifications, Devices) are slotted into the matching iOS group.
private val drawerGroups: List<DrawerGroup> = listOf(
    DrawerGroup("Insights", R.string.more_group_insights, listOf(
        Destination.InsightsHub, Destination.Intelligence, Destination.Coach,
        Destination.Insights, Destination.Explore, Destination.Compare,
    ), defaultExpanded = true),
    DrawerGroup("Body", R.string.more_group_body, listOf(
        Destination.Live, Destination.Workouts, Destination.Health, Destination.VitalSigns,
        Destination.LabBook, Destination.Stress, Destination.Breathe, Destination.Intervals,
        Destination.Rhythm,
    ), defaultExpanded = true),
    DrawerGroup("Data", R.string.more_group_data, listOf(
        Destination.FusedRecord, Destination.AppleHealth, Destination.DataSources,
        Destination.BackupSync, Destination.Devices, Destination.NoopLimitations,
    ), defaultExpanded = false),
    DrawerGroup("App", R.string.more_group_app, listOf(
        Destination.Automations, Destination.SmartAlarm, Destination.Notifications,
        Destination.TestCentre, Destination.Settings,
    ), defaultExpanded = false),
)

/** The headers open by default at first run, derived from [drawerGroups.defaultExpanded] (Insights +
 *  Body), so the seed lives in one place and the persistence default can't drift from the UI default. */
private fun defaultExpandedHeaders(): Set<String> =
    drawerGroups.filter { it.defaultExpanded }.map { it.header }.toSet()

/**
 * Persisted open/closed state of the More page's collapsible groups (#860 item 2) - the Android twin of
 * the iOS `MoreSectionPrefs`. The set of EXPANDED group headers is stored as one sorted comma-joined
 * string under a single SharedPreferences key, encoded identically to iOS (same `more.expandedSections`
 * suffix, same CSV-of-headers, same Insights+Body default) so the two platforms behave the same. An empty
 * stored string is a valid state (everything collapsed), distinct from "never set" (which yields the seed).
 */
internal object MoreSectionPrefs {
    const val KEY = "noop.more.expandedSections"

    /** Read the expanded-header set; returns [default] when the key was never written (first run). */
    fun read(prefs: android.content.SharedPreferences, default: Set<String>): Set<String> {
        val raw = prefs.getString(KEY, null) ?: return default
        return decode(raw)
    }

    /** Persist the expanded-header set as a sorted, comma-joined string. */
    fun write(prefs: android.content.SharedPreferences, headers: Set<String>) {
        prefs.edit().putString(KEY, encode(headers)).apply()
    }

    /** Encode the set of expanded headers to a sorted, comma-joined string. */
    fun encode(headers: Set<String>): String = headers.sorted().joinToString(",")

    /** Decode the stored string to a set of expanded headers; blank tokens dropped, empty string -> empty set. */
    fun decode(raw: String): Set<String> =
        raw.split(",").map { it.trim() }.filter { it.isNotEmpty() }.toSet()
}

/**
 * App shell: a single [Scaffold] with a floating [GlassBottomBar] (Today · Trends · Sleep · More)
 * driving one [NavHost], mirroring the iOS RootTabView. There is NO global toolbar and no nav drawer
 * — every screen self-titles via [ScreenScaffold], and the "More" sheet (opened from the bar) reaches
 * every destination in [drawerGroups], so nothing is lost. A single [AppViewModel] is created here and
 * shared with every screen, so the BLE connection and cached metrics stay app-wide singletons.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(viewModel: AppViewModel = viewModel()) {
    val nav = rememberNavController()

    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val current = Destination.forRoute(currentRoute)
    var showQuickActions by remember { mutableStateOf(false) }
    // The Updates inbox sheet (opened by the Today header bell). The store is a process singleton so
    // the Today cards and the import path post to the same inbox this sheet renders.
    val context = androidx.compose.ui.platform.LocalContext.current
    val updateStore = remember { UpdateStore.from(context) }
    var showUpdatesInbox by remember { mutableStateOf(false) }
    // #984: the changelog sheet a What's New inbox row opens. Held here (not inside the inbox) so it
    // survives the inbox sheet closing — the tap dismisses the inbox and presents this over the app.
    var showWhatsNewFromInbox by remember { mutableStateOf(false) }

    run {
        Scaffold(
            containerColor = Palette.surfaceBase,
            bottomBar = {
                // One unified "glass" bar: four evenly-spaced tabs — Today · Trends · Sleep · More
                // (matches the iOS FloatingTabBar). The quick-action "+" lives in the Today header's
                // top-right (balancing the avatar), so the bar is clean tabs only. "More" navigates to
                // its own page (mirroring the iOS More tab) that reaches every grouped destination, so no
                // destination is lost without the drawer.
                GlassBottomBar(
                    current = current,
                    onTabSelected = { dest ->
                        if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)
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
                        // The quick-action "+" lives in the Today header's top-right now (off the
                        // bottom bar) — it opens the same quick-action sheet the bar used to.
                        onQuickActions = { showQuickActions = true },
                        // The Updates "ringer" — the bell sits before the +, and opens the inbox
                        // sheet AppRoot presents (it owns the nav for deep-links).
                        updateStore = updateStore,
                        onOpenUpdates = { showUpdatesInbox = true },
                        // The leading profile avatar opens Settings (where the photo is set/changed),
                        // mirroring iOS's avatar-leading Today header. The drawer hamburger is unchanged.
                        onOpenSettings = { nav.navigateTopLevel(Destination.Settings.route) },
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
                composable(Destination.NoopLimitations.route) { NoopLimitationsScreen() }
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
                // The "More" page — the iOS More tab's twin: a navigated ScreenScaffold page hosting the
                // full grouped destination list (was a pull-up sheet). A row navigates top-level.
                composable(Destination.More.route) {
                    MoreScreen(onNavigate = { nav.navigateTopLevel(it) })
                }
            }
        }

        // Quick-actions sheet, opened by the raised gold centre FAB. Each row routes to an
        // existing destination — nothing new is built here, the FAB is just a faster door in.
        if (showQuickActions) {
            ModalBottomSheet(
                onDismissRequest = { showQuickActions = false },
                containerColor = Palette.surfaceRaised,
                contentColor = Palette.textPrimary,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp)
                        .padding(bottom = 24.dp),
                ) {
                    Overline(
                        "Quick actions",
                        modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp),
                        color = Palette.textTertiary,
                    )
                    // Updates inbox — relocated here off the Today header (the liquid Today header mirrors iOS,
                    // which has no notifications bell). The feature is fully intact and one tap away: this row
                    // opens the same inbox sheet, showing the unread count as a trailing badge.
                    NavigationDrawerItem(
                        selected = false,
                        onClick = {
                            showQuickActions = false
                            showUpdatesInbox = true
                        },
                        icon = { Icon(Icons.Filled.Notifications, contentDescription = null) },
                        label = { Text(uiString(R.string.l10n_app_root_updates_c76d1807), style = NoopType.body) },
                        badge = {
                            val unread = updateStore.unreadCount
                            if (unread > 0) {
                                Text(
                                    if (unread > 99) "99+" else unread.toString(),
                                    style = NoopType.captionNumber,
                                    color = Palette.statusCritical,
                                )
                            }
                        },
                        colors = NavigationDrawerItemDefaults.colors(
                            unselectedContainerColor = Palette.surfaceRaised,
                            unselectedIconColor = Palette.accent,
                            unselectedTextColor = Palette.textPrimary,
                        ),
                        modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                    )
                    quickActions.forEach { action ->
                        NavigationDrawerItem(
                            selected = false,
                            onClick = {
                                showQuickActions = false
                                if (action.route != currentRoute) {
                                    nav.navigateTopLevel(action.route)
                                }
                            },
                            icon = { Icon(action.icon, contentDescription = null) },
                            label = { Text(stringResource(action.titleRes), style = NoopType.body) },
                            colors = NavigationDrawerItemDefaults.colors(
                                unselectedContainerColor = Palette.surfaceRaised,
                                unselectedIconColor = Palette.accent,
                                unselectedTextColor = Palette.textPrimary,
                            ),
                            modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                        )
                    }
                }
            }
        }

        // The Updates inbox (opened by the Today header bell). Presented here so it has the nav for
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

// MARK: - More page
//
// The "More" tab's destination — a full navigated page (mirroring the iOS More tab's NavigationStack
// List), replacing the old pull-up ModalBottomSheet. It hosts the SAME grouped destinations
// ([drawerGroups]) inside a [ScreenScaffold], with the exact section-header + row styling the sheet
// used (uppercase [Overline] group labels, icon + label [NavigationDrawerItem] rows) — now with a
// trailing chevron so each row reads as a navigation push, matching the iOS disclosure rows. Tapping a
// row navigates top-level; there is no sheet to dismiss. The floating bottom bar stays visible because
// this is just another NavHost destination under the same Scaffold.

/** The full grouped destination list as a navigated page (the iOS More tab's twin). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MoreScreen(onNavigate: (String) -> Unit) {
    // S2 parity: each group's open/closed state, seeded from `defaultExpanded` (Insights + Body open,
    // Data + App collapsed). PERSISTED (#860 item 2): the user's open/closed choice must survive leaving
    // and re-entering the More page (and relaunch), not reset to the seed every visit. Backed by
    // [MoreSectionPrefs] (a CSV of expanded headers in SharedPreferences), mirroring the iOS
    // @AppStorage("more.expandedSections"). Seeded ONCE from the stored value so first run still shows the
    // Insights+Body default; every toggle writes through so the next visit reflects the saved state.
    val context = androidx.compose.ui.platform.LocalContext.current
    val expanded = remember {
        val stored = MoreSectionPrefs.read(NoopPrefs.of(context), defaultExpandedHeaders())
        androidx.compose.runtime.mutableStateMapOf<String, Boolean>().apply {
            drawerGroups.forEach { put(it.header, stored.contains(it.header)) }
        }
    }
    // Day-cycle sky backdrop + sky-behind-cards, the SAME two gates every other tab honours (Today /
    // Trends / Sleep / metric detail) — More was the one tab still on the flat canvas, so switching to
    // it visibly "lost" the theme. SharedPreferences isn't reactive; read once like the other tabs.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    ScreenScaffold(
        title = uiString(R.string.l10n_app_root_more_4bab2d8f),
        subtitle = "Everything else, one tap away",
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down.
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        // Mirror the iOS More page: each group is a tappable UPPERCASE overline header (with a disclosure
        // chevron) over a single grouped white NoopCard whose rows are tight (accent icon + title +
        // chevron) and separated by inset hairlines (NOT loose NavigationDrawerItems on the bare surface).
        drawerGroups.forEach { group ->
            val isOpen = expanded[group.header] ?: group.defaultExpanded
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                MoreGroupHeader(
                    title = stringResource(group.headerRes),
                    expanded = isOpen,
                    onToggle = {
                        expanded[group.header] = !isOpen
                        // Persist the new open set so the choice survives leaving + re-entering the page
                        // and relaunch (#860 item 2), mirroring the iOS @AppStorage write.
                        val open = drawerGroups.map { it.header }.filter { expanded[it] == true }.toSet()
                        MoreSectionPrefs.write(NoopPrefs.of(context), open)
                    },
                )
                if (isOpen) {
                    NoopCard(padding = 0.dp) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            group.items.forEachIndexed { i, dest ->
                                MoreRow(dest = dest, onClick = { onNavigate(dest.route) })
                                if (i < group.items.lastIndex) {
                                    HorizontalDivider(
                                        color = Palette.hairline,
                                        modifier = Modifier.padding(start = 50.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A tappable group header for the More page (S2): the same UPPERCASE [Overline] label as before, now
 *  with a trailing chevron that rotates between open (0deg) and closed (-90deg), mirroring the iOS
 *  collapsible More sections. Tapping toggles the group; the whole row is the tap target. */
@Composable
private fun MoreGroupHeader(title: String, expanded: Boolean, onToggle: () -> Unit) {
    val rotation by animateFloatAsState(
        targetValue = if (expanded) 0f else -90f,
        animationSpec = tween(durationMillis = 240, easing = NavEasing),
        label = uiString(R.string.l10n_app_root_moregroupchevron_b2b36ec6),
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onToggle)
            .semantics {
                contentDescription = title
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Overline(title, modifier = Modifier.weight(1f), color = Palette.textTertiary)
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier
                .size(Metrics.iconSmall)
                .rotate(rotation),
        )
    }
}

/** One tappable destination row in the More page — accent icon + title + trailing chevron in a
 *  comfortable tap target, mirroring the iOS MoreRow. */
@Composable
private fun MoreRow(dest: Destination, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(dest.icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(14.dp))
        Text(stringResource(dest.titleRes), style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
    }
}

// MARK: - Glass bottom bar
//
// The signature bar, ported from iOS's FloatingTabBar: ONE rounded "glass" island holding four
// evenly-spaced inline slots — Today · Trends · Sleep · More. The quick-action "+" now lives in the
// Today header's top-right (it left the bar to balance the avatar), so the bar is clean tabs only.
// The "glass" feel is a translucent raised surface with a low elevation and a subtle hairline border
// — frosted, not a hard opaque slab and not a glow. Each nav slot is an icon over a small label;
// active = gold accent, inactive = textSecondary. All routing is unchanged: the four tabs switch the
// same destinations.

/** A single bottom-bar nav slot: the destination it switches to, plus the bar-specific icon/label. */
private data class BarTab(val dest: Destination, val icon: ImageVector, @StringRes val labelRes: Int)

/** The nav slots in iOS order: Today · Trends · Sleep · More.
 *  More is special-cased (it opens the sheet rather than a route), so it is appended at the call site. */
private val barLeadingTabs = listOf(
    BarTab(Destination.Today, Icons.Outlined.GridView, R.string.nav_today),
    // chart.line.uptrend.xyaxis on iOS — the rising-trend glyph, not a flat bar chart.
    BarTab(Destination.Trends, Icons.AutoMirrored.Filled.TrendingUp, R.string.nav_trends),
)
private val barTrailingTabs = listOf(
    BarTab(Destination.Sleep, Icons.Filled.Bedtime, R.string.nav_sleep),
)

@Composable
private fun GlassBottomBar(
    current: Destination,
    onTabSelected: (Destination) -> Unit,
) {
    val barShape = RoundedCornerShape(50)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            // Clear the gesture-nav bar (home indicator) first, then add breathing room so the capsule
            // floats free of the bottom edge rather than jamming against it — iOS clears the home-indicator
            // safe area + 4pt; here navigationBarsPadding + 12dp gives the same lift.
            .navigationBarsPadding()
            .padding(horizontal = 22.dp)
            .padding(top = 4.dp, bottom = Metrics.space12),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            shape = barShape,
            // "Glass": a translucent raised surface — a frosted island, not a hard slab. Compose has no
            // cheap blur, so translucency (≈0.80) + a hairline rim is the Liquid-Glass stand-in. A soft,
            // low drop shadow reads as floating without a glow.
            color = Palette.surfaceRaised.copy(alpha = 0.80f),
            tonalElevation = 2.dp,
            shadowElevation = 4.dp,
            modifier = Modifier
                .fillMaxWidth()
                // Cap the width so the pill stays a centred floating island on tablets, not a full-bleed bar.
                .widthIn(max = 480.dp)
                .border(0.5.dp, Palette.hairline.copy(alpha = 0.6f), barShape),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                barLeadingTabs.forEach { tab ->
                    BarSlot(
                        icon = tab.icon,
                        label = stringResource(tab.labelRes),
                        active = current == tab.dest,
                        modifier = Modifier.weight(1f),
                        onClick = { onTabSelected(tab.dest) },
                    )
                }
                barTrailingTabs.forEach { tab ->
                    BarSlot(
                        icon = tab.icon,
                        label = stringResource(tab.labelRes),
                        active = current == tab.dest,
                        modifier = Modifier.weight(1f),
                        onClick = { onTabSelected(tab.dest) },
                    )
                }
                BarSlot(
                    icon = Icons.Filled.MoreHoriz,
                    label = stringResource(R.string.nav_more),
                    // Selected on the More page itself, and also kept lit whenever the current screen is
                    // one reached THROUGH More (i.e. not one of the bar's own three tabs) — so drilling
                    // into any grouped destination still reads as "you're in More", never "nowhere".
                    active = current != Destination.Today && current != Destination.Trends &&
                        current != Destination.Sleep,
                    modifier = Modifier.weight(1f),
                    onClick = { onTabSelected(Destination.More) },
                )
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
            .clip(RoundedCornerShape(14.dp))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(vertical = 3.dp)
            .semantics { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(Metrics.iconSmall))
        Text(
            label,
            style = NoopType.footnote.copy(
                fontSize = 10.sp,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
        )
    }
}

/** A centre-FAB quick action: a display title, an icon and the destination route it opens. */
private data class QuickAction(@StringRes val titleRes: Int, val icon: ImageVector, val route: String)

/** The quick actions on the gold centre FAB, each routing to an existing destination. Live HR leads
 *  — it moved off the bottom bar (so the FAB no longer overlaps a tab) but stays one tap away here. */
private val quickActions: List<QuickAction> = listOf(
    QuickAction(R.string.action_live_hr, Destination.Live.icon, Destination.Live.route),
    QuickAction(R.string.action_start_workout, Icons.Filled.FitnessCenter, Destination.Workouts.route),
    QuickAction(R.string.action_log_journal, Icons.Filled.Edit, Destination.Insights.route),
    QuickAction(R.string.action_breathe, Icons.Filled.Air, Destination.Breathe.route),
)

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
