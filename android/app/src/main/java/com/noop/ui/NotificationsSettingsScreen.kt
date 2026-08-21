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
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
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
    var appQuery by remember { mutableStateOf("") }

    val enabledState = remember { mutableStateMapOf<String, Boolean>().apply { notifCatalog.forEach { put(it.id, NotifPrefs.appEnabled(context, it.id)) } } }
    val patternState = remember { mutableStateMapOf<String, BuzzPattern>().apply { notifCatalog.forEach { put(it.id, NotifPrefs.appPattern(context, it)) } } }
    val phonePermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        phoneCalls = granted
        permissionDenied = !granted
        NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, granted)
    }
    val enabledApps = enabledState.values.count { it }
    val deliveryReady = master && live.connected && live.encryptedBond && (!wornOnly || live.worn) && !quiet
    val notificationAccess = notificationAccessGranted(context)

    ScreenScaffold(title = "Notifications", subtitle = "Make the information you need reach your wrist.") {
        NotificationHero(master, live.connected, live.encryptedBond, live.worn, deliveryReady, enabledApps, {
            master = it
            NotifPrefs.setBool(context, NotifPrefs.MASTER, it)
            if (!it) CallAlertController.stopAll()
        }) { vm.buzz(loops = 2) }

        CallsControlCard(master, calls, phoneCalls, voipCalls, callPattern, live.connected && live.encryptedBond, permissionDenied,
            { calls = it; NotifPrefs.setBool(context, NotifPrefs.CALLS_MASTER, it); if (!it) CallAlertController.stopAll() },
            { value ->
                if (!value) {
                    phoneCalls = false; permissionDenied = false
                    NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, false)
                    CallAlertController.stopSource(CallAlertSource.PHONE)
                } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
                    phoneCalls = true; permissionDenied = false
                    NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, true)
                } else phonePermissionLauncher.launch(Manifest.permission.READ_PHONE_STATE)
            },
            { voipCalls = it; NotifPrefs.setBool(context, NotifPrefs.CALLS_VOIP, it); if (!it) CallAlertController.stopSource(CallAlertSource.VOIP) },
            { callPattern = it; NotifPrefs.setCallPattern(context, it) },
            { vm.buzz(loops = callPattern.loops) })

        AppsControlCard(master, appQuery, { appQuery = it }, enabledState, patternState,
            { app, value -> enabledState[app.id] = value; NotifPrefs.setAppEnabled(context, app.id, value) },
            { app, pattern -> patternState[app.id] = pattern; NotifPrefs.setAppPattern(context, app.id, pattern) },
            { app -> vm.buzz(loops = (patternState[app.id] ?: app.category.defaultPattern).loops) })

        NotificationBehaviourCard(master, wornOnly, quiet, alarmTimer, allOther,
            { wornOnly = it; NotifPrefs.setBool(context, NotifPrefs.WORN, it) },
            { quiet = it; NotifPrefs.setBool(context, NotifPrefs.QUIET, it) },
            { alarmTimer = it; NotifPrefs.setBool(context, NotifPrefs.ALARM_TIMER, it) },
            { allOther = it; NotifPrefs.setBool(context, NotifPrefs.ALL_OTHER, it) })
        AccessCard(context, notificationAccess)
        DiagnosticsCard(context, master, live.connected, live.encryptedBond, live.worn, notificationAccess, calls && (phoneCalls || voipCalls))
    }
}

@Composable
private fun NotificationHero(enabled: Boolean, connected: Boolean, encryptedBond: Boolean, worn: Boolean, ready: Boolean, enabledApps: Int, onMasterChange: (Boolean) -> Unit, onTest: () -> Unit) {
    NoopCard(padding = 20.dp, tint = if (ready) Palette.accent else Palette.hairline) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Overline("WRIST ALERTS", color = Palette.accent)
                    Text("Notification bridge", style = NoopType.title2, color = Palette.textPrimary)
                    Text(when {
                        !enabled -> "Off — your WHOOP will stay quiet."
                        !connected -> "Waiting for your WHOOP to connect."
                        !encryptedBond -> "Connected, but the secure command link is not ready."
                        !worn -> "Strap connected, but not currently worn."
                        else -> "Ready — important events can reach your wrist."
                    }, style = NoopType.subhead, color = Palette.textSecondary)
                }
                NoopSwitch(enabled, onMasterChange, true, "Wrist alerts")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusChip(Icons.Filled.Watch, if (connected) "WHOOP connected" else "WHOOP offline", connected)
                StatusChip(Icons.Filled.CheckCircle, if (encryptedBond) "Secure link" else "Link not ready", encryptedBond)
                StatusChip(Icons.Filled.NotificationsActive, "$enabledApps apps", enabledApps > 0)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Test your wrist", style = NoopType.body, color = Palette.textPrimary)
                    Text("Sends a short two-pulse test now.", style = NoopType.footnote, color = Palette.textTertiary)
                }
                ActionPill("Test buzz", Icons.Filled.GraphicEq, connected && encryptedBond, onTest)
            }
        }
    }
}

