package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.notif.CallAlertController
import com.noop.notif.CallAlertSource

/**
 * NOOP Next notification control centre.
 *
 * The previous screen mixed every setting into a long list. This version puts the important
 * path first: enable wrist alerts, verify the strap, configure calls, then configure apps.
 * Existing preference keys are intentionally preserved so upgrades don't reset the user's choices.
 */
@Composable
fun NotificationsSettingsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()

    var master by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) }
    var calls by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) }
    var phoneCalls by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_PHONE, false)) }
    var voipCalls by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_VOIP, false)) }
    var wornOnly by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.WORN, true)) }
    var quiet by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.QUIET, false)) }
    var alarmTimer by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.ALARM_TIMER, false)) }
    var allOther by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.ALL_OTHER, false)) }
    var callPattern by remember { mutableStateOf(NotifPrefs.callPattern(context)) }
    var permissionDenied by remember { mutableStateOf(false) }

    val enabledState: SnapshotStateMap<String, Boolean> = remember {
        mutableStateMapOf<String, Boolean>().apply {
            notifCatalog.forEach { put(it.id, NotifPrefs.appEnabled(context, it.id)) }
        }
    }
    val patternState: SnapshotStateMap<String, BuzzPattern> = remember {
        mutableStateMapOf<String, BuzzPattern>().apply {
            notifCatalog.forEach { put(it.id, NotifPrefs.appPattern(context, it)) }
        }
    }

    val phonePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        phoneCalls = granted
        permissionDenied = !granted
        NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, granted)
    }

    val enabledApps = enabledState.values.count { it }
    val deliveryReady = master && live.connected && (!wornOnly || live.worn) && !quiet

    ScreenScaffold(
        title = "Notifications",
        subtitle = "Make the information you need reach your wrist.",
    ) {
        NotificationHero(
            enabled = master,
            connected = live.connected,
            worn = live.worn,
            ready = deliveryReady,
            enabledApps = enabledApps,
            onMasterChange = {
                master = it
                NotifPrefs.setBool(context, NotifPrefs.MASTER, it)
                if (!it) CallAlertController.stopAll()
            },
            onTest = { vm.buzz(loops = 2) },
        )

        CallsControlCard(
            master = master,
            enabled = calls,
            phoneEnabled = phoneCalls,
            voipEnabled = voipCalls,
            pattern = callPattern,
            bonded = live.bonded,
            permissionDenied = permissionDenied,
            onEnabled = {
                calls = it
                NotifPrefs.setBool(context, NotifPrefs.CALLS_MASTER, it)
                if (!it) CallAlertController.stopAll()
            },
            onPhone = { value ->
                if (!value) {
                    phoneCalls = false
                    permissionDenied = false
                    NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, false)
                    CallAlertController.stopSource(CallAlertSource.PHONE)
                } else {
                    val granted = ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.READ_PHONE_STATE,
                    ) == PackageManager.PERMISSION_GRANTED
                    if (granted) {
                        phoneCalls = true
                        permissionDenied = false
                        NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, true)
                    } else {
                        phonePermissionLauncher.launch(Manifest.permission.READ_PHONE_STATE)
                    }
                }
            },
            onVoip = {
                voipCalls = it
                NotifPrefs.setBool(context, NotifPrefs.CALLS_VOIP, it)
                if (!it) CallAlertController.stopSource(CallAlertSource.VOIP)
            },
            onPattern = {
                callPattern = it
                NotifPrefs.setCallPattern(context, it)
            },
            onTest = { vm.buzz(loops = callPattern.loops) },
        )

        AppsControlCard(
            master = master,
            enabledState = enabledState,
            patternState = patternState,
            onToggle = { app, value ->
                enabledState[app.id] = value
                NotifPrefs.setAppEnabled(context, app.id, value)
            },
            onPattern = { app, pattern ->
                patternState[app.id] = pattern
                NotifPrefs.setAppPattern(context, app.id, pattern)
            },
            onTest = { app -> vm.buzz(loops = (patternState[app.id] ?: app.category.defaultPattern).loops) },
        )

        NotificationBehaviourCard(
            master = master,
            wornOnly = wornOnly,
            quiet = quiet,
            alarmTimer = alarmTimer,
            allOther = allOther,
            onWornOnly = {
                wornOnly = it
                NotifPrefs.setBool(context, NotifPrefs.WORN, it)
            },
            onQuiet = {
                quiet = it
                NotifPrefs.setBool(context, NotifPrefs.QUIET, it)
            },
            onAlarm = {
                alarmTimer = it
                NotifPrefs.setBool(context, NotifPrefs.ALARM_TIMER, it)
            },
            onAllOther = {
                allOther = it
                NotifPrefs.setBool(context, NotifPrefs.ALL_OTHER, it)
            },
        )

        AccessCard(context = context)
    }
}

