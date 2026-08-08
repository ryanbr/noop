package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlin.math.roundToInt
import kotlin.math.sqrt
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import com.noop.analytics.HrZones
import com.noop.analytics.SpotHrvReading
import com.noop.analytics.Sport
import com.noop.analytics.WorkoutSport
import com.noop.ble.LiveState
import com.noop.oura.OuraWearState
import com.noop.ble.WhoopModel

/**
 * Live — the real-time strap view + hardware-test surface. A big smoothed HR number,
 * a connection pill, a battery/last-event status grid, and connect/disconnect/buzz
 * controls. Ports LiveView.swift to Compose. Toggles the strap's real-time HR stream
 * on/off as the screen enters/leaves composition.
 */

// MARK: - Liquid hero tokens (the liquid Live restyle)
//
// The hero card the live HR vessel floats on, mirroring the liquid Today hero. A translucent near-black
// (mock rgba(13,14,20,.80)) so it floats over the day-of-sky; the vessel + the white count-up number read
// crisp on it. Radius 26 + a white@0.11 hairline give the frosted-glass edge. (Twins of the liquid Today
// LIQUID_HERO_FILL / LIQUID_HERO_RADIUS, redeclared here since those are file-private to TodayScreen.)
private val LIVE_HERO_RADIUS: Dp = 26.dp

