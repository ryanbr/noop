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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.draw.clip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrZones
import com.noop.ble.StandardHrSource
import kotlinx.coroutines.delay

/**
 * Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
 * elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
 * app uses (no invented numbers). Shown full-screen while a manual workout is active, entered from
 * the Start-workout control. End stops the workout and dismisses.
 *
 * Live HR is the smoothed [AppViewModel.bpm]; the zone is derived from the user's HR-max via the
 * shared [HrZones] model; elapsed time ticks from the workout's start; effort is the running
 * [AppViewModel.ActiveWorkout.liveStrain] (StrainScorer over the captured window). Keeps the realtime
 * HR stream on while visible, ref-counted in the ViewModel so it hands off cleanly with Live/Health.
 */
@Composable
fun LiveWorkoutScreen(vm: AppViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    // Effort display scale (#268) — routes the live Effort read-out so it matches every other surface.
    val effortScale = UnitPrefs.effortScale(context)
    val unitSystem = UnitPrefs.system(context)
    val bpm by vm.bpm.collectAsStateWithLifecycle()
    val activeWorkout by vm.activeWorkout.collectAsStateWithLifecycle()
    // Additive: instantaneous speed/cadence/power from a connected standard fitness sensor (RSC/CSC/CPS),
    // read ALONGSIDE HR by the SourceCoordinator's isolated StandardHrSource. Empty (all-null) when no such
    // sensor is feeding, so the readout below hides entirely — a plain HR-only workout looks unchanged. HR
    // / zone / effort above are untouched.
    val sensor by remember(context) {
        (context.applicationContext as com.noop.NoopApplication).sourceCoordinator.sensorMetrics
    }.collectAsStateWithLifecycle()

    // Keep the live HR stream on for the duration of the workout screen (ref-counted with Live/Health).
    DisposableEffect(Unit) {
        vm.requestRealtimeHr()
        onDispose { vm.releaseRealtimeHr() }
    }

    // Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    // Read the same pref key the iOS @AppStorage uses ("workoutKeepScreenOn") and flag the view's window
    // only while this screen is up, clearing it on the way out so normal screen-timeout resumes. Mirrors
    // iOS calling ScreenIdle.keepAwake(true) on appear and false on disappear.
    val view = LocalView.current
    DisposableEffect(Unit) {
        val on = NoopPrefs.of(context).getBoolean("workoutKeepScreenOn", false)
        if (on) view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    val w = activeWorkout
    // If the workout ended elsewhere (e.g. process restart cleared it), close out.
    LaunchedEffect(w == null) { if (w == null) onClose() }
    if (w == null) return

    val zoneSet = remember(profile.hrMax, profile.hrZoneThresholds) { profile.hrZoneSet }
    val zone = bpm?.let { zoneSet.zoneNumber(it.toDouble()) } ?: 0

    // Guards the destructive End action behind a confirm (#517) — a stray tap on the full-width
    // button used to end the workout instantly with no way back.
    var showEndConfirm by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(w.startMs) {
        while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
    }
    val currentPauseMs = w.pausedAtMs?.let { nowMs - it } ?: 0L
    val elapsedS = ((nowMs - w.startMs - w.pausedDurationMs - currentPauseMs) / 1000).coerceAtLeast(0)

    // A scenic Effort-tinted backdrop behind the whole in-exercise screen — the live workout reads as
    // an Effort-world hero, not a flat panel.
    Box(modifier = Modifier.fillMaxSize().background(Palette.surfaceBase)) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Effort)
        // #845: the in-exercise content is fixed-height (HR hero + effort gauge + zone rail + stat row +
        // End button). On a tall, content-dense screen it ran PAST the available height: the old layout was a
        // plain fillMaxSize Column with a weighted Spacer pushing End down, so when content overflowed the
        // Spacer collapsed to nothing and the bottom Avg/Peak/Effort stat row got squeezed against the edge
        // with its values clipped. Make the column scrollable so the whole stack stays fully readable when it
        // doesn't fit, and add navigationBarsPadding so the bottom row/button clear the Android 15 gesture
        // inset. When everything DOES fit there's nothing to scroll, so it looks unchanged.
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(28.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Header — sport name on the left, a recording-status capsule on the right (glanceable
            // hierarchy parity with the iOS live-workout redesign; the elapsed clock moved to its own
            // centered TIME hero below).
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    w.sport.name, style = NoopType.title1, color = Palette.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier
                        .background(Palette.metricRose.copy(alpha = 0.12f), RoundedCornerShape(50))
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(Palette.metricRose))
                    Overline(
                        if (w.pausedAtMs != null) uiString(R.string.workout_action_paused)
                        else uiString(R.string.workout_action_recording),
                        color = Palette.metricRose,
                    )
                }
            }

            // Centered TIME hero — the elapsed clock, promoted out of the header into the glanceable stack.
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Overline("Time", color = Palette.textSecondary)
                Text(
                    String.format("%d:%02d", elapsedS / 60, elapsedS % 60),
                    style = NoopType.number(56f), color = Palette.textPrimary,
                )
            }

            // Centered live-HR hero — tinted to the current zone; the zone label sits on the zone rail below.
            HeroHeartRate(bpm = bpm, zone = zone)

            // The accumulating Effort — same liveStrain source and 0–21 / 0–100 scale, rendered as a centered
            // free metric to sit alongside TIME and HEART RATE. Keeps the "of N" scale the iOS redesign dropped.
            EffortGauge(liveStrain = w.liveStrain, effortScale = effortScale)

            // Zone section — the zone label capsule on the header row, the five-segment rail, and the band.
            ZoneRail(zone = zone, zoneSet = zoneSet)

            // Live stats grid — avg / peak / effort, from the captured window.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_avg_cdc93143), value = if (w.avgHr > 0) "${w.avgHr}" else "—",
                    accent = if (w.avgHr > 0) Palette.metricRose else Palette.textPrimary)
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_peak_c83dbbd3), value = if (w.peakHr > 0) "${w.peakHr}" else "—",
                    accent = if (w.peakHr > 0) Palette.metricRose else Palette.textPrimary)
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_effort_8c974bc6), value = UnitFormatter.effortDisplay(w.liveStrain, effortScale),
                    accent = Palette.strainColor(w.liveStrain))
            }

            // Live GPS distance + average pace for distance sports (#1195). The values are already computed
            // and published on every accepted fix (mirrored from GpsSession into ActiveWorkout) — this only
            // surfaces them live, where before they appeared solely in the post-workout detail. Hidden until
            // the first accepted fix, so a denied-permission session shows no empty tiles. Reuses the already
            // localized "Distance"/"Pace" labels. Mirrors the iOS DistancePaceRowIfPresent leaf.
            if (w.gpsEnabled && w.track.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                    StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_distance_42320809),
                        value = UnitFormatter.distanceFromMeters(w.distanceM, unitSystem), accent = Palette.effortColor)
                    StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_screen_pace_7a9a6226),
                        value = UnitFormatter.paceFromSecPerKm(w.paceSecPerKm, unitSystem), accent = Palette.effortColor)
                }
            }

            // Additive sensor readout — only renders when a connected standard fitness sensor is feeding.
            SensorRow(sensor)

            // #845: a fixed gap before End instead of a weighted Spacer. A weight needs a bounded height to
            // share out, but the column is now scrollable (unbounded), so a weighted Spacer can't size and
            // the End button would no longer be separated from the stats. A constant gap keeps the spacing
            // and the button stays reachable by scrolling when the content overflows.
            Spacer(Modifier.height(12.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = { vm.toggleWorkoutPause() }, modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) { Text(if (w.pausedAtMs != null) uiString(R.string.workout_action_resume) else uiString(R.string.workout_action_pause), style = NoopType.headline) }
                Button(
                    onClick = { showDeleteConfirm = true }, modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(vertical = 14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Palette.statusCritical),
                ) { Text(uiString(R.string.workout_action_delete), style = NoopType.headline) }
                Button(
                    onClick = { showEndConfirm = true }, modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) { Text(uiString(R.string.workout_action_end), style = NoopType.headline) }
            }
        }
    }

    // Confirm before ending (#517): a stray tap on "End workout" used to stop the session and
    // discard the in-progress recording with no way back.
    if (showEndConfirm) {
        AlertDialog(
            onDismissRequest = { showEndConfirm = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    uiString(R.string.l10n_live_workout_screen_end_this_workout_4869c76a),
                    style = NoopType.title2, color = Palette.textPrimary,
                )
            },
            text = {
                Text(
                    uiString(R.string.l10n_live_workout_screen_this_stops_recording_and_saves_what_3e17a23e),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = { showEndConfirm = false; vm.endWorkout(); onClose() }) {
                    Text(
                        uiString(R.string.l10n_live_workout_screen_end_workout_3e8d6238),
                        style = NoopType.body, color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { showEndConfirm = false }) {
                    Text(
                        uiString(R.string.l10n_live_workout_screen_cancel_77dfd213),
                        style = NoopType.body, color = Palette.textSecondary,
                    )
                }
            },
        )
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.workout_delete_title), style = NoopType.title2, color = Palette.textPrimary) },
            text = { Text(uiString(R.string.workout_delete_message), style = NoopType.subhead, color = Palette.textSecondary) },
            confirmButton = {
                TextButton(onClick = { showDeleteConfirm = false; vm.discardWorkout(); onClose() }) {
                    Text(uiString(R.string.workout_action_delete), style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) {
                    Text(uiString(R.string.l10n_live_workout_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

/**
 * Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor / power
 * meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent render — each
 * tile is dropped when its value is absent, and the whole row is hidden when nothing is present, so a plain
 * HR-only workout looks exactly as before. Honest units: speed km/h, cadence per-minute (steps for running
 * / rpm for cycling), power watts. Reuses the same metric tile as the HR stats grid; tinted with the Effort
 * world so it reads as part of the hero. Nothing here touches HR / zone / effort.
 */
@Composable
private fun SensorRow(sensor: StandardHrSource.SensorMetrics) {
    val speed = StandardHrSource.formatSpeedKmh(sensor.speedKmh)
    val cadence = StandardHrSource.formatCadence(sensor.cadence)
    val power = StandardHrSource.formatPowerWatts(sensor.powerWatts)
    if (speed == null && cadence == null && power == null) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Overline("Sensor")
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            if (speed != null) {
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_speed_2d2cb022), value = "$speed km/h", accent = Palette.effortColor)
            }
            if (cadence != null) {
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_cadence_68af11f0), value = "$cadence/min", accent = Palette.effortColor)
            }
            if (power != null) {
                StatTile(modifier = Modifier.weight(1f), label = uiString(R.string.l10n_live_workout_screen_power_7548ab52), value = "$power W", accent = Palette.effortColor)
            }
        }
    }
}

