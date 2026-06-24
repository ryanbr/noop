package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.analytics.AutoWorkoutDetector
import com.noop.data.DailyMetric
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * AutoWorkoutNudge — the NON-DESTRUCTIVE "looks like a workout" Today card (MVP auto-detect, opt-in).
 *
 * Android twin of iOS `AutoWorkoutCard` (Strand/Screens/AutoWorkoutCard.swift), wired to the byte-parity
 * [AutoWorkoutDetector]. Gated on [NoopPrefs.autoDetectWorkouts] (default OFF) — when off, NOTHING runs
 * and nothing renders. When on, after Today appears (and whenever the data refreshes) it scans the last
 * couple of days of strap HR through the pure detector, excludes any window that OVERLAPS a saved workout
 * (any source) or was previously dismissed, and surfaces ONE card — the most recent candidate:
 *
 *   "Looks like a workout around <start>–<end> (avg HR <avg>, <dur> min). Save it?"
 *
 * SAVE → builds a manual-style "Workout" row over the window (avg HR filled) via the existing
 * [WorkoutEditing.buildManualRow] + [com.noop.data.WhoopRepository.saveManualWorkout] path. DISMISS
 * (× or "Not a workout") → records the window in the durable, SEPARATE [AutoWorkoutPrefs] dismissed set
 * so it never re-prompts. It NEVER creates a workout without the user tapping Save.
 *
 * Design-Reset compliant: a flat accent-tinted [NoopCard], NoopMetrics tokens, no gold — matching the
 * other Today cards (mirrors [DonationNudgeCard] and the iOS source exactly).
 */

/** The strap source the scan + saves use, matching the rest of Today ("my-whoop"). */
private const val AUTO_DETECT_DEVICE = "my-whoop"

/** Generic sport label for a saved auto-detected bout — the user can re-label via Workouts → Edit. */
private const val AUTO_DETECT_SPORT = "Workout"

/** Days of HR history the scan covers — matches the iOS `autoDetectCandidate(daysBack: 2)`. */
private const val AUTO_DETECT_DAYS_BACK = 2L

private val autoNudgeTimeFmt: DateTimeFormatter =
    // HH:mm in the user's locale/timezone — mirrors the iOS card's short-time DateFormatter.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private val autoNudgeDateFmt: DateTimeFormatter =
    // Localized MEDIUM date ("23 Jun 2026") for a workout older than yesterday — mirrors the iOS card.
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private fun hhmm(epochSec: Long): String = autoNudgeTimeFmt.format(Instant.ofEpochSecond(epochSec))

/** A relative LOCAL-day prefix for the prompt (#719): "" when the workout started today, "yesterday "
 *  when yesterday, else "on <date> " — so a time-only prompt can no longer read last night as today. */
private fun dayLabel(epochSec: Long): String {
    val zone = ZoneId.systemDefault()
    val day = Instant.ofEpochSecond(epochSec).atZone(zone).toLocalDate()
    val today = LocalDate.now(zone)
    return when (day) {
        today -> ""
        today.minusDays(1) -> "yesterday "
        else -> "on ${autoNudgeDateFmt.format(Instant.ofEpochSecond(epochSec))} "
    }
}

/** "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?" — mirrors iOS. */
private fun promptText(w: AutoWorkoutDetector.DetectedWorkout): String =
    "Looks like a workout ${dayLabel(w.startSec)}around ${hhmm(w.startSec)}–${hhmm(w.endSec)} " +
        "(avg HR ${w.avgBpm}, ${w.durationMin} min). Save it?"