@Composable
private fun NotificationHero(
    enabled: Boolean,
    connected: Boolean,
    worn: Boolean,
    ready: Boolean,
    enabledApps: Int,
    onMasterChange: (Boolean) -> Unit,
    onTest: () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = if (ready) Palette.accent else Palette.hairline) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Overline("WRIST ALERTS", color = Palette.accent)
                    Text("Notification bridge", style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        when {
                            !enabled -> "Off — your WHOOP will stay quiet."
                            !connected -> "Waiting for your WHOOP to connect."
                            !worn -> "Strap connected, but not currently worn."
                            else -> "Ready — important events can reach your wrist."
                        },
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
                NoopSwitch(checked = enabled, onChange = onMasterChange, enabled = true, label = "Wrist alerts")
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusChip(
                    icon = Icons.Filled.Watch,
                    text = if (connected) "WHOOP connected" else "WHOOP offline",
                    positive = connected,
                )
                StatusChip(
                    icon = Icons.Filled.CheckCircle,
                    text = "$enabledApps apps",
                    positive = enabledApps > 0,
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Test your wrist", style = NoopType.body, color = Palette.textPrimary)
                    Text("Sends a short two-pulse test now.", style = NoopType.footnote, color = Palette.textTertiary)
                }
                ActionPill("Test buzz", Icons.Filled.GraphicEq, connected, onTest)
            }
        }
    }
}

@Composable
private fun CallsControlCard(
    master: Boolean,
    enabled: Boolean,
    phoneEnabled: Boolean,
    voipEnabled: Boolean,
    pattern: BuzzPattern,
    bonded: Boolean,
    permissionDenied: Boolean,
    onEnabled: (Boolean) -> Unit,
    onPhone: (Boolean) -> Unit,
    onVoip: (Boolean) -> Unit,
    onPattern: (BuzzPattern) -> Unit,
    onTest: () -> Unit,
) {
    SectionCard(Icons.Filled.Call, "Calls", "Phone calls deserve the most obvious wrist cue.") {
        ToggleRow("Incoming calls", "Master switch for call haptics.", enabled, master, onEnabled)
        if (enabled) {
            DividerLine()
            ToggleRow("Phone calls", "Native cellular calls. NOOP does not upload numbers or call logs.", phoneEnabled, master, onPhone)
            if (permissionDenied) {
                Text("Phone permission was denied. Turn it on in Android Settings to detect calls.", style = NoopType.footnote, color = Palette.statusCritical)
            }
            DividerLine()
            ToggleRow("VoIP calls", "Best-effort detection for supported calling apps.", voipEnabled, master, onVoip)
            DividerLine()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Call pattern", style = NoopType.body, color = Palette.textPrimary)
                    Text("Immediate buzz + finite reminders while ringing.", style = NoopType.footnote, color = Palette.textTertiary)
                }
                PatternPicker(pattern, master, "call alerts", onPattern)
                ActionPill("Test", Icons.Filled.GraphicEq, bonded && master, onTest)
            }
        }
    }
}

@Composable
private fun AppsControlCard(
    master: Boolean,
    enabledState: SnapshotStateMap<String, Boolean>,
    patternState: SnapshotStateMap<String, BuzzPattern>,
    onToggle: (NotifApp, Boolean) -> Unit,
    onPattern: (NotifApp, BuzzPattern) -> Unit,
    onTest: (NotifApp) -> Unit,
) {
    SectionCard(Icons.Filled.NotificationsActive, "Apps", "Choose exactly which notifications deserve your attention.") {
        val grouped = notifCatalog.groupBy { it.category }
        grouped.forEach { (category, apps) ->
            Text(category.title, style = NoopType.caption, color = Palette.accent)
            apps.forEachIndexed { index, app ->
                AppAlertRow(
                    app = app,
                    enabled = enabledState[app.id] ?: false,
                    pattern = patternState[app.id] ?: app.category.defaultPattern,
                    interactive = master,
                    onToggle = { onToggle(app, it) },
                    onPattern = { onPattern(app, it) },
                    onTest = { onTest(app) },
                )
                if (index != apps.lastIndex) DividerLine()
            }
            if (category != grouped.keys.last()) Spacer(Modifier.size(10.dp))
        }
    }
}

