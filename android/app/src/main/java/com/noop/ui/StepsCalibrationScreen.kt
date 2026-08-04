package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import com.noop.data.WhoopRepository
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.SyncProblem
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.analytics.StepsEstimateEngine
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - StepsCalibrationScreen (ported from Strand/Screens/SettingsView.swift StepsCalibrationSheet)
//
// WHOOP 4.0 steps-ESTIMATE calibration. A 4.0 sends no step count over BLE, so NOOP estimates steps
// from the strap's daily MOTION VOLUME, calibrated per-user against the phone's real step count. This
// screen is read-only over the engine's fit (it never recomputes the headline): an honest explainer,
// the current calibration, a recent estimated-vs-phone accuracy table, and a manual coefficient
// override with a live preview. Mirrors the macOS StepsCalibrationSheet card-for-card and shares its
// confidence wording via [StepsCalibrationFormat]. Presented in a full-screen Dialog from Settings →
// Profile → "Steps estimate".

/** Shared formatters for the steps-estimate calibration UI — kept apart so the Profile summary row and
 *  this screen agree on the confidence wording. Mirrors the macOS `StepsCalibrationFormat`. */
object StepsCalibrationFormat {
    /** A 0–1 confidence as Low / Medium / High. Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual
     *  coefficient is confidence 1.0 → "High". */
    fun confidenceLabel(confidence: Double): String = when {
        confidence < 0.34 -> "Low"
        confidence < 0.67 -> "Medium"
        else -> "High"
    }
}

/** One recent day's estimated-vs-phone steps comparison row for the accuracy table. */
private data class StepsComparisonRow(val day: String, val estimated: Int, val actual: Int) {
    /** Signed error of the estimate vs the phone count, as a percentage. */
    val errorPct: Double get() = if (actual > 0) (estimated - actual).toDouble() / actual * 100 else 0.0
}

@Composable
fun StepsCalibrationScreen(
    vm: AppViewModel,
    profile: ProfileStore,
    onProfileChanged: () -> Unit,
    onClose: () -> Unit,
) {
    val scroll = rememberScrollState()

    // Recent days that have BOTH an estimate (reconstructed) and a phone count — the accuracy table.
    var comparison by remember { mutableStateOf<List<StepsComparisonRow>>(emptyList()) }
    // A representative recent motion volume (median of the days we measured), seeding the live preview.
    var sampleMotion by remember { mutableStateOf<Double?>(null) }
    // Flips true once the load pass has run, so the "no motion synced" note (#37) doesn't flash on first frame.
    var loaded by remember { mutableStateOf(false) }

    // The stepper's ceiling anchors to whatever's in force with generous headroom, so a nudge either way
    // stays reachable; a floor keeps it usable before any fit. Mirrors the macOS sliderMax.
    val stepperMax = maxOf(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50.0) * 2

    // Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    // strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone
    // count never co-exist in storage. To still SHOW how close the estimate is, we reconstruct what the
    // estimate WOULD have been on recent phone-covered days: read each day's motion the same way the
    // engine does (gravity over [localMidnight, +24h)) and run the public StepsEstimateEngine with the
    // live calibration. Reuses the engine, never invents a number, needs no extra storage.
    LaunchedEffect(Unit) {
        loaded = true
        val coeff = if (profile.stepsManualCoefficient > 0) {
            profile.stepsManualCoefficient
        } else {
            profile.stepsCalibrationCoefficient
        }
        if (coeff <= 0) return@LaunchedEffect

        // Phone step counts come from apple-health AND, for HC-only users, Health Connect (#37). Both are
        // stored in appleDaily under their own source; union them with apple-health winning per day.
        val stepsByDay = LinkedHashMap<String, Int>()
        for (row in vm.repo.appleDaily(WhoopRepository.APPLE_HEALTH_SOURCE, "0000-01-01", "9999-12-31")) {
            row.steps?.takeIf { it > 0 }?.let { stepsByDay[row.day] = it }
        }
        for (row in vm.repo.appleDaily(WhoopRepository.HEALTH_CONNECT_SOURCE, "0000-01-01", "9999-12-31")) {
            row.steps?.takeIf { it > 0 }?.let { stepsByDay.putIfAbsent(row.day, it) }
        }
        val phoneDays = stepsByDay.entries
            .map { it.key to it.value }
            .sortedByDescending { it.first }

        val cal = StepsEstimateEngine.Calibration(
            coefficient = coeff,
            sampleDays = profile.stepsCalibrationSampleDays,
            confidence = profile.stepsCalibrationConfidence,
            manual = profile.stepsManualCoefficient > 0,
        )
        val rows = ArrayList<StepsComparisonRow>()
        val motions = ArrayList<Double>()
        for ((day, phone) in phoneDays.take(10)) {           // scan extra to fill 7 after motion gaps
            val mid = runCatching {
                LocalDate.parse(day).atStartOfDay(ZoneId.systemDefault()).toEpochSecond()
            }.getOrNull() ?: continue
            val grav = vm.repo.gravitySamples("my-whoop", mid, mid + 86_400 - 1)
            val motion = StepsEstimateEngine.dayMotionIntensity(grav)
            val est = StepsEstimateEngine.estimate(motion, cal) ?: continue
            motions.add(motion)
            rows.add(StepsComparisonRow(day, est, phone))
            if (rows.size >= 7) break
        }
        comparison = rows
        if (motions.isNotEmpty()) sampleMotion = motions.sorted()[motions.size / 2]
    }

    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            Header(onClose)
            Hairline()
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(scroll)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                ExplainerCard()
                if (loaded && sampleMotion == null) NoMotionNote()
                // #589: the matched-day count (phone-counted days we could pair with strap motion — the
                // engine's "usable overlapping days") drives the "Need N more days…" countdown. In the
                // not-calibrated state the comparison build early-returns on coeff <= 0, so this is 0 and
                // the headline reads the full MIN_CALIBRATION_DAYS — exactly the Swift behaviour.
                CurrentFitCard(profile, matchedDays = comparison.size)
                ComparisonCard(comparison)
                ManualAdjustCard(
                    profile = profile,
                    stepperMax = stepperMax,
                    sampleMotion = sampleMotion,
                    onProfileChanged = onProfileChanged,
                )
            }
            Hairline()
            Footer(onClose)
        }
    }
}