@Composable
fun AutoWorkoutNudgeCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
) {
    val context = LocalContext.current
    // Read once — SharedPreferences isn't reactive; when off, the whole feature is invisible + inert.
    val enabled = remember { NoopPrefs.autoDetectWorkouts(context) }
    if (!enabled) return

    val scope = rememberCoroutineScope()
    // The single surfaced candidate (null = nothing to suggest). Re-scanned whenever the day data grows.
    var candidate by remember { mutableStateOf<AutoWorkoutDetector.DetectedWorkout?>(null) }
    // Hide immediately on Save/X without waiting for the next reload (mirrors iOS `handledThisSession`).
    var handledThisSession by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    // Re-scan after Today appears / when the data refreshes (days = the recompute trigger; the Android
    // analog of the iOS refreshSeq). All reads + detection run off the main thread. Mirrors `reload()`.
    LaunchedEffect(days, enabled) {
        val next = runCatching { autoDetectCandidate(viewModel, context, days) }.getOrNull()
        // A fresh scan that surfaces a DIFFERENT window resets the session guard so a new bout can show.
        if (next != candidate) handledThisSession = false
        candidate = next
    }

    val w = candidate
    if (handledThisSession || w == null) return

    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.AutoMirrored.Filled.DirectionsRun,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Looks like a workout", style = NoopType.headline, color = Palette.textPrimary)
                }
                // Standard × dismiss → record the window durably so it never re-prompts.
                IconButton(
                    onClick = {
                        AutoWorkoutPrefs.dismiss(context, w)
                        handledThisSession = true
                        candidate = null
                    },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = "Dismiss this workout suggestion" },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Text(
                promptText(w),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    enabled = !saving,
                    onClick = {
                        saving = true
                        handledThisSession = true
                        scope.launch {
                            // Build a manual-style "Workout" row over the detected window (avg HR filled),
                            // saved via the SAME manual path the Workouts screen uses — non-destructive
                            // until this tap. Mirrors iOS `saveDetectedWorkout`.
                            val durMin = ((w.endSec - w.startSec) / 60L).toInt().coerceAtLeast(1)
                            val row = WorkoutEditing.buildManualRow(
                                deviceId = AUTO_DETECT_DEVICE,
                                startSeconds = w.startSec,
                                durationMin = durMin,
                                sport = AUTO_DETECT_SPORT,
                                avgHr = w.avgBpm,
                                energyKcal = null,
                            )
                            if (row != null) runCatching { viewModel.repo.saveManualWorkout(row) }
                            candidate = null
                            saving = false
                        }
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) { Text(if (saving) "Saving…" else "Save it") }

                OutlinedButton(
                    enabled = !saving,
                    onClick = {
                        AutoWorkoutPrefs.dismiss(context, w)
                        handledThisSession = true
                        candidate = null
                    },
                ) { Text("Not a workout", color = Palette.textSecondary) }
            }
        }
    }
}

/**
 * Pure read + suggestion path mirroring iOS `Repository.autoDetectCandidate(daysBack:)`. Scans the last
 * [AUTO_DETECT_DAYS_BACK] days of HR, runs the byte-parity detector, excludes saved + dismissed windows,
 * and returns the MOST RECENT surviving candidate (newest first), or null. Never writes anything.
 */
private suspend fun autoDetectCandidate(
    viewModel: AppViewModel,
    context: android.content.Context,
    days: List<DailyMetric>,
): AutoWorkoutDetector.DetectedWorkout? {
    val nowSec = System.currentTimeMillis() / 1000
    val fromSec = nowSec - AUTO_DETECT_DAYS_BACK * 86_400L
    val repo = viewModel.repo

    val hr = repo.hrSamples(AUTO_DETECT_DEVICE, fromSec, nowSec, limit = 200_000)
    if (hr.size < 2) return null

    // Resting HR: most recent nightly RHR in history, else the detector's own default (60). Byte-faithful
    // to iOS `days.last(where: { restingHr != nil })?.restingHr`.
    val restingHr = days.lastOrNull { it.restingHr != null }?.restingHr

    // Exclude EVERY already-saved workout window (any source — strap/manual, Apple Health, Health Connect,
    // computed "detected" bouts, imported lifting). Matches the iOS `workoutRows()` source union.
    val computed = repo.computedDeviceId(AUTO_DETECT_DEVICE)
    val saved = (
        repo.workouts(AUTO_DETECT_DEVICE, fromSec, nowSec) +
            repo.workouts("apple-health", fromSec, nowSec) +
            repo.workouts("health-connect", fromSec, nowSec) +
            repo.workouts(computed, fromSec, nowSec) +
            repo.workouts("lifting", fromSec, nowSec)
        ).map { it.startTs to it.endTs }

    val candidates = AutoWorkoutDetector.detect(
        hr = hr,
        restingHR = restingHr,
        gravity = emptyList(), // HR-only MVP (matches iOS passing motion: nil)
        savedWorkouts = saved,
    )
    // Drop anything the user already dismissed, then take the most recent. Mirrors iOS exactly.
    val dismissed = AutoWorkoutPrefs.dismissed(context)
    return candidates
        .filter { AutoWorkoutPrefs.token(it) !in dismissed }
        .maxByOrNull { it.startSec }
}
