package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Context
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

// MARK: - ScoringGuideScreen (ported from Strand/Screens/ScoringGuideView.swift)
//
// "How your scores work" — the one honest explainer for NOOP's three daily scores
// (Charge, Effort, Rest) and the confidence labels. Presented as a sheet, mirroring
// WhatsNewSheet's presentation + dismiss + layout idiom: a fixed header with a close
// button, a scrollable column of cards, and a "Got it" footer. Reachable from
// Settings → About, the ⓘ on each Today score, and the one-time first-run card.
//
// All copy here is the single approved source of truth, shared verbatim across
// macOS / iOS / Android. Design Reset: each score section is accented with the SAME Reset
// score token its Today hero ring draws with (Charge = green, Effort = blue accent, Rest =
// slate) — no gold / strain / sleep-purple — so a glance maps a section to its Today ring.

/**
 * The three score sections the guide can deep-link to. Case names mirror the macOS/iOS
 * `ScoreSection` exactly (charge/effort/rest) so the three platforms stay in lockstep; the
 * Android enum keeps Kotlin's UPPER_SNAKE convention. Used as the scroll anchor key by the
 * ⓘ affordances on the Today screen so each opens at its own score.
 */
enum class ScoreSection {
    CHARGE,
    EFFORT,
    REST;

    /** The accent each section uses — the SAME Reset score token its Today hero ring draws with, so a
     *  section reads as that score's colour. No gold / strain / sleep-purple: Charge = chargeColor green,
     *  Effort = effortColor blue accent, Rest = restColor slate (Design Reset, 2026-06-23). */
    val accent: Color
        get() = when (this) {
            CHARGE -> Palette.chargeColor   // Charge hero ring — green
            EFFORT -> Palette.effortColor   // Effort hero ring — blue accent
            REST -> Palette.restColor       // Rest hero ring — slate
        }

    /** The header glyph (heart/spark · flame · moon). */
    val icon: ImageVector
        get() = when (this) {
            CHARGE -> Icons.Filled.Favorite
            EFFORT -> Icons.Filled.Whatshot
            REST -> Icons.Filled.Bedtime
        }

    val label: String
        get() = when (this) {
            CHARGE -> "Charge"
            EFFORT -> "Effort"
            REST -> "Rest"
        }

    /** A representative sample fraction (0–1) for the section's illustrative gauge — a
     *  "what a strong day looks like" reading, purely decorative in the guide. */
    val sampleFraction: Double
        get() = when (this) {
            CHARGE -> 0.82
            EFFORT -> 0.64
            REST -> 0.88
        }

    /** The number shown inside the sample gauge (the 0–100 score the fraction maps to). */
    val sampleNumber: String
        get() = "${(sampleFraction * 100).roundToInt()}"
}

/**
 * One-time first-run flag for the Today "New here?" scoring-guide card. A tiny self-contained
 * plain-prefs store, so the card's seen-state lives next to the screen that owns it and never
 * touches the unrelated onboarding/changelog prefs.
 */
object ScoringGuidePrefs {
    private const val FILE = "noop_scoring_guide_prefs"
    private const val KEY_CARD_SEEN = "scoringGuideCardSeen"

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Whether the one-time first-run card has been seen/dismissed (default false = show it once). */
    fun cardSeen(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_CARD_SEEN, false)

    /** Set once the user opens the guide from the card OR dismisses it — either way it never returns. */
    fun setCardSeen(ctx: Context) =
        prefs(ctx).edit().putBoolean(KEY_CARD_SEEN, true).apply()
}

/**
 * The scoring-guide sheet. [initialSection], when set, scrolls to and briefly highlights that
 * score's card on appear — the deep-link used by the Today ⓘ affordances. [onClose] dismisses.
 */
