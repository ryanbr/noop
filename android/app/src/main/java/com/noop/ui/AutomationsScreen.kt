package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrZones
import com.noop.analytics.NapCandidate
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live
 * biometrics into on-device actions and haptic coaching. HR-zone coaching and the illness
 * watch are real + persisted (ViewModel-backed); the remaining toggles (stress nudge,
 * auto-lock) are still local UI placeholders mirroring AutomationsView.swift. The strap
 * firmware alarm moved to the Smart Alarm screen (#766).
 */
@Composable
fun AutomationsScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()

    // Double-tap action (parity since 4.2.8) — real + persisted via the ViewModel (NoopPrefs). The
    // dispatch runs in the ViewModel on a fresh strap DOUBLE_TAP event; this card just edits the choice.
    val doubleTapAction by viewModel.doubleTapAction.collectAsStateWithLifecycle()

    var stressNudge by remember { mutableStateOf(false) }
    var autoLockOnWristOff by remember { mutableStateOf(false) }
    // Illness watch is real + persisted (opt-OUT — the watch has always run on Android).
    val illnessWatch by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    // Battery alerts are real + persisted (opt-OUT, default ON; #368, thanks @ujix).
    val batteryAlerts by viewModel.batteryAlertsEnabled.collectAsStateWithLifecycle()
    val ctx = LocalContext.current

    // HR-zone coaching is real + persisted (zone-based, mirrors macOS): the ViewModel owns the toggle +
    // recovery option and buzzes the strap on entering the top zone (and Zone 1 if recovery is on).
    val profile = remember { ProfileStore.from(ctx.applicationContext) }
    val zoneCoaching by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val zoneCoachRecovery by viewModel.zoneCoachRecovery.collectAsStateWithLifecycle()
    // The Zone 5 entry threshold (≥ 90% of HR-max), from the same HrZones model used everywhere.
    val zone5Bpm = remember(profile.hrMax) {
        HrZones.zones(maxHR = profile.hrMax.toDouble()).zones.firstOrNull { it.number == 5 }?.lower?.roundToInt() ?: 0
    }

    // Inactivity reminder (#419) — real + persisted via InactivityPrefs (opt-in, default OFF). Seeded
    // once, written through on change (SharedPreferences isn't reactive). The buzz itself fires from the
    // BLE offload path (WhoopBleClient.maybeBuzzInactivity → the shipped SedentaryDetector engine); this
    // screen only edits the prefs the engine reads.
    var inactivityEnabled by remember { mutableStateOf(InactivityPrefs.enabled(ctx)) }
    var inactivityThreshold by remember { mutableStateOf(InactivityPrefs.thresholdMinutes(ctx)) }
    var inactivityReNudge by remember { mutableStateOf(InactivityPrefs.reNudgeMinutes(ctx)) }
    var inactivityBuzzLoops by remember { mutableStateOf(InactivityPrefs.buzzLoops(ctx)) }
    var inactivityActiveHours by remember { mutableStateOf(InactivityPrefs.activeHoursEnabled(ctx)) }
    var inactivityActiveStart by remember { mutableStateOf(InactivityPrefs.activeStartMinutes(ctx)) }
    var inactivityActiveEnd by remember { mutableStateOf(InactivityPrefs.activeEndMinutes(ctx)) }
    var inactivityOnlyWorn by remember { mutableStateOf(NotifPrefs.getBool(ctx, NotifPrefs.WORN, true)) }
    // The engine also requires the global notification master (default OFF); surface that dependency so
    // enabling the reminder while master is off isn't silently inert.
    val notifMasterOn = NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)

    // PERF (#707): lazy scaffold — each settings section is an unconditional top-level child, so each
    // becomes one `item { }` in the same order. No standalone Spacers (the eager `spacedBy(20.dp)` is
    // reproduced by the LazyColumn), so spacing is byte-identical; only on-screen sections compose + get
    // accessibility-walked on scroll.
    LazyScreenScaffold(
        title = "Automations",
        subtitle = "Make the strap do things — tap to act, walk away to lock, train by feel.",
    ) {
        // Double-tap (parity since 4.2.8): a real, persisted action picker bound to the ViewModel, with a
        // Test action button. Mirrors AutomationsView.swift's Picker (Apple-applicable subset only; no
        // lockScreen / runShortcut on Android).
        item {
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Double-tap",
            blurb = "Double-tap the strap to trigger an action on this device. (The strap exposes a single double-tap gesture.)",
            active = doubleTapAction != DoubleTapAction.NONE,
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("When I double-tap", style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                DoubleTapActionPicker(
                    selected = doubleTapAction,
                    onSelect = { viewModel.setDoubleTapAction(it) },
                )
            }
            RowDivider()
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = { viewModel.testDoubleTapAction() },
                    enabled = doubleTapAction != DoubleTapAction.NONE,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Test action", style = NoopType.body)
                }
                Spacer(Modifier.weight(1f))
                StatePill(
                    if (live.bonded) "Strap bonded" else "Not connected",
                    tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning,
                )
            }
        }
        }

        // Haptic coaching.
        item {
        SettingsSection(
            icon = Icons.Filled.Bolt,
            title = "Haptic coaching",
            blurb = "Train by feel — the strap buzzes so you don't have to watch a screen.",
            active = zoneCoaching || stressNudge,
        ) {
            ToggleRow(
                label = "HR-zone coaching",
                help = "A triple-buzz when you climb into your top zone (Zone 5, ≥ $zone5Bpm bpm) — a cue to ease off. Max HR comes from Settings.",
                checked = zoneCoaching,
                onChange = { viewModel.setZoneCoaching(it) },
            )
            if (zoneCoaching) {
                RowDivider()
                ToggleRow(
                    label = "Recovery buzz",
                    help = "Also buzz once when your heart rate drops back to Zone 1 — a cue that you've recovered.",
                    checked = zoneCoachRecovery,
                    onChange = { viewModel.setZoneCoachRecovery(it) },
                )
            }
            RowDivider()
            ToggleRow(
                label = "Resting stress nudge (experimental)",
                help = "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                checked = stressNudge,
                onChange = { stressNudge = it },
            )
        }
        }

        // Wear & presence.
        item {
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Wear & presence",
            blurb = "React when the strap comes off or goes on.",
            active = autoLockOnWristOff,
        ) {
            ToggleRow(
                label = "Lock the device when I take the strap off",
                help = "Fires the moment the strap leaves your wrist.",
                checked = autoLockOnWristOff,
                onChange = { autoLockOnWristOff = it },
            )
        }
        }

        // Inactivity reminder (#419) — real + persisted via InactivityPrefs; opt-in, default OFF.
        item {
        SettingsSection(
            icon = Icons.Filled.Timer,
            title = "Inactivity reminder",
            blurb = "A gentle wrist buzz when you've been sitting too long — a nudge to get up and move. Inferred from the strap's motion on each history sync, so it lags real time by a sync or two.",
            active = inactivityEnabled,
        ) {
            ToggleRow(
                label = "Enable inactivity reminder",
                help = "Buzzes after you've been sitting past your threshold.",
                checked = inactivityEnabled,
                onChange = {
                    inactivityEnabled = it
                    InactivityPrefs.setBool(ctx, InactivityPrefs.ENABLED, it)
                },
            )
            if (inactivityEnabled) {
                if (!notifMasterOn) {
                    RowDivider()
                    Text(
                        "Notifications are off, so this can't buzz yet — turn on the master switch in " +
                            "Settings → Notifications to let it through.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
                RowDivider()
                StepperRow(
                    label = "Sitting for",
                    help = "Minutes seated before the first nudge.",
                    value = inactivityThreshold, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityThreshold = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.THRESHOLD_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = "Re-nudge every",
                    help = "If you're still seated, buzz again this often.",
                    value = inactivityReNudge, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityReNudge = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.RENUDGE_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = "Buzz strength",
                    help = "How strong the buzz is.",
                    value = inactivityBuzzLoops, suffix = "×", range = 1..4, step = 1,
                    onChange = {
                        inactivityBuzzLoops = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.BUZZ_LOOPS, it)
                    },
                )
                RowDivider()
                ToggleRow(
                    label = "Only when worn",
                    help = "Don't buzz when the strap is off your wrist.",
                    checked = inactivityOnlyWorn,
                    onChange = {
                        inactivityOnlyWorn = it
                        // Reuses the shared notification only-when-worn gate (NotifPrefs.WORN).
                        NotifPrefs.setBool(ctx, NotifPrefs.WORN, it)
                    },
                )
                RowDivider()
                ToggleRow(
                    label = "Only during active hours",
                    help = "Only nudge during your active hours.",
                    checked = inactivityActiveHours,
                    onChange = {
                        inactivityActiveHours = it
                        InactivityPrefs.setBool(ctx, InactivityPrefs.ACTIVE_HOURS_ENABLED, it)
                    },
                )
                if (inactivityActiveHours) {
                    RowDivider()
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("From", style = NoopType.body, color = Palette.textPrimary)
                        Spacer(Modifier.weight(1f))
                        TimeChip(
                            minutes = inactivityActiveStart,
                            accessibilityLabel = "Active hours start",
                            onPicked = {
                                inactivityActiveStart = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_START_MIN, it)
                            },
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("to", style = NoopType.body, color = Palette.textSecondary)
                        Spacer(Modifier.width(8.dp))
                        TimeChip(
                            minutes = inactivityActiveEnd,
                            accessibilityLabel = "Active hours end",
                            onPicked = {
                                inactivityActiveEnd = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_END_MIN, it)
                            },
                        )
                    }
                }
            }
        }
        }

        // On-device short-nap detection (PR #569 reimpl) — opt-in, default OFF. Detected on the offload
        // hook; a confident nap is offered as a review card you accept (it becomes a nap session) or
        // dismiss. NEVER auto-written.
        item { NapDetectionSection(viewModel) }

        // Illness early-warning (real + persisted; opt-OUT — the watch has always run on Android).
        item {
        SettingsSection(
            icon = Icons.Filled.MonitorHeart,
            title = "Illness early-warning",
            blurb = "Watches your resting HR, HRV, skin temperature and respiration against your own 28-day baseline. On-device and approximate — informational only, not a diagnosis.",
            active = illnessWatch,
        ) {
            ToggleRow(
                label = "Watch for early-illness signs",
                help = "Needs at least 14 days of history. When two or more signals drift together you get a banner on Today and a notification — at most once a day.",
                checked = illnessWatch,
                onChange = { viewModel.setIllnessWatchEnabled(it) },
            )
        }
        }

        // Battery alerts (real + persisted; opt-OUT, default ON — #368, thanks @ujix).
        item {
        SettingsSection(
            icon = Icons.Filled.BatteryStd,
            title = "Battery alerts",
            blurb = "A heads-up when the strap battery gets low so you can recharge before bed, and a note when it's finished charging.",
            active = batteryAlerts,
        ) {
            ToggleRow(
                label = "Notify on low and full battery",
                help = "Sends a notification when the strap drops to 15% or reaches a full charge — at most once per charge cycle.",
                checked = batteryAlerts,
                onChange = { viewModel.setBatteryAlertsEnabled(it) },
            )
        }
        }
    }
}

