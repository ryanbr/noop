package com.noop.ui

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberTimePickerState
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle

// MARK: - NotificationsSettingsScreen
//
// Android port of NotificationSettingsView.swift. Choose which apps tap your wrist and
// how (per-app buzz pattern), with a master switch and overnight quiet hours.
//
// macOS resolves real installed apps via LaunchServices/NSWorkspace. Android restricts
// package visibility (API 30+) and there is no equivalent "notification-capable app"
// query, so we ship a curated catalog of common notification apps grouped exactly like
// the Mac screen. Preferences persist in SharedPreferences (the Android counterpart to
// UserDefaults); when the background bridge ships it reads the same prefs.
//
// Delivery requires a NotificationListenerService with Notification Access granted — the
// behaviour card deep-links to Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS for that.

// MARK: - Domain model (mirrors NotificationSettingsStore.swift)

/** Haptic pattern fired on the strap; only the repeat count varies. */
internal enum class BuzzPattern(val label: String, val loops: Int) {
    Single("Single", 1),
    Double("Double", 2),
    Triple("Triple", 3),
    Long("Long", 5),
}

/** Grouping for the settings screen, with its header icon + default pattern. */
internal enum class NotifCategory(
    val title: String,
    val icon: ImageVector,
    val defaultPattern: BuzzPattern,
) {
    Email("Email", Icons.Filled.Email, BuzzPattern.Double),
    Messaging("Messaging", Icons.Filled.Chat, BuzzPattern.Single),
    Meetings("Meetings & Calls", Icons.Filled.Videocam, BuzzPattern.Triple),
    Calendar("Calendar & Reminders", Icons.Filled.CalendarMonth, BuzzPattern.Double),
}

/** A notification-capable app NOOP can mirror to the wrist. `id` is the persistence key. */
internal data class NotifApp(
    val id: String,
    val name: String,
    val category: NotifCategory,
    val glyph: ImageVector,
)

/**
 * Curated catalog of common Android notification apps, grouped to match the Mac screen.
 * Unlike macOS we cannot enumerate which are actually installed (restricted package
 * visibility), so we present the full set as configurable examples.
 */
private val notifCatalog: List<NotifApp> = listOf(
    NotifApp("com.google.android.gm", "Gmail", NotifCategory.Email, Icons.Filled.Email),
    NotifApp("com.microsoft.office.outlook", "Outlook", NotifCategory.Email, Icons.Filled.Email),
    NotifApp("com.whatsapp", "WhatsApp", NotifCategory.Messaging, Icons.Filled.Chat),
    NotifApp("com.google.android.apps.messaging", "Messages", NotifCategory.Messaging, Icons.Filled.Chat),
    NotifApp("com.Slack", "Slack", NotifCategory.Messaging, Icons.Filled.Chat),
    NotifApp("org.telegram.messenger", "Telegram", NotifCategory.Messaging, Icons.Filled.Chat),
    NotifApp("com.microsoft.teams", "Microsoft Teams", NotifCategory.Meetings, Icons.Filled.Videocam),
    NotifApp("us.zoom.videomeetings", "Zoom", NotifCategory.Meetings, Icons.Filled.Videocam),
    NotifApp("com.google.android.calendar", "Calendar", NotifCategory.Calendar, Icons.Filled.CalendarMonth),
)

private fun appsIn(category: NotifCategory): List<NotifApp> =
    notifCatalog.filter { it.category == category }

private val activeCategories: List<NotifCategory> =
    NotifCategory.entries.filter { appsIn(it).isNotEmpty() }

// MARK: - SharedPreferences store (mirrors the UserDefaults-backed Swift store)

/**
 * Plain-prefs store for wrist-alert settings (the AI key uses encrypted prefs; these are
 * non-secret toggles). Per-app prefs are flattened to `app.<id>.enabled` / `app.<id>.pattern`
 * keys so no JSON dependency is needed.
 */
internal object NotifPrefs {
    private const val FILE = "noop_notif_prefs"
    const val MASTER = "notif.masterEnabled"
    const val WORN = "notif.onlyWhenWorn"
    const val QUIET = "notif.quietHoursEnabled"
    const val QUIET_START = "notif.quietStartMinutes"
    const val QUIET_END = "notif.quietEndMinutes"

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun getBool(ctx: Context, key: String, default: Boolean) =
        prefs(ctx).getBoolean(key, default)

    fun setBool(ctx: Context, key: String, value: Boolean) =
        prefs(ctx).edit().putBoolean(key, value).apply()

