package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Intent
import android.net.Uri
import android.os.Build
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.PuffinExperiment

/**
 * Smart alarm (#207) — Android phone-based wake, with a guaranteed hard-deadline fallback.
 *
 * The user picks the EARLIEST acceptable wake time and a window length. NOOP watches the overnight
 * strap stream and, if it spots a lighter sleep phase inside the window, wakes you then — but a
 * GUARANTEED exact OS alarm is always scheduled at the window's END (via AlarmManager), independent
 * of Bluetooth, the strap, or the app being alive. The smart logic can only ever move the alarm
 * EARLIER; it can never cancel or skip the fallback. So you're woken by the window's end no matter
 * what. This screen is explicit about that safety guarantee.
 *
 * This is the ONE alarm surface (#766). It hosts the phone-based Wake Window above, the strap's own
 * standalone firmware wake-alarm (moved here from Automations), and the cross-platform WIND-DOWN nudge,
 * so every wake/alarm control lives together instead of being split across two screens.
 */
@Composable
fun SmartAlarmScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val enabled by vm.phoneAlarmEnabled.collectAsStateWithLifecycle()
    val targetMinutes by vm.phoneAlarmTargetMinutes.collectAsStateWithLifecycle()
    val windowMinutes by vm.phoneAlarmWindowMinutes.collectAsStateWithLifecycle()
    val phoneAlarmWeekdays by vm.phoneAlarmWeekdays.collectAsStateWithLifecycle()
    val buzzWhoop4 by vm.buzzWhoop4Enabled.collectAsStateWithLifecycle()
    // #536: the hint adapts to bond state — the strap can only be armed when a WHOOP 4.0 is connected.
    val liveState = vm.live.collectAsStateWithLifecycle().value
    val bonded = liveState.bonded
    // #821: the strap-buzz row was hardcoded to "WHOOP 4", which reads wrong on a connected 5/MG (issue
    // #730 follow-up). Name the actual strap generation instead: a detected 5/MG says "WHOOP 5/MG", anything
    // else (a 4.0, or nothing connected yet) keeps "WHOOP 4.0", so the label never claims the wrong device.
    val strapName = if (liveState.whoop5Detected) "WHOOP 5/MG" else "WHOOP 4.0"

    // True when exact alarms are permitted. Re-read on each (re)composition because the user can grant
    // it in Settings and come back — there's no result callback for this special-access permission.
    var canSchedule by remember { mutableStateOf(vm.canScheduleExactAlarms()) }

    // PERF (#707): lazy scaffold — each of the four cards is one `item { }` (all unconditional). Order +
    // spacing unchanged (LazyColumn reproduces the eager `spacedBy(20.dp)`); only on-screen cards compose +
    // are accessibility-walked.
    LazyScreenScaffold(
        // #766: "Alarms" because this screen now holds the phone Wake Window, the strap's firmware
        // wake-alarm (moved here from Automations), and the wind-down reminder, so the broader title fits.
        title = uiString(R.string.l10n_smart_alarm_screen_alarms_131dd3d6),
        subtitle = "Your wake window, the strap wake-alarm, and the evening wind-down reminder, in one place.",
    ) {
        // The guaranteed-wake card always shows so the safety promise is the first thing read.
        item { WindowCard(enabled = enabled, targetMinutes = targetMinutes, windowMinutes = windowMinutes) }

        item {
        AlarmSettingsCard {
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_wake_me_with_a_smart_alarm_bbbd082d),
                help = "A guaranteed OS alarm is set for the end of your window; the strap stream can move it earlier if you're sleeping lightly.",
                checked = enabled,
                onChange = { want ->
                    if (want && !vm.canScheduleExactAlarms()) {
                        // No callback for this special-access grant — send the user to the system page,
                        // and re-read the state when they return (canSchedule recomputes on recompose).
                        requestExactAlarmAccess(context)
                        canSchedule = vm.canScheduleExactAlarms()
                    } else {
                        val ok = vm.setPhoneAlarmEnabled(want)
                        canSchedule = vm.canScheduleExactAlarms()
                        if (!ok) requestExactAlarmAccess(context)
                    }
                },
            )

            if (enabled && !canSchedule) {
                RowDividerLocal()
                Text(
                    uiString(R.string.l10n_smart_alarm_screen_noop_doesn_t_have_permission_to_5b67cef0) +
                        "Tap to allow it in system settings.",
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            requestExactAlarmAccess(context)
                            canSchedule = vm.canScheduleExactAlarms()
                        },
                )
            }

            if (enabled) {
                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_smart_alarm_screen_wake_me_no_earlier_than_67411622), style = NoopType.body, color = Palette.textPrimary)
                        Text(uiString(R.string.l10n_smart_alarm_screen_the_earliest_noop_will_wake_you_b641a2d4), style = NoopType.footnote, color = Palette.textTertiary)
                    }
                    Spacer(Modifier.width(16.dp))
                    TimeChip(
                        minutes = targetMinutes,
                        accessibilityLabel = "Earliest wake time",
                        onPicked = { vm.setPhoneAlarmTargetMinutes(it) },
                    )
                }

                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_smart_alarm_screen_window_length_46179fcb), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_smart_alarm_screen_the_guaranteed_alarm_fires_this_long_b0c51052),
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                    }
                    Spacer(Modifier.width(16.dp))
                    WindowStepper(
                        windowMinutes = windowMinutes,
                        onChange = { vm.setPhoneAlarmWindowMinutes(it) },
                    )
                }

                // Days this alarm fires on. The SAME shared picker the strap alarm below uses, and the
                // same empty-means-every-day contract, so identical-looking circles behave identically on
                // one screen. Lets a weekend be switched off without disabling the alarm and having to
                // remember to switch it back on.
                RowDividerLocal()
                AlarmWeekdayPicker(
                    selected = phoneAlarmWeekdays,
                    onToggle = { dow ->
                        vm.setPhoneAlarmWeekdays(toggledSmartAlarmWeekday(dow, phoneAlarmWeekdays))
                    },
                )
            }

            // #536: companion strap-buzz, always visible so it's discoverable. Arms the strap's own firmware
            // alarm at the earliest wake time, so the strap buzzes first and the OS alarm backs it up.
            // #821: label + copy name the CONNECTED strap generation (strapName), not a hardcoded "WHOOP 4".
            RowDividerLocal()
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_buzz_strapname_813772f4, strapName),
                help = if (bonded)
                    "Also arms your $strapName to buzz at your earliest wake time, so the strap wakes you first and the phone alarm is the guaranteed backup."
                else
                    "Connect your strap to use this. It arms the strap to buzz at your earliest wake time as a gentler first wake-up.",
                checked = buzzWhoop4,
                onChange = { vm.setBuzzWhoop4Enabled(it) },
            )
        }
        }

        // #766: the strap's own firmware wake-alarm (its own time + weekdays + per-day overrides). Moved
        // here from Automations so every wake/alarm control sits on the one Alarms screen instead of being
        // conflated with the wind-down reminder. Distinct from "Buzz WHOOP 4" above, which arms the strap
        // at the PHONE alarm's time; this card is the strap's standalone schedule.
        item { StrapAlarmCard(vm) }

        // The cross-platform wind-down nudge lives here too.
        item { WindDownCard(vm) }

        // #821: the "how the smart wake works" explainer sat in the MIDDLE of the page (between the wake-alarm
        // settings and the strap alarm), which read as an interruption. It's reference detail, not a control,
        // so it belongs at the BOTTOM after every alarm/reminder control, moved here.
        item { ExplanationCard() }
    }
}

