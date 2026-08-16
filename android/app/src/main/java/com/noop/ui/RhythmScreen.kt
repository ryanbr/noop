package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.noop.analytics.RhythmConfidence
import com.noop.analytics.RhythmEmptyState
import com.noop.analytics.RhythmRegularity
import com.noop.analytics.RhythmScreener
import kotlin.math.min

/*
 * RhythmScreen.kt — EXPERIMENTAL beat-to-beat regularity VISUALIZATION (v5 "Rhythm").
 *
 * Faithful Compose twin of Strand/Screens/RhythmView.swift.
 * Spec: docs/superpowers/specs/2026-06-19-v5-rhythm-screening-design.md (§6, §9, §11).
 *
 * WHAT THIS SHIPS (and deliberately does NOT):
 *   The §11 "visualization-only" path: a Poincaré scatter of the night's R-R cloud plus the
 *   DESCRIPTIVE RhythmScreener stats (SD1/SD2, normalised RMSSD, ectopic fraction) and a
 *   NEUTRAL regularity label ("looked steady" / "some variation" / "varied more than usual").
 *   NO clinical verdict, NO "see a clinician" call-to-action, NO disease name, NO red/alarm
 *   styling, NO probability-of-condition. The screening heads-up is HELD per §11.
 *
 * SELF-CONTAINED: the screen takes the engine results (NightRhythmSummary + per-window
 * WindowResults) as params. It does NOT touch AppViewModel. The consent record is a local
 * SharedPreferences flag (mirroring TermsGate), so the feature is OFF by default and only
 * shows after the user reads the experimental, non-diagnostic disclaimer and ticks the
 * un-pre-checked box. Central wiring (Wave 3) mounts it as an experimental item under
 * Settings / Health behind this gate.
 */

// ── Consent record (local, version-stamped — mirrors Terms) ──────────────────────────────

/**
 * On-device consent record for the experimental Rhythm visualization. Mirrors the [Terms]
 * clickwrap: a CURRENT version is stored once the user accepts; bumping it on a material
 * change to the disclaimer re-prompts. Nothing shows until accepted. Default OFF. Mirrors
 * macOS `RhythmConsent`.
 */
object RhythmConsent {
    /** Bump on a material change to the experimental/non-diagnostic wording to re-prompt. */
    const val CURRENT_VERSION = "1.0"

    /** SharedPreferences key holding the accepted consent version ("" = never accepted). */
    const val KEY_ACCEPTED_VERSION = "noop.rhythmConsentVersion"

    /** SharedPreferences key for the feature on/off flag (default OFF). */
    const val KEY_ENABLED = "noop.rhythmScreening"

    fun acceptedVersion(context: Context): String =
        NoopPrefs.of(context).getString(KEY_ACCEPTED_VERSION, "") ?: ""

    fun isEnabled(context: Context): Boolean =
        NoopPrefs.of(context).getBoolean(KEY_ENABLED, false)

    /** True when consent is recorded for the current version AND the feature is on. */
    fun consentGiven(context: Context): Boolean =
        isEnabled(context) && acceptedVersion(context) == CURRENT_VERSION

    /** Record acceptance + turn the feature on, atomically. */
    fun accept(context: Context) {
        NoopPrefs.of(context).edit()
            .putString(KEY_ACCEPTED_VERSION, CURRENT_VERSION)
            .putBoolean(KEY_ENABLED, true)
            .apply()
    }

    /** The points the user must read before turning the feature on (spec §9). No condition
     *  name, no diagnosis, no "consider a clinician" verdict. Kept identical to macOS. */
    val points: List<Pair<String, String>> = listOf(
        "Experimental, and not a medical device" to
            "This is an experimental wellness visualization of your beat-to-beat timing. It is NOT an ECG, and it cannot diagnose, detect, or rule out any heart condition.",
        "It is a picture, not a verdict" to
            "It shows the shape of your heartbeat timing and a plain-language description of how steady it looked. It does not tell you whether anything is right or wrong.",
        "Variation is normal and often benign" to
            "Beat-to-beat timing varies for many ordinary reasons: breathing, movement, an imperfect optical reading, or the occasional extra or skipped beat that most healthy people have.",
        "It is not a substitute for a professional" to
            "If you feel unwell or are worried about your heart, contact a qualified professional; in an emergency, your local emergency service. Do not rely on NOOP.",
        "Everything stays on your device" to
            "All of this is computed on your own device from data you already have. No heartbeat data leaves it.",
    )
}