// MARK: - Header / footer

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Overline("Steps estimate", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_steps_calibration_screen_calibrate_your_steps_38b4e814), style = NoopType.display(26f), color = Palette.textPrimary)
            Text(uiString(R.string.l10n_steps_calibration_screen_whoop_4_0_motion_steps_a63239dc), style = NoopType.caption, color = Palette.textSecondary)
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_steps_calibration_screen_close_bbfa773e), tint = Palette.textTertiary, modifier = Modifier.size(22.dp))
        }
    }
}

@Composable
private fun Footer(onClose: () -> Unit) {
    Row(modifier = Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
        Button(
            onClick = onClose,
            colors = ButtonDefaults.buttonColors(containerColor = Palette.accent, contentColor = Palette.surfaceBase),
        ) {
            Text(uiString(R.string.l10n_steps_calibration_screen_done_e9b450d1), modifier = Modifier.padding(horizontal = 24.dp))
        }
    }
}

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

// MARK: - Cards

/** The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc. */
@Composable
private fun ExplainerCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.AutoMirrored.Filled.DirectionsWalk, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(20.dp))
                Text(uiString(R.string.l10n_steps_calibration_screen_how_this_works_b895a8c3), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_steps_calibration_screen_noop_estimates_your_steps_from_your_d569bc31),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Text(
                uiString(R.string.l10n_steps_calibration_screen_on_the_days_your_phone_also_2f65a14c) +
                    "steps, then applies that to the strap-only days. The more matching days it has, the " +
                    "more it trusts the estimate.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** Shown when the strap has banked NO motion yet (sampleMotion == null) — the real reason a fresh
 *  WHOOP 4.0 reads zero steps (#37 bringiton321). Steps come from the strap's synced motion history,
 *  so without a backfill there's nothing to estimate from — calibration can't help until it syncs. */
@Composable
private fun NoMotionNote() {
    NoopCard(padding = 20.dp, tint = Palette.metricAmber) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.SyncProblem, contentDescription = null, tint = Palette.metricAmber, modifier = Modifier.size(20.dp))
                Text(uiString(R.string.l10n_steps_calibration_screen_no_motion_synced_yet_65106670), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_steps_calibration_screen_we_re_not_seeing_any_motion_6ac8e092) +
                    "banked motion history, so your strap needs to sync that history before NOOP has " +
                    "anything to count.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Text(
                uiString(R.string.l10n_steps_calibration_screen_open_noop_near_your_strap_and_e08ddd6d) +
                    "first run). Once a day or two of motion lands, your step estimate and the calibration " +
                    "below will start to fill in.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence — or
 *  an honest "what we still need" prompt when nothing's fit and no manual value is set. */
@Composable
private fun CurrentFitCard(profile: ProfileStore, matchedDays: Int) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline("Current calibration")
            if (profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0) {
                val coeff = if (profile.stepsManualCoefficient > 0) {
                    profile.stepsManualCoefficient
                } else {
                    profile.stepsCalibrationCoefficient
                }
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(String.format(Locale.US, "%.1f", coeff), style = NoopType.number(30f), color = Palette.accent)
                    Text(uiString(R.string.l10n_steps_calibration_screen_steps_per_motion_unit_a2c2ac56), style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.padding(bottom = 4.dp))
                }
                if (profile.stepsManualCoefficient > 0) {
                    StatLine("Source", "Manual (you set this by hand)")
                } else {
                    val days = profile.stepsCalibrationSampleDays
                    StatLine("Fitted from", "$days day${if (days == 1) "" else "s"} your phone also counted")
                    StatLine(
                        "Confidence",
                        "${StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)} · " +
                            "${(profile.stepsCalibrationConfidence * 100).roundToInt()}%",
                    )
                }
            } else {
                Text(uiString(R.string.l10n_steps_calibration_screen_not_calibrated_yet_30abe0d0), style = NoopType.bodyNumber, color = Palette.textPrimary)
                // #589: a concrete countdown instead of a vague "a few days". Headline comes straight from
                // the engine's NeedsMoreDays state so the wording matches the Today steps tile + the Swift card.
                Text(
                    StepsEstimateEngine.CalibrationStatus
                        .NeedsMoreDays(have = matchedDays, need = StepsEstimateEngine.MIN_CALIBRATION_DAYS)
                        .headline,
                    style = NoopType.bodyNumber,
                    color = Palette.accent,
                )
                Text(
                    uiString(R.string.l10n_steps_calibration_screen_these_are_the_days_where_your_ae5c9c2c),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The accuracy table: recent days with BOTH an estimate and a phone count, side by side, so the user
 *  can SEE how close the estimate runs. Empty until enough both-have days exist. */
@Composable
private fun ComparisonCard(rows: List<StepsComparisonRow>) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline("Estimated vs your phone")
            if (rows.isEmpty()) {
                Text(
                    uiString(R.string.l10n_steps_calibration_screen_no_days_yet_where_both_noop_71d6005b) +
                        "few days alongside the strap, they'll appear here so you can see how close the " +
                        "estimate is.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            } else {
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(uiString(R.string.l10n_steps_calibration_screen_day_987b9ced), style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                    Text(uiString(R.string.l10n_steps_calibration_screen_est_18b405fb), style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.End, modifier = Modifier.width(64.dp))
                    Text(uiString(R.string.l10n_steps_calibration_screen_phone_77064d52), style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.End, modifier = Modifier.width(64.dp))
                    Text("Δ", style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.End, modifier = Modifier.width(52.dp))
                }
                for (row in rows) {
                    Row(
                        modifier = Modifier.fillMaxWidth().semantics {
                            contentDescription =
                                uiString(R.string.l10n_steps_calibration_screen_shortday_row_day_estimated_row_estimated_f2d71597, shortDay(row.day), row.estimated, row.actual) +
                                    "steps, ${row.errorPct.roundToInt()} percent difference"
                        },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(shortDay(row.day), style = NoopType.footnote, color = Palette.textSecondary, modifier = Modifier.weight(1f))
                        Text(grouped(row.estimated), style = NoopType.captionNumber, color = Palette.textPrimary, textAlign = TextAlign.End, modifier = Modifier.width(64.dp))
                        Text(grouped(row.actual), style = NoopType.captionNumber, color = Palette.textPrimary, textAlign = TextAlign.End, modifier = Modifier.width(64.dp))
                        Text(
                            String.format(Locale.US, "%+.0f%%", row.errorPct),
                            style = NoopType.captionNumber,
                            color = if (abs(row.errorPct) <= 15) Palette.metricCyan else Palette.statusWarning,
                            textAlign = TextAlign.End,
                            modifier = Modifier.width(52.dp),
                        )
                    }
                }
                Text(
                    uiString(R.string.l10n_steps_calibration_screen_these_days_are_excluded_from_the_6bedabbf),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** One step of the manual coefficient stepper (#698): a slider spanning the full 0..[stepperMax] range
 *  made a specific one-decimal value (e.g. nudging an auto 1.4 down to 1.2) practically undraggable —
 *  the whole usable precision was compressed into a handful of drag pixels. A fixed 0.1 tick, like the
 *  Profile card's age/weight steppers, makes that exact. */
private const val STEPS_COEFFICIENT_STEP = 0.1

/** Manual override: a stepper (mirrors the Profile card's age/weight [StepperField]s) bound directly to
 *  [ProfileStore.stepsManualCoefficient], with a live preview of what a typical recent day would
 *  estimate at the current setting. 0 means auto-fit; stepping down to 0 returns to it. Nudges start
 *  from whichever value is currently EFFECTIVE (the auto fit, until first overridden), so reaching a
 *  nearby value like 1.2 from an auto-fitted 1.4 is two taps, not a drag from zero (#698). */
@Composable
private fun ManualAdjustCard(
    profile: ProfileStore,
    stepperMax: Double,
    sampleMotion: Double?,
    onProfileChanged: () -> Unit,
) {
    val manual = profile.stepsManualCoefficient
    val effective = if (manual > 0) manual else profile.stepsCalibrationCoefficient

    fun step(delta: Double) {
        val next = (Math.round((effective + delta) * 10) / 10.0).coerceIn(0.0, stepperMax)
        profile.stepsManualCoefficient = next
        onProfileChanged()
    }

    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline("Adjust manually")
            Text(
                uiString(R.string.l10n_steps_calibration_screen_override_the_automatic_fit_with_your_36a7b6fa) +
                    "has no step history to learn from, or the estimate runs consistently high or low. " +
                    "Step all the way down to return to auto.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (manual > 0) String.format(Locale.US, "%.1f", manual) else "Auto",
                    style = NoopType.number(24f),
                    color = if (manual > 0) Palette.accent else Palette.textSecondary,
                )
                Text(
                    if (manual > 0) "steps / motion unit" else "fit from your phone",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                StepperField(
                    value = if (manual > 0) String.format(Locale.US, "%.1f", manual) else "Auto",
                    accessibility = if (manual > 0) {
                        String.format(Locale.US, "Manual steps coefficient, %.1f steps per motion unit", manual)
                    } else {
                        "Manual steps coefficient, automatic"
                    },
                    onMinus = { step(-STEPS_COEFFICIENT_STEP) },
                    onPlus = { step(STEPS_COEFFICIENT_STEP) },
                )
            }
            // Live preview: a typical recent day re-estimated at the effective (manual or auto) coefficient.
            if (sampleMotion != null && effective > 0) {
                val preview = (sampleMotion * effective).roundToInt()
                StatLine(
                    "A typical recent day",
                    "≈ ${grouped(preview)} steps${if (manual > 0) " at this setting" else " (auto)"}",
                )
            }
            if (manual > 0) {
                Text(
                    uiString(R.string.l10n_steps_calibration_screen_takes_effect_on_the_next_analytics_13205327),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** A small "label … value" line shared by the fit + preview cards. */
@Composable
private fun StatLine(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text(label, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(12.dp))
        Text(value, style = NoopType.footnote, color = Palette.textSecondary, textAlign = TextAlign.End)
    }
}

// MARK: - Formatting

private fun grouped(n: Int): String =
    if (abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"

/** "yyyy-MM-dd" → "EEE d MMM" for the table's day column. */
private fun shortDay(key: String): String = runCatching {
    LocalDate.parse(key).format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.US))
}.getOrDefault(key)
