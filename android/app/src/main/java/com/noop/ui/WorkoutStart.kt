package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Sport
import com.noop.analytics.WorkoutSport
import kotlinx.coroutines.delay

/**
 * The shared "Start a workout" picker — sport search + GPS toggle, then [AppViewModel.startWorkout].
 * Lives in one place so both the Live screen and the Workouts screen open the SAME sheet (#115).
 *
 * GPS needs ACCESS_FINE_LOCATION, which the BLE flow does NOT grant on Android 12+, so a GPS start
 * requests it first and falls back to a route-less workout if denied (#101). Calls [onDismiss] once
 * the workout has started (or the user cancels).
 */
@Composable
fun StartWorkoutSheet(vm: AppViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf<Sport>(WorkoutSport.default) }
    var gpsOn by remember(selected) { mutableStateOf(selected.isDistanceSport) }
    val filtered = WorkoutSport.all.filter { it.name.contains(query, ignoreCase = true) }
    // #297: the user's last selections, one tap away above the full catalogue. Only catalogue-resolvable
    // recents show here — a live start selects a typed [Sport], and the shared store can hold free-typed
    // names from the manual add/edit picker. Hidden once the user starts searching.
    val recents = if (query.isBlank()) {
        RecentSportsPrefs.recent(context)
            .mapNotNull { n -> WorkoutSport.all.firstOrNull { it.name.equals(n, ignoreCase = true) } }
    } else {
        emptyList()
    }
    val sportScroll = rememberScrollState()
    // Live workout mode (#238): once a workout begins, the sheet transitions IN PLACE into the full
    // in-exercise screen — staying mounted so its state survives — and only tells the parent to close
    // (onDismiss) when the live workout itself is closed. Hosted HERE so BOTH entry points (Live +
    // Workouts) that use this sheet get the live workout without each screen wiring it.
    var showLiveWorkout by remember { mutableStateOf(false) }
    val startWithGps = rememberRequestLocation { granted ->
        vm.startWorkout(selected, gpsEnabled = gpsOn && granted)
        showLiveWorkout = true
    }

    if (showLiveWorkout) {
        Dialog(
            onDismissRequest = { showLiveWorkout = false; onDismiss() },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            LiveWorkoutScreen(vm = vm, onClose = { showLiveWorkout = false; onDismiss() })
        }
        return
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(uiString(R.string.l10n_workout_start_start_a_workout_32caf94d)) },
        text = {
            Column {
                OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    label = { Text(uiString(R.string.l10n_workout_start_search_sport_004b7928)) }, singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Column(
                    modifier = Modifier.heightIn(max = 240.dp)
                        .simpleVerticalScrollbar(sportScroll)
                        .verticalScroll(sportScroll),
                ) {
                    if (recents.isNotEmpty()) {
                        Overline("Recent", modifier = Modifier.padding(top = 6.dp))
                        recents.forEach { sp ->
                            StartSportRow(sp, isSelected = sp == selected) {
                                selected = sp; gpsOn = sp.isDistanceSport
                            }
                        }
                        Overline("All activities", modifier = Modifier.padding(top = 6.dp))
                    }
                    filtered.forEach { sp ->
                        StartSportRow(sp, isSelected = sp == selected) {
                            selected = sp; gpsOn = sp.isDistanceSport
                        }
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                ) {
                    Text(uiString(R.string.l10n_workout_start_track_gps_route_133861c5), style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Switch(checked = gpsOn, onCheckedChange = { gpsOn = it })
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                // #297: a confirmed start is a real selection — fold it into the recents (recorded even
                // if the GPS permission is then denied; the workout still starts route-less, #101).
                RecentSportsPrefs.record(context, selected.name)
                if (gpsOn) {
                    startWithGps() // requests location, then starts + opens live workout in the callback (#101)
                } else {
                    vm.startWorkout(selected, gpsEnabled = false)
                    showLiveWorkout = true
                }
            }) {
                Text(uiString(R.string.l10n_workout_start_start_selected_name_10603889, selected.name))
            }
        },
        dismissButton = {
            OutlinedButton(onClick = onDismiss) { Text(uiString(R.string.l10n_workout_start_cancel_77dfd213)) }
        },
    )
}

