package com.noop.ui

import com.noop.R
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// MARK: - NoopLimitationsScreen — "what NOOP can (and can't) read off each strap"
//
// A More-tab page (Data group): the plain tri-state capability grid of what NOOP reads live off a WHOOP
// 4.0 vs a 5.0/MG, note-free, with a legend in place of per-row prose. Marks mirror the decoder/analytics
// truth (Interpreter / AnalyticsEngine / HistoricalStreams): full = read live; partial = an on-device
// estimate or an experimental / firmware-gated read; none = not off the strap (SpO₂ % is import-only on
// both; blood pressure has no path). iOS twin: NoopLimitationsView. Rendered through the shared
// ScreenScaffold like every other More destination — the bottom bar carries navigation (no close button).

/** Tri-state support for a metric on a given strap — honest, never overstated. */
private enum class LimitState { FULL, PARTIAL, NONE }

/** One row: a metric, and how it reads on a 4.0 vs a 5.0/MG. No note — the legend carries the meaning. */
private data class LimitRow(val feature: String, val whoop4: LimitState, val whoop5: LimitState)

private val LIMIT_ROWS: List<LimitRow> = listOf(
    LimitRow("Live heart rate", LimitState.FULL, LimitState.FULL),
    LimitRow("HRV (rMSSD)", LimitState.FULL, LimitState.FULL),
    LimitRow("Sleep staging", LimitState.FULL, LimitState.FULL),
    LimitRow("Recovery & strain", LimitState.FULL, LimitState.FULL),
    // PARTIAL on BOTH generations: the displayed respiratory rate is always SleepStager.respRateFromRR
    // — an on-device RSA estimate off the R-R stream, which is what PARTIAL means — computed with NO
    // family branch (AnalyticsEngine respRateDaily). The 5.0/MG v18 wire carries no respiratory channel
    // (Whoop5HistoricalDecodeTest pins resp_rate_raw null); the 4.0 v24 layout DOES carry resp_rate_raw,
    // but it is a raw ADC stored unconverted (schema: "resp rate computed server-side") and never shown.
    // Neither is "read live off the strap" (FULL) — also why an over-counted-R-R 4.0 night (#1331) blanks
    // it. Twin of the Swift NoopLimitationsView row.
    LimitRow("Respiratory rate", LimitState.PARTIAL, LimitState.PARTIAL),
    LimitRow("Stress (on-device)", LimitState.FULL, LimitState.FULL),
    LimitRow("Workout detection", LimitState.FULL, LimitState.FULL),
    LimitRow("Skin temperature", LimitState.PARTIAL, LimitState.FULL),
    LimitRow("Steps", LimitState.PARTIAL, LimitState.FULL),
    LimitRow("Blood oxygen (SpO₂ %)", LimitState.NONE, LimitState.NONE),
    LimitRow("ECG", LimitState.NONE, LimitState.PARTIAL),
    LimitRow("Blood pressure", LimitState.NONE, LimitState.NONE),
)

@Composable
fun NoopLimitationsScreen() {
    ScreenScaffold(
        title = stringResource(R.string.nav_noop_limitations),
        subtitle = "What each strap can read",
    ) {
        LimitTableCard()
        LegendCard()
    }
}

@Composable
private fun LimitTableCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("What NOOP reads")
            // Column header.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Feature", style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                Text("4.0", style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(48.dp))
                Text("5.0/MG", style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(48.dp))
            }
            LIMIT_ROWS.forEachIndexed { idx, row ->
                if (idx > 0) Hairline()
                Row(
                    modifier = Modifier.fillMaxWidth().semantics {
                        contentDescription = "${row.feature}: WHOOP 4.0 ${row.whoop4.spoken}, 5.0/MG ${row.whoop5.spoken}"
                    },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(row.feature, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    SupportCell(row.whoop4)
                    SupportCell(row.whoop5)
                }
            }
        }
    }
}

@Composable
private fun LegendCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Overline("Legend")
            LegendRow(LimitState.FULL, "Read live off the strap")
            LegendRow(LimitState.PARTIAL, "On-device estimate, or experimental / firmware-gated")
            LegendRow(LimitState.NONE, "Not from the strap. SpO₂ can be filled by importing a WHOOP or Health export.")
        }
    }
}

@Composable
private fun LegendRow(state: LimitState, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SupportCell(state)
        Text(label, style = NoopType.footnote, color = Palette.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SupportCell(state: LimitState) {
    Box(modifier = Modifier.width(48.dp), contentAlignment = Alignment.Center) {
        when (state) {
            LimitState.FULL -> SupportGlyph(Icons.Filled.Check, Palette.statusPositive, "yes")
            LimitState.PARTIAL -> SupportGlyph(Icons.Filled.Remove, Palette.statusWarning, "partly")
            LimitState.NONE -> SupportGlyph(Icons.Filled.Close, Palette.textTertiary, "no")
        }
    }
}

@Composable
private fun SupportGlyph(icon: ImageVector, tint: Color, label: String) {
    Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(18.dp))
}

@Composable
private fun Hairline() {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
}

/** Spoken support label for the row's accessibility description. */
private val LimitState.spoken: String
    get() = when (this) {
        LimitState.FULL -> "yes"
        LimitState.PARTIAL -> "partly"
        LimitState.NONE -> "no"
    }
