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

// MARK: - WhoopModelComparisonScreen (FI-2 / #490) — "what each strap can read, and why"
//
// A plain-English comparison of the WHOOP 4.0 and the WHOOP 5.0/MG, reached from Settings → Strap by
// EITHER model owner. The point (issue #490): a 4.0 user wrongly believed broadcast-out was 5.0-only.
// In truth NOOP's OWN heart-rate re-broadcast (Data Sources → "Broadcast heart rate") works on ANY
// strap — it re-advertises whatever live HR NOOP is reading. What's genuinely 5/MG-only is the strap
// FIRMWARE broadcast flag (whoop_live_hr_in_adv_ind_pkt), because the 4.0 firmware has no such config.
// This screen draws that line honestly, and reassures a 4.0 owner their strap is fully supported.

/** One capability row: a feature, and whether each strap can do it (Yes / No / a short qualifier). */
private data class CapabilityRow(
    val feature: String,
    val whoop4: Support,
    val whoop5: Support,
    val note: String? = null,
)

/** Tri-state support for the comparison table — honest, never overstated. */
private enum class Support { YES, NO, PARTIAL }

private val CAPABILITIES: List<CapabilityRow> = listOf(
    CapabilityRow(
        "Live heart rate",
        Support.YES, Support.YES,
        "Both stream live HR to NOOP over Bluetooth.",
    ),
    CapabilityRow(
        "Sleep, recovery & strain history",
        Support.YES, Support.PARTIAL,
        "The 4.0's history is fully decoded. On a 5/MG, history decoding is experimental: live HR works, " +
            "deeper history is still being mapped.",
    ),
    CapabilityRow(
        "NOOP re-broadcasts your HR (gym / Zwift / Garmin)",
        Support.YES, Support.YES,
        "Data Sources → \"Broadcast heart rate\" turns your PHONE into a standard BLE HR sensor using " +
            "whatever HR NOOP is reading, so this works on a 4.0 too. It's local Bluetooth; nothing leaves " +
            "your phone.",
    ),
    CapabilityRow(
        "Strap broadcasts its own HR (firmware flag)",
        Support.NO, Support.YES,
        "Making the STRAP itself advertise HR (the whoop_live_hr_in_adv_ind_pkt config) only exists on " +
            "5/MG firmware. A 4.0 can't do this, but the phone re-broadcast above covers the same use.",
    ),
    CapabilityRow(
        "Steps",
        Support.PARTIAL, Support.YES,
        "A 4.0 sends no step count, so NOOP ESTIMATES steps from motion, calibrated to your phone " +
            "(Settings → Profile → Steps estimate). A 5/MG reports a motion counter NOOP reads directly.",
    ),
    CapabilityRow(
        "Rename the strap's Bluetooth name",
        Support.YES, Support.NO,
        "Renaming works over the 4.0's firmware command; the 5/MG path isn't supported.",
    ),
    CapabilityRow(
        "Buzz the strap (alarms, haptics, time)",
        Support.YES, Support.YES,
    ),
)

@Composable
fun WhoopModelComparisonScreen(onClose: () -> Unit) {
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
                IntroCard()
                CapabilityTableCard()
                ReassuranceCard()
            }
            Hairline()
            Footer(onClose)
        }
    }
}

@Composable
private fun IntroCard() {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(uiString(R.string.l10n_whoop_model_comparison_screen_both_straps_are_supported_8545557a), style = NoopType.headline, color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_whoop_model_comparison_screen_noop_pairs_with_the_whoop_4_599b088c) +
                    " heart rate, your scores, buzzing the strap), but a few firmware features differ. Here's " +
                    "what each can do, and why.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun CapabilityTableCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("Feature by strap")
            // Column header.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(uiString(R.string.l10n_whoop_model_comparison_screen_feature_ad565d9d), style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                Text("4.0", style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(48.dp))
                Text(uiString(R.string.l10n_whoop_model_comparison_screen_5_mg_62eaa522), style = NoopType.caption, color = Palette.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(48.dp))
            }
            CAPABILITIES.forEachIndexed { idx, cap ->
                if (idx > 0) Hairline()
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth().semantics {
                            contentDescription =
                                uiString(R.string.l10n_whoop_model_comparison_screen_cap_feature_whoop_4_0_cap_bc142cb8, cap.feature, cap.whoop4.spoken, cap.whoop5.spoken)
                        },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(cap.feature, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                        SupportCell(cap.whoop4)
                        SupportCell(cap.whoop5)
                    }
                    cap.note?.let {
                        Text(it, style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun SupportCell(support: Support) {
    Box(modifier = Modifier.width(48.dp), contentAlignment = Alignment.Center) {
        when (support) {
            Support.YES -> SupportGlyph(Icons.Filled.Check, Palette.statusPositive, "Yes")
            Support.NO -> SupportGlyph(Icons.Filled.Close, Palette.textTertiary, "No")
            Support.PARTIAL -> SupportGlyph(Icons.Filled.Remove, Palette.statusWarning, "Partly")
        }
    }
}

@Composable
private fun SupportGlyph(icon: ImageVector, tint: Color, label: String) {
    Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(18.dp))
}

@Composable
private fun ReassuranceCard() {
    NoopCard(padding = 20.dp, tint = Palette.metricCyan) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(uiString(R.string.l10n_whoop_model_comparison_screen_on_a_whoop_4_0_32a5968d), style = NoopType.headline, color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_whoop_model_comparison_screen_you_re_not_missing_the_broadcast_1d2fa907) +
                    " Zwift, Peloton or a Garmin, open Data Sources and turn on \"Broadcast heart rate\": " +
                    "your phone becomes a standard Bluetooth HR sensor using your strap's live reading. The " +
                    "firmware-only flag a 5/MG has just does the same job from the strap instead of the phone.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - Header / footer (matches StepsCalibrationScreen's idiom)

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Overline("Your strap", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_whoop_model_comparison_screen_4_0_vs_5_0_mg_56099a02), style = NoopType.display(26f), color = Palette.textPrimary)
            Text(uiString(R.string.l10n_whoop_model_comparison_screen_what_each_can_read_and_why_4348bd67), style = NoopType.caption, color = Palette.textSecondary)
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_whoop_model_comparison_screen_close_bbfa773e), tint = Palette.textTertiary, modifier = Modifier.size(22.dp))
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
            Text(uiString(R.string.l10n_whoop_model_comparison_screen_done_e9b450d1), modifier = Modifier.padding(horizontal = 24.dp))
        }
    }
}

@Composable
private fun Hairline() {
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
}

/** Spoken support label for the row's accessibility description. */
private val Support.spoken: String
    get() = when (this) {
        Support.YES -> "yes"
        Support.NO -> "no"
        Support.PARTIAL -> "partly"
    }