// ── Consent gate (clickwrap — mirrors TermsGateScreen) ───────────────────────────────────

/**
 * Feature-specific consent gate, shown the FIRST time the user enables the Rhythm
 * visualization (and again if [RhythmConsent.CURRENT_VERSION] changes). Must tick the
 * un-pre-checked box and tap to proceed; acceptance is persisted by [onAccept]. Backing out
 * via [onCancel] leaves the feature OFF. Mirrors macOS `RhythmConsentGate`.
 */
@Composable
fun RhythmConsentGate(
    onAccept: () -> Unit,
    onCancel: (() -> Unit)? = null,
) {
    var checked by remember { mutableStateOf(false) }
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
            Spacer(Modifier.height(40.dp))
            Text(uiString(R.string.l10n_rhythm_screen_before_you_turn_on_rhythm_e85a832c), style = NoopType.title1, color = Palette.textPrimary)
            Spacer(Modifier.height(4.dp))
            Text(
                uiString(R.string.l10n_rhythm_screen_an_experimental_picture_of_your_beat_966289c6),
                style = NoopType.subhead, color = Palette.textSecondary,
            )
            Spacer(Modifier.height(20.dp))

            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                RhythmConsent.points.forEach { (head, body) ->
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(head, style = NoopType.headline, color = Palette.textPrimary)
                        Text(body, style = NoopType.footnote, color = Palette.textSecondary)
                    }
                }
                Text(
                    uiString(R.string.l10n_rhythm_screen_this_is_a_wellness_visualization_not_3409b935),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }

            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.Top) {
                Checkbox(
                    checked = checked,
                    onCheckedChange = { checked = it },
                    colors = CheckboxDefaults.colors(checkedColor = Palette.accent),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    uiString(R.string.l10n_rhythm_screen_i_understand_this_is_an_experimental_3dab06e6),
                    style = NoopType.footnote, color = Palette.textPrimary,
                    modifier = Modifier.padding(top = 14.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = onAccept,
                enabled = checked,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.gold,
                    contentColor = Palette.goldDeepText,
                ),
            ) {
                Text(uiString(R.string.l10n_rhythm_screen_turn_on_rhythm_2275168c), style = NoopType.body)
            }
            if (onCancel != null) {
                TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                    Text(uiString(R.string.l10n_rhythm_screen_not_now_e4571490), style = NoopType.body, color = Palette.gold)
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

// ── The visualization screen ─────────────────────────────────────────────────────────────

/**
 * The experimental Rhythm visualization. Self-contained: takes the engine outputs as params
 * (the night summary + the per-window results, whose poincaré clouds + stats it renders).
 * Shows the consent gate first if consent isn't recorded for the current version. NEVER
 * touches AppViewModel.
 */
@Composable
fun RhythmScreen(
    night: RhythmScreener.NightRhythmSummary?,
    windows: List<RhythmScreener.WindowResult>,
    emptyReason: RhythmEmptyState = RhythmEmptyState.GATHERING_DATA,
    onClose: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    // Local consent record — feature OFF until the gate is passed. SharedPreferences isn't
    // reactive, so we hold the consent flag in remembered state seeded from prefs.
    var consentGiven by remember { mutableStateOf(RhythmConsent.consentGiven(context)) }

    if (!consentGiven) {
        RhythmConsentGate(
            onAccept = {
                RhythmConsent.accept(context)
                consentGiven = true
            },
            onCancel = onClose,
        )
        return
    }

    RhythmVisualization(night = night, windows = windows, emptyReason = emptyReason, onClose = onClose)
}

@Composable
private fun RhythmVisualization(
    night: RhythmScreener.NightRhythmSummary?,
    windows: List<RhythmScreener.WindowResult>,
    emptyReason: RhythmEmptyState,
    onClose: (() -> Unit)?,
) {
    // The headline window: prefer the most-varied readable window so the "what a diffuse
    // cloud looks like" example is the informative one; fall back to the first readable.
    val readable = windows.filter { it.label != RhythmRegularity.UNREADABLE }
    val headline = readable.firstOrNull { it.label == RhythmRegularity.VARIED }
        ?: readable.firstOrNull { it.label == RhythmRegularity.OCCASIONAL_ECTOPY }
        ?: readable.firstOrNull()
    val allPoints = windows.flatMap { it.poincare }

    // PERF (#707): lazy scaffold — each card is its own `item { }` (in the conditional branches too) so
    // only on-screen cards compose + are accessibility-walked, with the LazyColumn's `spacedBy(20.dp)`
    // reproducing the eager column's inter-card spacing exactly. The Poincaré PlotCard is the heavy one.
    LazyScreenScaffold(
        title = uiString(R.string.l10n_rhythm_screen_rhythm_c715bb28),
        subtitle = "An experimental picture of your beat-to-beat timing",
        trailing = if (onClose != null) {
            {
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_rhythm_screen_close_rhythm_e0239fa8), tint = Palette.textTertiary)
                }
            }
        } else {
            null
        },
    ) {
        item { SourceBadge("Experimental", tint = Palette.restColor) }

        if (allPoints.isEmpty()) {
            item { RhythmEmptyStateNote(emptyReason) }
        } else {
            item { SummaryCard(night = night, headline = headline) }
            item { PlotCard(points = allPoints) }
            item { StatsCard(headline = headline) }
            // #1298: the clinician-share button lives here on iOS, but Android's Rhythm screen is still
            // fed null/empty (no capture pipeline yet), so a Share action would be unreachable. The pure
            // RhythmExport builder is in place; wire the button when the Android rhythm loader lands.
        }

        item { MethodologyCard() }
        item { RhythmDisclaimerNote() }
    }
}

