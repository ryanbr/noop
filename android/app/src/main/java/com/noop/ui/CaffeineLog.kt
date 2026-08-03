package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Context
import android.widget.Toast
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.analytics.CaffeineActiveEstimate
import com.noop.analytics.CaffeineDecay
import com.noop.analytics.CaffeineIntake
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.UUID
import kotlin.math.roundToInt

// MARK: - Caffeine window (#526) — pure persistence helpers + the Insights logging card.
//
// Faithful Kotlin twin of Strand/Screens/CaffeineLogCard.swift + the CaffeineLogStore persistence.
// OPT-IN, manual-first: the user logs a caffeine intake (time + OPTIONAL mg) and NOOP shows a rough,
// on-device "still active" hint from a ~5–6 h half-life decay. Nothing leaves the device. The decay math
// + honesty rules live in com.noop.analytics.CaffeineDecay (cross-platform parity). Reuses the journal's
// SharedPreferences + showToast (Toast) patterns.

private const val CAFFEINE_PREFS = "noop_prefs"
private const val CAFFEINE_KEY = "noop.caffeineIntakes"
/** Drop intakes older than this many hours on load — well past the decay horizon, so the estimate is
 *  unchanged but the stored blob can't grow without bound. Matches Swift CaffeineLogStore.retentionHours. */
private const val CAFFEINE_RETENTION_HOURS = 48.0

/** Load the user's logged caffeine intakes, pruning anything past the retention horizon. */
internal fun loadCaffeineIntakes(context: Context, nowEpochSec: Long = System.currentTimeMillis() / 1000L): List<CaffeineIntake> {
    val raw = context.getSharedPreferences(CAFFEINE_PREFS, Context.MODE_PRIVATE).getString(CAFFEINE_KEY, "") ?: ""
    if (raw.isBlank()) return emptyList()
    val cutoff = nowEpochSec - (CAFFEINE_RETENTION_HOURS * 3600).toLong()
    return runCatching {
        val arr = JSONArray(raw)
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val at = o.optLong("at", Long.MIN_VALUE)
            if (at == Long.MIN_VALUE || at < cutoff) return@mapNotNull null
            CaffeineIntake(
                id = o.optString("id", UUID.randomUUID().toString()),
                atEpochSec = at,
                mg = if (o.has("mg") && !o.isNull("mg")) o.optDouble("mg") else null,
            )
        }.sortedByDescending { it.atEpochSec }
    }.getOrDefault(emptyList())
}

private fun saveCaffeineIntakes(context: Context, intakes: List<CaffeineIntake>) {
    val arr = JSONArray()
    for (i in intakes) {
        val o = JSONObject()
        o.put("id", i.id)
        o.put("at", i.atEpochSec)
        if (i.mg != null) o.put("mg", i.mg) else o.put("mg", JSONObject.NULL)
        arr.put(o)
    }
    context.getSharedPreferences(CAFFEINE_PREFS, Context.MODE_PRIVATE)
        .edit().putString(CAFFEINE_KEY, arr.toString()).apply()
}

/** Sanitise a user-entered mg into a stored value: blank/invalid/negative → null (unknown, not garbage);
 *  absurdly large → clamped. Honest: unknown amount is better than a wrong amount. Mirrors Swift. */
internal fun sanitiseCaffeineMg(input: String?): Double? {
    val v = input?.trim()?.toDoubleOrNull() ?: return null
    if (!v.isFinite() || v <= 0) return null
    return minOf(v, 2000.0)
}

/** Append a logged intake (newest-first) and persist. Returns the new list. */
internal fun addCaffeineIntake(context: Context, atEpochSec: Long, mgInput: String?): List<CaffeineIntake> {
    val intake = CaffeineIntake(UUID.randomUUID().toString(), atEpochSec, sanitiseCaffeineMg(mgInput))
    val next = (listOf(intake) + loadCaffeineIntakes(context)).sortedByDescending { it.atEpochSec }
    saveCaffeineIntakes(context, next)
    return next
}

internal fun removeCaffeineIntake(context: Context, id: String): List<CaffeineIntake> {
    val next = loadCaffeineIntakes(context).filterNot { it.id == id }
    saveCaffeineIntakes(context, next)
    return next
}

// MARK: - Cutoff window (PR#566, mvanhorn) — local-time helpers over the pure CaffeineDecay math.

/** Minutes since local midnight for an epoch-seconds timestamp — so an intake's clock time can be
 *  compared against the cutoff. Pure given a fixed clock; uses the device timezone. */