@Composable
fun ScoringGuideScreen(
    onClose: () -> Unit,
    initialSection: ScoreSection? = null,
) {
    val scroll = rememberScrollState()
    // Section → its Y offset within the scroll column, captured as each card lays out, so the
    // deep-link can animate-scroll to it. Plain scroll positions (not the experimental
    // BringIntoViewRequester) keep this on stable foundation APIs.
    val anchors = remember { mutableStateMapOf<ScoreSection, Int>() }
    var highlighted by remember { mutableStateOf<ScoreSection?>(null) }
    // Root-space top of the scroll viewport, captured once at first layout (scroll == 0) so each
    // card's captured root-Y can be converted to a content offset for animateScrollTo.
    var viewportTop by remember { mutableStateOf<Int?>(null) }

    // Deep-link: once the target card has measured, scroll to it and pulse its accent ring, then
    // fade it. Keyed on the anchor becoming available so it fires after layout, not before.
    val targetY = initialSection?.let { anchors[it] }
    LaunchedEffect(initialSection, targetY) {
        val section = initialSection ?: return@LaunchedEffect
        val y = anchors[section] ?: return@LaunchedEffect
        delay(50)
        scroll.animateScrollTo((y - (viewportTop ?: 0)).coerceAtLeast(0))
        highlighted = section
        delay(1600)
        if (highlighted == section) highlighted = null
    }

    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Design Reset: a FLAT opaque WHOOP-grey title surface — no scenic hero, no bloom, no
            // domain tint. The header reads as a clean raised card edge, matching the Today look.
            Box(modifier = Modifier.background(Palette.surfaceRaised)) {
                Header(onClose = onClose)
            }
            Hairline()

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .onGloballyPositioned {
                        if (viewportTop == null) viewportTop = it.positionInRoot().y.toInt()
                    }
                    .verticalScroll(scroll)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                IntroCard()
                ScoreCard(
                    section = ScoreSection.CHARGE,
                    headline = "Charge: how recovered are you?",
                    body = "Led by your heart-rate variability (HRV) measured against your own " +
                        "personal baseline, plus resting heart rate, last night's Rest, breathing " +
                        "rate, and a skin-temperature signal (an early illness or overreach flag). " +
                        "Higher HRV versus your baseline means more Charge. NOOP needs a few nights " +
                        "to learn your baseline first. Until then you'll see “Calibrating”.",
                    vsWhoop = "Same core idea as WHOOP's Recovery % (HRV-led recovery), but our " +
                        "weighting and baseline maths are our own, and openly documented.",
                    highlighted = highlighted == ScoreSection.CHARGE,
                    onPositioned = { if (ScoreSection.CHARGE !in anchors) anchors[ScoreSection.CHARGE] = it },
                )
                ScoreCard(
                    section = ScoreSection.EFFORT,
                    headline = "Effort: how hard did your heart work?",
                    body = "Your cardiovascular load. NOOP turns every second of heart rate into a " +
                        "training-impulse using heart-rate-reserve zones (Karvonen), weights time in " +
                        "harder zones more heavily (Edwards / Banister), and places it on a " +
                        "logarithmic 0-100 scale, so easy days sit low and an all-out day approaches " +
                        "100, which stays genuinely rare. A long walk with little cardio still counts, " +
                        "through a steps / active-energy floor.",
                    vsWhoop = "Same cardiovascular-load idea as WHOOP's Day Strain (0-21). We " +
                        "rescaled the top of the ladder from 21 to 100 so all three scores share one " +
                        "scale. The rungs didn't move, so a 100 is as rare as a 21.0 was.",
                    highlighted = highlighted == ScoreSection.EFFORT,
                    onPositioned = { if (ScoreSection.EFFORT !in anchors) anchors[ScoreSection.EFFORT] = it },
                )
                ScoreCard(
                    section = ScoreSection.REST,
                    headline = "Rest: how restorative was your sleep?",
                    body = "A blend of how long you slept versus your personal need (the biggest " +
                        "factor), how efficiently (asleep versus in bed), how much was restorative " +
                        "(deep + REM sleep), and how consistent your sleep and wake timing is.",
                    vsWhoop = "Similar in spirit to WHOOP's Sleep Performance %; our composite is our own.",
                    highlighted = highlighted == ScoreSection.REST,
                    onPositioned = { if (ScoreSection.REST !in anchors) anchors[ScoreSection.REST] = it },
                )
                ConfidenceCard()
                FooterNote()
            }

            Hairline()
            Footer(onClose = onClose)
        }
    }
}

// MARK: - Header ("How your scores work" + "Charge · Effort · Rest" + close X)

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Overline("Your daily scores", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_scoring_guide_screen_how_your_scores_work_21a0e2be), style = NoopType.display(26f), color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_scoring_guide_screen_charge_effort_rest_f396a530),
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Filled.Close,
                contentDescription = uiString(R.string.l10n_scoring_guide_screen_close_bbfa773e),
                tint = Palette.textTertiary,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

// MARK: - Intro card (THE THREE SCORES + paragraph + accent legend)

@Composable
private fun IntroCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("The three scores")
            Text(
                uiString(R.string.l10n_scoring_guide_screen_noop_gives_you_three_daily_scores_36244209) +
                    "scale. They're built from your strap's raw signals using published, " +
                    "peer-reviewed sport science, and computed entirely on your device. They are " +
                    "NOT WHOOP's scores: we don't have WHOOP's private algorithms and don't pretend " +
                    "to. They aim at the same three questions using open science, so they'll usually " +
                    "track WHOOP's in direction, but won't match number-for-number. And that's the " +
                    "point.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                LegendDot(ScoreSection.CHARGE)
                LegendDot(ScoreSection.EFFORT)
                LegendDot(ScoreSection.REST)
            }
        }
    }
}

