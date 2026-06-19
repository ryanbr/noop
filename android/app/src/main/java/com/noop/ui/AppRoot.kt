package com.noop.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.noop.analytics.FusionSource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.launch

// MARK: - Navigation model
//
// The macOS app's sidebar holds many sections; on Android we mirror that with a
// ModalNavigationDrawer (hamburger in the top bar) for the full grouped list, plus a
// bottom NavigationBar for the four everyday screens (Today/Trends/Live/Sleep) with a
// "More" sheet that reuses the same groups — both routes reach every destination.
// Destinations are grouped exactly as the sidebar groups them. Routes whose screens
// belong to later waves point at a ComingSoon placeholder so the app compiles today.

/** A single drawer destination: stable route, display title, sidebar icon. */
private enum class Destination(
    val route: String,
    val title: String,
    val icon: ImageVector,
) {
    // Group: Today
    Today("today", "Today", Icons.Filled.Home),
    Intelligence("intelligence", "Intelligence", Icons.Filled.Psychology),

    // Group: Live
    Live("live", "Live", Icons.Filled.FavoriteBorder),
    Intervals("intervals", "Intervals", Icons.Filled.Timeline),

    // Group: Recovery
    Sleep("sleep", "Sleep", Icons.Filled.Bedtime),
    Breathe("breathe", "Breathe", Icons.Filled.Air),
    Stress("stress", "Stress", Icons.Filled.Spa),

    // Group: Activity
    Workouts("workouts", "Workouts", Icons.Filled.FitnessCenter),
    Trends("trends", "Trends", Icons.AutoMirrored.Filled.TrendingUp),

    // Group: Insight
    Coach("coach", "Coach", Icons.Filled.AutoAwesome),
    InsightsHub("insights_hub", "What Moves You", Icons.Filled.Insights),
    Insights("insights", "Insights", Icons.Filled.Insights),
    Explore("explore", "Explore", Icons.Filled.Explore),
    Compare("compare", "Compare", Icons.AutoMirrored.Filled.CompareArrows),

    // Group: Health
    Health("health", "Health", Icons.Filled.MonitorHeart),
    VitalSigns("vital_signs", "Vital Signs", Icons.Filled.HealthAndSafety),
    VitalSignsDetail("vital_detail/{key}", "Vital Signs", Icons.Filled.HealthAndSafety),
    LabBook("lab_book", "Lab Book", Icons.Filled.HealthAndSafety),
    Rhythm("rhythm", "Rhythm", Icons.Filled.MonitorHeart),
    AppleHealth("apple_health", "Apple Health", Icons.Filled.HealthAndSafety),

    // Group: System
    Automations("automations", "Automations", Icons.Filled.Bolt),
    SmartAlarm("smart_alarm", "Smart Alarm", Icons.Filled.Alarm),
    Devices("devices", "Devices", Icons.Filled.Sensors),
    DataSources("data_sources", "Data Sources", Icons.Filled.Storage),
    FusedRecord("fused_record", "Your Data, Fused", Icons.AutoMirrored.Filled.CompareArrows),
    Notifications("notifications", "Notifications", Icons.Filled.Notifications),
    Support("support", "Support", Icons.Filled.Tune),
    Settings("settings", "Settings", Icons.Filled.Settings);

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

/** Sidebar groups, mirroring the macOS section ordering. */
private data class DrawerGroup(val header: String, val items: List<Destination>)

private val drawerGroups: List<DrawerGroup> = listOf(
    DrawerGroup("Overview", listOf(Destination.Today, Destination.Intelligence)),
    DrawerGroup("Live", listOf(Destination.Live, Destination.Intervals)),
    DrawerGroup("Charge", listOf(Destination.Sleep, Destination.Breathe, Destination.Stress)),
    DrawerGroup("Activity", listOf(Destination.Workouts, Destination.Trends)),
    DrawerGroup("Insight", listOf(
        Destination.Coach, Destination.InsightsHub, Destination.Insights,
        Destination.Explore, Destination.Compare,
    )),
    DrawerGroup("Health", listOf(
        Destination.Health, Destination.VitalSigns, Destination.LabBook,
        Destination.Rhythm, Destination.AppleHealth,
    )),
    DrawerGroup("System", listOf(
        Destination.Automations, Destination.SmartAlarm, Destination.Devices, Destination.DataSources,
        Destination.FusedRecord, Destination.Notifications, Destination.Support, Destination.Settings,
    )),
)

/** The everyday screens that earn a permanent bottom tab. Three tabs + a "More" item flank the
 *  raised centre FAB so it sits in a real gap (between Trends and Sleep) rather than on top of a
 *  tab. Live (real-time HR) is a "watch it now" action — it lives on the FAB's quick-action sheet
 *  and in the drawer, not on the bar. */
private val bottomTabs = listOf(
    Destination.Today, Destination.Trends, Destination.Sleep,
)

/**
 * App shell: a bottom [NavigationBar] (Today/Trends/Live/Sleep + a "More" sheet) and a
 * [ModalNavigationDrawer] (hamburger in a [TopAppBar] titled with the current screen),
 * both driving one [NavHost]. A single [AppViewModel] is created here and shared with
 * every screen, so the BLE connection and cached metrics stay app-wide singletons.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(viewModel: AppViewModel = viewModel()) {
    val nav = rememberNavController()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()

    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val current = Destination.forRoute(currentRoute)
    var showMoreSheet by remember { mutableStateOf(false) }
    var showQuickActions by remember { mutableStateOf(false) }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(
                drawerContainerColor = Palette.surfaceRaised,
                drawerContentColor = Palette.textPrimary,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 12.dp, vertical = 16.dp),
                ) {
                    // Drawer header: brand glyph beside the "Strand · Instrument" lockup so the
                    // logo reads at the top of the navigation, matching the in-app top bar.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(start = 16.dp, top = 2.dp, bottom = 12.dp),
                    ) {
                        BrandMark(size = 22.dp)
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Overline(
                                "Strand",
                                modifier = Modifier.padding(bottom = 4.dp),
                                color = Palette.accent,
                            )
                            Text(
                                "Instrument",
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                    }

                    drawerGroups.forEachIndexed { index, group ->
                        if (index > 0) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                        Overline(
                            group.header,
                            modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp),
                            color = Palette.textTertiary,
                        )
                        group.items.forEach { dest ->
                            val selected = backStack?.destination?.hierarchy
                                ?.any { it.route == dest.route } == true
                            NavigationDrawerItem(
                                selected = selected,
                                onClick = {
                                    scope.launch { drawerState.close() }
                                    if (dest.route != currentRoute) {
                                        nav.navigateTopLevel(dest.route)
                                    }
                                },
                                icon = { Icon(dest.icon, contentDescription = null) },
                                label = { Text(dest.title, style = NoopType.body) },
                                colors = NavigationDrawerItemDefaults.colors(
                                    selectedContainerColor = Palette.surfaceOverlay, // subtle neutral lift, no gold wash
                                    unselectedContainerColor = Palette.surfaceRaised,
                                    selectedIconColor = Palette.accent,
                                    unselectedIconColor = Palette.textSecondary,
                                    selectedTextColor = Palette.textPrimary,
                                    unselectedTextColor = Palette.textSecondary,
                                ),
                                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                            )
                        }
                    }
                }
            }
        },
    ) {
        Scaffold(
            containerColor = Palette.surfaceBase,
            topBar = {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            // Brand glyph reads in-app on every screen — the open recovery ring
                            // ("O" of NOOP) sits just before the screen title.
                            BrandMark(size = 22.dp)
                            Spacer(Modifier.width(10.dp))
                            Text(current.title, style = NoopType.title2, color = Palette.textPrimary)
                            if (BuildConfig.ENABLE_DEMO) {
                                Spacer(Modifier.width(10.dp))
                                Text(
                                    "DEMO",
                                    style = NoopType.footnote,
                                    color = Palette.surfaceBase,
                                    modifier = Modifier
                                        .background(Palette.accent, RoundedCornerShape(6.dp))
                                        .padding(horizontal = 8.dp, vertical = 2.dp),
                                )
                            }
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = { scope.launch { drawerState.open() } }) {
                            Icon(
                                Icons.Filled.Menu,
                                contentDescription = "Open navigation",
                                tint = Palette.textPrimary,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Palette.surfaceBase,
                        titleContentColor = Palette.textPrimary,
                        navigationIconContentColor = Palette.textPrimary,
                    ),
                )
            },
            bottomBar = {
                // One-thumb navigation for the four everyday screens plus a raised gold centre FAB
                // for quick actions — mirroring the macOS/iOS tab bar. The drawer stays (same
                // destinations, grouped) so nothing moved for existing users; the bar is additive.
                Box(contentAlignment = Alignment.TopCenter) {
                    NavigationBar(containerColor = Palette.surfaceRaised) {
                        bottomTabs.forEach { dest ->
                            NavigationBarItem(
                                selected = current == dest,
                                onClick = {
                                    if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)
                                },
                                icon = { Icon(dest.icon, contentDescription = dest.title) },
                                label = { Text(dest.title, style = NoopType.footnote) },
                                colors = navBarItemColors(),
                            )
                        }
                        NavigationBarItem(
                            // Lights up whenever the current screen ISN'T one of the four tabs, so the
                            // bar never looks like you're nowhere.
                            selected = bottomTabs.none { it == current },
                            onClick = { showMoreSheet = true },
                            icon = { Icon(Icons.Filled.GridView, contentDescription = "More screens") },
                            label = { Text("More", style = NoopType.footnote) },
                            colors = navBarItemColors(),
                        )
                    }
                    // Raised gold-gradient centre FAB, lifted ~20dp above the bar (spec: margin-top:-20px).
                    // Opens a bottom sheet of quick actions routing to existing destinations.
                    FloatingActionButton(
                        onClick = { showQuickActions = true },
                        containerColor = Color.Transparent,
                        contentColor = Palette.goldDeepText,
                        shape = CircleShape,
                        // Flat — no Material drop shadow; the redesign keeps glow low (the gold
                        // gradient alone reads as raised against the navy bar).
                        elevation = FloatingActionButtonDefaults.elevation(
                            defaultElevation = 0.dp,
                            pressedElevation = 0.dp,
                            focusedElevation = 0.dp,
                            hoveredElevation = 0.dp,
                        ),
                        modifier = Modifier
                            .offset(y = (-20).dp)
                            .size(46.dp)
                            .clip(CircleShape)
                            .background(Brush.linearGradient(*Palette.goldGradient.toTypedArray())),
                    ) {
                        Icon(
                            Icons.Filled.Add,
                            contentDescription = "Quick actions",
                            tint = Palette.goldDeepText,
                        )
                    }
                }
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
                        onSupport = { nav.navigateTopLevel(Destination.Support.route) },
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
                composable(Destination.Intervals.route) { IntervalsScreen(viewModel) }
                composable(Destination.Breathe.route) { BreatheScreen(viewModel) }
                composable(Destination.Coach.route) { CoachScreen() }
                composable(Destination.Explore.route) { TrendsExploreScreen(viewModel) }
                composable(Destination.Automations.route) { AutomationsScreen(viewModel) }
                composable(Destination.SmartAlarm.route) { SmartAlarmScreen(viewModel) }
                composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }
                composable(Destination.Support.route) { SupportScreen() }
                composable(Destination.Intelligence.route) { IntelligenceScreen(viewModel) }

                // --- Placeholder routes (later waves fill these in) ---
                composable(Destination.Stress.route) {
                    StressScreen(
                        vm = viewModel,
                        onBreathe = { nav.navigateTopLevel(Destination.Breathe.route) },
                    )
                }
                composable(Destination.Trends.route) { TrendsScreen(viewModel) }
                composable(Destination.Insights.route) { InsightsScreen(viewModel) }
                composable(Destination.Compare.route) { CompareScreen(viewModel) }
                composable(Destination.Health.route) {
                    HealthScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                        onOpenLabBook = { nav.navigateTopLevel(Destination.LabBook.route) },
                        onOpenFusedRecord = { nav.navigateTopLevel(Destination.FusedRecord.route) },
                    )
                }
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
                composable(Destination.Devices.route) { DevicesScreen(viewModel) }
                composable(Destination.DataSources.route) { DataSourcesScreen(viewModel) }
                composable(Destination.Notifications.route) { NotificationsSettingsScreen(viewModel) }
                composable(Destination.Settings.route) { SettingsScreen(viewModel) }
            }
        }

        // "More" — every destination, grouped exactly like the drawer, one thumb away. The drawer
        // itself stays for anyone used to the hamburger; both routes lead to the same screens.
        if (showMoreSheet) {
            ModalBottomSheet(
                onDismissRequest = { showMoreSheet = false },
                containerColor = Palette.surfaceRaised,
                contentColor = Palette.textPrimary,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 12.dp)
                        .padding(bottom = 24.dp),
                ) {
                    drawerGroups.forEachIndexed { index, group ->
                        if (index > 0) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                        Overline(
                            group.header,
                            modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp),
                            color = Palette.textTertiary,
                        )
                        group.items.forEach { dest ->
                            val selected = backStack?.destination?.hierarchy
                                ?.any { it.route == dest.route } == true
                            NavigationDrawerItem(
                                selected = selected,
                                onClick = {
                                    showMoreSheet = false
                                    if (dest.route != currentRoute) {
                                        nav.navigateTopLevel(dest.route)
                                    }
                                },
                                icon = { Icon(dest.icon, contentDescription = null) },
                                label = { Text(dest.title, style = NoopType.body) },
                                colors = NavigationDrawerItemDefaults.colors(
                                    selectedContainerColor = Palette.surfaceOverlay, // subtle neutral lift, no gold wash
                                    unselectedContainerColor = Palette.surfaceRaised,
                                    selectedIconColor = Palette.accent,
                                    unselectedIconColor = Palette.textSecondary,
                                    selectedTextColor = Palette.textPrimary,
                                    unselectedTextColor = Palette.textSecondary,
                                ),
                                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                            )
                        }
                    }
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
                            label = { Text(action.title, style = NoopType.body) },
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
    }
}

/** A centre-FAB quick action: a display title, an icon and the destination route it opens. */
private data class QuickAction(val title: String, val icon: ImageVector, val route: String)

/** The quick actions on the gold centre FAB, each routing to an existing destination. Live HR leads
 *  — it moved off the bottom bar (so the FAB no longer overlaps a tab) but stays one tap away here. */
private val quickActions: List<QuickAction> = listOf(
    QuickAction("Live HR", Destination.Live.icon, Destination.Live.route),
    QuickAction("Start workout", Icons.Filled.FitnessCenter, Destination.Workouts.route),
    QuickAction("Log journal", Icons.Filled.Edit, Destination.Insights.route),
    QuickAction("Breathe", Icons.Filled.Air, Destination.Breathe.route),
)

/** Bottom-bar item colours, matching the drawer's accent-on-raised selection treatment. */
@Composable
private fun navBarItemColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = Palette.accent,
    selectedTextColor = Palette.textPrimary,
    indicatorColor = Color.Transparent, // no gold pill behind the selected tab — just the gold icon

    unselectedIconColor = Palette.textSecondary,
    unselectedTextColor = Palette.textSecondary,
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
    val sweep = Brush.sweepGradient(*Palette.goldGradient.toTypedArray())
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
            brush = sweep,
            startAngle = -90f,
            sweepAngle = 288f,
            useCenter = false,
            topLeft = topLeft,
            size = arcSize,
            style = capStroke,
        )
        // Solid gold "on-device core" dot at the centre.
        drawCircle(color = Palette.gold, radius = stroke * 0.62f, center = center)
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
                    "This section is on the way.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
