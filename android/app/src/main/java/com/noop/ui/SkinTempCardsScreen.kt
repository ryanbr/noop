package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.analytics.CircadianEngine
import com.noop.analytics.CyclePhaseEngine
import com.noop.analytics.IllnessDistance
import com.noop.analytics.IllnessSignalEngine
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Skin-temperature suite cards (v5 pillar) — Compose twin
//
// Kotlin/Compose mirror of Strand/Screens/SkinTempCardsView.swift. Three self-contained,
// reusable cards driven entirely by a pure com.noop.analytics engine RESULT passed in
// (Wave 3 runs the engines in the analytics pass and mounts these in the Health hub):
//
//   • CycleAwarenessCard   — CyclePhaseEngine.Result. OPT-IN (the host gates on a default-OFF
//                            preference). Awareness only — NOT contraception, NOT a fertility/
//                            ovulation predictor, NOT a diagnosis. Phase + cycle-day RANGE +
//                            probabilistic next-period WINDOW (never a hard date).
//   • BodyClockCard        — CircadianEngine.PhaseEstimate (+ optional JetLagPlan). LIGHT +
//                            SLEEP TIMING only, never a supplement/drug.
//   • HeadsUpCard          — IllnessSignalEngine.Result. Confounder-suppressed illness
//                            "heads-up". On-device estimate — not a diagnosis.
//
// DESIGN-SYSTEM ONLY: NoopCard + Palette/DomainTheme tokens, NoopType, Metrics, StatePill.
// No raw hex, no ad-hoc cards. Privacy-forward copy names the user-exported backup exception
// on every sensitive surface. Cards take VALUES not stores, so a slip stays local and the
// engines remain testable + I/O-free. Wave-3 wiring noted at the foot.

// MARK: - Shared chrome

@Composable
private fun PrivacyNote(text: String = uiString(com.noop.R.string.cycle_tracker_privacy)) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.semantics { contentDescription = text },
    ) {
        Icon(
            Icons.Filled.Lock,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(11.dp),
        )
        Text(text, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

/** A quiet tinted chip (fired signal / confounder / overline-adjacent tag). */
@Composable
private fun WhyChip(label: String, tint: Color) {
    Text(
        label,
        style = NoopType.captionNumber,
        color = tint,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

// MARK: - 1. Cycle awareness card (OPT-IN)

/**
 * Cycle phase awareness from the nightly skin-temperature shift. OPT-IN by design — the host
 * renders this only after the user enables cycle awareness (default OFF). Awareness only;
 * never contraception / fertility / diagnosis. Calm Rest indigo world — no valence, no red.
 */
@Composable
fun CycleAwarenessCard(
    result: CyclePhaseEngine.Result,
    onLogPeriod: (() -> Unit)? = null,
    onOpenDetail: (() -> Unit)? = null,
    // #801: symmetric off-control. When supplied, the card shows a "Turn off" action so the user can
    // disable cycle awareness from the SAME place they enabled it (Health), not only from Automations.
    onTurnOff: (() -> Unit)? = null,
) {
    val hue = Palette.restColor
    NoopCard(tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: overline + confidence pill.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Cycle awareness")
                    Text(
                        uiString(R.string.l10n_skin_temp_cards_screen_from_your_nightly_temperature_ff8cca1a),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                StatePill(cycleConfidenceLabel(result.confidence), tone = cycleConfidenceTone(result.confidence))
            }

            // Headline phase + cycle-day RANGE.
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    cyclePhaseTitle(result.phase),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                cycleDayText(result)?.let {
                    Text(it, style = NoopType.bodyNumber, color = Palette.textSecondary)
                }
            }

            Text(result.note, style = NoopType.subhead, color = Palette.textSecondary)

            // Probabilistic next-period WINDOW, never a single date.
            result.nextPeriodWindow?.let { w ->
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = hue, modifier = Modifier.size(16.dp))
                    Text(
                        uiString(R.string.l10n_skin_temp_cards_screen_a_period_is_likely_between_prettyday_bc501b32, prettyDay(w.earliestDay)) +
                            "${prettyDay(w.latestDay)} (a window, not a fixed date).",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }

            // Actions.
            if (onLogPeriod != null || onOpenDetail != null || onTurnOff != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    if (onLogPeriod != null) {
                        OutlinedButton(onClick = onLogPeriod) { Text(uiString(R.string.l10n_skin_temp_cards_screen_log_period_start_c97241d0)) }
                    }
                    if (onOpenDetail != null) {
                        OutlinedButton(
                            onClick = onOpenDetail,
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        ) { Text(uiString(R.string.l10n_skin_temp_cards_screen_view_detail_27af4b67)) }
                    }
                    // #801: symmetric off-control (turn cycle awareness off where it was turned on).
                    if (onTurnOff != null) {
                        OutlinedButton(onClick = onTurnOff) { Text(uiString(R.string.l10n_skin_temp_cards_screen_turn_off_8807c2b3)) }
                    }
                }
            }

            HorizontalDivider(color = Palette.hairline)

            // Standing awareness-only legal line (verbatim from the engine) + privacy promise.
            Text(CyclePhaseEngine.awarenessLine, style = NoopType.footnote, color = Palette.textTertiary)
            PrivacyNote()
        }
    }
}

/**
 * Shown in place of the card when the user has NOT opted in. A single calm opt-in card restating
 * the privacy promise at the point of consent (manual-first; default OFF).
 */
@Composable
fun CycleAwarenessOptInCard(onEnable: () -> Unit) {
    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Thermostat, contentDescription = null, tint = Palette.restColor, modifier = Modifier.size(18.dp))
                Text(uiString(R.string.l10n_skin_temp_cards_screen_cycle_awareness_ffb94783), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_skin_temp_cards_screen_noop_can_read_a_coarse_menstrual_c79e4b85) +
                    "entirely on your device. It is awareness only: not contraception, not a fertility " +
                    "predictor, not a medical service.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            PrivacyNote()
            OutlinedButton(onClick = onEnable) { Text(uiString(R.string.l10n_skin_temp_cards_screen_turn_on_cycle_awareness_7c2d328f)) }
        }
    }
}