@Composable
private fun CallsControlCard(master: Boolean, enabled: Boolean, phoneEnabled: Boolean, voipEnabled: Boolean, pattern: BuzzPattern, commandReady: Boolean, permissionDenied: Boolean, onEnabled: (Boolean) -> Unit, onPhone: (Boolean) -> Unit, onVoip: (Boolean) -> Unit, onPattern: (BuzzPattern) -> Unit, onTest: () -> Unit) {
    SectionCard(Icons.Filled.Call, "Calls", "Phone calls deserve the most obvious wrist cue.") {
        ToggleRow("Incoming calls", "Master switch for call haptics.", enabled, master, onEnabled)
        if (enabled) {
            DividerLine()
            ToggleRow("Phone calls", "Native cellular calls. NOOP does not upload numbers or call logs.", phoneEnabled, master, onPhone)
            if (permissionDenied) Text("Phone permission was denied. Turn it on in Android Settings to detect calls.", style = NoopType.footnote, color = Palette.statusCritical)
            DividerLine()
            ToggleRow("VoIP calls", "Best-effort detection for supported calling apps.", voipEnabled, master, onVoip)
            DividerLine()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Call pattern", style = NoopType.body, color = Palette.textPrimary)
                    Text("Immediate buzz + finite reminders while ringing.", style = NoopType.footnote, color = Palette.textTertiary)
                }
                PatternPicker(pattern, master, onPattern)
                ActionPill("Test", Icons.Filled.GraphicEq, commandReady && master, onTest)
            }
        }
    }
}

@Composable
private fun AppsControlCard(master: Boolean, query: String, onQueryChange: (String) -> Unit, enabledState: SnapshotStateMap<String, Boolean>, patternState: SnapshotStateMap<String, BuzzPattern>, onToggle: (NotifApp, Boolean) -> Unit, onPattern: (NotifApp, BuzzPattern) -> Unit, onTest: (NotifApp) -> Unit) {
    val filtered = remember(query) {
        val normalized = query.trim().lowercase()
        if (normalized.isEmpty()) notifCatalog else notifCatalog.filter { it.name.lowercase().contains(normalized) || it.id.lowercase().contains(normalized) }
    }
    SectionCard(Icons.Filled.NotificationsActive, "Apps", "Choose exactly which notifications deserve your attention.") {
        OutlinedTextField(value = query, onValueChange = onQueryChange, modifier = Modifier.fillMaxWidth(), singleLine = true, leadingIcon = { Icon(Icons.Filled.Search, null) }, placeholder = { Text("Search apps") }, shape = RoundedCornerShape(12.dp))
        if (filtered.isEmpty()) {
            Text("No supported app matches this search.", style = NoopType.footnote, color = Palette.textTertiary)
        } else {
            filtered.groupBy { it.category }.forEach { (category, apps) ->
                Text(category.title, style = NoopType.caption, color = Palette.accent)
                apps.forEachIndexed { index, app ->
                    AppAlertRow(app, enabledState[app.id] ?: false, patternState[app.id] ?: app.category.defaultPattern, master, { onToggle(app, it) }, { onPattern(app, it) }, { onTest(app) })
                    if (index != apps.lastIndex) DividerLine()
                }
            }
        }
    }
}

@Composable
private fun AppAlertRow(app: NotifApp, enabled: Boolean, pattern: BuzzPattern, interactive: Boolean, onToggle: (Boolean) -> Unit, onPattern: (BuzzPattern) -> Unit, onTest: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (enabled) Palette.accentMuted.copy(alpha = 0.45f) else Palette.surfaceInset.copy(alpha = 0.45f)).padding(horizontal = 10.dp, vertical = 9.dp).alpha(if (interactive) 1f else Palette.disabledOpacity),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(34.dp).clip(RoundedCornerShape(9.dp)).background(Palette.surfaceRaised), Alignment.Center) { Icon(app.glyph, null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp)) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(app.name, style = NoopType.body, color = Palette.textPrimary)
            Text(if (enabled) "Wrist alert enabled" else "Off", style = NoopType.footnote, color = if (enabled) Palette.accent else Palette.textTertiary)
        }
        if (enabled) {
            PatternPicker(pattern, interactive, onPattern)
            ActionPill("Test", Icons.Filled.GraphicEq, interactive, onTest)
        }
        NoopSwitch(enabled, onToggle, interactive, "${app.name} wrist alert")
    }
}