// MARK: - On-device nap detection (PR #569 reimpl under NoopApp)

/**
 * The nap-detection automation: a toggle plus the REVIEW queue. Detection runs on the offload hook
 * (WhoopBleClient.maybeDetectNaps → the pure NapDetector); a confident NAP is queued in NapStore and shown
 * here as a card the user ACCEPTS (→ a manual nap session, the #508 path) or DISMISSES. The engine never
 * auto-writes a session, and an INCONCLUSIVE window queues nothing — honest by construction.
 */
@Composable
private fun NapDetectionSection(viewModel: AppViewModel) {
    val scope = rememberCoroutineScope()
    val enabled by viewModel.napDetectionEnabled.collectAsStateWithLifecycle()
    // The queue isn't a reactive flow (it's written from the BLE layer); re-read it on each toggle/action.
    var pending by remember { mutableStateOf(viewModel.pendingNaps()) }

    SettingsSection(
        icon = Icons.Filled.Bedtime,
        title = "Nap detection",
        blurb = "Spots a likely daytime nap from the strap's motion and heart rate on each history sync, " +
            "then asks you to confirm it. Inferred and approximate — NOOP never adds a nap to your sleep " +
            "without your OK.",
        active = enabled,
    ) {
        ToggleRow(
            label = "Detect short naps",
            help = "When a sync shows a quiet, settled stretch in the day, NOOP offers it here for you to keep or skip.",
            checked = enabled,
            onChange = {
                viewModel.setNapDetectionEnabled(it)
                if (it) pending = viewModel.pendingNaps()
            },
        )
        if (enabled) {
            if (pending.isEmpty()) {
                RowDivider()
                Text(
                    "No naps to review. Detected naps show up here after a history sync.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            } else {
                pending.forEach { nap ->
                    RowDivider()
                    NapReviewRow(
                        nap = nap,
                        onAccept = { scope.launch { pending = viewModel.acceptDetectedNap(nap) } },
                        onDismiss = { pending = viewModel.dismissDetectedNap(nap) },
                    )
                }
            }
        }
    }
}

/** One pending nap candidate: an honest "HH:mm–HH:mm · ~N min" line (+ mean HR when known) with Keep /
 *  Skip controls. Keep persists it as a nap session; Skip forgets it (and won't re-queue the window). */
@Composable
private fun NapReviewRow(nap: NapCandidate, onAccept: () -> Unit, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(napWindowLabel(nap, ctx), style = NoopType.body, color = Palette.textPrimary)
            Text(napDetailLabel(nap), style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(8.dp))
        NapActionButton(Icons.Filled.Check, "Keep this nap", Palette.statusPositive, onAccept)
        Spacer(Modifier.width(8.dp))
        NapActionButton(Icons.Filled.Close, "Skip this nap", Palette.textTertiary, onDismiss)
    }
}