internal fun localMinutesOfDay(epochSec: Long): Int {
    val cal = Calendar.getInstance().apply { timeInMillis = epochSec * 1000L }
    return cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
}

/** True when [intake] was logged after the caffeine cutoff for [bedtimeMinutes] (so it's likely still
 *  active at bedtime). Delegates the decay math to [CaffeineDecay.isPastCutoff]; only the clock mapping
 *  lives here. */
internal fun isIntakePastCutoff(intake: CaffeineIntake, bedtimeMinutes: Int): Boolean =
    CaffeineDecay.isPastCutoff(localMinutesOfDay(intake.atEpochSec), bedtimeMinutes)

// MARK: - The logging card (hosted in Insights, in the "log today" block)

/**
 * Log a caffeine intake (time + OPTIONAL mg) and see a plain on-device "still active" hint. OPT-IN:
 * shows the empty-state line until the user logs one. Self-contained — owns its own SharedPreferences
 * state, so the host needs no wiring. The estimate is clearly framed as a rough guide, never a health
 * claim. Twin of macOS CaffeineLogCard.
 */
@Composable
fun CaffeineLogCard() {
    val context = LocalContext.current
    var intakes by remember { mutableStateOf(loadCaffeineIntakes(context)) }
    var mgDraft by remember { mutableStateOf("") }
    // Recompute against "now" each recomposition; a logged intake bumps `intakes` which recomposes.
    val nowSec = System.currentTimeMillis() / 1000L
    val estimate = CaffeineActiveEstimate.compute(intakes, nowSec)

    // Cutoff nudge (PR#566, mvanhorn) — opt-in, default OFF. SharedPreferences isn't reactive, so the
    // toggle + bedtime mirror into local state and write straight through. The cutoff time is derived
    // purely from the bedtime via CaffeineDecay; no notification — a quiet inline hint only.
    var cutoffEnabled by remember { mutableStateOf(NoopPrefs.caffeineCutoffEnabled(context)) }
    var bedtimeMinutes by remember { mutableStateOf(NoopPrefs.caffeineBedtimeMinutes(context)) }
    val cutoffMinutes = CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Overline("Log")
                Text(uiString(R.string.l10n_caffeine_log_caffeine_22859fa3), style = NoopType.title2, color = Palette.textPrimary)
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    uiString(R.string.l10n_caffeine_log_log_a_coffee_tea_or_energy_982bde5b),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )

                CaffeineActiveHint(estimate, hasAnyLog = intakes.isNotEmpty())

                CaffeineDivider()

                // Cutoff nudge (PR#566, mvanhorn): the latest you can have caffeine and still clear most of
                // it by bed. Opt-in. When on, shows the cutoff time (derived from your bedtime) and flags a
                // late intake below. A guide from the same half-life model, not a rule.
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(uiString(R.string.l10n_caffeine_log_late_caffeine_nudge_6b2ff690), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_caffeine_log_flag_drinks_late_enough_to_still_af311272),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = cutoffEnabled,
                        onCheckedChange = {
                            cutoffEnabled = it
                            NoopPrefs.setCaffeineCutoffEnabled(context, it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_caffeine_log_late_caffeine_nudge_6b2ff690) },
                    )
                }
                if (cutoffEnabled) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(uiString(R.string.l10n_caffeine_log_bedtime_e3cb8bd6), style = NoopType.footnote, color = Palette.textSecondary)
                        Spacer(Modifier.weight(1f))
                        TimeChip(
                            minutes = bedtimeMinutes,
                            accessibilityLabel = "Bedtime for the caffeine cutoff",
                            onPicked = {
                                bedtimeMinutes = it
                                NoopPrefs.setCaffeineBedtimeMinutes(context, it)
                            },
                        )
                    }
                    Text(
                        uiString(R.string.l10n_caffeine_log_have_your_last_caffeine_by_about_16b09033, clockLabel(cutoffMinutes)) +
                            "by ${clockLabel(bedtimeMinutes)}. A rough guide from a typical 5 to 6 hour " +
                            "half-life, not a rule.",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }

                CaffeineDivider()

                // Optional amount — leave blank if unknown. We never invent a number.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = mgDraft,
                        onValueChange = { mgDraft = it },
                        placeholder = {
                            Text(uiString(R.string.l10n_caffeine_log_amount_in_mg_optional_f0749888), style = NoopType.body, color = Palette.textTertiary)
                        },
                        singleLine = true,
                        textStyle = NoopType.body,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = caffeineFieldColors(),
                        shape = RoundedCornerShape(14.dp),
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("mg", style = NoopType.footnote, color = Palette.textTertiary)
                }

                // Log "now" or a quick number of hours ago.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(uiString(R.string.l10n_caffeine_log_had_it_8576ac66), style = NoopType.footnote, color = Palette.textSecondary)
                    Spacer(Modifier.weight(1f))
                    for (h in intArrayOf(0, 1, 2, 3)) {
                        CaffeineChip(if (h == 0) "Now" else "${h}h ago") {
                            val at = (System.currentTimeMillis() / 1000L) - h * 3600L
                            intakes = addCaffeineIntake(context, at, mgDraft)
                            mgDraft = ""
                            Toast.makeText(context, "Caffeine logged.", Toast.LENGTH_SHORT).show()
                        }
                        Spacer(Modifier.width(6.dp))
                    }
                }

                if (intakes.isNotEmpty()) {
                    CaffeineDivider()
                    Text(uiString(R.string.l10n_caffeine_log_logged_today_0071a46c), style = NoopType.caption, color = Palette.textTertiary)
                    intakes.forEach { intake ->
                        val late = cutoffEnabled && isIntakePastCutoff(intake, bedtimeMinutes)
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    caffeineIntakeLabel(intake, context),
                                    style = NoopType.body,
                                    color = Palette.textPrimary,
                                )
                                if (late) {
                                    Text(
                                        uiString(R.string.l10n_caffeine_log_after_your_clocklabel_cutoffminutes_cutoff_may_3c023900, clockLabel(cutoffMinutes)),
                                        style = NoopType.caption,
                                        color = Palette.statusWarning,
                                    )
                                }
                            }
                            CaffeineRemoveButton {
                                intakes = removeCaffeineIntake(context, intake.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CaffeineActiveHint(estimate: CaffeineActiveEstimate, hasAnyLog: Boolean) {
    if (estimate.hasActive) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                estimate.totalRemainingMg?.let { "About ${it.roundToInt()} mg may still be active" }
                    ?: "Caffeine may still be active",
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(caffeineActiveDetail(estimate), style = NoopType.footnote, color = Palette.textTertiary)
        }
    } else {
        Text(
            if (!hasAnyLog) "No caffeine logged. Log an intake to see an estimate."
            else "Estimated mostly cleared. Nothing logged is likely still active.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

private fun caffeineActiveDetail(estimate: CaffeineActiveEstimate): String {
    val parts = ArrayList<String>()
    estimate.hoursSinceMostRecentActive?.let { parts.add("most recent intake about ${caffeineHoursLabel(it)} ago") }
    if (estimate.activeIntakeCount > 1) parts.add("${estimate.activeIntakeCount} intakes still in the estimate")
    val lead = if (parts.isEmpty()) "" else parts.joinToString(" · ") + ". "
    return lead + "Rough guide only, based on what you logged."
}

private fun caffeineHoursLabel(hrs: Double): String {
    if (hrs < 1) return "under an hour"
    val r = hrs.roundToInt()
    return if (r == 1) "1 hour" else "$r hours"
}

private fun caffeineIntakeLabel(intake: CaffeineIntake, context: Context): String {
    val time = android.text.format.DateFormat.getTimeFormat(context)
        .format(java.util.Date(intake.atEpochSec * 1000L))
    return if (intake.mg != null) "$time · ${intake.mg.roundToInt()} mg" else "$time · amount not logged"
}

/** A minutes-since-midnight value as a wall-clock label (e.g. "2:30 PM" / "14:30"), respecting the
 *  device's 12/24-hour preference — used for the caffeine cutoff + bedtime hints. */
@Composable
private fun clockLabel(minutesOfDay: Int): String {
    val context = LocalContext.current
    val cal = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, (minutesOfDay / 60) % 24)
        set(Calendar.MINUTE, minutesOfDay % 60)
    }
    return android.text.format.DateFormat.getTimeFormat(context).format(cal.time)
}

@Composable
private fun CaffeineDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .height(1.dp)
            .background(Palette.hairline),
    )
}

@Composable
private fun CaffeineChip(label: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        label,
        style = NoopType.caption,
        color = Palette.textSecondary,
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

@Composable
private fun CaffeineRemoveButton(onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        uiString(R.string.l10n_caffeine_log_remove_e963907d),
        style = NoopType.caption,
        color = Palette.statusCritical,
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.statusCritical.copy(alpha = 0.5f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun caffeineFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    disabledTextColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    disabledBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
)