/** One tappable sport row — shared by the #297 Recent block and the full catalogue list. */
@Composable
private fun StartSportRow(sp: Sport, isSelected: Boolean, onPick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .clickable(onClick = onPick)
            .padding(vertical = 10.dp),
    ) {
        // Per-sport glyph (shared sportIcon catalogue), so the picker reads by icon like the iOS
        // workout selection screen and the Workouts list rows — not a bare text list.
        Icon(
            sportIcon(sp.name), contentDescription = null,
            tint = if (isSelected) Palette.accent else Palette.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            sp.name, style = NoopType.body,
            color = if (isSelected) Palette.accent else Palette.textPrimary,
        )
        if (sp.isDistanceSport) {
            Spacer(Modifier.width(6.dp))
            Text(uiString(R.string.l10n_workout_start_gps_124667d8), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

/**
 * Start-a-workout entry for the Workouts screen (#115) — mirrors the Live screen's control so a user
 * can begin a session from either place. Shows a compact "running" banner while a workout is active
 * (the rich live card stays on Live); otherwise an action row with Start (when a strap is bonded, since
 * a live session needs the strap to stream) beside Add — or just Add when there's no strap.
 */
@Composable
fun WorkoutStartSection(vm: AppViewModel, onAdd: () -> Unit) {
    val live by vm.live.collectAsStateWithLifecycle()
    val activeWorkout by vm.activeWorkout.collectAsStateWithLifecycle()
    var showSportPicker by remember { mutableStateOf(false) }
    var confirmingEnd by remember { mutableStateOf(false) }
    // Live workout mode (#238): the full-screen in-exercise view. StartWorkoutSheet opens it the
    // moment a workout begins; this re-entry lets the user re-open it from the compact banner after
    // dismissing. Closing just hides the overlay — the workout keeps recording in the background.
    var showLiveWorkout by remember { mutableStateOf(false) }

    val w = activeWorkout
    if (w != null) {
        var nowMs by remember { mutableStateOf(w.startMs) }
        LaunchedEffect(w.startMs) {
            while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
        }
        val elapsedS = ActiveWorkoutClock.activeElapsedSeconds(
            startMs = w.startMs, pausedAtMs = w.pausedAtMs,
            pausedDurationMs = w.pausedDurationMs, nowMs = nowMs,
        )
        // Recording: the live banner, with Add kept visible below so a past workout can still be logged
        // mid-session (it used to live in the range bar).
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            NoopCard {
                // Two rows, not one: this banner already carried a sport label, a clock, Open and End,
                // and a third button would squeeze all five onto one line on a narrow phone. The state
                // reads on top, the actions sit below with equal weight.
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text(uiString(R.string.l10n_workout_start_w_sport_name_uppercase_e59bc678, w.sport.name.uppercase()), style = NoopType.overline, color = Palette.statusCritical)
                        // A frozen clock alone is ambiguous with a STALLED one, so say which it is. Reuses
                        // the string #1533 already localized rather than minting new copy for a tag.
                        if (w.pausedAtMs != null) {
                            Spacer(Modifier.width(8.dp))
                            Text(uiString(R.string.workout_action_paused), style = NoopType.overline, color = Palette.textSecondary)
                        }
                        Spacer(Modifier.width(10.dp))
                        // elapsedClock, not a local %d:%02d — that one had no hour roll-over at all, so a
                        // 90-minute session read "90:00" here while every other surface read "1:30:00".
                        Text(elapsedClock(elapsedS), style = NoopType.title2, color = Palette.textPrimary)
                        Spacer(Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        // End was reachable here and Pause was not, so the only control this banner
                        // offered without opening the live view was the irreversible one.
                        Button(
                            onClick = { vm.toggleWorkoutPause() },
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text(
                                if (w.pausedAtMs != null) uiString(R.string.workout_action_resume)
                                else uiString(R.string.workout_action_pause),
                                style = NoopType.captionNumber,
                            )
                        }
                        // Re-open the full-screen live workout view.
                        OutlinedButton(
                            onClick = { showLiveWorkout = true },
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        ) { Text(uiString(R.string.l10n_workout_start_open_cf9b7706), style = NoopType.captionNumber) }
                        Button(
                            onClick = { confirmingEnd = true },
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase,
                            ),
                        ) { Text(uiString(R.string.l10n_workout_start_end_a2bb9d34), style = NoopType.captionNumber) }
                    }
                }
            }
            AddWorkoutButton(onAdd, Modifier.fillMaxWidth())
        }
    } else if (live.bonded) {
        // Start + Add as an equal-width action row (EXP-018 parity with the iOS workoutActionRow).
        //
        // #1602: CENTRED, not top-aligned. A Row defaults to `Alignment.Top`, so any height difference
        // between the two children showed as one button riding higher than the other — which is how this
        // was reported. The heights are now matched in `AddWorkoutButton`, so this is belt-and-braces:
        // it keeps a future divergence looking like a size difference rather than a broken layout.
        // SwiftUI's HStack centres by default, which is why the iOS twin never showed it.
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Button(
                onClick = { showSportPicker = true },
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                ),
            ) { Text(uiString(R.string.l10n_workout_start_start_workout_d0f3f2cd), style = NoopType.captionNumber) }
            AddWorkoutButton(onAdd, Modifier.weight(1f))
        }
    } else {
        // No strap to stream from: no live Start, but keep Add so a user with no imports can still log.
        AddWorkoutButton(onAdd, Modifier.fillMaxWidth())
    }

    if (showSportPicker) {
        StartWorkoutSheet(vm = vm, onDismiss = { showSportPicker = false })
    }

    // The full-screen live workout overlay (#238). A plain full-screen Dialog so it floats over
    // whichever screen launched it. Dismiss just hides it; End (inside) stops the workout.
    if (showLiveWorkout && activeWorkout != null) {
        Dialog(
            onDismissRequest = { showLiveWorkout = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            LiveWorkoutScreen(vm = vm, onClose = { showLiveWorkout = false })
        }
    }

    if (confirmingEnd) {
        EndWorkoutConfirmationDialog(
            onConfirm = {
                confirmingEnd = false
                vm.endWorkout()
            },
            onDismiss = { confirmingEnd = false },
        )
    }
}

/**
 * A thin scroll indicator drawn on the right edge of a vertically-scrolling container, so a capped
 * list — like the named-sport picker (~25 sports, WorkoutSport.all) — visibly reads as scrollable
 * rather than complete. Only paints when there is overflow.
 */
private fun Modifier.simpleVerticalScrollbar(state: ScrollState, width: Dp = 3.dp): Modifier =
    drawWithContent {
        drawContent()
        if (state.maxValue > 0) {
            val viewport = size.height
            val contentH = viewport + state.maxValue
            val thumbH = (viewport / contentH) * viewport
            val thumbY = (state.value.toFloat() / state.maxValue) * (viewport - thumbH)
            val w = width.toPx()
            drawRoundRect(
                color = Palette.textTertiary.copy(alpha = 0.5f),
                topLeft = Offset(size.width - w, thumbY),
                size = Size(w, thumbH),
                cornerRadius = CornerRadius(w / 2, w / 2),
            )
        }
    }