@Composable
private fun AppAlertRow(
    app: NotifApp,
    enabled: Boolean,
    pattern: BuzzPattern,
    interactive: Boolean,
    onToggle: (Boolean) -> Unit,
    onPattern: (BuzzPattern) -> Unit,
    onTest: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (enabled) Palette.accentMuted.copy(alpha = 0.45f) else Palette.surfaceInset.copy(alpha = 0.45f))
            .padding(horizontal = 10.dp, vertical = 9.dp)
            .alpha(if (interactive) 1f else Palette.disabledOpacity),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(34.dp).clip(RoundedCornerShape(9.dp)).background(Palette.surfaceRaised),
            contentAlignment = Alignment.Center,
        ) {
            Icon(app.glyph, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(app.name, style = NoopType.body, color = Palette.textPrimary)
            Text(if (enabled) "Wrist alert enabled" else "Off", style = NoopType.footnote, color = if (enabled) Palette.accent else Palette.textTertiary)
        }
        if (enabled) {
            PatternPicker(pattern, interactive, app.name, onPattern)
            ActionPill("Test", Icons.Filled.GraphicEq, interactive, onTest)
        }
        NoopSwitch(checked = enabled, onChange = onToggle, enabled = interactive, label = "${app.name} wrist alert")
    }
}

@Composable
private fun NotificationBehaviourCard(
    master: Boolean,
    wornOnly: Boolean,
    quiet: Boolean,
    alarmTimer: Boolean,
    allOther: Boolean,
    onWornOnly: (Boolean) -> Unit,
    onQuiet: (Boolean) -> Unit,
    onAlarm: (Boolean) -> Unit,
    onAllOther: (Boolean) -> Unit,
) {
    SectionCard(Icons.Filled.Tune, "Behaviour", "Rules that keep wrist alerts useful instead of noisy.") {
        ToggleRow("Only when worn", "Don't buzz an unattended strap.", wornOnly, master, onWornOnly)
        DividerLine()
        ToggleRow("Quiet hours", "Mute all wrist alerts during your saved quiet window.", quiet, master, onQuiet)
        DividerLine()
        ToggleRow("Phone alarms & timers", "Buzz when another clock app posts an alarm notification.", alarmTimer, master, onAlarm)
        DividerLine()
        ToggleRow("Other apps", "Allow notifications from apps not listed above. This can be noisy.", allOther, master, onAllOther)
    }
}

@Composable
private fun AccessCard(context: Context) {
    SectionCard(Icons.Filled.Settings, "Permissions & privacy", "NOOP needs Android notification access to see app events.") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                "Notification contents stay on this phone. NOOP uses the posting app and event state to decide whether to buzz your WHOOP.",
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        ActionPill(
            "Open Notification Access",
            Icons.Filled.OpenInNew,
            true,
        ) {
            runCatching {
                context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}

@Composable
private fun SectionCard(icon: ImageVector, title: String, subtitle: String, content: @Composable () -> Unit) {
    NoopCard(padding = 18.dp, tint = Palette.hairline) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    modifier = Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(Palette.accentMuted),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                }
                Column {
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
            content()
        }
    }
}

@Composable
private fun ToggleRow(label: String, help: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(12.dp))
        NoopSwitch(checked, onChange, enabled, label)
    }
}

@Composable
private fun StatusChip(icon: ImageVector, text: String, positive: Boolean) {
    val tint = if (positive) Palette.accent else Palette.textTertiary
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceInset)
            .border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(13.dp))
        Text(text, style = NoopType.caption, color = tint)
    }
}

@Composable
private fun ActionPill(label: String, icon: ImageVector, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (enabled) Palette.accent else Palette.textTertiary
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = if (enabled) 0.12f else 0.04f))
            .border(1.dp, tint.copy(alpha = 0.25f), RoundedCornerShape(50))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(13.dp))
        Text(label, style = NoopType.caption, color = tint)
    }
}

@Composable
private fun PatternPicker(pattern: BuzzPattern, enabled: Boolean, name: String, onSelect: (BuzzPattern) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ActionPill(pattern.label, Icons.Filled.GraphicEq, enabled) { expanded = true }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            BuzzPattern.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(if (option == pattern) "✓ ${option.label}" else option.label, color = Palette.textPrimary) },
                    onClick = {
                        onSelect(option)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun NoopSwitch(checked: Boolean, onChange: (Boolean) -> Unit, enabled: Boolean, label: String) {
    Switch(
        checked = checked,
        onCheckedChange = onChange,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = Palette.surfaceBase,
            checkedTrackColor = Palette.accent,
            uncheckedThumbColor = Palette.textSecondary,
            uncheckedTrackColor = Palette.surfaceInset,
            uncheckedBorderColor = Palette.hairline,
        ),
    )
}

@Composable
private fun DividerLine() {
    Box(modifier = Modifier.fillMaxWidth().size(height = 1.dp, width = 1.dp).background(Palette.hairline.copy(alpha = 0.65f)))
}