@Composable
private fun LegendDot(section: ScoreSection) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(section.accent),
        )
        Text(section.label, style = NoopType.caption, color = Palette.textSecondary)
    }
}

// MARK: - Score card (accent strip + tinted icon/headline + body + "vs WHOOP" line)

@Composable
private fun ScoreCard(
    section: ScoreSection,
    headline: String,
    body: String,
    vsWhoop: String,
    highlighted: Boolean,
    onPositioned: (Int) -> Unit,
) {
    // Deep-link highlight: a brief accent ring when arrived at via an ⓘ, fading back to the hairline.
    val ringColor by animateColorAsState(
        targetValue = if (highlighted) section.accent else Palette.hairline,
        label = uiString(R.string.l10n_scoring_guide_screen_scorecardhighlight_4af6985c),
    )
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned { onPositioned(it.positionInRoot().y.toInt()) }
            .clip(shape)
            // Design Reset: a FLAT neutral frosted surface (no domain-colour navy bevel), faintly washed
            // with the section's Reset accent so a glance still maps a card to its Today ring.
            .frostedCardSurface(tint = section.accent, cornerRadius = Metrics.cardRadius)
            .border(if (highlighted) 2.dp else 1.dp, ringColor, shape)
            .padding(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            // Header row — a clean flat sample ring (no bloom) of the section's accent beside the headline.
            Row(
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SampleRing(section)
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.weight(1f),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            section.icon,
                            contentDescription = null,
                            tint = section.accent,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            section.label.uppercase(),
                            style = NoopType.overline,
                            color = section.accent,
                        )
                    }
                    Text(headline, style = NoopType.headline, color = Palette.textPrimary)
                }
            }
            Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            Hairline()
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    uiString(R.string.l10n_scoring_guide_screen_vs_whoop_9a8126a7),
                    style = NoopType.overline,
                    color = section.accent,
                    modifier = Modifier.padding(top = 1.dp),
                )
                Text(
                    vsWhoop,
                    style = NoopType.footnote.copy(fontStyle = FontStyle.Italic),
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/**
 * The flat illustrative ring for a score section — a clean [GlowRing] (Design Reset: solid crisp arc,
 * NO bloom) in the section's Reset accent, the same primitive the Today hero rings use, with the score
 * name as a small caption below. Decorative ("what a strong day looks like"), so it carries no semantics.
 * Replaces the old per-section bloom [BevelGauge].
 */
@Composable
private fun SampleRing(section: ScoreSection) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        GlowRing(
            fraction = section.sampleFraction.toFloat(),
            value = section.sampleFraction * 100.0,
            color = section.accent,
            diameter = 76.dp,
            lineWidth = 8.dp,
        )
        Text(
            section.label.uppercase(),
            style = NoopType.overline,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Confidence card (Solid / Building / Calibrating pills + explainer)

@Composable
private fun ConfidenceCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                uiString(R.string.l10n_scoring_guide_screen_how_sure_is_noop_solid_building_c21d86d7),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatePill("Solid", tone = StrandTone.Positive, showsDot = true)
                StatePill("Building", tone = StrandTone.Warning, showsDot = true)
                StatePill("Calibrating", tone = StrandTone.Neutral, showsDot = true)
            }
            Text(
                uiString(R.string.l10n_scoring_guide_screen_every_score_carries_a_small_honesty_e5b722eb) +
                    "learning your baseline, or doesn't have enough data yet. Building means there's " +
                    "enough to show, but it's thin. Solid means full inputs are present. When NOOP " +
                    "can't compute a score honestly, it shows nothing rather than a fake number.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - Footer note (muted disclaimer) + footer bar ("Got it")

@Composable
private fun FooterNote() {
    Text(
        uiString(R.string.l10n_scoring_guide_screen_these_are_independent_approximations_from_a_301457ed),
        style = NoopType.footnote,
        color = Palette.textTertiary,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp),
    )
}

@Composable
private fun Footer(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        Button(
            onClick = onClose,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
            ),
        ) {
            Text(uiString(R.string.l10n_scoring_guide_screen_got_it_5b8027fa), style = NoopType.captionNumber)
        }
    }
}

// MARK: - Hairline divider (mirrors WhatsNewSheet's Hairline)

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}
