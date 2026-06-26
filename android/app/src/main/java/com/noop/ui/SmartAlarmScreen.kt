package com.noop.ui

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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.text.style.TextAlign
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
 * Also hosts the cross-platform WIND-DOWN nudge toggle (a gentle evening reminder), so both the wake
 * alarm and the nudge live in one place.
 *
 * #766: this screen is now the single home for BOTH alarm engines. The phone smart-window alarm above and
 * the strap firmware alarm below used to sit in two different places (the latter under Automations), which
 * read as duplicate "Smart alarm" entries. They're genuinely different mechanisms — phone sound + light-
 * sleep detection vs. an offline wrist buzz from the strap's own firmware — so they stay two labelled
 * sections rather than one merged control, but they now live together. The relocation is presentation only:
 * each engine keeps its own ViewModel-backed prefs and scheduler; nothing about how either fires changed.
 */
@Composable
fun SmartAlarmScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val enabled by vm.phoneAlarmEnabled.collectAsStateWithLifecycle()
    val targetMinutes by vm.phoneAlarmTargetMinutes.collectAsStateWithLifecycle()
    val windowMinutes by vm.phoneAlarmWindowMinutes.collectAsStateWithLifecycle()
    val buzzWhoop4 by vm.buzzWhoop4Enabled.collectAsStateWithLifecycle()
    // #536: the hint adapts to bond state — the strap can only be armed when a WHOOP 4.0 is connected.
    val live = vm.live.collectAsStateWithLifecycle().value
    val bonded = live.bonded
    // Strap firmware alarm (#51), relocated here from Automations (#766). The SECOND alarm engine: arms the
    // strap's own firmware alarm to buzz the wrist at a fixed wake time, fully offline, even with NOOP closed.
    // Its own VM-backed prefs — the move changed presentation only, not storage or arming.
    val strapAlarm by vm.smartAlarmEnabled.collectAsStateWithLifecycle()
    val strapAlarmMinutes by vm.smartAlarmMinutes.collectAsStateWithLifecycle()
    val strapAlarmWeekdays by vm.smartAlarmWeekdays.collectAsStateWithLifecycle()
    val strapAlarmDayOverrides by vm.smartAlarmDayOverrides.collectAsStateWithLifecycle()
    // EXPERIMENTAL on WHOOP 5/MG: the firmware alarm only arms when Experimental probes are on (#111),
    // otherwise the time is saved but the strap is never armed — surfaced in the card so it isn't silent.
    val experimentalOn = PuffinExperiment.from(context).isEnabled

    // True when exact alarms are permitted. Re-read on each (re)composition because the user can grant
    // it in Settings and come back — there's no result callback for this special-access permission.
    var canSchedule by remember { mutableStateOf(vm.canScheduleExactAlarms()) }

    // PERF (#707): lazy scaffold — each of the four cards is one `item { }` (all unconditional). Order +
    // spacing unchanged (LazyColumn reproduces the eager `spacedBy(20.dp)`); only on-screen cards compose +
    // are accessibility-walked.
    LazyScreenScaffold(
        title = "Smart alarm",
        subtitle = "Two ways to wake, in one place: a phone smart-window alarm and the strap's own offline firmware buzz.",
    ) {
        // The guaranteed-wake card always shows so the safety promise is the first thing read.
        item { WindowCard(enabled = enabled, targetMinutes = targetMinutes, windowMinutes = windowMinutes) }

        item {
        AlarmSettingsCard {
            ToggleRowLocal(
                label = "Wake me with a smart alarm",
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
                    "NOOP doesn't have permission to set exact alarms, so your wake isn't guaranteed. " +
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
                        Text("Wake me no earlier than", style = NoopType.body, color = Palette.textPrimary)
                        Text("The earliest NOOP will wake you.", style = NoopType.footnote, color = Palette.textTertiary)
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
                        Text("Window length", style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            "The guaranteed alarm fires this long after your earliest time.",
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                    }
                    Spacer(Modifier.width(16.dp))
                    WindowStepper(
                        windowMinutes = windowMinutes,
                        onChange = { vm.setPhoneAlarmWindowMinutes(it) },
                    )
                }
            }

            // #536: companion strap-buzz, always visible so it's discoverable. Arms the WHOOP 4.0's own
            // firmware alarm at the earliest wake time, so the strap buzzes first and the OS alarm backs it up.
            RowDividerLocal()
            ToggleRowLocal(
                label = "Buzz WHOOP 4",
                help = if (bonded)
                    "Also arms your WHOOP 4.0 to buzz at your earliest wake time, so the strap wakes you first and the phone alarm is the guaranteed backup."
                else
                    "Connect your WHOOP 4.0 to use this. It arms the strap to buzz at your earliest wake time as a gentler first wake-up.",
                checked = buzzWhoop4,
                onChange = { vm.setBuzzWhoop4Enabled(it) },
            )
        }
        }

        // The honest explanation of how detection works + its limits.
        item { ExplanationCard() }

        // Strap firmware alarm (#766): the second alarm engine, relocated from Automations so every alarm
        // setting lives on this one screen. Always shown so it's discoverable even when off.
        item {
            StrapAlarmCard(
                enabled = strapAlarm,
                minutes = strapAlarmMinutes,
                weekdays = strapAlarmWeekdays,
                dayOverrides = strapAlarmDayOverrides,
                bonded = bonded,
                whoop5Detected = live.whoop5Detected,
                experimentalOn = experimentalOn,
                onEnabledChange = { vm.setSmartAlarmEnabled(it) },
                onMinutesChange = { vm.setSmartAlarmMinutes(it) },
                onWeekdaysToggle = { dow -> vm.setSmartAlarmWeekdays(toggledSmartAlarmWeekday(dow, strapAlarmWeekdays)) },
                onSetOverride = { dow, minutes -> vm.setSmartAlarmDayOverride(dow, minutes) },
            )
        }

        // The cross-platform wind-down nudge lives here too.
        item { WindDownCard(vm) }
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
                        "A backup alarm is set for ${hhmm(deadline)} — it fires even if Bluetooth drops, the strap isn't worn, or NOOP is closed.",
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                } else {
                    Text("Off", style = NoopType.title2, color = Palette.textSecondary)
                    Text(
                        "Turn on the smart alarm to wake inside a window you choose.",
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
                Text("Phone smart-window alarm", style = NoopType.headline, color = Palette.textPrimary)
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
                    Text("Wind-down nudge", style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            ToggleRowLocal(
                label = "Remind me to wind down",
                help = "A gentle evening notification, timed from your wake time and usual sleep need, so you can settle in time. It's a suggestion, not an alarm.",
                checked = enabled,
                onChange = { vm.setWindDownEnabled(it) },
            )
        }
    }
}