    fun getInt(ctx: Context, key: String, default: Int) =
        prefs(ctx).getInt(key, default)

    fun setInt(ctx: Context, key: String, value: Int) =
        prefs(ctx).edit().putInt(key, value).apply()

    fun appEnabled(ctx: Context, id: String): Boolean =
        prefs(ctx).getBoolean("app.$id.enabled", false) // opt-in, default OFF

    fun setAppEnabled(ctx: Context, id: String, value: Boolean) =
        prefs(ctx).edit().putBoolean("app.$id.enabled", value).apply()

    fun appPattern(ctx: Context, app: NotifApp): BuzzPattern {
        val name = prefs(ctx).getString("app.${app.id}.pattern", null)
        return BuzzPattern.entries.firstOrNull { it.name == name } ?: app.category.defaultPattern
    }

    fun setAppPattern(ctx: Context, id: String, pattern: BuzzPattern) =
        prefs(ctx).edit().putString("app.$id.pattern", pattern.name).apply()

    /** Buzz loop-count for [pkg] (for the notification listener; no NotifApp needed). Defaults to
     *  Double if no per-app pattern was chosen. */
    fun appLoops(ctx: Context, pkg: String): Int {
        val name = prefs(ctx).getString("app.$pkg.pattern", null)
        return BuzzPattern.entries.firstOrNull { it.name == name }?.loops ?: BuzzPattern.Double.loops
    }
}

// MARK: - Screen