/**
 * The strap's standalone silent wake-alarm (#766, moved from AutomationsScreen). Arms the strap's own
 * firmware alarm at the chosen time/weekdays over BLE, so it buzzes even if NOOP is closed. Reuses the
 * shared [AlarmWeekdayPicker] / [AlarmDayOverridePicker] from AutomationsScreen (same behaviour, just a
 * new home). Functions are untouched: it drives the same `viewModel.setSmartAlarm*` calls as before.
 */
@Composable
private fun StrapAlarmCard(vm: AppViewModel) {
    val context = LocalContext.current
    val smartAlarm by vm.smartAlarmEnabled.collectAsStateWithLifecycle()
    val alarmMinutes by vm.smartAlarmMinutes.collectAsStateWithLifecycle()
    val alarmWeekdays by vm.smartAlarmWeekdays.collectAsStateWithLifecycle()
    val alarmDayOverrides by vm.smartAlarmDayOverrides.collectAsStateWithLifecycle()
    val live = vm.live.collectAsStateWithLifecycle().value
    // The firmware alarm is EXPERIMENTAL on a WHOOP 5/MG: it only arms when Experimental probes are on,
    // otherwise enabling it silently arms nothing (#111), so the UI says so instead of promising a wake.
    val experimentalOn = PuffinExperiment.from(context).isEnabled

    NoopCard(padding = 20.dp, tint = if (smartAlarm) Palette.accent else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Morning")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Alarm, contentDescription = null, tint = Palette.accent)
                    Spacer(Modifier.width(10.dp))
                    Text(uiString(R.string.l10n_smart_alarm_screen_strap_wake_alarm_1828fff3), style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            // Truth-sync (#535): the WHOOP 4.0 alarm payload was captured from the official app and
            // confirmed buzzing on a real 4.0 by the capture author, so the copy no longer calls the
            // 4.0 path experimental. The 5/MG Experimental-gate branch below is deliberately untouched.
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_wake_me_with_a_strap_buzz_1681ba1d),
                help = "Arms the strap to buzz at your wake time, even if NOOP is closed. Sends the exact alarm command the official app sends, confirmed buzzing on a real WHOOP 4.0 (community wire capture + on-device test, #535). Keep a backup alarm for anything you truly can't miss.",
                checked = smartAlarm,
                onChange = { vm.setSmartAlarmEnabled(it) },
            )
            if (smartAlarm) {
                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(uiString(R.string.l10n_smart_alarm_screen_wake_at_49089991), style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = alarmMinutes,
                        accessibilityLabel = "Strap alarm wake time",
                        onPicked = { vm.setSmartAlarmMinutes(it) },
                    )
                }
                RowDividerLocal()
                AlarmWeekdayPicker(
                    selected = alarmWeekdays,
                    onToggle = { dow -> vm.setSmartAlarmWeekdays(toggledSmartAlarmWeekday(dow, alarmWeekdays)) },
                )
                RowDividerLocal()
                // Per-weekday wake-time OVERRIDES (#554): a different time for any day the alarm fires on.
                AlarmDayOverridePicker(
                    defaultMinutes = alarmMinutes,
                    enabledDays = alarmWeekdays,
                    overrides = alarmDayOverrides,
                    onSetOverride = { dow, minutes -> vm.setSmartAlarmDayOverride(dow, minutes) },
                )
                RowDividerLocal()
                if (live.whoop5Detected && !experimentalOn) {
                    Text(
                        uiString(R.string.l10n_smart_alarm_screen_your_whoop_5_mg_won_t_75029bae) +
                            "Experimental). Right now your wake time is saved but the strap is NOT armed.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                } else if (live.whoop5Detected) {
                    // 5/MG with Experimental ON: the strap IS armed (experimental rev-4 payload) but a
                    // strap-driven wake has NEVER been captured on 5/MG, so the "confirmed on 4.0" copy must
                    // NOT show here (#864 honesty). Byte-identical wording to the Swift SmartAlarmView twin.
                    Text(
                        if (live.bonded)
                            "Armed on the strap itself with the experimental 5/MG command. A strap-driven wake is still unconfirmed on 5/MG on our side (confirmed only on WHOOP 4.0), so keep a backup alarm for anything you truly can't miss."
                        else
                            "Connect your strap to arm this; it's set on the strap's own firmware alarm. Confirmed working on WHOOP 4.0; still experimental on 5.0 and MG. Keep a backup alarm for anything you truly can't miss.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                } else {
                    Text(
                        if (live.bonded)
                            // Truth-sync (#535): confirmed buzzing on a real WHOOP 4.0; byte-identical
                            // wording to the Swift SmartAlarmView.
                            "Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Sends the exact alarm command the official app sends, confirmed buzzing on a real WHOOP 4.0 (community wire capture + on-device test, #535). Keep a backup alarm for anything you truly can't miss."
                        else
                            "Connect your strap to arm this; it's set on the strap's own firmware alarm. Confirmed working on WHOOP 4.0; still experimental on 5.0 and MG. Keep a backup alarm for anything you truly can't miss.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - Cards

/**
 * The always-visible "you WILL be woken by" guarantee card — a small Rest-world frosted hero. The
 * wake window reads as a clean earliest→deadline time pairing in big rounded numerals over a scenic
 * Rest backdrop (it's about waking, so it lives in the indigo world, not the brand-green chrome).
 */
@Composable
private fun WindowCard(enabled: Boolean, targetMinutes: Int, windowMinutes: Int) {
    val deadline = (targetMinutes + windowMinutes) % (24 * 60)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius)),
    ) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Rest)
        Row(modifier = Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Shield, contentDescription = null, tint = DomainTheme.Rest.color)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Overline("Guaranteed wake")
                if (enabled) {
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(hhmm(targetMinutes), style = NoopType.number(28f), color = DomainTheme.Rest.color)
                        Text("→", style = NoopType.title2, color = Palette.textTertiary)
                        Text(hhmm(deadline), style = NoopType.number(28f), color = DomainTheme.Rest.bright)
                    }
                    Text(
                        uiString(R.string.l10n_smart_alarm_screen_a_backup_alarm_is_set_for_cf8b94fb, hhmm(deadline)),
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                } else {
                    Text(uiString(R.string.l10n_smart_alarm_screen_off_e3de5ab0), style = NoopType.title2, color = Palette.textSecondary)
                    Text(
                        uiString(R.string.l10n_smart_alarm_screen_turn_on_the_smart_alarm_to_65700430),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun AlarmSettingsCard(content: @Composable () -> Unit) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Alarm, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text(uiString(R.string.l10n_smart_alarm_screen_wake_alarm_37af3ecf), style = NoopType.headline, color = Palette.textPrimary)
            }
            content()
        }
    }
}

