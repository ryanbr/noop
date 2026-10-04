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
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.notif.CallAlertController
import com.noop.notif.CallAlertSource
import com.noop.notif.NotifierApp
import com.noop.notif.NotifierAppDiscovery
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Calendar

// MARK: - NotificationsSettingsScreen
//
// Android port of NotificationSettingsView.swift. Choose which apps tap your wrist and
// how (per-app buzz pattern), with a master switch and overnight quiet hours.
//
// macOS resolves real installed apps via LaunchServices/NSWorkspace. Android restricts
// package visibility (API 30+), so the App Notifications page enumerates the notifier apps
// itself: apps that declare POST_NOTIFICATIONS (via the manifest's intent-shaped <queries>
// entry) plus every app the notification listener has seen post (the Notification Access
// grant carries their visibility — see com/noop/notif/NotifierAppDiscovery.kt). Preferences
// persist in SharedPreferences (the Android counterpart to UserDefaults); the notification
// listener reads the same prefs, keyed by package name.
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

// MARK: - SharedPreferences store (mirrors the UserDefaults-backed Swift store)

/**
 * Plain-prefs store for wrist-alert settings (the AI key uses encrypted prefs; these are
 * non-secret toggles). Per-app prefs are flattened to `app.<id>.enabled` / `app.<id>.pattern`
 * keys so no JSON dependency is needed.
 */
internal object NotifPrefs {
    private const val FILE = "noop_notif_prefs"
    const val MASTER = "notif.masterEnabled"
    /** Catch-all: buzz for every app the user has NOT individually enabled on the Other apps
     *  page. Opt-in, default OFF. (#168) */
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

    /** Package-keyed pattern read for discovered apps (no curated [NotifApp] exists for them).
     *  Defaults to Double — the same default [appLoops] gives the listener. */
    fun appPatternFor(ctx: Context, id: String): BuzzPattern {
        val name = prefs(ctx).getString("app.$id.pattern", null)
        return BuzzPattern.entries.firstOrNull { it.name == name } ?: BuzzPattern.Double
    }

    fun setAppPattern(ctx: Context, id: String, pattern: BuzzPattern) =
        prefs(ctx).edit().putString("app.$id.pattern", pattern.name).apply()

    /** Every per-app wrist-alert opt-in persisted — the picks made on the App Notifications page.
     *  The Notifications header counts these, so the pill tells the truth about what will buzz. */
    fun enabledAppCount(ctx: Context): Int = enabledAppPackages(ctx).size