@Composable
fun LiveScreen(viewModel: AppViewModel, onManageDevices: () -> Unit = {}) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    // #628: the Oura ring's live wear/charge state (null for WHOOP / before evidence). Preferred by the
    // "Worn" stat below, so removing the ring or putting it on the charger flips it instead of lingering.
    val ouraWear by viewModel.ouraWearState.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsStateWithLifecycle()
    val selectedModel by viewModel.selectedModel.collectAsStateWithLifecycle()
    // Active band name (MW-6) — names the band whose live data the console shows; falls back to "WHOOP".
    val activeDeviceName by viewModel.activeDeviceName.collectAsStateWithLifecycle()
    val activeWorkout by viewModel.activeWorkout.collectAsStateWithLifecycle()
    val lastWorkout by viewModel.lastWorkout.collectAsStateWithLifecycle()

    // Imperial/Metric display preference (D#103). Live distance/pace are computed from metres + sec/km
    // and re-labelled here. Display-only.
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    // Effort display scale (#268) — routes the live + saved workout Effort read-outs. Display-only.
    val effortScale = UnitPrefs.effortScale(context)
    // Same day-cycle gate as the liquid Today (LiquidScreenSky.kt): the time-of-day sky settles behind the
    // top content when the user hasn't opted out; otherwise the scaffold paints the plain dark canvas.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    // The runtime Bluetooth permission gates scanning. If it isn't granted, the Connect button
    // REQUESTS it (rather than silently doing nothing), then connects once allowed. Shared with
    // Settings → Re-scan via rememberRequestScan so no entry point can forget the gate (issue #1).
    val requestConnect = rememberRequestScan { viewModel.connect() }

    // Keep the realtime HR stream on while this screen is visible (ref-counted in the ViewModel, so
    // navigating to Health Monitor — which also wants it — doesn't stop it). Refresh battery on bond.
    DisposableEffect(Unit) {
        viewModel.requestRealtimeHr()
        onDispose { viewModel.releaseRealtimeHr() }
    }
    LaunchedEffect(live.bonded) {
        if (live.bonded) viewModel.getBattery()
    }

    val activeConnection = live.connected && live.bonded

    // Live HR zone for the focal readout's colour world (presentation only — same shared HrZones model
    // the live-workout screen uses). 0 = below Zone 1 / no HR yet.
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val zoneSet = remember(profile.hrMax) { HrZones.zones(maxHR = profile.hrMax.toDouble()) }
    val liveZone = bpm?.let { zoneSet.zoneNumber(it.toDouble()) } ?: 0

    // HR-zone coaching state, shown read-only here; the toggles live in Automations.
    val zoneCoaching by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val zone5Bpm = zoneSet.zones.firstOrNull { it.number == 5 }?.lower?.roundToInt() ?: 0

    // PERF (#707): the eager ScreenScaffold built (and accessibility-walked) every section up front; on a
    // live-ticking console that long column is what the Compose semantics copy hits each scroll frame.
    // Hoisting these two presentation-only sheet toggles out of the (now-lazy) content lambda — they were
    // shared across sibling sections — and rendering the sheets at body level (an overlay either way, so
    // appearance/behaviour-identical) lets the body migrate to LazyScreenScaffold below. Each former
    // top-level child becomes one `item { }` in the SAME order/spacing, so only on-screen sections compose
    // and semanticize. The live/bpm body reads are intentionally LEFT as-is (this screen's whole purpose is
    // the live readout); see the report note.
    var showSportPicker by remember { mutableStateOf(false) }
    var showHrvSnapshot by remember { mutableStateOf(false) }
    // Live workout mode (#238): the full-screen in-exercise overlay. Normally opened at workout START
    // (StartWorkoutSheet); this lets the Today "workout in progress" indicator re-open it for a session
    // already in flight by consuming the ViewModel's one-shot on appear (iOS parity:
    // LiveView.consumeActiveWorkoutRequest). Closing just hides it; the workout keeps recording.
    var showLiveWorkout by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // consumeActiveWorkoutRequest() returns true exactly once per raise, and only while a workout is
        // active, so a stale flag can never open an empty overlay.
        if (viewModel.consumeActiveWorkoutRequest()) showLiveWorkout = true
    }

    // GPS workout sport picker — the shared sheet (also used on the Workouts screen, #115). Rendered at
    // body level so it floats over Live as an overlay regardless of list position (unchanged behaviour).
    if (showSportPicker) {
        StartWorkoutSheet(vm = viewModel, onDismiss = { showSportPicker = false })
    }

    // Manual HRV snapshot (#127) — a still, seated 60s R-R reading. A plain full-screen Dialog so it floats
    // over Live; gated on a bonded connection (the reading needs the live R-R stream).
    if (showHrvSnapshot) {
        Dialog(
            onDismissRequest = { showHrvSnapshot = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            // Tell the reading where its R-R is coming from so the caveat is honest: a WHOOP 5/MG derives
            // R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is electrical R-R.
            // Driven off the picked strap model.
            val hrvSource = when (selectedModel) {
                WhoopModel.WHOOP5_MG -> SpotHrvReading.Source.OPTICAL_PPG
                WhoopModel.WHOOP4 -> SpotHrvReading.Source.CHEST_STRAP
            }
            HrvSnapshotScreen(
                viewModel = viewModel,
                source = hrvSource,
                onClose = { showHrvSnapshot = false },
            )
        }
    }

    // The full-screen live-workout overlay (#238). A plain full-screen Dialog so it floats over Live, the
    // same idiom WorkoutStartSection uses; opened by the Today indicator's one-shot above (or a future
    // in-screen re-open). Guarded on an active workout so it never shows an empty overlay. Dismiss hides it;
    // End (inside) stops the workout.
    if (showLiveWorkout && activeWorkout != null) {
        Dialog(
            onDismissRequest = { showLiveWorkout = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            LiveWorkoutScreen(vm = viewModel, onClose = { showLiveWorkout = false })
        }
    }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_live_screen_live_body_console_54838e06),
        subtitle = "Current physiology, strap trust, and session controls",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // behind the header + hero and the cards float over the flat canvas below. Reuses the shared
        // LiquidScreenSky() slot verbatim; when the day-cycle background is off, the scaffold paints the
        // plain surface instead (matching the liquid Today's showDayCycleBackground gate).
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {

        // Active band row (MW-6) — names the band the console is reading, with a "Manage devices"
        // affordance that opens the Devices screen. Additive; the connect/disconnect controls below are
        // untouched. Mirrors the iOS Live screen's active-band header + Manage-devices link.
        item {
        ActiveBandRow(name = activeDeviceName ?: "WHOOP", onManageDevices = onManageDevices)
        }

        // Console header — the pill + a connection-mode badge (+ a live SYNCING badge during a history
        // offload), with battery / worn / last-sync stats. Mirrors the macOS consoleHeader.
        item {
        ConsoleHeader(live = live, activeConnection = activeConnection, ouraWear = ouraWear)
        }

        // Primary Connect affordance, surfaced ABOVE the fold whenever there's no link — the real
        // Connect control otherwise lives far below, past the Signal Trust grid, so an offline user
        // saw only inert copy up top. Gated purely on `!live.connected`, so it disappears the instant
        // the radio connects. Mirrors the macOS offlineConnectCallout.
        if (!live.connected) {
            item {
            OfflineConnectCallout(
                scanning = live.scanning,
                onConnect = { requestConnect() },
            )
            }
        }

        // Why it's in this state and what to try (permission, strap busy, not found…).
        live.statusNote?.let { note ->
            item {
            Text(
                note,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
            }
        }

        // Strap wiped its Bluetooth bond (firmware reset / official WHOOP app re-bond): show the forget+
        // re-pair steps in-app instead of looping a dead reconnect — parity with the macOS v1.73 banner.
        live.reconnectGuide?.let { guide ->
            item {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.surfaceRaised, RoundedCornerShape(12.dp))
                    .border(1.dp, Palette.statusWarning.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    uiString(R.string.l10n_live_screen_can_t_connect_your_strap_s_cf78be83),
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                )
                Text(guide, style = NoopType.footnote, color = Palette.textSecondary)
            }
            }
        }

        // Honest sync outcome for a cloud-free app. While offloading, say so plainly — the brief
        // "· syncing" pill suffix is easy to miss (#91/#93). Otherwise: a non-silent error if the
        // last offload stalled, else a relative "history synced N ago". (PR #85; sync-visibility v1.70)
        // The item is gated on this block actually having something to render — in the old eager Column an
        // empty branch produced NO child (no spacing gap); an unconditional lazy `item {}` would instead
        // insert a 0-height row that `spacedBy(20.dp)` flanks, so the guard preserves the exact spacing.
        if (live.backfilling || live.lastSyncError != null || live.lastSyncAt != null) {
        item {
        if (live.backfilling) {
            // INDETERMINATE on purpose: the strap never tells us how many records remain, so a percent
            // would be a lie. A small spinner + the live acked-chunk count is the honest "it's working"
            // signal. The chunk count only appears once the first chunk lands (0 reads as "starting"). (#93)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(13.dp),
                    strokeWidth = 2.dp,
                    color = Palette.accent,
                )
                Text(
                    if (live.syncChunksThisSession > 0)
                        "Syncing your strap history… ${live.syncChunksThisSession} chunks pulled"
                    else "Syncing your strap history…",
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        } else {
            val syncError = live.lastSyncError
            if (syncError != null) {
                Text(
                    syncError,
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                live.lastSyncAt?.let { at ->
                    Text(
                        uiString(R.string.l10n_live_screen_history_synced_relativeago_at_0ece753a, relativeAgo(at)),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        }
        }

        // Body console — focal live HR VESSEL + live physiology (R-R thread, rolling RMSSD, frame/event).
        item {
        BodyConsole(live = live, bpm = bpm, activeConnection = activeConnection, zone = liveZone, hrMax = profile.hrMax)
        }

        // Signal Trust rail — one tile per signal that has to be current for the console to be trusted.
        item {
        SignalTrustRail(live = live, bpm = bpm, activeConnection = activeConnection)
        }

        // Max HR + the top-zone entry threshold (read-only; manage coaching in Automations).
        item {
        MaxHrZoneCard(hrMax = profile.hrMax, zone5Bpm = zone5Bpm, coachingOn = zoneCoaching)
        }

        // (The Start-workout sheet + HRV-snapshot Dialog were hoisted to the body above — they're overlays
        // that float regardless of list position, so this is appearance/behaviour-identical and keeps the
        // composable-only `remember`/Dialog out of the LazyListScope lambda.)

        // Session console — record or inspect the current stream.
        item {
        SectionHeader(title = uiString(R.string.l10n_live_screen_session_f7f1997c), overline = "Record or inspect the current stream")
        }

        // Manual workout — start/stop a session yourself; records HR + strain until you end it.
        // This block emits MULTIPLE siblings in its `else` branch (the actions Row, the last-workout note,
        // the HRV button), which in the old eager scaffold were spaced by the column's `spacedBy(20.dp)`.
        // Wrapping the whole block in one lazy item, they'd lose that inter-child spacing — so an explicit
        // `Column(spacedBy(20.dp))` inside the item reproduces the exact gaps (the if-branch's single card
        // is unaffected). Spacing to the neighbouring items is the LazyColumn's own `spacedBy(20.dp)`.
        item {
        Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        val w = activeWorkout
        if (w != null) {
            var confirmingEnd by remember(w.startMs) { mutableStateOf(false) }
            var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
            LaunchedEffect(w.startMs) {
                while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
            }
            val elapsedS = ((nowMs - w.startMs) / 1000).coerceAtLeast(0)
            NoopCard(tint = Palette.effortColor) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text(uiString(R.string.l10n_live_screen_w_sport_name_uppercase_e59bc678, w.sport.name.uppercase()), style = NoopType.overline, color = Palette.statusCritical)
                        Spacer(Modifier.weight(1f))
                        Text(
                            // Shared clock: M:SS up to an hour, H:MM:SS past it (so a long session reads
                            // "1:30:00", not "90:00"), the same format the Today indicator uses.
                            elapsedClock(elapsedS),
                            style = NoopType.number(22f), color = Palette.textPrimary,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                        StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_hr_f187928f), value = bpm?.toString() ?: "—",
                            accent = if (bpm == null) Palette.textPrimary else Palette.metricRose)
                        StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_avg_cdc93143), value = if (w.avgHr > 0) "${w.avgHr}" else "—")
                        StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_peak_c83dbbd3), value = if (w.peakHr > 0) "${w.peakHr}" else "—")
                        StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_effort_8c974bc6), value = UnitFormatter.effortDisplay(w.liveStrain, effortScale),
                            accent = Palette.strainColor(w.liveStrain))
                    }
                    if (w.gpsEnabled) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                            StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_distance_42320809), value = liveDistance(w.distanceM, unitSystem))
                            StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_pace_7a9a6226), value = w.paceSecPerKm?.let { livePace(it, unitSystem) } ?: "—")
                        }
                    }
                    Button(
                        onClick = { confirmingEnd = true },
                        modifier = Modifier.fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_live_screen_end_workout_3e8d6238), style = NoopType.captionNumber) }
                }
            }
            if (confirmingEnd) {
                EndWorkoutConfirmationDialog(
                    onConfirm = {
                        confirmingEnd = false
                        viewModel.endWorkout()
                    },
                    onDismiss = { confirmingEnd = false },
                )
            }
        } else {
            // Start-workout + a Refresh-battery action, gated on a live link (parity with the macOS
            // sessionActions). The Refresh button re-reads strap battery / connection on demand.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = { showSportPicker = true },
                    modifier = Modifier.weight(1f),
                    enabled = activeConnection,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) {
                    Text(
                        uiString(R.string.l10n_live_screen_start_workout_d0f3f2cd), style = NoopType.captionNumber,
                        maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                    )
                }
                OutlinedButton(
                    onClick = { viewModel.getBattery() },
                    modifier = Modifier.weight(1f),
                    enabled = activeConnection,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp).padding(end = 4.dp),
                    )
                    Text(
                        uiString(R.string.l10n_live_screen_refresh_56e3badc), style = NoopType.captionNumber,
                        maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                    )
                }
            }
            lastWorkout?.let { row ->
                val mins = ((row.durationS ?: 0.0) / 60).toInt()
                val parts = listOfNotNull(
                    "$mins min",
                    row.distanceM?.let { liveDistance(it, unitSystem) },
                    row.avgHr?.let { "$it avg bpm" },
                    row.strain?.let { "strain ${UnitFormatter.effortDisplay(it, effortScale)}" },
                )
                Text(
                    uiString(R.string.live_workout_saved_summary, row.sport, parts.joinToString(" · ")),
                    style = NoopType.footnote, color = Palette.textSecondary,
                )
                row.routePolyline?.let { RouteCanvas(it, modifier = Modifier.padding(top = 8.dp)) }
            }

            // Manual HRV snapshot (#127) — a still, seated 60s R-R reading. Needs the live R-R stream,
            // so it's gated on a bonded connection just like the workout/refresh actions above.
            OutlinedButton(
                onClick = { showHrvSnapshot = true },
                modifier = Modifier.fillMaxWidth(),
                enabled = activeConnection,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.restBright),
            ) {
                Icon(
                    Icons.Filled.MonitorHeart,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp).padding(end = 4.dp),
                )
                Text(
                    uiString(R.string.l10n_live_screen_take_an_hrv_reading_20ecb2d2), style = NoopType.captionNumber,
                    maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                )
            }
        }
        }
        }

        // Strap picker — choose the model before scanning so we look for exactly one device family.
        // Shown whenever we're not actively streaming, so a user with both a WHOOP 4 and a 5/MG can
        // switch between them (it used to hide once `bonded`, which stuck after the first pairing).
        if (!(live.connected && live.bonded)) {
            // Two siblings (picker Row + optional 5/MG guidance) that the eager column spaced by 20dp —
            // an inner `Column(spacedBy(20.dp))` reproduces that gap inside the single lazy item.
            item {
            Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(uiString(R.string.l10n_live_screen_strap_02b88eeb), style = NoopType.footnote, color = Palette.textSecondary)
                SegmentedPillControl(
                    items = WhoopModel.entries.toList(),
                    selection = selectedModel,
                    label = { it.displayName },
                    onSelect = { viewModel.setSelectedModel(it) },
                )
            }
            // Proactive 5/MG guidance (#130): the strap bonds to one host at a time, so a scan finds
            // nothing while it's still paired in the official WHOOP app. Shown the moment 5/MG is picked.
            if (selectedModel == WhoopModel.WHOOP5_MG) {
                Text(
                    uiString(R.string.l10n_live_screen_whoop_5_0_mg_pairs_with_b93143f2) +
                        "the official WHOOP app and fully close that app, then Connect again.",
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                )
            }
            }
            }
        }

        // Controls.
        item {
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            // Compact, single-line labels: with three weight(1f) buttons in a row, the default
            // body style + icon could wrap "Re-scan"/"Searching…" to two lines on narrow phones,
            // making one button taller than the others. captionNumber + maxLines=1 keeps the row
            // even. Connect disables while a scan is in flight so it can't be re-tapped mid-search.
            Button(
                onClick = { requestConnect() },
                modifier = Modifier.weight(1f),
                enabled = !live.scanning,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Icon(
                    Icons.Filled.Bluetooth,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    when {
                        live.scanning -> "Searching…"
                        live.connected -> "Re-scan"
                        else -> "Connect"
                    },
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }

            OutlinedButton(
                // #921: the confirmed one-shot sequence (pattern + RUN_ALARM where the family gate
                // allows it, acked). A bare pattern write here matched the iOS silent no-buzz path.
                onClick = { viewModel.buzzStrapOnce() },
                modifier = Modifier.weight(1f),
                enabled = live.bonded,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
            ) {
                Icon(
                    Icons.Filled.GraphicEq,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    uiString(R.string.l10n_live_screen_buzz_edbd47b2),
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }

            OutlinedButton(
                onClick = { viewModel.disconnect() },
                modifier = Modifier.weight(1f),
                enabled = live.connected,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
            ) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    uiString(R.string.l10n_live_screen_end_a2bb9d34),
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }
        }
        }

        // Manual "Sync now" — kick a historical offload on demand instead of waiting for the 15-min
        // periodic timer (#93). Only meaningful once bonded (the offload needs the command channel), and
        // disabled mid-session so a double-tap can't fight the in-flight offload — viewModel.syncNow()
        // also no-ops in that case, this is just the matching UI state. While syncing, the button shows
        // an INDETERMINATE spinner (NEVER a percent — total pending records are unknowable from the
        // protocol); the "Syncing your strap history… N chunks pulled" line above carries the live count.
        if (live.bonded) {
            item {
            OutlinedButton(
                onClick = { viewModel.syncNow() },
                modifier = Modifier.fillMaxWidth(),
                enabled = !live.backfilling,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
            ) {
                if (live.backfilling) {
                    CircularProgressIndicator(
                        modifier = Modifier
                            .size(18.dp)
                            .padding(end = 4.dp),
                        strokeWidth = 2.dp,
                        color = Palette.accent,
                    )
                } else {
                    Icon(
                        Icons.Filled.Sync,
                        contentDescription = null,
                        modifier = Modifier
                            .size(18.dp)
                            .padding(end = 4.dp),
                    )
                }
                Text(
                    if (live.backfilling) "Syncing…" else "Sync now",
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }
            }
        }

        // Foolproof connection walkthrough — detects each blocker (WHOOP app, Bluetooth,
        // permission) and offers a one-tap fix. Hidden once the strap is bonded.
        if (!live.bonded) {
            item {
            ConnectionHelp(viewModel, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

// MARK: - Console header

/**
 * Read-only Max-HR + top-zone card. Max HR is the age-based value from Settings; the Zone 5 entry
 * (≥ 90% of max) is where HR-zone coaching buzzes. Managing coaching lives in Automations.
 * Reimplemented from @cbarrado's PR #350.
 */
@Composable
private fun MaxHrZoneCard(hrMax: Int, zone5Bpm: Int, coachingOn: Boolean) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_live_screen_max_hr_6acd9e07),
                    value = "$hrMax bpm",
                    accent = Palette.textPrimary,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_live_screen_top_zone_282d0f66),
                    value = "≥ $zone5Bpm bpm",
                    accent = if (coachingOn) Palette.accent else Palette.textTertiary,
                )
            }
            Text(
                if (coachingOn)
                    "Strap buzzes when you climb into Zone 5 (≥ $zone5Bpm bpm). Manage it in Automations → Haptic coaching."
                else
                    "Turn on HR-zone coaching in Automations for a wrist buzz when you reach Zone 5 (≥ $zone5Bpm bpm).",
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * Active band row (MW-6): names the band whose live data the console is showing, with a "Manage devices"
 * affordance that opens the Devices screen. Additive — it sits above the console header and never touches
 * the connect/disconnect controls. Mirrors the iOS Live screen's active-band header + Manage-devices link.
 */
@Composable
private fun ActiveBandRow(name: String, onManageDevices: () -> Unit) {
    NoopCard(padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Icon(
                Icons.Filled.Watch,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.size(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Overline("Active band")
                Text(name, style = NoopType.headline, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // liquidPress: the "Manage devices" affordance settles inward on press (the iOS LiquidPressStyle
            // feel), the SAME interactionSource driving its clickable + the press response.
            val manageInteraction = remember { MutableInteractionSource() }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .liquidPress(manageInteraction)
                    .clickable(
                        interactionSource = manageInteraction,
                        indication = null,
                        onClick = onManageDevices,
                    )
                    .semantics { contentDescription = uiString(R.string.l10n_live_screen_manage_devices_e5c277ff) }
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            ) {
                Text(uiString(R.string.l10n_live_screen_manage_devices_e5c277ff), style = NoopType.subhead, color = Palette.accent)
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun ConsoleHeader(live: LiveState, activeConnection: Boolean, ouraWear: OuraWearState? = null) {
    NoopCard(padding = 14.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Badges row — pill + connection-mode badge + a live SYNCING badge during an offload.
            val (label, tone) = when {
                live.encryptedBond && live.backfilling -> "Bonded · syncing" to StrandTone.Accent
                live.encryptedBond -> "Bonded" to StrandTone.Positive
                live.bonded -> "Live HR (not fully paired)" to StrandTone.Warning
                ringStreaming(live) -> "Streaming" to StrandTone.Positive   // #56: trusted non-WHOOP stream
                live.connected -> "Connected" to StrandTone.Warning
                live.scanning -> "Searching…" to StrandTone.Warning
                else -> "Disconnected" to StrandTone.Critical
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StatePill(label, tone = tone, pulsing = live.bonded || live.scanning)
                // Suppress the redundant rose "OFFLINE" badge while fully offline — the pill already
                // reads "Disconnected" in critical/rose. Keep it for every informative state (FULL BOND
                // / LIVE HR ONLY / CONNECTING / PAIRED). Gate matches exactly the "OFFLINE" branch.
                if (showsModeBadge(live, activeConnection)) {
                    SourceBadge(connectionModeBadge(live, activeConnection), tint = connectionModeColor(live, activeConnection))
                }
                if (live.backfilling) {
                    SourceBadge("SYNCING ${live.syncChunksThisSession}", tint = Palette.metricCyan)
                }
            }
            // Stats row — battery / worn / last-sync. Worn is only trustworthy on a live link.
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.fillMaxWidth()) {
                // Charging bolt next to the battery % when the strap reports it's charging (PR #568 reimpl).
                HeaderStat(
                    "Battery",
                    live.batteryPct?.let { "${it.toInt()}%" } ?: "—",
                    charging = live.charging == true,
                )
                HeaderStat("Worn", wornLabel(live, activeConnection, ouraWear))
                HeaderStat("Last sync", lastSyncLabel(live))
            }
        }
    }
}

@Composable
private fun HeaderStat(title: String, value: String, charging: Boolean = false) {
    Column(horizontalAlignment = Alignment.Start) {
        Text(title.uppercase(), style = NoopType.footnote, color = Palette.textTertiary)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                value, style = NoopType.captionNumber, color = Palette.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (charging) {
                Icon(
                    Icons.Filled.Bolt,
                    contentDescription = uiString(R.string.l10n_live_screen_charging_5f99fe21),
                    tint = Palette.statusPositive,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

// MARK: - Offline connect callout

/**
 * The above-the-fold primary Connect affordance, shown only while disconnected. Promotes the formerly-
 * inert "Scan and connect…" caption into an accent NoopCard with a real, full-width Connect button (the
 * same scan action the controls row uses below), so the offline state has an obvious action up top
 * instead of burying it past the Signal Trust grid. Mirrors the macOS offlineConnectCallout.
 */
@Composable
private fun OfflineConnectCallout(scanning: Boolean, onConnect: () -> Unit) {
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    Icons.Filled.Bluetooth,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(20.dp),
                )
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_live_screen_start_a_live_stream_419bf5aa), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_live_screen_scan_and_connect_to_start_a_3e27b47b),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }
            Button(
                onClick = onConnect,
                modifier = Modifier.fillMaxWidth(),
                enabled = !scanning,
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Icon(
                    Icons.Filled.Bluetooth,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp).padding(end = 4.dp),
                )
                Text(
                    if (scanning) "Searching…" else "Scan & Connect",
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }
        }
    }
}

/** #56: a non-WHOOP live source (the Oura ring, and on Android any external HR source that drives
 *  [LiveState.streamingLiveHR]) that is connected and actively streaming live HR. It streams without a
 *  WHOOP encrypted bond, so `bonded`/`activeConnection` never trip — which left the console reading
 *  "stream not yet trusted" for a perfectly good stream. The status copy treats this as a trusted stream;
 *  the bond-only feature gates (buzz, alarm, HRV snapshot) keep keying off `activeConnection`. Twin of the
 *  iOS LiveView.ringStreaming. */
private fun ringStreaming(live: LiveState): Boolean = live.connected && live.streamingLiveHR

/** The "Worn" stat text. An Oura ring reports a precise live wear/charge state (live-HR presence + charger
 *  STATE + a removal watchdog), so prefer it — it flips to not-worn the moment the ring is off the finger
 *  or on the charger, unlike the WHOOP wrist boolean which lingers. WHOOP has no such signal ([ouraWear]
 *  stays null) so it keeps the wrist-event read. "—" off a live link; because an Oura ring streams WITHOUT
 *  bonding, a live stream counts as a link too (not just [activeConnection]). Mirrors iOS LiveView.wornNow
 *  (#628 / #218). */
private fun wornLabel(live: LiveState, activeConnection: Boolean, ouraWear: OuraWearState?): String {
    val liveLink = activeConnection || ringStreaming(live)
    return when {
        !liveLink -> "—"
        ouraWear != null -> if (ouraWear == OuraWearState.WORN) "Yes" else "No"
        else -> if (live.worn) "Yes" else "No"
    }
}

private fun connectionModeBadge(live: LiveState, activeConnection: Boolean): String = when {
    activeConnection && live.encryptedBond -> "FULL BOND"
    activeConnection -> "LIVE HR ONLY"
    ringStreaming(live) -> "STREAMING"
    live.connected -> "CONNECTING"
    live.encryptedBond -> "PAIRED"
    else -> "OFFLINE"
}

/** Whether to render the connection-mode badge. False exactly when the badge would read "OFFLINE" —
 *  the pill already says "Disconnected", so the duplicate rose badge is pure redundancy. */
private fun showsModeBadge(live: LiveState, activeConnection: Boolean): Boolean =
    !(!activeConnection && !live.connected && !live.encryptedBond)

private fun connectionModeColor(live: LiveState, activeConnection: Boolean): Color = when {
    (activeConnection && live.encryptedBond) || ringStreaming(live) -> Palette.accent
    activeConnection || live.connected -> Palette.statusWarning
    else -> Palette.metricRose
}

private fun lastSyncLabel(live: LiveState): String =
    live.lastSyncAt?.let { relativeAgo(it) } ?: "Never"

// MARK: - Body console (focal HR ring + live physiology)

@Composable
private fun BodyConsole(live: LiveState, bpm: Int?, activeConnection: Boolean, zone: Int, hrMax: Int) {
    // The liquid hero CARD: a translucent near-black that floats over the day-of-sky so the HR vessel + the
    // white count-up number stay crisp — the card does the contrast work, not a muted sky. A rounded 26
    // corner + a faint white hairline give it the frosted-glass edge of the liquid Today heroCard
    // (heroFill = rgba(13,14,20,.80), stroke white@0.11). Mirrors the pilot LiquidTodayView heroCard.
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(LIVE_HERO_RADIUS))
            .background(Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity))
            .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIVE_HERO_RADIUS))
            .padding(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            HeartReadout(live = live, bpm = bpm, activeConnection = activeConnection, zone = zone, hrMax = hrMax)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            PhysiologyStack(live = live, activeConnection = activeConnection)
        }
    }
}