/**
 * #1360: a TRUTHFUL empty state. When every window was refused for a *capture* reason the device can
 * never satisfy — its beats arrive banked, or it records no stillness signal at all — say so, instead of
 * the "try again after a settled night" copy that is a lie when tomorrow is structurally identical.
 * GATHERING_DATA/NONE keep the original "no clear reading yet" wording (a genuine try-again). The bodies
 * are English literals matching the screen's existing empty-state body (localized copy follows when the
 * Android rhythm loader lands — the screen is not yet fed real windows). Twin of the Swift `emptyState`.
 */
@Composable
private fun RhythmEmptyStateNote(reason: RhythmEmptyState) {
    when (reason) {
        RhythmEmptyState.DEVICE_BANKS_BEATS -> DataPendingNote(
            title = uiString(R.string.l10n_rhythm_screen_this_device_can_t_support_a_bb41aada),
            body = "Rhythm needs beat-to-beat timing measured one beat at a time. Your device stores its heartbeats in batches, so the exact spacing between them isn't recoverable. Nothing is wrong with your night.",
        )
        RhythmEmptyState.DEVICE_NO_MOTION -> DataPendingNote(
            title = uiString(R.string.l10n_rhythm_screen_this_device_can_t_support_a_bb41aada),
            body = "Rhythm reads only during still, resting windows, and this device doesn't record the stillness signal it needs to find them. Nothing is wrong with your night.",
        )
        RhythmEmptyState.NONE, RhythmEmptyState.GATHERING_DATA -> DataPendingNote(
            title = uiString(R.string.l10n_rhythm_screen_no_clear_reading_yet_92f40443),
            body = "Rhythm only looks during quiet, still, resting windows, so it needs a calm night's worth of steady beats. Once there's a clean window, the scatter and its description show here.",
        )
    }
}

// ── Summary card — the neutral, plain-language headline (NO verdict) ──────────────────────

