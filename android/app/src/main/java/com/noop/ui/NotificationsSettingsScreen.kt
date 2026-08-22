package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.automirrored.filled.OpenInNew
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
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.notif.CallAlertController
import com.noop.notif.CallAlertSource
import java.util.Calendar

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
    Messaging("Messaging", Icons.AutoMirrored.Filled.Chat, BuzzPattern.Single),
    Meetings("Meetings", Icons.Filled.Videocam, BuzzPattern.Triple),
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
    NotifApp("com.whatsapp", "WhatsApp", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("com.google.android.apps.messaging", "Messages", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("com.Slack", "Slack", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("org.telegram.messenger", "Telegram", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    // Teams' ringing-call notifications are handled by the Calls card below (VoIP path). This
    // per-app row covers everything else Teams sends to the shade (chats, @-mentions, channel
    // posts), which read as messages, so it lives under Messaging with the chat glyph.
    NotifApp("com.microsoft.teams", "Microsoft Teams", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
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
    /** Catch-all: buzz for any app NOT in the curated catalog (Android can't enumerate installed
     *  apps, so this is how a user covers BeReal/etc. that aren't listed). Opt-in, default OFF. (#168) */
    const val ALL_OTHER = "notif.allOtherApps"
    const val WORN = "notif.onlyWhenWorn"
    const val QUIET = "notif.quietHoursEnabled"
    const val QUIET_START = "notif.quietStartMinutes"
    const val QUIET_END = "notif.quietEndMinutes"
    const val CALLS_MASTER = "notif.calls.masterEnabled"
    const val CALLS_PHONE = "notif.calls.phoneEnabled"
    const val CALLS_VOIP = "notif.calls.voipEnabled"
    const val CALLS_PATTERN = "notif.calls.pattern"
    /** Buzz the strap when the phone's native Clock fires a timer/alarm (CATEGORY_ALARM). Android-only
     *  (iOS can't observe another app's notifications). Default OFF. */
    const val ALARM_TIMER = "notif.alarmTimer"

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

    fun callPattern(ctx: Context): BuzzPattern {
        val name = prefs(ctx).getString(CALLS_PATTERN, null)
        return BuzzPattern.entries.firstOrNull { it.name == name } ?: BuzzPattern.Triple
    }

    fun setCallPattern(ctx: Context, pattern: BuzzPattern) =
        prefs(ctx).edit().putString(CALLS_PATTERN, pattern.name).apply()

    fun callLoops(ctx: Context): Int = callPattern(ctx).loops

    fun inQuietHours(ctx: Context): Boolean {
        if (!getBool(ctx, QUIET, false)) return false
        val start = getInt(ctx, QUIET_START, 22 * 60)
        val end = getInt(ctx, QUIET_END, 7 * 60)
        val cal = Calendar.getInstance()
        val now = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        // Quiet window may wrap midnight (e.g. 22:00 -> 07:00).
        return if (start <= end) now in start until end else (now >= start || now < end)
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
    var allOtherApps by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.ALL_OTHER, false)) }
    var quietHoursEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.QUIET, false)) }
    var quietStartMinutes by remember { mutableStateOf(NotifPrefs.getInt(context, NotifPrefs.QUIET_START, 22 * 60)) }
    var quietEndMinutes by remember { mutableStateOf(NotifPrefs.getInt(context, NotifPrefs.QUIET_END, 7 * 60)) }
    var callsEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) }
    var phoneCallsEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_PHONE, false)) }
    var voipCallsEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.CALLS_VOIP, false)) }
    var alarmTimerEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.ALARM_TIMER, false)) }
    var callsPattern by remember { mutableStateOf(NotifPrefs.callPattern(context)) }
    // Scheduled report notifications (#517) — opt-in, default OFF. SharedPreferences isn't reactive, so
    // each Switch mirrors into local state and writes straight through to NoopPrefs.
    var morningReport by remember { mutableStateOf(NoopPrefs.morningReportEnabled(context)) }
    var postWorkoutReport by remember { mutableStateOf(NoopPrefs.postWorkoutReportEnabled(context)) }
    var strainTargetReport by remember { mutableStateOf(NoopPrefs.strainTargetEnabled(context)) }
    var phonePermissionDenied by remember { mutableStateOf(false) }
    val phonePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        phoneCallsEnabled = granted
        phonePermissionDenied = !granted
        NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, granted)
    }

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
        title = uiString(R.string.l10n_notifications_settings_screen_notifications_753a22b2),
        subtitle = "Buzz your strap when these apps notify you. Everything runs on this device.",
    ) {
        // MARK: Master card
        AlertSection(
            icon = Icons.Filled.NotificationsActive,
            title = uiString(R.string.l10n_notifications_settings_screen_wrist_alerts_75581d51),
            blurb = "When on, NOOP taps your wrist for the apps you pick below, so you can leave " +
                "your phone and still feel what matters.",
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(uiString(R.string.l10n_notifications_settings_screen_enable_wrist_alerts_462b9e0f), style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                NoopSwitch(
                    checked = masterEnabled,
                    onChange = {
                        masterEnabled = it
                        NotifPrefs.setBool(context, NotifPrefs.MASTER, it)
                    },
                    label = uiString(R.string.l10n_notifications_settings_screen_enable_wrist_alerts_462b9e0f),
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
                    label = uiString(R.string.l10n_notifications_settings_screen_test_buzz_deeab5ae),
                    icon = Icons.Filled.GraphicEq,
                    enabled = live.bonded,
                    onClick = { vm.buzz(loops = 2) },
                )
            }

            DeliveryNote()
        }

        CallsCard(
            masterEnabled = masterEnabled,
            callsEnabled = callsEnabled,
            phoneCallsEnabled = phoneCallsEnabled,
            voipCallsEnabled = voipCallsEnabled,
            pattern = callsPattern,
            bonded = live.bonded,
            permissionDenied = phonePermissionDenied,
            onCallsEnabled = {
                callsEnabled = it
                NotifPrefs.setBool(context, NotifPrefs.CALLS_MASTER, it)
                if (!it) CallAlertController.stopAll()
            },
            onPhoneCallsEnabled = { value ->
                if (!value) {
                    phoneCallsEnabled = false
                    phonePermissionDenied = false
                    NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, false)
                    CallAlertController.stopSource(CallAlertSource.PHONE)
                    return@CallsCard
                }
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.READ_PHONE_STATE,
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    phoneCallsEnabled = true
                    phonePermissionDenied = false
                    NotifPrefs.setBool(context, NotifPrefs.CALLS_PHONE, true)
                } else {
                    phonePermissionLauncher.launch(Manifest.permission.READ_PHONE_STATE)
                }
            },
            onVoipCallsEnabled = {
                voipCallsEnabled = it
                NotifPrefs.setBool(context, NotifPrefs.CALLS_VOIP, it)
                if (!it) CallAlertController.stopSource(CallAlertSource.VOIP)
            },
            onPattern = {
                callsPattern = it
                NotifPrefs.setCallPattern(context, it)
            },
            onTest = { vm.buzz(loops = callsPattern.loops) },
        )

        // #1115 follow-up: buzz the strap when the phone's native Clock fires a timer or alarm
        // (CATEGORY_ALARM, any clock app). Android-only — iOS can't observe another app's notifications.
        AlertSection(
            icon = Icons.Filled.Alarm,
            title = uiString(R.string.notif_timer_alarm_title),
            blurb = "Buzz your wrist when your phone's Clock app finishes a timer or rings an alarm.",
        ) {
            Column(modifier = Modifier.alphaIf(if (masterEnabled) 1f else Palette.disabledOpacity)) {
                FormToggleRow(
                    label = uiString(R.string.notif_timer_alarm_title),
                    help = "Requires wrist alerts (above) to be on. Buzzes once when a timer/alarm notification fires.",
                    checked = alarmTimerEnabled,
                    enabled = masterEnabled,
                    onChange = {
                        alarmTimerEnabled = it
                        NotifPrefs.setBool(context, NotifPrefs.ALARM_TIMER, it)
                    },
                )
            }
        }

        // #926: the "every pattern buzzes the same on a 5/MG" note that used to sit here is GONE — the
        // limitation it described is fixed. overallLoop (byte 11 of the maverick haptic body) is now
        // written as `loops - 1` in WhoopBleClient.maverickHapticBody, hardware-confirmed on a real
        // 5/MG, so all four patterns are distinct on that family too. Leaving the note would be worse
        // than never having had it: a caption telling the user their setting does nothing, next to a
        // control that now works.

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
            title = uiString(R.string.l10n_notifications_settings_screen_behaviour_171ca038),
            blurb = "Fine-tune when alerts reach your wrist.",
        ) {
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_only_buzz_when_worn_6211cee3),
                help = "Skip alerts when the strap is off your wrist.",
                checked = onlyWhenWorn,
                onChange = {
                    onlyWhenWorn = it
                    NotifPrefs.setBool(context, NotifPrefs.WORN, it)
                },
            )
            RowDivider()
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_all_other_apps_51a8af2c),
                help = "Also buzz for apps that aren't in the lists above (e.g. BeReal). Android " +
                    "doesn't let NOOP see every installed app, so this is how you cover the rest. " +
                    "Can be chatty; quiet hours and \"only when worn\" still apply.",
                checked = allOtherApps,
                onChange = {
                    allOtherApps = it
                    NotifPrefs.setBool(context, NotifPrefs.ALL_OTHER, it)
                },
            )
            RowDivider()
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_quiet_hours_706b24d0),
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
                    Text(uiString(R.string.l10n_notifications_settings_screen_from_3f66052a), style = NoopType.body, color = Palette.textPrimary)
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

        // MARK: Daily reports (#517) — phone notifications, not wrist buzzes. Opt-in, default OFF, no AI.
        AlertSection(
            icon = Icons.Filled.NotificationsActive,
            title = uiString(R.string.l10n_notifications_settings_screen_daily_reports_c1a22a74),
            blurb = "Optional phone notifications, off by default. These arrive after your strap syncs " +
                "and NOOP scores the data, so they land soon after, not the exact second you wake or " +
                "finish a workout. Everything is worked out on this phone.",
        ) {
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_morning_recap_45ec05c5),
                help = "After last night is processed, a notification with your Charge and Rest. Posts " +
                    "once a day, after your strap has synced the night.",
                checked = morningReport,
                onChange = {
                    morningReport = it
                    NoopPrefs.setMorningReportEnabled(context, it)
                },
            )
            RowDivider()
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_post_workout_summary_13e488f5),
                help = "When a new workout syncs in, a notification with its Effort, duration and average " +
                    "heart rate. Shows up after the session reaches NOOP on the next sync.",
                checked = postWorkoutReport,
                onChange = {
                    postWorkoutReport = it
                    NoopPrefs.setPostWorkoutReportEnabled(context, it)
                    // Seed the frontier to the newest existing workout when turning ON, so enabling it
                    // doesn't immediately fire a summary for a session already in history.
                    if (it) vm.seedWorkoutReportFrontier()
                },
            )
            RowDivider()
            // #593: NOOP's own optimal-strain-reached nudge (not WHOOP's copy).
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_optimal_strain_reached_2862ec2b),
                help = "Once a day, a notification when your Effort reaches the low end of today's optimal " +
                    "strain range (from your recovery). Posts after your strap syncs and NOOP scores the day.",
                checked = strainTargetReport,
                onChange = {
                    strainTargetReport = it
                    NoopPrefs.setStrainTargetEnabled(context, it)
                },
            )
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