@Composable
private fun NotificationBehaviourCard(master: Boolean, wornOnly: Boolean, quiet: Boolean, alarmTimer: Boolean, allOther: Boolean, onWornOnly: (Boolean) -> Unit, onQuiet: (Boolean) -> Unit, onAlarm: (Boolean) -> Unit, onAllOther: (Boolean) -> Unit) {
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
private fun AccessCard(context: Context, notificationAccess: Boolean) {
    val phonePermission = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
    SectionCard(Icons.Filled.Settings, "Permissions & privacy", "NOOP needs Android notification access to see app events.") {
        StatusRow(Icons.Filled.NotificationsActive, "Notification access", if (notificationAccess) "Enabled — app events can be received locally." else "Required for app and VoIP notification detection.", notificationAccess)
        StatusRow(Icons.Filled.Phone, "Phone state permission", if (phonePermission) "Enabled — native call state can be detected." else "Required only for native cellular call detection.", phonePermission)
        DividerLine()
        Text("Notification contents stay on this phone. NOOP uses the posting app and event state to decide whether to buzz your WHOOP.", style = NoopType.footnote, color = Palette.textSecondary)
        ActionPill("Open Notification Access", Icons.Filled.OpenInNew, true) { runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
    }
}

@Composable
private fun DiagnosticsCard(context: Context, enabled: Boolean, connected: Boolean, encryptedBond: Boolean, worn: Boolean, notificationAccess: Boolean, callsEnabled: Boolean) {
    val wearGate = NotifPrefs.getBool(context, NotifPrefs.WORN, true)
    val ready = enabled && connected && encryptedBond && notificationAccess && (!wearGate || worn)
    SectionCard(Icons.Filled.GraphicEq, "Delivery diagnostics", "A quick explanation of why an alert can or cannot reach your wrist.") {
        StatusRow(Icons.Filled.Watch, "WHOOP connection", if (connected) "Connected" else "Disconnected — connect your WHOOP first.", connected)
        StatusRow(Icons.Filled.CheckCircle, "Secure command link", if (encryptedBond) "Ready for haptic commands" else "Not ready — haptics will be held.", encryptedBond)
        StatusRow(Icons.Filled.NotificationsActive, "Notification listener", if (notificationAccess) "Ready for app events" else "Disabled — app alerts and VoIP detection are unavailable.", notificationAccess)
        StatusRow(Icons.Filled.Call, "Call alerts", if (callsEnabled) "Enabled" else "Disabled", callsEnabled)
        DividerLine()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Overall readiness", style = NoopType.body, color = Palette.textPrimary)
                Text(if (ready) "Everything required for local wrist delivery is ready." else "One or more prerequisites need attention.", style = NoopType.footnote, color = Palette.textTertiary)
            }
            StatusChip(Icons.Filled.CheckCircle, if (ready) "READY" else "CHECK", ready)
        }
    }
}

@Composable
private fun StatusRow(icon: ImageVector, title: String, detail: String, positive: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, null, tint = if (positive) Palette.accent else Palette.textTertiary, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NoopType.body, color = Palette.textPrimary)
            Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
        }
        StatusChip(Icons.Filled.CheckCircle, if (positive) "OK" else "WAIT", positive)
    }
}

private fun notificationAccessGranted(context: Context): Boolean {
    val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
    return enabled.split(":").any { component -> component.startsWith(context.packageName) }
}

@Composable
private fun SectionCard(icon: ImageVector, title: String, subtitle: String, content: @Composable () -> Unit) {
    NoopCard(padding = 18.dp, tint = Palette.hairline) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(Palette.accentMuted), Alignment.Center) { Icon(icon, null, tint = Palette.accent, modifier = Modifier.size(18.dp)) }
                Column { Text(title, style = NoopType.title2, color = Palette.textPrimary); Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary) }
            }
            content()
        }
    }
}

@Composable
private fun ToggleRow(label: String, help: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) { Text(label, style = NoopType.body, color = Palette.textPrimary); Text(help, style = NoopType.footnote, color = Palette.textTertiary) }
        Spacer(Modifier.width(12.dp))
        NoopSwitch(checked, onChange, enabled, label)
    }
}

@Composable
private fun StatusChip(icon: ImageVector, text: String, positive: Boolean) {
    val tint = if (positive) Palette.accent else Palette.textTertiary
    Row(
        modifier = Modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceInset).border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(13.dp))
        Text(text, style = NoopType.caption, color = tint)
    }
}

@Composable
private fun ActionPill(label: String, icon: ImageVector, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (enabled) Palette.accent else Palette.textTertiary
    Row(
        modifier = Modifier.clip(RoundedCornerShape(50)).background(tint.copy(alpha = if (enabled) 0.12f else 0.04f)).border(1.dp, tint.copy(alpha = 0.25f), RoundedCornerShape(50)).clickable(enabled = enabled, onClick = onClick).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(13.dp))
        Text(label, style = NoopType.caption, color = tint)
    }
}

@Composable
private fun PatternPicker(pattern: BuzzPattern, enabled: Boolean, onSelect: (BuzzPattern) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ActionPill(pattern.label, Icons.Filled.GraphicEq, enabled) { expanded = true }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            BuzzPattern.entries.forEach { option ->
                DropdownMenuItem(text = { Text(if (option == pattern) "✓ ${option.label}" else option.label, color = Palette.textPrimary) }, onClick = { onSelect(option); expanded = false })
            }
        }
    }
}

@Composable
private fun NoopSwitch(checked: Boolean, onChange: (Boolean) -> Unit, enabled: Boolean, label: String) {
    Switch(checked = checked, onCheckedChange = onChange, enabled = enabled, colors = SwitchDefaults.colors(checkedThumbColor = Palette.surfaceBase, checkedTrackColor = Palette.accent, uncheckedThumbColor = Palette.textSecondary, uncheckedTrackColor = Palette.surfaceInset, uncheckedBorderColor = Palette.hairline))
}