@Composable
private fun HeartReadout(live: LiveState, bpm: Int?, activeConnection: Boolean, zone: Int, hrMax: Int) {
    // Tint by the live HR zone when streaming, the Effort world otherwise — the workouts/live colour world
    // (UNCHANGED from the hand-drawn ring this replaced: same zone→colour math, same value-sampled tint).
    val tint = when {
        bpm == null -> Palette.textSecondary
        zone >= 1 -> Palette.hrZoneColor(zone)
        else -> Palette.effortColor
    }
    // The vessel fill: current bpm as a fraction of the age-based max HR (the same hrMax the zone model
    // above uses). Null bpm → empty vessel. Clamped 0..1 by LiquidVessel at the draw call.
    val fraction = bpm?.let { (it.toDouble() / hrMax.toDouble()) } ?: 0.0

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Overline("Heart Rate")
        Box(
            modifier = Modifier
                .fillMaxWidth(0.6f)
                .aspectRatio(1f),
            contentAlignment = Alignment.Center,
        ) {
            // The live HR GAUGE as a liquid VESSEL — fills to bpm/hrMax in the zone tint, sloshing live once
            // a real HR is streaming (animated only when bpm != null, so an idle console poses static and
            // doesn't churn an empty canvas). Mirrors the liquid Today HeroScoreVessel idiom.
            LiquidVessel(
                value = fraction,
                tint = tint,
                animated = bpm != null,
                modifier = Modifier.fillMaxSize(),
            )
            // The bpm number rolled up over the vessel — white, tabular, a soft shadow for legibility, and
            // hit-transparent (clearAndSetSemantics + no clickable) so the tap falls THROUGH to the vessel,
            // which owns its own tap→splash+haptic. Mirrors HeroScoreVessel's count-up-over-vessel number.
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                if (bpm != null) {
                    CountUpText(
                        value = bpm.toDouble(),
                        format = { it.roundToInt().toString() },
                        style = NoopType.number(64f, weight = FontWeight.Bold)
                            .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                        color = Color.White,
                        modifier = Modifier.clearAndSetSemantics {},
                    )
                } else {
                    Text(
                        text = "—",
                        style = NoopType.number(64f, weight = FontWeight.Bold),
                        color = Palette.textSecondary,
                    )
                }
                Text("bpm", style = NoopType.subhead, color = Palette.textSecondary)
                if (zone >= 1) {
                    Text(uiString(R.string.l10n_live_screen_zone_zone_b8e9c0f9, zone), style = NoopType.overline, color = tint)
                }
            }
        }
        Text(
            signalTrustSummary(live, activeConnection),
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun PhysiologyStack(live: LiveState, activeConnection: Boolean) {
    val rmssd = rollingRMSSD(live.rrRecent)
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Overline("Live Physiology")
                Text(connectionModeDetail(live, activeConnection), style = NoopType.headline, color = Palette.textPrimary)
            }
            if (rmssd != null) {
                Column(horizontalAlignment = Alignment.End) {
                    Text(uiString(R.string.l10n_live_screen_rmssd_e240fd3c), style = NoopType.footnote, color = Palette.textTertiary)
                    Text(uiString(R.string.l10n_live_screen_rmssd_roundtoint_ms_9e6c0887, rmssd.roundToInt()), style = NoopType.number(24f), color = Palette.metricCyan)
                }
            }
        }
        RRStrip(rrRecent = live.rrRecent)
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            // Offline: show a muted "Offline" word (dimmed to textTertiary) instead of bare accent-
            // coloured em-dashes that read as broken live readouts. Real values + accents return on a
            // stream. Mirrors the macOS liveProofMetric(offline:).
            LiveProofMetric(
                Modifier.weight(1f), "R-R",
                if (activeConnection) (live.rr.lastOrNull()?.let { "$it ms" } ?: "—") else "Offline",
                Palette.metricCyan, offline = !activeConnection,
            )
            LiveProofMetric(
                Modifier.weight(1f), "Event",
                if (activeConnection) (live.lastEvent ?: "—") else "Offline",
                Palette.statusWarning, offline = !activeConnection,
            )
        }
    }
}