// MARK: - 2. Body Clock card

/**
 * Estimated body-clock phase + an optional jet-lag / shift plan. LIGHT + SLEEP TIMING only —
 * never a supplement. Behavioural awareness, approximate.
 */
@Composable
fun BodyClockCard(
    estimate: CircadianEngine.PhaseEstimate,
    plan: CircadianEngine.JetLagPlan? = null,
    onOpenPlanner: (() -> Unit)? = null,
) {
    val hue = Palette.restColor
    NoopCard(tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Body clock")
                    Text(uiString(R.string.l10n_skin_temp_cards_screen_light_sleep_timing_only_df2a1552), style = NoopType.footnote, color = Palette.textTertiary)
                }
                StatePill(bodyClockConfidenceLabel(estimate.confidence), tone = bodyClockConfidenceTone(estimate.confidence))
            }

            Text(bodyClockOffsetTitle(estimate), style = NoopType.title2, color = Palette.textPrimary)

            Text(estimate.note, style = NoopType.subhead, color = Palette.textSecondary)

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.NightsStay, contentDescription = null, tint = hue, modifier = Modifier.size(14.dp))
                Text(
                    uiString(R.string.l10n_skin_temp_cards_screen_estimated_body_clock_low_around_clockstring_fb0f0790, clockString(estimate.tempMinHour)),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }

            val firstDay = plan?.days?.firstOrNull()
            if (plan != null && plan.direction != CircadianEngine.ShiftDirection.NONE && firstDay != null) {
                HorizontalDivider(color = Palette.hairline)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline("Plan · ${plan.estimatedDays}-day shift")
                    Text(
                        uiString(R.string.l10n_skin_temp_cards_screen_day_1_bright_light_clockstring_firstday_43b5fe87, clockString(firstDay.brightLightStartHour)) +
                            "${clockString(firstDay.brightLightEndHour)}, lights-out around " +
                            "${clockString(firstDay.targetSleepHour)}.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                    Text(plan.note, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (onOpenPlanner != null) {
                OutlinedButton(
                    onClick = onOpenPlanner,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) { Text(if (plan == null) "Plan a trip or shift" else "View the full plan") }
            }
        }
    }
}

// MARK: - 3. Heads-Up card (illness early-warning, confounder-suppressed)

/**
 * The confounder-suppressed illness "heads-up". Renders the engine's already-decided level +
 * copy; the host only mounts it when the engine returns a non-quiet level. On-device estimate
 * — not a diagnosis. Mirrors the existing amber alert treatment.
 */