/** The cross-platform evening wind-down nudge — a gentle reminder, not an alarm. Rest-tinted when on. */
@Composable
private fun WindDownCard(vm: AppViewModel) {
    val enabled by vm.windDownEnabled.collectAsStateWithLifecycle()
    NoopCard(padding = 20.dp, tint = if (enabled) DomainTheme.Rest.color else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Evening")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Bedtime, contentDescription = null, tint = DomainTheme.Rest.color)
                    Spacer(Modifier.width(10.dp))
                    Text(uiString(R.string.l10n_smart_alarm_screen_wind_down_nudge_5ca87a0f), style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_remind_me_to_wind_down_4839f0d0),
                help = "A gentle evening notification, timed from your wake time and usual sleep need, so you can settle in time. It's a suggestion, not an alarm.",
                checked = enabled,
                onChange = { vm.setWindDownEnabled(it) },
            )
        }
    }
}

@Composable
private fun ExplanationCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text(uiString(R.string.l10n_smart_alarm_screen_how_the_smart_wake_works_8cf34930), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_smart_alarm_screen_while_you_re_inside_the_window_8700ca3b) +
                    "sleep sits near your nightly low and stays steady; when your heart rate lifts above " +
                    "that (a sign you're sleeping more lightly or starting to stir), NOOP wakes you a " +
                    "little early so you come up from a lighter phase.",
                style = NoopType.footnote, color = Palette.textSecondary,
            )
            Text(
                uiString(R.string.l10n_smart_alarm_screen_this_is_a_coarse_cue_from_d6bbabe7) +
                    "isn't streaming (Bluetooth off, not worn, app killed), no early wake happens and the " +
                    "guaranteed alarm at the window's end still wakes you.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Window stepper (5–60 min in 5-min steps)

@Composable
private fun WindowStepper(windowMinutes: Int, onChange: (Int) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StepperButton(symbol = "−", onClick = { onChange((windowMinutes - 5).coerceAtLeast(5)) }, label = uiString(R.string.l10n_smart_alarm_screen_shorten_window_5bf5b37d))
        Text(uiString(R.string.l10n_smart_alarm_screen_windowminutes_min_bd89fd82, windowMinutes), style = NoopType.bodyNumber, color = Palette.textPrimary)
        StepperButton(symbol = "+", onClick = { onChange((windowMinutes + 5).coerceAtMost(60)) }, label = uiString(R.string.l10n_smart_alarm_screen_lengthen_window_c947ea1d))
    }
}

// MARK: - Local toggle / divider (mirror the AutomationsScreen idiom, kept local to this lane's file)

@Composable
private fun ToggleRowLocal(label: String, help: String, checked: Boolean, onChange: (Boolean) -> Unit) {
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
private fun RowDividerLocal() {
    Spacer(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

// MARK: - Helpers

private fun hhmm(minutes: Int): String {
    val m = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
    return "%02d:%02d".format(m / 60, m % 60)
}

/** Open the system page where the user grants the exact-alarm special-access permission (API 31+).
 *  There's no runtime dialog for this; the user toggles it in Settings and returns. */
private fun requestExactAlarmAccess(context: android.content.Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    runCatching {
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }.onFailure {
        // Fall back to the app-details page if the OEM lacks the specific action.
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