@Composable
private fun CallsCard(
    masterEnabled: Boolean,
    callsEnabled: Boolean,
    phoneCallsEnabled: Boolean,
    voipCallsEnabled: Boolean,
    pattern: BuzzPattern,
    bonded: Boolean,
    permissionDenied: Boolean,
    onCallsEnabled: (Boolean) -> Unit,
    onPhoneCallsEnabled: (Boolean) -> Unit,
    onVoipCallsEnabled: (Boolean) -> Unit,
    onPattern: (BuzzPattern) -> Unit,
    onTest: () -> Unit,
) {
    val contentAlpha = if (masterEnabled) 1f else Palette.disabledOpacity
    AlertSection(
        icon = Icons.Filled.Call,
        title = uiString(R.string.l10n_notifications_settings_screen_calls_0a19b7e2),
        blurb = "Tap your wrist for incoming phone calls and strict best-effort VoIP calls.",
    ) {
        Column(modifier = Modifier.alphaIf(contentAlpha)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_notifications_settings_screen_buzz_on_incoming_calls_625804a1), style = NoopType.body, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_notifications_settings_screen_uses_the_same_quiet_hours_and_03badcac),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                if (callsEnabled) {
                    PatternMenu(pattern = pattern, enabled = masterEnabled, appName = "calls", onSelect = onPattern)
                    TestIconButton(enabled = masterEnabled && bonded, appName = "calls", onClick = onTest)
                }
                NoopSwitch(
                    checked = callsEnabled,
                    onChange = onCallsEnabled,
                    enabled = masterEnabled,
                    label = uiString(R.string.l10n_notifications_settings_screen_buzz_on_incoming_calls_625804a1),
                )
            }
            if (callsEnabled) {
                RowDivider()
                FormToggleRow(
                    label = uiString(R.string.l10n_notifications_settings_screen_phone_calls_b79420d9),
                    help = "Needs Phone permission; NOOP never reads numbers or call logs.",
                    checked = phoneCallsEnabled,
                    enabled = masterEnabled,
                    onChange = onPhoneCallsEnabled,
                )
                if (permissionDenied) {
                    Text(
                        uiString(R.string.l10n_notifications_settings_screen_phone_permission_was_denied_so_phone_db0ebdd8),
                        style = NoopType.footnote,
                        color = Palette.statusCritical,
                        modifier = Modifier.padding(top = 2.dp, bottom = 8.dp),
                    )
                }
                RowDivider()
                FormToggleRow(
                    label = uiString(R.string.l10n_notifications_settings_screen_voip_calls_96c5a102),
                    help = "Detects call-style notifications from known calling apps.",
                    checked = voipCallsEnabled,
                    enabled = masterEnabled,
                    onChange = onVoipCallsEnabled,
                )
            }
        }
    }
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
                uiString(R.string.l10n_notifications_settings_screen_wrist_delivery_needs_notification_access_so_2a14e784) +
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
                .semantics { contentDescription = uiString(R.string.l10n_notifications_settings_screen_open_notification_access_settings_93fcd1bf) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.AutoMirrored.Filled.OpenInNew,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
            Text(uiString(R.string.l10n_notifications_settings_screen_open_notification_access_658fd30f), style = NoopType.caption, color = Palette.accent)
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
            .height(48.dp)
            // An enabled app reads as a selected row: a soft accentMuted wash behind it.
            .clip(RoundedCornerShape(10.dp))
            .then(if (enabled) Modifier.background(Palette.accentMuted) else Modifier)
            .padding(horizontal = 8.dp),
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
            label = uiString(R.string.l10n_notifications_settings_screen_app_name_wrist_alerts_dd3540fa, app.name),
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
                .semantics { contentDescription = uiString(R.string.l10n_notifications_settings_screen_buzz_pattern_for_appname_905a31bd, appName) },
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
            .semantics { contentDescription = uiString(R.string.l10n_notifications_settings_screen_test_appname_buzz_dbae5be3, appName) },
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
        text = uiString(R.string.l10n_notifications_settings_screen_02d_02d_ce23a78c, hour, minute),
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
                        uiString(R.string.l10n_notifications_settings_screen_cancel_77dfd213),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .clickable { showPicker = false }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                    Text(
                        uiString(R.string.l10n_notifications_settings_screen_set_448ab73b),
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
    overline: String = "Alerts",
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline(overline)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
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
    enabled: Boolean = true,
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
        NoopSwitch(checked = checked, onChange = onChange, enabled = enabled, label = label)
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