@Composable
private fun NapActionButton(icon: ImageVector, contentDescription: String, tint: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(18.dp))
    }
}

/** "HH:mm–HH:mm · ~N min", local time. Pure-ish (reads the device clock format only). */
private fun napWindowLabel(nap: NapCandidate, ctx: android.content.Context): String {
    val fmt = android.text.format.DateFormat.getTimeFormat(ctx)
    val start = fmt.format(java.util.Date(nap.start * 1000L))
    val end = fmt.format(java.util.Date(nap.end * 1000L))
    val mins = nap.durationS / 60
    return "$start – $end · ~$mins min"
}

private fun napDetailLabel(nap: NapCandidate): String =
    if (nap.meanHr != null) "Quiet and settled, mean HR ~${nap.meanHr} bpm." else "Quiet and settled."

// MARK: - Section + rows (mirror the settings idiom from AutomationsView.swift)

@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    active: Boolean = false,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Automation")
                    if (active) Overline("ON", color = Palette.accent)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (active) Palette.accent else Palette.textSecondary,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

/** A compact dropdown that mirrors the iOS double-tap Picker: a tappable label + chevron that opens a
 *  menu of [DoubleTapAction]s. Labels come from [DoubleTapAction.label] so both clients read the same. */
@Composable
private fun DoubleTapActionPicker(
    selected: DoubleTapAction,
    onSelect: (DoubleTapAction) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .clickable { expanded = true }
                .background(Palette.surfaceInset)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(selected.label, style = NoopType.body, color = Palette.textPrimary)
            Spacer(Modifier.width(4.dp))
            Icon(
                Icons.Filled.ArrowDropDown,
                contentDescription = "Choose double-tap action",
                tint = Palette.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (action in DoubleTapAction.entries) {
                DropdownMenuItem(
                    text = {
                        Text(
                            action.label,
                            style = NoopType.body,
                            color = if (action == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = { onSelect(action); expanded = false },
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(vertical = 4.dp)
            .background(Palette.hairline),
    )
}

/** A label/help row with a −[value]+ stepper, clamped to [range] and moved by [step]. */
@Composable
private fun StepperRow(
    label: String,
    help: String,
    value: Int,
    suffix: String,
    range: IntRange,
    step: Int,
    onChange: (Int) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(12.dp))
        StepButton(Icons.Filled.Remove, "Decrease $label", enabled = value > range.first) {
            onChange((value - step).coerceAtLeast(range.first))
        }
        Text(
            "$value $suffix",
            style = NoopType.body,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp).widthIn(min = 56.dp),
        )
        StepButton(Icons.Filled.Add, "Increase $label", enabled = value < range.last) {
            onChange((value + step).coerceAtMost(range.last))
        }
    }
}

@Composable
private fun StepButton(icon: ImageVector, contentDescription: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = if (enabled) Palette.accent else Palette.textTertiary,
        )
    }
}