@Composable
fun NotificationsSettingsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()

    // Header settings, seeded from prefs once and written through on change.
    var masterEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) }
    var onlyWhenWorn by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.WORN, true)) }
    var quietHoursEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.QUIET, false)) }
    var quietStartMinutes by remember { mutableStateOf(NotifPrefs.getInt(context, NotifPrefs.QUIET_START, 22 * 60)) }
    var quietEndMinutes by remember { mutableStateOf(NotifPrefs.getInt(context, NotifPrefs.QUIET_END, 7 * 60)) }

    // Per-app enabled state, seeded from prefs so the UI is reactive within the session.
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
    val enabledCount = enabledState.values.count { it }

    ScreenScaffold(
        title = "Notifications",
        subtitle = "Buzz your strap when these apps notify you. Everything runs on this device.",
    ) {
        // MARK: Master card
        AlertSection(
            icon = Icons.Filled.NotificationsActive,
            title = "Wrist alerts",
            blurb = "When on, NOOP taps your wrist for the apps you pick below — so you can leave " +
                "your phone and still feel what matters.",
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Enable wrist alerts", style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                NoopSwitch(
                    checked = masterEnabled,
                    onChange = {
                        masterEnabled = it
                        NotifPrefs.setBool(context, NotifPrefs.MASTER, it)
                    },
                    label = "Enable wrist alerts",
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                StatePill(strapPillTitle(live), tone = strapPillTone(live), pulsing = live.connected)
                StatePill(
                    "$enabledCount app${if (enabledCount == 1) "" else "s"} on",
                    tone = if (enabledCount > 0) StrandTone.Positive else StrandTone.Neutral,
                    showsDot = false,
                )
                Spacer(Modifier.weight(1f))
                PillButton(
                    label = "Test buzz",
                    icon = Icons.Filled.GraphicEq,
                    enabled = live.bonded,
                    onClick = { vm.buzz(loops = 2) },
                )
            }

            DeliveryNote()
        }

        // MARK: Category cards
        activeCategories.forEach { cat ->
            CategoryCard(
                category = cat,
                apps = appsIn(cat),
                masterEnabled = masterEnabled,
                bonded = live.bonded,
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
        }

        // MARK: Behaviour card
        AlertSection(
            icon = Icons.Filled.Tune,
            title = "Behaviour",
            blurb = "Fine-tune when alerts reach your wrist.",
        ) {
            FormToggleRow(
                label = "Only buzz when worn",
                help = "Skip alerts when the strap is off your wrist.",
                checked = onlyWhenWorn,
                onChange = {
                    onlyWhenWorn = it
                    NotifPrefs.setBool(context, NotifPrefs.WORN, it)
                },
            )
            RowDivider()
            FormToggleRow(
                label = "Quiet hours",
                help = "Mute wrist alerts overnight.",
                checked = quietHoursEnabled,
                onChange = {
                    quietHoursEnabled = it
                    NotifPrefs.setBool(context, NotifPrefs.QUIET, it)
                },
            )
            if (quietHoursEnabled) {
                RowDivider()
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("From", style = NoopType.body, color = Palette.textPrimary)
                    TimeChip(
                        minutes = quietStartMinutes,
                        accessibilityLabel = "Quiet hours start",
                        onPicked = {
                            quietStartMinutes = it
                            NotifPrefs.setInt(context, NotifPrefs.QUIET_START, it)
                        },
                    )
                    Text("to", style = NoopType.body, color = Palette.textSecondary)
                    TimeChip(
                        minutes = quietEndMinutes,
                        accessibilityLabel = "Quiet hours end",
                        onPicked = {
                            quietEndMinutes = it
                            NotifPrefs.setInt(context, NotifPrefs.QUIET_END, it)
                        },
                    )
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

// MARK: - Strap status (mirrors the three-state mapping from the Mac screen)

private fun strapPillTitle(live: com.noop.ble.LiveState): String = when {
    live.connected -> "Strap connected"
    live.bonded -> "Strap idle"
    else -> "Strap not connected"
}

private fun strapPillTone(live: com.noop.ble.LiveState): StrandTone = when {
    live.connected -> StrandTone.Positive
    live.bonded -> StrandTone.Warning
    else -> StrandTone.Critical
}

// MARK: - Delivery note (Notification Access requirement + deep link)

@Composable
private fun DeliveryNote() {
    val context = LocalContext.current
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.accent.copy(alpha = 0.22f), shape)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(
                Icons.Filled.Info,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(16.dp),
            )
            Text(
                "Wrist delivery needs Notification Access so NOOP can read which apps notify " +
                    "you. Nothing leaves this device. Your choices are saved now and apply " +
                    "automatically once access is granted.",
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .clickable {
                    runCatching {
                        context.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                }
                .padding(horizontal = 2.dp, vertical = 2.dp)
                .semantics { contentDescription = "Open Notification Access settings" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.OpenInNew,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
            Text("Open Notification Access", style = NoopType.caption, color = Palette.accent)
        }
    }
}

// MARK: - Category card (rows of apps, dimmed/disabled when master is off)

@Composable
private fun CategoryCard(
    category: NotifCategory,
    apps: List<NotifApp>,
    masterEnabled: Boolean,
    bonded: Boolean,
    enabledState: SnapshotStateMap<String, Boolean>,
    patternState: SnapshotStateMap<String, BuzzPattern>,
    onToggle: (NotifApp, Boolean) -> Unit,
    onPattern: (NotifApp, BuzzPattern) -> Unit,
    onTest: (NotifApp) -> Unit,
) {
    val contentAlpha = if (masterEnabled) 1f else Palette.disabledOpacity
    AlertSection(icon = category.icon, title = category.title) {
        Column(modifier = Modifier.alphaIf(contentAlpha)) {
            apps.forEachIndexed { idx, app ->
                AppRow(
                    app = app,
                    enabled = enabledState[app.id] ?: false,
                    pattern = patternState[app.id] ?: app.category.defaultPattern,
                    interactive = masterEnabled,
                    bonded = bonded,
                    onToggle = { onToggle(app, it) },
                    onPattern = { onPattern(app, it) },
                    onTest = { onTest(app) },
                )
                if (idx < apps.size - 1) RowDivider()
            }
        }
    }
}

@Composable
private fun AppRow(
    app: NotifApp,
    enabled: Boolean,
    pattern: BuzzPattern,
    interactive: Boolean,
    bonded: Boolean,
    onToggle: (Boolean) -> Unit,
    onPattern: (BuzzPattern) -> Unit,
    onTest: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // App glyph in a rounded inset tile (stand-in for the real macOS app icon).
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(app.glyph, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp))
        }

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(app.name, style = NoopType.body, color = Palette.textPrimary)
            Text(
                if (enabled) "Buzzes your wrist" else "Off",
                style = NoopType.footnote,
                color = if (enabled) Palette.accent else Palette.textTertiary,
            )
        }

        if (enabled) {
            PatternMenu(
                pattern = pattern,
                enabled = interactive,
                appName = app.name,
                onSelect = onPattern,
            )
            TestIconButton(enabled = interactive && bonded, appName = app.name, onClick = onTest)
        }

        NoopSwitch(
            checked = enabled,
            onChange = onToggle,
            enabled = interactive,
            label = "${app.name} wrist alerts",
        )
    }
}

// MARK: - Pattern menu (DropdownMenu replacing the macOS Menu)

