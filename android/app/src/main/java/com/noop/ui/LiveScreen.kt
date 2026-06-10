package com.noop.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import com.noop.analytics.Sport
import com.noop.analytics.WorkoutSport
import com.noop.ble.WhoopModel

/**
 * Live — the real-time strap view + hardware-test surface. A big smoothed HR number,
 * a connection pill, a battery/last-event status grid, and connect/disconnect/buzz
 * controls. Ports LiveView.swift to Compose. Toggles the strap's real-time HR stream
 * on/off as the screen enters/leaves composition.
 */
@Composable
fun LiveScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsStateWithLifecycle()
    val selectedModel by viewModel.selectedModel.collectAsStateWithLifecycle()
    val activeWorkout by viewModel.activeWorkout.collectAsStateWithLifecycle()
    val lastWorkout by viewModel.lastWorkout.collectAsStateWithLifecycle()

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

    ScreenScaffold(title = "Live", subtitle = "All your data · none of the cloud") {

        // Connection pill row.
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            // encryptedBond → green "Bonded"; the 5/MG live-HR shortcut (bonded but no genuine encrypted
            // bond) → amber "Live HR (not fully paired)" so users know the encrypted channel isn't up (#69).
            val (label, tone) = when {
                live.encryptedBond && live.backfilling -> "Bonded · syncing" to StrandTone.Accent
                live.encryptedBond -> "Bonded" to StrandTone.Positive
                live.bonded -> "Live HR (not fully paired)" to StrandTone.Warning
                live.connected -> "Connected" to StrandTone.Warning
                live.scanning -> "Searching…" to StrandTone.Warning
                else -> "Disconnected" to StrandTone.Critical
            }
            StatePill(label, tone = tone, pulsing = live.bonded || live.scanning)
        }
        // Why it's in this state and what to try (permission, strap busy, not found…).
        live.statusNote?.let { note ->
            Text(
                note,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // Strap wiped its Bluetooth bond (firmware reset / official WHOOP app re-bond): show the forget+
        // re-pair steps in-app instead of looping a dead reconnect — parity with the macOS v1.73 banner.
        live.reconnectGuide?.let { guide ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.surfaceRaised, RoundedCornerShape(12.dp))
                    .border(1.dp, Palette.statusWarning.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    "Can't connect — your strap's pairing was reset",
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                )
                Text(guide, style = NoopType.footnote, color = Palette.textSecondary)
            }
        }

        // Honest sync outcome for a cloud-free app. While offloading, say so plainly — the brief
        // "· syncing" pill suffix is easy to miss (#91/#93). Otherwise: a non-silent error if the
        // last offload stalled, else a relative "history synced N ago". (PR #85; sync-visibility v1.70)
        if (live.backfilling) {
            Text(
                "Syncing your strap history…",
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
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
                        "History synced ${relativeAgo(at)}",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }

        // Big HR card.
        HeartRateCard(bpm = bpm, rr = live.rr)

        // Status grid.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Battery",
                value = live.batteryPct?.let { "${it.toInt()}%" } ?: "—",
                accent = batteryColor(live.batteryPct),
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Worn",
                value = if (live.worn) "Yes" else "Off",
                accent = if (live.worn) Palette.accent else Palette.textTertiary,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Last Event",
                value = live.lastEvent ?: "—",
                accent = Palette.textPrimary,
            )
        }

        // GPS workout sport picker — pick a sport (searchable) + GPS toggle, then start.
        var showSportPicker by remember { mutableStateOf(false) }
        if (showSportPicker) {
            var query by remember { mutableStateOf("") }
            var selected by remember { mutableStateOf(WorkoutSport.default) }
            var gpsOn by remember(selected) { mutableStateOf(selected.isDistanceSport) }
            val filtered = WorkoutSport.all.filter { it.name.contains(query, ignoreCase = true) }
            // GPS needs ACCESS_FINE_LOCATION, which is NOT granted by the BLE flow on Android 12+.
            // Request it before starting; if denied, the workout still starts (without a route). (#101)
            val startWithGps = rememberRequestLocation { granted ->
                viewModel.startWorkout(selected, gpsEnabled = gpsOn && granted)
                showSportPicker = false
            }
            AlertDialog(
                onDismissRequest = { showSportPicker = false },
                title = { Text("Start a workout") },
                text = {
                    Column {
                        OutlinedTextField(
                            value = query, onValueChange = { query = it },
                            label = { Text("Search sport") }, singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Column(modifier = Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
                            filtered.forEach { sp ->
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth()
                                        .clickable { selected = sp; gpsOn = sp.isDistanceSport }
                                        .padding(vertical = 10.dp),
                                ) {
                                    Text(
                                        sp.name, style = NoopType.body,
                                        color = if (sp == selected) Palette.accent else Palette.textPrimary,
                                    )
                                    if (sp.isDistanceSport) {
                                        Spacer(Modifier.width(6.dp))
                                        Text("· GPS", style = NoopType.footnote, color = Palette.textTertiary)
                                    }
                                }
                            }
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        ) {
                            Text("Track GPS route", style = NoopType.body, color = Palette.textPrimary)
                            Spacer(Modifier.weight(1f))
                            Switch(checked = gpsOn, onCheckedChange = { gpsOn = it })
                        }
                    }
                },
                confirmButton = {
                    Button(onClick = {
                        if (gpsOn) {
                            startWithGps() // requests location, then starts in the callback (#101)
                        } else {
                            viewModel.startWorkout(selected, gpsEnabled = false)
                            showSportPicker = false
                        }
                    }) {
                        Text("Start ${selected.name}")
                    }
                },
                dismissButton = {
                    OutlinedButton(onClick = { showSportPicker = false }) { Text("Cancel") }
                },
            )
        }

        // Manual workout — start/stop a session yourself; records HR + strain until you end it.
        val w = activeWorkout
        if (w != null) {
            var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
            LaunchedEffect(w.startMs) {
                while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
            }
            val elapsedS = ((nowMs - w.startMs) / 1000).coerceAtLeast(0)
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text("● ${w.sport.name.uppercase()}", style = NoopType.overline, color = Palette.statusCritical)
                        Spacer(Modifier.weight(1f))
                        Text(
                            String.format("%d:%02d", elapsedS / 60, elapsedS % 60),
                            style = NoopType.title2, color = Palette.textPrimary,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                        StatTile(modifier = Modifier.weight(1f), label = "HR", value = bpm?.toString() ?: "—")
                        StatTile(modifier = Modifier.weight(1f), label = "Avg", value = if (w.avgHr > 0) "${w.avgHr}" else "—")
                        StatTile(modifier = Modifier.weight(1f), label = "Peak", value = if (w.peakHr > 0) "${w.peakHr}" else "—")
                        StatTile(modifier = Modifier.weight(1f), label = "Strain", value = String.format("%.1f", w.liveStrain))
                    }
                    if (w.gpsEnabled) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                            StatTile(modifier = Modifier.weight(1f), label = "Distance", value = String.format("%.2f km", w.distanceM / 1000.0))
                            StatTile(modifier = Modifier.weight(1f), label = "Pace", value = w.paceSecPerKm?.let { String.format("%d:%02d /km", (it / 60).toInt(), (it % 60).toInt()) } ?: "—")
                        }
                    }
                    Button(
                        onClick = { viewModel.endWorkout() },
                        modifier = Modifier.fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("End workout", style = NoopType.captionNumber) }
                }
            }
        } else {
            if (live.bonded) {
                Button(
                    onClick = { showSportPicker = true },
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) { Text("Start workout", style = NoopType.captionNumber) }
            }
            lastWorkout?.let { row ->
                val mins = ((row.durationS ?: 0.0) / 60).toInt()
                val parts = listOfNotNull(
                    "$mins min",
                    row.distanceM?.let { String.format("%.2f km", it / 1000.0) },
                    row.avgHr?.let { "$it avg bpm" },
                    row.strain?.let { String.format("strain %.1f", it) },
                )
                Text(
                    "✓ ${row.sport} saved · ${parts.joinToString(" · ")}",
                    style = NoopType.footnote, color = Palette.textSecondary,
                )
                row.routePolyline?.let { RouteCanvas(it, modifier = Modifier.padding(top = 8.dp)) }
            }
        }

        // Strap picker — choose the model before scanning so we look for exactly one device family.
        // Shown whenever we're not actively streaming, so a user with both a WHOOP 4 and a 5/MG can
        // switch between them (it used to hide once `bonded`, which stuck after the first pairing).
        if (!(live.connected && live.bonded)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Strap", style = NoopType.footnote, color = Palette.textSecondary)
                SegmentedPillControl(
                    items = WhoopModel.entries.toList(),
                    selection = selectedModel,
                    label = { it.displayName },
                    onSelect = { viewModel.setSelectedModel(it) },
                )
            }
        }

        // Controls.
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
                onClick = { viewModel.buzz(2) },
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
                    "Buzz",
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
                    "End",
                    style = NoopType.captionNumber,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Clip,
                )
            }
        }

        // Foolproof connection walkthrough — detects each blocker (WHOOP app, Bluetooth,
        // permission) and offers a one-tap fix. Hidden once the strap is bonded.
        if (!live.bonded) {
            ConnectionHelp(viewModel, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun HeartRateCard(bpm: Int?, rr: List<Int>) {
    val color by animateColorAsState(
        if (bpm == null) Palette.textSecondary else Palette.accentHover,
        tween(Motion.durationStandard), label = "hrColor",
    )
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, shape)
            .border(1.dp, Palette.hairline, shape)
            .padding(vertical = 28.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Overline("Heart Rate")
            Text(
                text = bpm?.toString() ?: "—",
                style = NoopType.number(96f),
                color = color,
            )
            Text("bpm", style = NoopType.subhead, color = Palette.textSecondary)
            if (rr.isNotEmpty()) {
                Spacer(Modifier.padding(top = 4.dp))
                Text(
                    text = "R-R " + rr.takeLast(4).joinToString(" · ") + " ms",
                    style = NoopType.captionNumber,
                    color = Palette.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private fun batteryColor(pct: Double?): Color = when {
    pct == null -> Palette.textPrimary
    pct < 15 -> Palette.statusCritical
    pct < 30 -> Palette.statusWarning
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