@Composable
private fun SummaryCard(
    night: RhythmScreener.NightRhythmSummary?,
    headline: RhythmScreener.WindowResult?,
) {
    val label = night?.overall ?: headline?.label ?: RhythmRegularity.UNREADABLE
    NoopCard(padding = 18.dp, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline("Last night", modifier = Modifier.weight(1f))
                ConfidencePill(headline = headline, readable = night?.readableWindows)
            }
            StatusChip(label)
            Text(headlineDetail(label), style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

/**
 * OpenStrap-style status chip: a compact pill with an icon + the neutral regularity label. Modelled on
 * [SourceBadge], but in the calm Rest-blue palette — NEVER a warn/alarm colour (§11 forbids alarm styling;
 * OpenStrap tints its chip amber, NOOP does not). States differ by icon + wording only; the label reuses
 * the short [chipLabel]; the sentence [headlineDetail] reads below. Non-diagnostic. Twin of Swift `statusChip`.
 */
@Composable
private fun StatusChip(label: RhythmRegularity) {
    val shape = RoundedCornerShape(50)
    // Calm, non-alarm icons: a check for steady, a heart for any variation (never a warning triangle),
    // an info glyph when unread. No red, no alarm (§11).
    val icon = when (label) {
        RhythmRegularity.STEADY -> Icons.Filled.CheckCircle
        RhythmRegularity.OCCASIONAL_ECTOPY, RhythmRegularity.VARIED -> Icons.Filled.Favorite
        RhythmRegularity.UNREADABLE -> Icons.Filled.Info
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(shape)
            .background(Palette.restColor.copy(alpha = 0.14f))
            .border(1.dp, Palette.restColor.copy(alpha = 0.30f), shape)
            .padding(horizontal = Metrics.space12, vertical = 7.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Palette.restBright, modifier = Modifier.size(16.dp))
        Text(chipLabel(label), style = NoopType.subhead, color = Palette.restBright)
    }
}

/**
 * Honest confidence chip (mirrors ScoreStatePill) — so a thin night reads truthfully. Drawn
 * via [StatePill] in the calm, non-alarm tones (gold solid / blue building / slate calibrating).
 */
@Composable
private fun ConfidencePill(headline: RhythmScreener.WindowResult?, readable: Int?) {
    when (headline?.confidence ?: RhythmConfidence.CALIBRATING) {
        RhythmConfidence.SOLID ->
            StatePill("Solid", tone = StrandTone.Accent)
        RhythmConfidence.BUILDING ->
            StatePill(
                if ((readable ?: 0) <= 1) "Building · 1 window" else "Building",
                tone = StrandTone.Warning,
            )
        RhythmConfidence.CALIBRATING ->
            StatePill("Calibrating", tone = StrandTone.Neutral)
    }
}

// ── Plot card — the Poincaré scatter + the "comet vs cloud" reading note ──────────────────

@Composable
private fun PlotCard(points: List<RhythmScreener.PoincarePoint>) {
    NoopCard(padding = 18.dp, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline("Beat-to-beat scatter")
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.chartHeight + 24.dp)
                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(Metrics.cornerSm)),
            ) {
                ScenicHeroBackground(
                    modifier = Modifier.fillMaxSize(),
                    domain = DomainTheme.Rest,
                    starCount = 36,
                )
                PoincarePlot(
                    points = points,
                    modifier = Modifier.fillMaxSize().padding(8.dp),
                )
            }
            Text(
                uiString(R.string.l10n_rhythm_screen_each_dot_pairs_one_heartbeat_interval_07a1502c),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

/**
 * The Poincaré scatter: successive (NN[i], NN[i+1]) pairs. A steady rhythm draws a tight
 * elongated comet along the diagonal; a more variable one draws a rounder, diffuse cloud.
 * Purely descriptive, drawn in the calm Rest-blue world (never red). Decorative for
 * accessibility — the numbers + label carry the meaning.
 */
@Composable
private fun PoincarePlot(
    points: List<RhythmScreener.PoincarePoint>,
    modifier: Modifier = Modifier,
) {
    val tint = Palette.restBright
    val axis = Palette.hairlineStrong
    // Fixed physiological bounds (ms) so the same rhythm reads at the same scale night-to-
    // night — 300…1500 ms covers ~40…200 bpm, the readable resting band.
    val lo = 300.0
    val hi = 1500.0
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .aspectRatio(1f, matchHeightConstraintsFirst = true)
                .clearAndSetSemantics {},
        ) {
            val s = min(size.width, size.height)
            val inset = 8f
            val plot = s - inset * 2

            fun map(v: Double): Float {
                val clamped = v.coerceIn(lo, hi)
                val frac = (clamped - lo) / (hi - lo)
                return inset + frac.toFloat() * plot
            }

            // Identity diagonal (NN[i] == NN[i+1]) — the line a perfectly metronomic beat
            // would sit on. Faint hairline, reference only.
            drawLine(
                color = axis,
                start = Offset(inset, s - inset),
                end = Offset(s - inset, inset),
                strokeWidth = 1f,
            )

            // The point cloud — small, semi-transparent dots so density reads as a cloud.
            val r = 1.6f
            points.forEach { p ->
                val x = map(p.x)
                // Canvas y grows downward; invert so a higher NN[i+1] sits higher.
                val y = s - map(p.y)
                drawCircle(color = tint.copy(alpha = 0.55f), radius = r, center = Offset(x, y))
            }
        }
    }
}