@Composable
private fun EffortGauge(liveStrain: Double, effortScale: EffortScale) {
    val outOf = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0
    val value = UnitFormatter.effortValue(liveStrain, effortScale)
    // A centered free metric to sit alongside TIME and HEART RATE (glanceable parity with the iOS
    // live-workout redesign). The value counts up; the scale denominator stays visible below — a bare
    // number on the WHOOP 0–21 scale is ambiguous without "of 21", so unlike the iOS change we keep it.
    // mergeDescendants: read "Effort building, <value>, of N" as one TalkBack utterance (the CountUpText
    // otherwise reads on its own), matching the iOS effort VoiceOver label without new strings.
    Column(
        modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Overline("Effort building", color = Palette.effortColor)
        CountUpText(
            value = value,
            format = { v ->
                if (effortScale == EffortScale.WHOOP) String.format(java.util.Locale.US, "%.1f", v)
                else v.toInt().toString()
            },
            style = NoopType.number(56f),
            color = Palette.textPrimary,
        )
        Text(
            uiString(R.string.l10n_live_workout_screen_of_c5e92da0, outOf.toInt()),
            style = NoopType.captionNumber, color = Palette.textSecondary,
        )
    }
}

@Composable
private fun HeroHeartRate(bpm: Int?, zone: Int) {
    val tint = when {
        bpm == null -> Palette.textSecondary
        zone >= 1 -> Palette.hrZoneColor(zone)
        else -> Palette.effortColor
    }
    // Centered free metric — no card chrome, matching the TIME and EFFORT heroes. The zone label moved
    // to the zone-rail header row below, so the heart rate reads as one clean value.
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Overline("Heart rate", color = Palette.textSecondary)
        Text(bpm?.toString() ?: "—", style = NoopType.number(72f), color = tint)
        Text("bpm", style = NoopType.subhead, color = Palette.textSecondary)
    }
}

