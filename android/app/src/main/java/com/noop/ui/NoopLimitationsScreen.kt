package com.noop.ui

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// MARK: - NoopLimitationsScreen — "what NOOP can (and can't) read off each strap"
//
// A companion to WhoopModelComparisonScreen (#490), reached from Settings → Strap. Where that screen is
// prose-with-notes reassuring a 4.0 owner, this is the plain capability grid: every metric NOOP surfaces,
// and whether it comes live off a 4.0 vs a 5.0/MG — no per-row prose, just the honest tri-state and a
// legend. Marks mirror the values traced from the decoders/analytics: partial = an on-device estimate or an
// experimental/firmware-gated read; "not from strap" = only an import (WHOOP CSV / Health) can fill it.

/** Tri-state support for a metric on a given strap — honest, never overstated. */
private enum class LimitState { FULL, PARTIAL, NONE }

/** One row: a metric, and how it reads on a 4.0 vs a 5.0/MG. No note — the legend carries the meaning. */
private data class LimitRow(val feature: String, val whoop4: LimitState, val whoop5: LimitState)

private val LIMIT_ROWS: List<LimitRow> = listOf(
    LimitRow("Live heart rate", LimitState.FULL, LimitState.FULL),
    LimitRow("HRV (rMSSD)", LimitState.FULL, LimitState.FULL),
    LimitRow("Sleep staging", LimitState.FULL, LimitState.FULL),
    LimitRow("Recovery & strain", LimitState.FULL, LimitState.FULL),
    LimitRow("Respiratory rate", LimitState.FULL, LimitState.FULL),
    LimitRow("Stress (on-device)", LimitState.FULL, LimitState.FULL),
    LimitRow("Workout detection", LimitState.FULL, LimitState.FULL),
    LimitRow("Skin temperature", LimitState.PARTIAL, LimitState.FULL),
    LimitRow("Steps", LimitState.PARTIAL, LimitState.FULL),
    LimitRow("Blood oxygen (SpO₂ %)", LimitState.NONE, LimitState.NONE),
    LimitRow("ECG", LimitState.NONE, LimitState.PARTIAL),
    LimitRow("Blood pressure", LimitState.NONE, LimitState.NONE),
)

@Composable
fun NoopLimitationsScreen(onClose: () -> Unit) {
    val scroll = rememberScrollState()
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
                LimitTableCard()
                LegendCard()
            }
            Hairline()
            Footer(onClose)
        }
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

// MARK: - Header / footer (matches WhoopModelComparisonScreen's idiom)

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Overline("Per strap", color = Palette.textTertiary)
            Text("NOOP Limitations", style = NoopType.display(26f), color = Palette.textPrimary)
            Text("What each WHOOP can read", style = NoopType.caption, color = Palette.textSecondary)
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Filled.Close, contentDescription = "Close", tint = Palette.textTertiary, modifier = Modifier.size(22.dp))
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
            Text("Done", modifier = Modifier.padding(horizontal = 24.dp))
        }
    }
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
