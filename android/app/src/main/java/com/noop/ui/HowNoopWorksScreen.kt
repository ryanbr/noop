package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

// MARK: - HowNoopWorksScreen ("How NOOP works" primer)
//
// COMPONENT 5 of the sleep-guidance / explainability layer
// (docs/superpowers/specs/2026-06-20-sleep-guidance-explainability.md): a short,
// skimmable, plain-English primer reachable from a "?" in Settings → About. It
// answers the four questions the explainability layer raises across the app —
// how sleep gets sorted, how the scores + calibration work, what "recording"
// means, and where each number comes from (the provenance badges).
//
// Presented as a full-screen sheet, mirroring ScoringGuideScreen / WhatsNewSheet:
// a fixed scenic header with a close button, a scrollable column of cards, and a
// "Got it" footer. The four section bodies are the single approved source of truth,
// shared VERBATIM across macOS / iOS / Android — do not paraphrase or re-wrap the
// wording; keep it identical to the Swift HowNoopWorks primer. Honest per the
// explainability spec: nothing here promises a number NOOP won't show. No em-dashes.

/**
 * The four primer sections, in render order. Each carries its own glyph + accent so a
 * glance maps a card to the part of the app it explains (sleep purple, scores gold,
 * recording sensor-blue, provenance verified-cyan). Mirror the macOS/iOS section order
 * exactly so the three platforms stay in lockstep.
 */
private enum class PrimerSection(
    val title: String,
    val body: String,
    val icon: ImageVector,
) {
    SLEEP(
        title = uiString(R.string.l10n_how_noop_works_screen_how_your_sleep_is_sorted_6a8e82e0),
        body = "NOOP picks your main sleep as your longest real block, and (once it has " +
            "learned your usual hours) the one nearest your normal sleep time. Everything " +
            "else that day is a nap. You can always edit bed and wake times.",
        icon = Icons.Filled.Bedtime,
    ),
    SCORES(
        title = uiString(R.string.l10n_how_noop_works_screen_how_your_scores_work_21a0e2be),
        body = "Charge, Effort and Rest are scored on your own device from your strap data. " +
            "Charge needs about four nights of sleep to learn your baseline (that's \"Calibrating\", " +
            "counted as nights of 4 on the ring), and keeps sharpening over your first couple of weeks. " +
            "On a WHOOP 5 or MG the strap banks little history, so that count can sit at 0 of 4 until you " +
            "have worn it across a few nights. That's the strap's sync limit, not a fault. " +
            "Before there's a number, NOOP shows what it can without faking one.",
        icon = Icons.Filled.Insights,
    ),
    SCORE_RECIPE(
        title = uiString(R.string.l10n_how_noop_works_screen_how_your_scores_are_computed_1b2d6c30),
        body = "Charge weighs five signals against your own baseline: your overnight HRV matters most, " +
            "then your resting heart rate, how well you slept, your breathing rate, and how far your skin " +
            "temperature drifted from normal. Higher HRV and lower resting heart rate lift Charge; a big " +
            "skin-temperature drift in either direction lowers it. Each signal is measured as how far " +
            "tonight sits from your personal baseline, never an absolute target. If a signal is missing, " +
            "it's dropped and the rest are reweighted, so the number always reflects only what was " +
            "actually measured. The \"What shaped it\" breakdown under the Charge ring shows each signal's " +
            "point contribution.",
        icon = Icons.Filled.Calculate,
    ),
    RECORDING(
        title = uiString(R.string.l10n_how_noop_works_screen_what_recording_means_b896c422),
        body = "When your strap is connected NOOP is saving data live. \"Last synced\" tells " +
            "you how fresh it is. If it says \"Not recording\", reconnect.",
        icon = Icons.Filled.Sensors,
    ),
    PROVENANCE(
        title = uiString(R.string.l10n_how_noop_works_screen_where_your_numbers_come_from_e169963a),
        body = "A badge shows whether a number was scored on-device by NOOP, or imported " +
            "from Whoop or Apple Health.",
        icon = Icons.Filled.Verified,
    );

    /** The accent each section uses — matched to the surface it explains for continuity. */
    val accent: Color
        get() = when (this) {
            SLEEP -> Palette.metricPurple        // sleep world
            SCORES -> Palette.accent             // the daily scores' gold
            SCORE_RECIPE -> Palette.chargeColor  // the Charge world the recipe explains
            RECORDING -> Palette.metricCyan      // live / sensor signal
            PROVENANCE -> Palette.metricCyan     // the By-Day provenance badge tint
        }
}

/**
 * The "How NOOP works" primer sheet. [onClose] dismisses. Pure presentation — it reads
 * nothing and writes nothing; every line is static approved copy.
 */
@Composable
fun HowNoopWorksScreen(onClose: () -> Unit) {
    val scroll = rememberScrollState()

    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            // A scenic Charge-tinted hero behind the title region, the same premium backdrop
            // ScoringGuideScreen opens over, so the two explainers feel like one family.
            Box {
                ScenicHeroBackground(
                    modifier = Modifier.matchParentSize(),
                    domain = DomainTheme.Charge,
                    starCount = 28,
                )
                Header(onClose = onClose)
            }
            Hairline()

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(scroll)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                IntroCard()
                PrimerSection.values().forEach { section ->
                    PrimerCard(section)
                }
                FooterNote()
            }

            Hairline()
            Footer(onClose = onClose)
        }
    }
}

// MARK: - Header ("How NOOP works" + tagline + close X)

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
            Overline("The basics", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_how_noop_works_screen_how_noop_works_3396b27a), style = NoopType.display(26f), color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_how_noop_works_screen_sleep_scores_recording_where_your_numbers_1b3e981f),
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Filled.Close,
                contentDescription = uiString(R.string.l10n_how_noop_works_screen_close_bbfa773e),
                tint = Palette.textTertiary,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

// MARK: - Intro card (the one-line frame + accent legend)

@Composable
private fun IntroCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("The one rule")
            Text(
                uiString(R.string.l10n_how_noop_works_screen_noop_never_shows_you_a_number_d1db9958) +
                    "it tells you why and what to do next. Everything here runs on your " +
                    "device, from your strap.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                PrimerSection.values().forEach { LegendDot(it) }
            }
        }
    }
}

@Composable
private fun LegendDot(section: PrimerSection) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(section.accent),
    )
}

// MARK: - Primer card (tinted glyph/headline + body)

@Composable
private fun PrimerCard(section: PrimerSection) {
    NoopCard(padding = 20.dp, tint = section.accent) {
        Column(
            modifier = Modifier.semantics {
                contentDescription = uiString(R.string.l10n_how_noop_works_screen_section_title_section_body_efb1a999, section.title, section.body)
            },
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    section.icon,
                    contentDescription = null,
                    tint = section.accent,
                    modifier = Modifier.size(18.dp),
                )
                Text(section.title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(section.body, style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

// MARK: - Footer note (muted honesty line) + footer bar ("Got it")

@Composable
private fun FooterNote() {
    Text(
        uiString(R.string.l10n_how_noop_works_screen_noop_never_makes_up_a_number_da29aca5),
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
            Text(uiString(R.string.l10n_how_noop_works_screen_got_it_5b8027fa), style = NoopType.captionNumber)
        }
    }
}

// MARK: - Hairline divider (mirrors ScoringGuideScreen's Hairline)

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}