@Composable
private fun ZoneRail(zone: Int, zoneSet: com.noop.analytics.HrZoneSet) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Header row: the section label with the current-zone capsule on the right (moved off the HR hero).
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Overline("HR zone")
            Spacer(Modifier.weight(1f))
            val capsuleTint = if (zone >= 1) Palette.hrZoneColor(zone) else Palette.effortColor
            Text(
                if (zone >= 1) "Zone $zone · ${zoneName(zone)}" else "Below Zone 1",
                style = NoopType.captionNumber,
                color = capsuleTint,
                modifier = Modifier
                    .background(capsuleTint.copy(alpha = 0.12f), RoundedCornerShape(50))
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            (1..5).forEach { z ->
                val active = z == zone
                val color = Palette.hrZoneColor(z)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(if (active) 44.dp else 34.dp)
                        .background(
                            if (active) color else color.copy(alpha = 0.18f),
                            RoundedCornerShape(8.dp),
                        )
                        .border(
                            1.dp,
                            if (active) color else Palette.hairline,
                            RoundedCornerShape(8.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        uiString(R.string.l10n_live_workout_screen_z_z_d3991a28, z),
                        style = NoopType.captionNumber,
                        color = if (active) Palette.surfaceBase else Palette.textTertiary,
                    )
                }
            }
        }
        // The bpm band of the current zone, so the rail reads as concrete, not abstract.
        val band = zoneSet.zones.firstOrNull { it.number == zone }
        Text(
            if (band != null)
                "Zone $zone: ${band.lower.toInt()} - ${band.upper.toInt()} bpm (${(band.lowerPct * 100).toInt()} - ${(band.upperPct * 100).toInt()}% max HR)"
            else "Warming up - keep moving to climb into Zone 1.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

private fun zoneName(zone: Int): String = when (zone) {
    1 -> "Recovery"
    2 -> "Fat burn"
    3 -> "Aerobic"
    4 -> "Threshold"
    5 -> "Maximum"
    else -> ""
}