@Composable
fun HeadsUpCard(
    result: IllnessSignalEngine.Result,
    // Optional parallel Mahalanobis distance (IllnessDistance), computed on the SAME z-vector. It does
    // NOT gate this card (the engine's level already did); when the level is raised and a distance is
    // present we append a subtle "Confidence" line so the user can gauge how strong the signal is.
    distance: IllnessDistance.Result? = null,
) {
    val hue = headsUpHue(result.level)
    NoopCard(padding = 14.dp, tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(hue.copy(alpha = 0.16f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(headsUpGlyph(result.level), contentDescription = null, tint = hue, modifier = Modifier.size(15.dp))
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(headsUpTitle(result.level), style = NoopType.headline, color = Palette.textPrimary)
                    Text(result.copy, style = NoopType.subhead, color = Palette.textSecondary)
                }
            }

            // The visible "why": which signals fired.
            if (result.firedSignals.isNotEmpty()) {
                WhyRow("Signals up", result.firedSignals, hue)
            }
            // ...and what was ruled out (the differentiating part vs a black-box warning).
            if (result.suppressedBy.isNotEmpty()) {
                WhyRow("Explained by", result.suppressedBy, Palette.textTertiary)
            }
            // Optional confidence read from the parallel Mahalanobis distance, only when the level is
            // raised. Subtle by design: it augments, never gates (the engine already decided to raise).
            headsUpConfidenceLine(result.level, distance)?.let { line ->
                Text(line, style = NoopType.caption, color = Palette.textTertiary)
            }
        }
    }
}

/**
 * A subtle confidence read from the parallel Mahalanobis distance, surfaced ONLY on the RAISED state (and
 * when a distance is present). null otherwise. The already-unwell state is driven purely by the user's own
 * log and can have a near-zero distance (0-1 present features), giving a misleading "Confidence: slight
 * (distance 0.0)", so it's excluded. The raised path always has >= 2 present features, so its distance is
 * meaningful. The band mirrors iOS exactly. Augment-only, never gates.
 */
private fun headsUpConfidenceLine(
    level: IllnessSignalEngine.Level,
    distance: IllnessDistance.Result?,
): String? {
    if (level != IllnessSignalEngine.Level.RAISED) return null
    val d = distance ?: return null
    return "Confidence: ${illnessConfidenceBand(d.distance)} (distance ${illnessConfidenceFormatted(d.distance)})"
}

/**
 * Maps the parallel Mahalanobis distance to a plain confidence word. Presentation-only: NEVER decides
 * whether the Heads-Up card shows (the engine's level already did). Bands: >= 3.5 strong, >= 2.5
 * moderate, else slight. Identical to the Swift twin (IllnessConfidence.band).
 */
private fun illnessConfidenceBand(distance: Double): String = when {
    distance >= 3.5 -> "strong"
    distance >= 2.5 -> "moderate"
    else -> "slight"
}

/** One-decimal display value for the distance, locale-independent. Mirrors iOS String(format: "%.1f"). */
private fun illnessConfidenceFormatted(distance: Double): String =
    String.format(java.util.Locale.US, "%.1f", distance)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WhyRow(label: String, values: List<String>, tint: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics {
            contentDescription = uiString(R.string.skin_temp_reason_summary, label, values.joinToString(", "))
        },
    ) {
        Overline(label)
        // Chips wrap to the next line rather than overflowing the card on a long confounder list.
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            values.forEach { WhyChip(it, tint) }
        }
    }
}

// MARK: - Derived copy / presentation (mirror the Swift card exactly)

private fun cyclePhaseTitle(phase: CyclePhaseEngine.Phase): String = when (phase) {
    CyclePhaseEngine.Phase.FOLLICULAR -> uiString(R.string.cycle_phase_follicular)
    CyclePhaseEngine.Phase.PERI_OVULATORY -> uiString(R.string.cycle_phase_mid_cycle)
    CyclePhaseEngine.Phase.LUTEAL -> uiString(R.string.cycle_phase_luteal)
    CyclePhaseEngine.Phase.UNKNOWN -> uiString(R.string.cycle_phase_unclear)
    CyclePhaseEngine.Phase.LEARNING -> uiString(R.string.cycle_phase_learning)
}

/** "~day 18–22" — always a RANGE, never a single point. */
private fun cycleDayText(r: CyclePhaseEngine.Result): String? {
    val lo = r.cycleDayLow ?: return null
    val hi = r.cycleDayHigh ?: return null
    // Localized (uiString resolves via the app's resources — safe outside composition). Was a hardcoded
    // interpolation, so the label shipped English regardless of locale; the audit misses it because this
    // isn't a @Composable. Twin of the iOS `· ~day %lld` / `· ~day %lld–%lld` catalog entries.
    return if (lo == hi) uiString(R.string.cycle_day_single, lo) else uiString(R.string.cycle_day_range, lo, hi)
}