    /** The app packages the user has opted in. The App Notifications page pins these rows above
     *  the search field for the whole visit, so the picks stay in sight. */
    fun enabledAppPackages(ctx: Context): Set<String> =
        prefs(ctx).all.entries.filter { (key, value) ->
            value == true && key.startsWith("app.") && key.endsWith(".enabled")
        }.map { (key, _) -> key.removePrefix("app.").removeSuffix(".enabled") }.toSet()

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
fun NotificationsSettingsScreen(vm: AppViewModel, onOpenOtherApps: () -> Unit = {}) {
    val context = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()

    // Header settings, seeded from prefs once and written through on change.
    var masterEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) }
    var onlyWhenWorn by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.WORN, true)) }
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

    // The header pill counts every app that will buzz — the per-app picks persisted on the
    // Other apps page. SharedPreferences isn't reactive, so the count is re-read on every
    // resume: returning from that page updates the pill.
    var enabledCount by remember { mutableStateOf(NotifPrefs.enabledAppCount(context)) }
    LifecycleResumeEffect(Unit) {
        enabledCount = NotifPrefs.enabledAppCount(context)
        onPauseOrDispose { }
    }

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

        // MARK: App Notifications — the picker for which apps buzz the wrist lives on its own
        // page (OtherAppsScreen); the pill on the master card counts its picks.
        AlertSection(
            icon = Icons.Filled.Apps,
            title = uiString(R.string.l10n_notifications_settings_screen_app_notifications_00e65fd6),
        ) {
            ChooseAppsButton(onClick = onOpenOtherApps)
        }

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
            // The "All other apps" catch-all moved to the top of the Other apps page, where it
            // can explain what it does to the per-app picks below it.
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
    // The Notification Access grant is PER APP and can change while this screen is open (the user
    // taps through to system settings and back), so re-check on every resume, not just first draw.
    var accessGranted by remember { mutableStateOf(NotifierAppDiscovery.notificationAccessGranted(context)) }
    LifecycleResumeEffect(Unit) {
        accessGranted = NotifierAppDiscovery.notificationAccessGranted(context)
        onPauseOrDispose { }
    }
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
                uiString(R.string.l10n_notifications_settings_screen_wrist_delivery_needs_notification_access_so_2a14e784),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        // Live grant state: the #1 cause of "toggled the app, got nothing on the wrist" is this
        // app not being granted (the grant is per app — a fresh install starts ungranted).
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(if (accessGranted) Palette.statusPositive else Palette.statusCritical),
            )
            Text(
                uiString(
                    if (accessGranted) {
                        R.string.l10n_notifications_settings_screen_notification_access_is_on_for_this_af3ffc72
                    } else {
                        R.string.l10n_notifications_settings_screen_notification_access_is_off_for_this_b27ba957
                    },
                ),
                style = NoopType.footnote,
                color = if (accessGranted) Palette.statusPositive else Palette.statusCritical,
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

// MARK: - App Notifications page (discovered notifier apps, per-app opt-in)

/**
 * The App Notifications page: every app on this phone that can notify the user, discovered live
 * instead of curated, entered from the Notifications screen via a button. Sources merged by
 * [NotifierAppDiscovery.load]: apps declaring POST_NOTIFICATIONS (visible via the manifest's
 * intent-shaped <queries> entry) plus every app the notification listener has seen post (the
 * Notification Access grant carries their visibility, covering pre-API-33 targets that never
 * declare the permission).
 *
 * Apps the user has already opted in are pinned above the search field for the whole visit, from
 * the moment the page opens (their labels resolve in the first off-thread sweep, ahead of the full
 * scan), so their switches stay in sight; the snapshot is taken at entry, so toggling mid-visit
 * never reorders the page.
 *
 * The "All other apps" catch-all lives at the top of this page in its own section: with it on,
 * every app buzzes, so the per-app switches below are inert — the page says so and dims the list. Rows reuse the same per-app prefs the notification listener
 * gates on — `app.<pkg>.enabled` / `app.<pkg>.pattern` — so a discovered app buzzes exactly
 * like a curated one, with its own pattern. The PackageManager walk runs off the main thread;
 * the list re-scans on demand.
 */
@Composable
fun OtherAppsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val live by vm.live.collectAsStateWithLifecycle()

    var masterEnabled by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) }
    var allOtherApps by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.ALL_OTHER, false)) }
    var apps by remember { mutableStateOf<List<NotifierApp>>(emptyList()) }
    var scanning by remember { mutableStateOf(true) }
    var scanTick by remember { mutableStateOf(0) }
    var query by remember { mutableStateOf("") }
    // Snapshot taken when the page opens: the apps already opted in. Positions are frozen for the
    // visit — toggling mid-visit flips the switch where the row sits, it never reorders the page.
    // Leaving and re-entering (or re-scanning after a reopen) re-takes the snapshot.
    val pinnedAtEntry = remember { NotifPrefs.enabledAppPackages(context) }
    // The opted-in rows resolved straight from prefs at entry: their labels land in the first
    // off-thread sweep, so the pinned band shows BEFORE the full scan finishes and stays after it.
    var pinnedSeed by remember { mutableStateOf<List<NotifierApp>>(emptyList()) }
    val enabledState = remember {
        mutableStateMapOf<String, Boolean>().apply {
            pinnedAtEntry.forEach { put(it, NotifPrefs.appEnabled(context, it)) }
        }
    }
    val patternState = remember {
        mutableStateMapOf<String, BuzzPattern>().apply {
            pinnedAtEntry.forEach { put(it, NotifPrefs.appPatternFor(context, it)) }
        }
    }
    val iconState = remember { mutableStateMapOf<String, ImageBitmap>() }

    LaunchedEffect(scanTick) {
        // Opted-in apps first: labels + icons for the pinned band resolve in this quick sweep, so
        // the user's picks are on screen before the full scan lands.
        val seed = withContext(Dispatchers.IO) {
            pinnedAtEntry.mapNotNull { NotifierAppDiscovery.appFor(context, it) }
        }
        val seedIcons = withContext(Dispatchers.IO) {
            seed.associate { app ->
                app.packageName to runCatching {
                    context.packageManager.getApplicationIcon(app.packageName).toBitmap(96, 96).asImageBitmap()
                }.getOrNull()
            }
        }
        pinnedSeed = seed
        seed.forEach { app ->
            seedIcons[app.packageName]?.let { iconState.putIfAbsent(app.packageName, it) }
        }
        // getInstalledPackages(GET_PERMISSIONS) walks every visible package — IO thread, not the UI.
        val list = withContext(Dispatchers.IO) { NotifierAppDiscovery.load(context) }
        // Real launcher icons, loaded off-thread in the same sweep (getApplicationIcon decodes
        // every app's icon — a main-thread walk over dozens of apps would jank the page).
        val icons = withContext(Dispatchers.IO) {
            list.associate { app ->
                app.packageName to runCatching {
                    context.packageManager.getApplicationIcon(app.packageName).toBitmap(96, 96).asImageBitmap()
                }.getOrNull()
            }
        }
        list.forEach { put ->
            enabledState.putIfAbsent(put.packageName, NotifPrefs.appEnabled(context, put.packageName))
            patternState.putIfAbsent(put.packageName, NotifPrefs.appPatternFor(context, put.packageName))
            icons[put.packageName]?.let { iconState.putIfAbsent(put.packageName, it) }
        }
        apps = list
        scanning = false
    }

    // Pinned band: the opted-in apps from the prefs snapshot at entry. Before the scan lands the
    // rows come from [pinnedSeed]; after it, from the scanned list (same rows, richer data).
    val pinned = pinnedSeed.sortedBy { it.label.lowercase() }.map { seed ->
        apps.firstOrNull { it.packageName == seed.packageName } ?: seed
    }
    val visible = apps.filter { it.packageName !in pinnedAtEntry }.filter {
        query.isBlank() ||
            it.label.contains(query, ignoreCase = true) ||
            it.packageName.contains(query, ignoreCase = true)
    }

    ScreenScaffold(
        title = uiString(R.string.l10n_notifications_settings_screen_app_notifications_00e65fd6),
        subtitle = uiString(R.string.l10n_notifications_settings_screen_apps_on_this_phone_that_can_6b7ae956),
    ) {
        // MARK: All other apps — the catch-all, in its own section at the top of the page.
        AlertSection(
            icon = Icons.Filled.NotificationsActive,
            title = uiString(R.string.l10n_notifications_settings_screen_all_other_apps_51a8af2c),
        ) {
            FormToggleRow(
                label = uiString(R.string.l10n_notifications_settings_screen_all_other_apps_51a8af2c),
                help = uiString(R.string.l10n_notifications_settings_screen_also_buzz_for_apps_not_listed_e60214ec),
                checked = allOtherApps,
                onChange = {
                    allOtherApps = it
                    NotifPrefs.setBool(context, NotifPrefs.ALL_OTHER, it)
                },
            )
            RowDivider()
            Text(
                uiString(R.string.l10n_notifications_settings_screen_when_all_other_apps_is_every_bf6e5671),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }

        // MARK: Detected apps — dense per-app list. Inert while the catch-all is on: it already
        // covers every app below, so individual picks would promise nothing the catch-all doesn't.
        AlertSection(
            icon = Icons.Filled.Apps,
            title = uiString(R.string.l10n_notifications_settings_screen_installed_apps_c21260b2),
        ) {
            Column(
                modifier = Modifier.alphaIf(if (masterEnabled && !allOtherApps) 1f else Palette.disabledOpacity),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                // Apps already opted in when the page opened sit above the search field, shown from
                // the moment the page opens (labels resolve in the first off-thread sweep) — they
                // don't wait for the full scan, and they stay visible after it.
                pinned.forEachIndexed { idx, app ->
                    DiscoveredAppRow(
                        app = app,
                        enabled = enabledState[app.packageName] ?: false,
                        pattern = patternState[app.packageName] ?: BuzzPattern.Double,
                        icon = iconState[app.packageName],
                        interactive = masterEnabled && !allOtherApps,
                        bonded = live.bonded,
                        dense = true,
                        onToggle = { value ->
                            enabledState[app.packageName] = value
                            NotifPrefs.setAppEnabled(context, app.packageName, value)
                        },
                        onPattern = { pattern ->
                            patternState[app.packageName] = pattern
                            NotifPrefs.setAppPattern(context, app.packageName, pattern)
                        },
                        onTest = { vm.buzz(loops = (patternState[app.packageName] ?: BuzzPattern.Double).loops) },
                    )
                    if (idx < pinned.size - 1) RowDivider()
                }
                if (pinned.isNotEmpty()) RowDivider()
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    placeholder = { Text(uiString(R.string.l10n_notifications_settings_screen_search_apps_ca3ce8f3), style = NoopType.body, color = Palette.textTertiary) },
                    label = { Text(uiString(R.string.l10n_notifications_settings_screen_search_apps_ca3ce8f3), style = NoopType.caption, color = Palette.textSecondary) },
                    colors = notifFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    PillButton(
                        label = uiString(R.string.l10n_notifications_settings_screen_scan_again_f6ab55dd),
                        icon = Icons.Filled.PlayArrow,
                        enabled = masterEnabled && !allOtherApps,
                        onClick = { scanTick++ },
                    )
                    Spacer(Modifier.weight(1f))
                }
                if (visible.isEmpty() && scanning) {
                    // The scan starts the moment the page opens; until the PackageManager walk
                    // lands, the list area shows this placeholder instead of an empty void.
                    Text(
                        uiString(R.string.l10n_notifications_settings_screen_scanning_installed_04ab2344),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                } else if (visible.isEmpty()) {
                    Text(
                        uiString(R.string.l10n_notifications_settings_screen_no_apps_discovered_post_a_notification_0ca6e7bc),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                visible.forEachIndexed { idx, app ->
                    DiscoveredAppRow(
                        app = app,
                        enabled = enabledState[app.packageName] ?: false,
                        pattern = patternState[app.packageName] ?: BuzzPattern.Double,
                        icon = iconState[app.packageName],
                        interactive = masterEnabled && !allOtherApps,
                        bonded = live.bonded,
                        dense = true,
                        onToggle = { value ->
                            enabledState[app.packageName] = value
                            NotifPrefs.setAppEnabled(context, app.packageName, value)
                        },
                        onPattern = { pattern ->
                            patternState[app.packageName] = pattern
                            NotifPrefs.setAppPattern(context, app.packageName, pattern)
                        },
                        onTest = { vm.buzz(loops = (patternState[app.packageName] ?: BuzzPattern.Double).loops) },
                    )
                    if (idx < visible.size - 1) RowDivider()
                }
            }
        }
    }
}

@Composable
private fun DiscoveredAppRow(
    app: NotifierApp,
    enabled: Boolean,
    pattern: BuzzPattern,
    icon: ImageBitmap? = null,
    interactive: Boolean,
    bonded: Boolean,
    dense: Boolean = false,
    onToggle: (Boolean) -> Unit,
    onPattern: (BuzzPattern) -> Unit,
    onTest: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(if (dense) 40.dp else 48.dp)
            .clip(RoundedCornerShape(10.dp))
            .then(if (enabled) Modifier.background(Palette.accentMuted) else Modifier)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // The app's REAL launcher icon, decoded off-thread at scan time (see the iconState sweep
        // in OtherAppsScreen). The generic apps glyph stays as the fallback for the rare package
        // whose icon refuses to decode.
        Box(
            modifier = Modifier
                .size(if (dense) 28.dp else 34.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            if (icon != null) {
                Image(
                    bitmap = icon,
                    contentDescription = app.label,
                    modifier = Modifier.size(if (dense) 24.dp else 28.dp),
                )
            } else {
                Icon(Icons.Filled.Apps, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(if (dense) 15.dp else 18.dp))
            }
        }

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(app.label, style = NoopType.body, color = Palette.textPrimary)
            // The off state reads from the switch itself; only the on state gets the caption.
            if (enabled) {
                Text("Buzzes your wrist", style = NoopType.footnote, color = Palette.accent)
            }
        }

        if (enabled) {
            PatternMenu(
                pattern = pattern,
                enabled = interactive,
                appName = app.label,
                onSelect = onPattern,
            )
            TestIconButton(enabled = interactive && bonded, appName = app.label, onClick = onTest)
        }

        NoopSwitch(
            checked = enabled,
            onChange = onToggle,
            enabled = interactive,
            label = uiString(R.string.l10n_notifications_settings_screen_app_name_wrist_alerts_dd3540fa, app.label),
        )
    }
}

/** Field colors for the search box, mirroring AddDeviceWizard's wizardFieldColors (private there). */
@Composable
private fun notifFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

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

// MARK: - Choose Apps button (full-width entry into the discovered-app picker page)

/**
 * The App Notifications section's entry into [OtherAppsScreen]: a big full-width button, padded
 * like the rows it sits beside. Bigger than the compact [PillButton] on purpose — it is the door
 * to a whole page, not an inline action.
 */
@Composable
private fun ChooseAppsButton(onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.accent.copy(alpha = 0.12f))
            .border(1.dp, Palette.accent.copy(alpha = 0.30f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Apps, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(20.dp))
        Text(
            uiString(R.string.l10n_notifications_settings_screen_choose_apps_72d037f2),
            style = NoopType.body,
            color = Palette.accent,
        )
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.AutoMirrored.Filled.OpenInNew,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(15.dp),
        )
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