/**
 * Strap firmware alarm (#51) — the second alarm engine, co-located here with the phone alarm (#766). Arms
 * the strap's OWN firmware alarm to buzz the wrist at a fixed wake time, fully offline (works with NOOP
 * closed / Bluetooth asleep). Distinct from the phone smart-window alarm: no smart light-sleep detection,
 * but it reaches you on the wrist without the phone. Card body is the section lifted verbatim from
 * AutomationsScreen, re-skinned to this screen's NoopCard idiom; all VM wiring is unchanged.
 */
@Composable
private fun StrapAlarmCard(
    enabled: Boolean,
    minutes: Int,
    weekdays: Set<Int>,
    dayOverrides: Map<Int, Int>,
    bonded: Boolean,
    whoop5Detected: Boolean,
    experimentalOn: Boolean,
    onEnabledChange: (Boolean) -> Unit,
    onMinutesChange: (Int) -> Unit,
    onWeekdaysToggle: (Int) -> Unit,
    onSetOverride: (Int, Int?) -> Unit,
) {
    // Tint when armed so the active state reads at a glance — matches the WindDownCard idiom on this screen
    // and restores the accent highlight the old Automations SettingsSection(active:) gave this card.
    NoopCard(padding = 20.dp, tint = if (enabled) Palette.accent else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Alarm, contentDescription = null, tint = if (enabled) Palette.accent else Palette.textSecondary)
                    Spacer(Modifier.width(10.dp))
                    Text("Strap firmware alarm", style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(
                    "Wake to a buzz from the strap's own firmware alarm, even if NOOP is closed. Still experimental on WHOOP 4.0, so keep a backup alarm until you've confirmed it wakes you.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
            ToggleRowLocal(
                label = "Enable strap alarm",
                help = "Arms the strap to buzz at your wake time.",
                checked = enabled,
                onChange = onEnabledChange,
            )
            if (enabled) {
                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Wake at", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = minutes,
                        accessibilityLabel = "Strap alarm wake time",
                        onPicked = onMinutesChange,
                    )
                }
                RowDividerLocal()
                AlarmWeekdayPicker(selected = weekdays, onToggle = onWeekdaysToggle)
                RowDividerLocal()
                // Per-weekday wake-time OVERRIDES (#554): set a different time for any day the alarm fires on;
                // a day with no override uses the "Wake at" time above.
                AlarmDayOverridePicker(
                    defaultMinutes = minutes,
                    enabledDays = weekdays,
                    overrides = dayOverrides,
                    onSetOverride = onSetOverride,
                )
                RowDividerLocal()
                // A WHOOP 5/MG only arms when Experimental probes are on; without it the time is saved but
                // the strap is NEVER armed, so call that out in amber rather than promise a wake (#111).
                if (whoop5Detected && !experimentalOn) {
                    Text(
                        "Your WHOOP 5/MG won't arm this until Experimental mode is on (Settings → " +
                            "Experimental). Right now your wake time is saved but the strap is NOT armed.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                } else {
                    Text(
                        if (bonded)
                            "Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Still experimental — we can't yet guarantee it fires, so keep a backup alarm."
                        else
                            "Connect your strap to arm this — it's set on the strap's own firmware alarm. Still experimental, so keep a backup alarm until you've confirmed it wakes you.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - Strap-alarm weekday + per-day override pickers (relocated from AutomationsScreen, #766)

/**
 * Per-weekday wake-time OVERRIDES for the strap alarm (#554). For each day the alarm fires on, shows the
 * effective wake time (the day's override, else the default) as a [TimeChip]; picking a time sets that
 * day's override, and a "Reset" affordance clears it back to the default. Days the alarm doesn't fire on
 * aren't shown (no point overriding a day it won't ring). Empty enabledDays = every day, so all seven show.
 */
@Composable
private fun AlarmDayOverridePicker(
    defaultMinutes: Int,
    enabledDays: Set<Int>,
    overrides: Map<Int, Int>,
    onSetOverride: (Int, Int?) -> Unit,
) {
    val fireDays = SMART_ALARM_WEEKDAY_ORDER.filter { smartAlarmWeekdayIsSelected(it, enabledDays) }
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Per-day wake time", style = NoopType.caption, color = Palette.textTertiary)
        fireDays.forEach { dow ->
            val effective = overrides[dow] ?: defaultMinutes
            val hasOverride = overrides.containsKey(dow)
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(smartAlarmWeekdayName(dow), style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                if (hasOverride) {
                    Text(
                        "Reset",
                        style = NoopType.caption,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(CircleShape)
                            .clickable { onSetOverride(dow, null) }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                TimeChip(
                    minutes = effective,
                    accessibilityLabel = "${smartAlarmWeekdayName(dow)} wake time",
                    onPicked = { onSetOverride(dow, it) },
                )
            }
        }
        Text(
            "Each day uses the time above unless you set a different one here.",
            style = NoopType.footnote, color = Palette.textTertiary,
        )
    }
}

/**
 * Weekday selector for the strap alarm (#539). One tappable circle per weekday, Monday-first. An empty
 * [selected] set means "every day" (all circles read as on). Mirrors the macOS AutomationsView picker.
 */
@Composable
private fun AlarmWeekdayPicker(selected: Set<Int>, onToggle: (Int) -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (dow in SMART_ALARM_WEEKDAY_ORDER) {
                val on = smartAlarmWeekdayIsSelected(dow, selected)
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(if (on) Palette.accent else Palette.surfaceInset)
                        .clickable { onToggle(dow) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        smartAlarmWeekdayInitial(dow),
                        style = NoopType.caption,
                        color = if (on) Palette.surfaceBase else Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        Text(smartAlarmWeekdaySummary(selected), style = NoopType.caption, color = Palette.textTertiary)
    }
}

/** Calendar.DAY_OF_WEEK numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1). */
private val SMART_ALARM_WEEKDAY_ORDER = intArrayOf(2, 3, 4, 5, 6, 7, 1)

/** A day reads as "on" when the set is empty (= every day) or explicitly contains it. Pure for tests. */
internal fun smartAlarmWeekdayIsSelected(dow: Int, days: Set<Int>): Boolean =
    days.isEmpty() || days.contains(dow)

/**
 * Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
 * Pure + side-effect-free for unit tests. Pulling a day out of the implicit "every day" expands to the
 * explicit other six; selecting the seventh collapses back to the empty "every day" set. Mirrors macOS
 * `AutomationsView.toggledWeekday`.
 */
internal fun toggledSmartAlarmWeekday(dow: Int, days: Set<Int>): Set<Int> {
    val next: MutableSet<Int> = when {
        days.isEmpty() -> (1..7).toMutableSet().also { it.remove(dow) }
        days.contains(dow) -> days.toMutableSet().also { it.remove(dow) }
        else -> days.toMutableSet().also { it.add(dow) }
    }
    return if (next.size == 7) emptySet() else next
}

/** Human-readable summary of the selection. Pure for tests. Mirrors macOS `weekdaySummary`. */
internal fun smartAlarmWeekdaySummary(days: Set<Int>): String = when {
    days.isEmpty() || days.size == 7 -> "Every day"
    days == setOf(2, 3, 4, 5, 6) -> "Weekdays"
    days == setOf(1, 7) -> "Weekends"
    else -> SMART_ALARM_WEEKDAY_ORDER.filter { days.contains(it) }
        .joinToString(", ") { smartAlarmWeekdayName(it) }
}

private fun smartAlarmWeekdayInitial(dow: Int): String = when (dow) {
    1 -> "S"; 2 -> "M"; 3 -> "T"; 4 -> "W"; 5 -> "T"; 6 -> "F"; 7 -> "S"; else -> "?"
}

private fun smartAlarmWeekdayName(dow: Int): String = when (dow) {
    1 -> "Sun"; 2 -> "Mon"; 3 -> "Tue"; 4 -> "Wed"; 5 -> "Thu"; 6 -> "Fri"; 7 -> "Sat"; else -> "?"
}

@Composable
private fun ExplanationCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text("How the smart wake works", style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                "While you're inside the window, NOOP watches your live heart rate from the strap. Deep " +
                    "sleep sits near your nightly low and stays steady; when your heart rate lifts above " +
                    "that — a sign you're sleeping more lightly or starting to stir — NOOP wakes you a " +
                    "little early so you come up from a lighter phase.",
                style = NoopType.footnote, color = Palette.textSecondary,
            )
            Text(
                "This is a coarse cue from heart rate, not a clinical sleep-stage reading. If the strap " +
                    "isn't streaming — Bluetooth off, not worn, app killed — no early wake happens and the " +
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
        StepperButton(symbol = "−", onClick = { onChange((windowMinutes - 5).coerceAtLeast(5)) }, label = "Shorten window")
        Text("$windowMinutes min", style = NoopType.bodyNumber, color = Palette.textPrimary)
        StepperButton(symbol = "+", onClick = { onChange((windowMinutes + 5).coerceAtMost(60)) }, label = "Lengthen window")
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