// ── Stats card — the descriptive numbers (equal-height tiles) ─────────────────────────────

@Composable
private fun StatsCard(headline: RhythmScreener.WindowResult?) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = uiString(R.string.l10n_rhythm_screen_the_numbers_7b3cbf64), overline = "Descriptive stats")
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_short_axis_66a0b7bf), value = fmt(headline?.sd1, "%.0f"),
                caption = "SD1 · ms", accent = Palette.restBright,
                modifier = Modifier.weight(1f),
            )
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_long_axis_02300830), value = fmt(headline?.sd2, "%.0f"),
                caption = "SD2 · ms", accent = Palette.restColor,
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_cloud_shape_2a745ff0), value = fmt(headline?.sd1sd2, "%.2f"),
                caption = "SD1:SD2 ratio", accent = Palette.metricCyan,
                modifier = Modifier.weight(1f),
            )
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_beat_to_beat_34a3a652), value = percent(headline?.normRmssd),
                caption = "variation index", accent = Palette.metricPurple,
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_extra_skipped_4a153489), value = percent(headline?.ectopicFraction),
                caption = "of beats", accent = Palette.restColor,
                modifier = Modifier.weight(1f),
            )
            StatTile(
                label = uiString(R.string.l10n_rhythm_screen_beats_read_15da45e3), value = headline?.nBeats?.toString() ?: "—",
                caption = "clean intervals", accent = Palette.textSecondary,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

// ── Methodology + the permanent, non-dismissible disclaimer ───────────────────────────────

@Composable
private fun MethodologyCard() {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline("How this is measured")
            Text(
                uiString(R.string.l10n_rhythm_screen_during_quiet_still_resting_windows_noop_45488969),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

/**
 * The standing experimental + non-diagnostic note (spec §6 permanent block, §7 wording).
 * Calm titanium styling — never red. Reused at the foot of every result state.
 */
@Composable
private fun RhythmDisclaimerNote() {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.Info,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
            Text(
                uiString(R.string.l10n_rhythm_screen_experimental_wellness_visualization_not_a_diagnosis_0745e8b7),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

// ── Copy mapping (neutral, non-clinical — NO verdict, NO condition name) ──────────────────

/** SHORT neutral status word inside the status chip (compact, so the chip reads like OpenStrap's; the
 *  sentence-length [headlineDetail] carries the description below). Twin of Swift `chipLabel`. */
private fun chipLabel(label: RhythmRegularity): String = when (label) {
    RhythmRegularity.STEADY -> "Steady"
    RhythmRegularity.OCCASIONAL_ECTOPY -> "Some variation"
    RhythmRegularity.VARIED -> "More varied"
    RhythmRegularity.UNREADABLE -> "No clear reading"
}

private fun headlineDetail(label: RhythmRegularity): String = when (label) {
    RhythmRegularity.STEADY ->
        "Across the quiet windows we could read, your beat-to-beat timing held a tight, even shape."
    RhythmRegularity.OCCASIONAL_ECTOPY ->
        "Mostly steady, with a few isolated extra or skipped beats. Very common and usually nothing."
    RhythmRegularity.VARIED ->
        "The scatter looked rounder and more spread out than a tight, steady beat. This has many ordinary causes and is not a diagnosis."
    RhythmRegularity.UNREADABLE ->
        "There wasn't a calm, still window clean enough to describe. Try again after a settled night."
}

// ── Formatting ────────────────────────────────────────────────────────────────────────────

private fun fmt(value: Double?, format: String): String =
    if (value == null) "—" else String.format(format, value)

/** A 0…1 fraction rendered as a whole-number percent (normalised RMSSD / ectopic fraction). */
private fun percent(value: Double?): String =
    if (value == null) "—" else String.format("%.0f%%", value * 100)