@Composable
private fun PatternMenu(
    pattern: BuzzPattern,
    enabled: Boolean,
    appName: String,
    onSelect: (BuzzPattern) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)
    Box {
        Row(
            modifier = Modifier
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, shape)
                .clickable(enabled = enabled) { expanded = true }
                .padding(horizontal = 10.dp, vertical = 5.dp)
                .semantics { contentDescription = "Buzz pattern for $appName" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(
                Icons.Filled.GraphicEq,
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(12.dp),
            )
            Text(pattern.label, style = NoopType.caption, color = Palette.textSecondary)
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceOverlay),
        ) {
            BuzzPattern.entries.forEach { p ->
                DropdownMenuItem(
                    text = {
                        Text(
                            p.label,
                            style = NoopType.body,
                            color = if (p == pattern) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = {
                        onSelect(p)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Test buttons

@Composable
private fun TestIconButton(enabled: Boolean, appName: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    val tint = if (enabled) Palette.accent else Palette.textTertiary
    Box(
        modifier = Modifier
            .size(28.dp)
            .clip(shape)
            .background(Palette.accent.copy(alpha = if (enabled) 0.12f else 0.04f))
            .border(1.dp, tint.copy(alpha = 0.30f), shape)
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = "Test $appName buzz" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
    }
}

@Composable
private fun PillButton(label: String, icon: ImageVector, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    val tint = if (enabled) Palette.accent else Palette.textTertiary
    Row(
        modifier = Modifier
            .clip(shape)
            .background(Palette.accent.copy(alpha = if (enabled) 0.12f else 0.04f))
            .border(1.dp, tint.copy(alpha = 0.30f), shape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(label, style = NoopType.caption, color = tint)
    }
}

// MARK: - Time chip (TimePickerDialog → HH:mm). Reused by the Automations smart-alarm time too.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimeChip(
    minutes: Int,
    accessibilityLabel: String,
    onPicked: (Int) -> Unit,
) {
    var showPicker by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)
    val hour = minutes / 60
    val minute = minutes % 60
    Text(
        text = "%02d:%02d".format(hour, minute),
        style = NoopType.number(15f),
        color = Palette.accent,
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .clickable { showPicker = true }
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .semantics { contentDescription = accessibilityLabel },
    )

    if (showPicker) {
        // Material3 1.2.x has TimePicker + rememberTimePickerState but not a packaged
        // TimePickerDialog, so we wrap the picker in a plain Dialog ourselves.
        val state = rememberTimePickerState(
            initialHour = hour,
            initialMinute = minute,
            is24Hour = true,
        )
        Dialog(onDismissRequest = { showPicker = false }) {
            Column(
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(Palette.surfaceOverlay)
                    .border(1.dp, Palette.hairline, RoundedCornerShape(20.dp))
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(accessibilityLabel, style = NoopType.headline, color = Palette.textPrimary)
                TimePicker(
                    state = state,
                    colors = TimePickerDefaults.colors(
                        clockDialColor = Palette.surfaceInset,
                        clockDialSelectedContentColor = Palette.surfaceBase,
                        clockDialUnselectedContentColor = Palette.textPrimary,
                        selectorColor = Palette.accent,
                        periodSelectorBorderColor = Palette.hairline,
                        timeSelectorSelectedContainerColor = Palette.accentMuted,
                        timeSelectorUnselectedContainerColor = Palette.surfaceInset,
                        timeSelectorSelectedContentColor = Palette.accent,
                        timeSelectorUnselectedContentColor = Palette.textPrimary,
                    ),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                ) {
                    Text(
                        "Cancel",
                        style = NoopType.body,
                        color = Palette.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .clickable { showPicker = false }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                    Text(
                        "Set",
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .clickable {
                                onPicked(state.hour * 60 + state.minute)
                                showPicker = false
                            }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }
}

// MARK: - Section card (icon + title header, optional blurb, content)

@Composable
private fun AlertSection(
    icon: ImageVector,
    title: String,
    blurb: String? = null,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
            }
            if (blurb != null) {
                Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            }
            content()
        }
    }
}

// MARK: - Label + help + switch row (mirrors FormToggleRow)

@Composable
private fun FormToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        NoopSwitch(checked = checked, onChange = onChange, label = label)
    }
}

// MARK: - Shared bits

@Composable
private fun NoopSwitch(
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    enabled: Boolean = true,
    label: String,
) {
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
        modifier = Modifier.semantics { contentDescription = label },
    )
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

/** Apply a uniform alpha to a subtree (dims disabled category content). */
private fun Modifier.alphaIf(value: Float): Modifier = this.alpha(value)