/** The recent R-R buffer as a live liquid THREAD — the beat-by-beat trace with a travelling glint +
 *  endpoint pulse (a single HR number can look frozen; a flowing thread can't). R-R intervals ARE the
 *  time between heartbeats, so the buffer is a genuine beat-by-beat series; the thread auto-normalises its
 *  own min/max, so the raw ms values feed it directly. Empty state shows a muted flat thread + the
 *  "Waiting…" caption. Same data binding (live.rrRecent) as the bar strip this replaced. */
@Composable
private fun RRStrip(rrRecent: List<Int>) {
    val values = rrRecent.takeLast(18)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (values.size >= 2) {
            // Live thread — flows (glint + pulse) as new intervals land. Heart-pink (LiquidThread default).
            LiquidThread(
                bpm = values.map { it.toDouble() },
                animated = true,
                height = 58.dp,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            // Empty / single-sample state: a muted flat hairline placeholder at the same height, so the
            // card doesn't jump when the first pair of intervals arrives and the thread takes over.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(58.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(2.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Palette.hairline),
                )
            }
        }
        Text(
            if (values.isEmpty()) "Waiting for R-R intervals."
            else "Recent intervals: " + values.takeLast(5).joinToString(" · ") + " ms",
            style = NoopType.footnote,
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** One R-R / Event proof tile. When [offline] the value is dimmed to textTertiary (regardless of the
 *  passed accent) so an idle tile reads as a muted empty state, not a broken live readout in
 *  cyan/amber — matching the rrStrip's "Waiting for R-R intervals." treatment above. */
@Composable
private fun LiveProofMetric(modifier: Modifier, label: String, value: String, tint: Color, offline: Boolean = false) {
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(label.uppercase(), style = NoopType.footnote, color = Palette.textTertiary)
        Text(
            value,
            style = NoopType.captionNumber,
            color = if (offline) Palette.textTertiary else tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Signal Trust rail

@Composable
private fun SignalTrustRail(live: LiveState, bpm: Int?, activeConnection: Boolean) {
    val tiles = signalTiles(live, bpm, activeConnection)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = uiString(R.string.l10n_live_screen_signal_trust_4a91fe00), overline = "Proof that the console is current")
        // Two tiles per row (a LazyVerticalGrid can't live inside the scrolling ScreenScaffold —
        // infinite-height constraints — so use fixed Rows, the correct Compose idiom here).
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                rowTiles.forEach { tile ->
                    SignalTrustTile(tile, modifier = Modifier.weight(1f))
                }
                // Pad an odd final row so the lone tile keeps half-width (matches the grid above).
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

private data class SignalTile(
    val title: String,
    val value: String,
    val detail: String,
    val tint: Color,
)

private fun signalTiles(live: LiveState, bpm: Int?, activeConnection: Boolean): List<SignalTile> = listOf(
    SignalTile(
        "Heart rate",
        bpm?.let { "$it bpm" } ?: "Missing",
        if (activeConnection || ringStreaming(live)) "Streaming now" else "No active stream",
        if (bpm == null) Palette.textTertiary else Palette.accent,
    ),
    SignalTile(
        "R-R intervals",
        if (live.rrRecent.isEmpty()) "Missing" else "${live.rrRecent.size} recent",
        rollingRMSSD(live.rrRecent)?.let { "RMSSD ${it.roundToInt()} ms" } ?: "Needs interval frames",
        if (live.rrRecent.isEmpty()) Palette.textTertiary else Palette.metricCyan,
    ),
    SignalTile(
        "Connection",
        when {
            activeConnection && live.encryptedBond -> "Encrypted"
            activeConnection -> "Partial"
            ringStreaming(live) -> "Streaming"
            live.connected -> "Connected"
            else -> "Offline"
        },
        when {
            activeConnection && live.encryptedBond -> "Controls unlocked"
            ringStreaming(live) -> "Live stream, no WHOOP bond"
            else -> "Standard HR is not a full bond"
        },
        connectionModeColor(live, activeConnection),
    ),
    SignalTile(
        "History sync",
        if (live.backfilling) "${live.syncChunksThisSession} chunks" else lastSyncLabel(live),
        when {
            live.lastSyncError != null -> live.lastSyncError
            live.backfilling -> "Offload in progress"
            live.lastSyncAt == null -> "No completed offload yet"
            else -> "Last offload completed"
        },
        if (live.backfilling) Palette.metricCyan else Palette.textSecondary,
    ),
    SignalTile(
        "Battery",
        live.batteryPct?.let { "${it.toInt()}%" } ?: "Unknown",
        if (live.charging == true) "Charging" else "Last reported by strap",
        batteryTint(live.batteryPct),
    ),
    // Wear is only trustworthy on a live link: `worn` defaults true and is only updated by
    // WRIST_ON/OFF events, so while OFFLINE it would read a false-green "On wrist". Gate value + tint
    // on activeConnection (triage fix for PR#191, parity with the macOS Wear tile).
    SignalTile(
        "Wear state",
        if (activeConnection) (if (live.worn) "On wrist" else "Off wrist") else "Unknown",
        if (activeConnection) (if (live.worn) "Eligible for live physiology" else "Wear the strap for scoring") else "Connect to read wear state",
        when {
            !activeConnection -> Palette.textTertiary
            live.worn -> Palette.accent
            else -> Palette.statusWarning
        },
    ),
)

@Composable
private fun SignalTrustTile(tile: SignalTile, modifier: Modifier = Modifier) {
    NoopCard(modifier = modifier.heightIn(min = 112.dp), padding = 14.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Overline(tile.title)
            Text(tile.value, style = NoopType.headline, color = tile.tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(tile.detail, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: - Pure helpers (shared by the body console + the trust rail)

private fun signalTrustSummary(live: LiveState, activeConnection: Boolean): String = when {
    activeConnection && live.encryptedBond -> "Encrypted stream - deep controls and history sync available."
    activeConnection -> "Live heart rate is flowing; full strap controls need an encrypted bond."
    live.connected -> "Connected, waiting for a streaming state."
    // The actionable "Scan and connect…" CTA now lives in the above-the-fold OfflineConnectCallout,
    // so this ring caption stays a calm empty-state descriptor rather than a competing CTA.
    else -> "Live heart rate appears here once a strap is connected."
}

private fun connectionModeDetail(live: LiveState, activeConnection: Boolean): String = when {
    activeConnection && live.encryptedBond -> "Full strap stream is active."
    activeConnection || ringStreaming(live) -> "Heart rate stream is active."
    live.connected -> "Radio connected, stream not yet trusted."
    else -> "No live stream."
}

/** A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
 *  clinical figure; blanked on disconnect by clearedBiometrics). null until ≥3 intervals land. */
private fun rollingRMSSD(rrRecent: List<Int>): Double? {
    val values = rrRecent.takeLast(12)
    if (values.size < 3) return null
    val diffs = values.zipWithNext { a, b -> (b - a).toDouble() }
    val meanSquare = diffs.sumOf { it * it } / diffs.size
    return sqrt(meanSquare)
}

private fun batteryTint(pct: Double?): Color = when {
    pct == null -> Palette.textTertiary
    pct <= 15 -> Palette.metricRose
    pct <= 30 -> Palette.statusWarning
    else -> Palette.accent
}

/**
 * Coarse relative-time label for the "History synced N ago" sync-status line. Pure + unit-tested
 * (RelativeAgoTest); [nowSec] is injectable for determinism. Buckets to just-now / min / h / d. (PR #85)
 */
internal fun relativeAgo(epochSec: Long, nowSec: Long = System.currentTimeMillis() / 1000L): String {
    val d = (nowSec - epochSec).coerceAtLeast(0)
    return when {
        d < 60L -> "just now"
        d < 3600L -> "${d / 60L} min ago"
        d < 86_400L -> "${d / 3600L} h ago"
        else -> "${d / 86_400L} d ago"
    }
}

/** Live workout distance from metres, 2-decimal precision, re-labelled to the active system (km / mi). */
private fun liveDistance(distanceM: Double, system: UnitSystem): String = when (system) {
    UnitSystem.METRIC -> java.lang.String.format(java.util.Locale.US, "%.2f km", distanceM / 1000.0)
    UnitSystem.IMPERIAL ->
        java.lang.String.format(java.util.Locale.US, "%.2f mi", UnitFormatter.kmToMiles(distanceM / 1000.0))
}

/** Live pace from seconds-per-km, re-labelled to minutes per km / per mile. A per-mile pace is per-km
 *  divided by miles-per-km (a mile is longer, so the time per unit is larger). */
private fun livePace(secPerKm: Double, system: UnitSystem): String {
    val sec = if (system == UnitSystem.IMPERIAL) secPerKm / UnitFormatter.MILES_PER_KILOMETER else secPerKm
    val unit = if (system == UnitSystem.IMPERIAL) "/mi" else "/km"
    return java.lang.String.format(java.util.Locale.US, "%d:%02d %s", (sec / 60).toInt(), (sec % 60).toInt(), unit)
}