private fun cycleConfidenceLabel(c: CyclePhaseEngine.Confidence): String = when (c) {
    CyclePhaseEngine.Confidence.LEARNING -> "Learning"
    CyclePhaseEngine.Confidence.BUILDING -> "Building"
    CyclePhaseEngine.Confidence.SOLID -> "Solid"
}

private fun cycleConfidenceTone(c: CyclePhaseEngine.Confidence): StrandTone = when (c) {
    CyclePhaseEngine.Confidence.LEARNING -> StrandTone.Neutral
    CyclePhaseEngine.Confidence.BUILDING -> StrandTone.Accent
    CyclePhaseEngine.Confidence.SOLID -> StrandTone.Accent
}

/** "About 25 min later than your schedule" — a plain, skimmable headline. */
private fun bodyClockOffsetTitle(e: CircadianEngine.PhaseEstimate): String {
    if (e.confidence == CircadianEngine.PhaseConfidence.UNREADABLE) return "Hard to read right now"
    val mins = abs(e.offsetVsScheduleMinutes).roundToInt()
    if (mins <= 20) return "About in sync with your schedule"
    val dir = if (e.offsetVsScheduleMinutes > 0) "later" else "earlier"
    return "About $mins min $dir than your schedule"
}

private fun bodyClockConfidenceLabel(c: CircadianEngine.PhaseConfidence): String = when (c) {
    CircadianEngine.PhaseConfidence.UNREADABLE -> "Calibrating"
    CircadianEngine.PhaseConfidence.WIDE -> "Building"
    CircadianEngine.PhaseConfidence.SOLID -> "Solid"
}

private fun bodyClockConfidenceTone(c: CircadianEngine.PhaseConfidence): StrandTone = when (c) {
    CircadianEngine.PhaseConfidence.UNREADABLE -> StrandTone.Neutral
    CircadianEngine.PhaseConfidence.WIDE -> StrandTone.Accent
    CircadianEngine.PhaseConfidence.SOLID -> StrandTone.Accent
}

/** Card hue follows the level: raised / already-unwell = amber warning (matches the shipped
 *  banner); suppressed / mild = a calmer neutral so it never scares. */
private fun headsUpHue(level: IllnessSignalEngine.Level): Color = when (level) {
    IllnessSignalEngine.Level.RAISED, IllnessSignalEngine.Level.ALREADY_UNWELL -> Palette.statusWarning
    else -> Palette.restColor
}

private fun headsUpGlyph(level: IllnessSignalEngine.Level): ImageVector = when (level) {
    IllnessSignalEngine.Level.RAISED -> Icons.Filled.Warning
    IllnessSignalEngine.Level.ALREADY_UNWELL -> Icons.Filled.NightsStay
    IllnessSignalEngine.Level.SUPPRESSED -> Icons.Filled.Info
    IllnessSignalEngine.Level.MILD -> Icons.Filled.MonitorHeart
    IllnessSignalEngine.Level.QUIET -> Icons.Filled.CheckCircle
}

private fun headsUpTitle(level: IllnessSignalEngine.Level): String = when (level) {
    IllnessSignalEngine.Level.RAISED -> "Heads-up"
    IllnessSignalEngine.Level.ALREADY_UNWELL -> "Rest up"
    IllnessSignalEngine.Level.SUPPRESSED -> "Probably not illness"
    IllnessSignalEngine.Level.MILD -> "A few signals are up"
    IllnessSignalEngine.Level.QUIET -> "Nothing notable"
}

// MARK: - Formatting helpers (locale-free, matching the engine's own helpers)

/** Render a fractional clock hour as "HH:MM". */
private fun clockString(hour: Double): String {
    var h = hour % 24.0
    if (h < 0) h += 24.0
    var hh = h.toInt()
    var mm = ((h - hh) * 60.0).roundToInt()
    if (mm == 60) { mm = 0; hh = (hh + 1) % 24 }
    return "%02d:%02d".format(hh, mm)
}

/** "12 Jun" from a "yyyy-MM-dd" key (display only; the engine math stays UTC). */
private fun prettyDay(key: String): String {
    val parts = key.split("-")
    if (parts.size != 3) return key
    val m = parts[1].toIntOrNull() ?: return key
    val d = parts[2].toIntOrNull() ?: return key
    if (m !in 1..12) return key
    val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    return "$d ${months[m - 1]}"
}
