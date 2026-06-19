package com.noop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.noop.analytics.AgreementState
import com.noop.analytics.ContributingSource
import com.noop.analytics.FusedMetricPoint
import com.noop.analytics.FusionSource
import com.noop.analytics.MetricArbitrationPolicy
import java.text.NumberFormat
import kotlin.math.roundToInt

// MARK: - FusedRecordScreen — "Your Data, Fused" (v5 — Local Multi-Device Fusion)
//
// Value-for-value Compose twin of Strand/Screens/FusedRecordView.swift
// (docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §UX). For each core metric
// it shows the BEST-sourced value, a provenance badge naming the source, the plain published reason
// from MetricArbitrationPolicy ("counts directly" / "best stager"), and the inline agreement state
// from FusionResolver (agree / minor delta / conflict). On a conflict it opens a compare detail
// listing EVERY source side by side and which one NOOP is using and why — it NEVER silently merges.
//
// SELF-CONTAINED: the screen takes a fully-resolved [FusedRecord] (the repository adapter that pulls
// today's per-source metrics and runs FusionResolver.resolve lives in Wave 3). It does no I/O and
// never touches AppViewModel directly, so it compiles and previews from a fixture. This file owns only
// PRESENTATION: a value formatter + the row/dialog chrome, built from the locked component set
// (NoopCard / StatePill / SourceBadge / SectionHeader / ScreenScaffold) and tokens (Palette / NoopType
// / Metrics).
//
// Wellness framing only: a source is "higher-trust for this metric" with a plain reason; we never say
// a number is accurate / correct / clinical, never flag a value as concerning.

// MARK: - Presentation model (the read-model this screen consumes)

/**
 * One resolved metric row for the fused record — the engine's [FusedMetricPoint] plus the display
 * [label] and an optional per-metric [accent]. The Wave 3 repository adapter builds these from the
 * rows it already loads.
 */
data class FusedRow(
    val point: FusedMetricPoint,
    val label: String,
    val accent: androidx.compose.ui.graphics.Color? = null,
)

/**
 * The whole fused day-record this screen renders. Built by the Wave 3 repository adapter; passed in so
 * the screen stays pure and previewable. [dayOwner] is the device that owns the day's scores (from
 * DayOwnerResolver) shown as the day badge; [contributingSourceCount] gates the single-source
 * degradation (≤ 1 ⇒ a plain record with no provenance noise).
 */
data class FusedRecord(
    val rows: List<FusedRow>,
    val dayOwner: FusionSource?,
    val contributingSourceCount: Int,
)

// MARK: - Screen

@Composable
fun FusedRecordScreen(
    record: FusedRecord,
    dayLabel: String = "Today",
    modifier: Modifier = Modifier,
) {
    // The metric currently open in the conflict-compare dialog (null = closed).
    var comparing by remember { mutableStateOf<FusedRow?>(null) }

    val isMultiSource = record.contributingSourceCount > 1
    val deviceNoun = "this device"

    val subtitle = if (isMultiSource) {
        "$dayLabel · best signal per metric, from ${record.contributingSourceCount} sources. Everything stays on $deviceNoun."
    } else {
        "$dayLabel · your record, on $deviceNoun."
    }

    ScreenScaffold(title = "Your Data, Fused", subtitle = subtitle, modifier = modifier) {
        if (isMultiSource) DayBadgeRow(record.dayOwner)

        if (record.rows.isEmpty()) {
            DataPendingNote(
                title = "Nothing to fuse yet",
                body = "Import a WHOOP export, Health Connect or a second band and your best-sourced record builds here — on this device.",
            )
        } else {
            NoopCard(padding = 0.dp) {
                Column {
                    record.rows.forEachIndexed { index, row ->
                        FusedMetricRow(
                            row = row,
                            showProvenance = isMultiSource,
                            onCompare = { comparing = row },
                        )
                        if (index < record.rows.lastIndex) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(start = Metrics.cardPadding),
                            )
                        }
                    }
                }
            }
        }

        PrivacyNote(deviceNoun)
        DisclaimerNote()
    }

    comparing?.let { row ->
        ConflictCompareDialog(row = row, onDismiss = { comparing = null })
    }
}

/** "Today's scores owned by WHOOP" — the scores' single-owner, made honest. */
@Composable
private fun DayBadgeRow(owner: FusionSource?) {
    val text = if (owner != null) {
        "Today's scores owned by ${owner.displayName}"
    } else {
        "Scores still calibrating — no single day-owner yet"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp)
            .semantics { contentDescription = text },
    ) {
        Icon(
            Icons.Outlined.VerifiedUser,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(14.dp),
        )
        Text(
            text,
            style = NoopType.footnote,
            color = if (owner != null) Palette.textSecondary else Palette.textTertiary,
        )
    }
}

@Composable
private fun PrivacyNote(deviceNoun: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp),
    ) {
        Icon(
            Icons.Outlined.Lock,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(13.dp),
        )
        Text(
            "Fused on $deviceNoun. Nothing leaves it — no account, no cloud.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

/** The pillar's standing non-clinical line (umbrella §4.1). Plain, wellness only. */
@Composable
private fun DisclaimerNote() {
    Text(
        "NOOP picks the best-sourced number and shows you where each came from. It's for wellness and curiosity — it doesn't diagnose or replace medical advice.",
        style = NoopType.footnote,
        color = Palette.textTertiary,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

// MARK: - One fused metric row

@Composable
private fun FusedMetricRow(
    row: FusedRow,
    showProvenance: Boolean,
    onCompare: () -> Unit,
) {
    val point = row.point
    val accent = row.accent ?: Palette.textPrimary
    val isConflict = point.agreement == AgreementState.CONFLICT

    val rowModifier = if (isConflict) {
        Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClickLabel = "Compare sources",
            ) { onCompare() }
    } else {
        Modifier.fillMaxWidth()
    }

    Column(
        modifier = rowModifier
            .padding(horizontal = Metrics.cardPadding, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Top line: metric label + the best-sourced value, right-aligned.
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                row.label,
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            AutoSizeValue(
                FusionFormat.value(point.value, point.metric),
                style = NoopType.number(20f),
                color = accent,
            )
        }

        if (showProvenance) {
            // Provenance: a source badge + the published one-line reason.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceBadge("from ${point.winningSource.displayName}", tint = Palette.accent)
                point.contributors.firstOrNull()?.reason?.let { reason ->
                    Text(reason, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            AgreementLine(point = point, onCompare = onCompare)
        }
    }
}

@Composable
private fun AgreementLine(point: FusedMetricPoint, onCompare: () -> Unit) {
    val other = point.contributors.drop(1).firstOrNull()
    when (point.agreement) {
        AgreementState.SINGLE -> Unit

        AgreementState.AGREE -> if (other != null) {
            Text(
                "${other.source.displayName} agrees: ${FusionFormat.value(other.value, point.metric)}",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }

        AgreementState.MINOR_DELTA -> if (other != null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                StatePill("Differs slightly", tone = StrandTone.Neutral, showsDot = false)
                Text(
                    "${other.source.displayName}: ${FusionFormat.value(other.value, point.metric)}",
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }

        AgreementState.CONFLICT -> Row(
            modifier = Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { onCompare() },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            StatePill("Sources differ", tone = StrandTone.Warning)
            Text(
                conflictSummary(point),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private fun conflictSummary(point: FusedMetricPoint): String {
    val other = point.contributors.drop(1).firstOrNull() ?: return "Tap to compare"
    return "${other.source.displayName} says ${FusionFormat.value(other.value, point.metric)} — tap to compare"
}

// MARK: - Conflict-compare dialog

/**
 * A small read-only dialog: every source's value for the metric, side by side, with the one NOOP is
 * using marked and its trust reason named. NOOP never adjudicates which is "correct" — it shows the
 * spread and explains its best-signal pick. Transparency, not diagnosis.
 */
@Composable
private fun ConflictCompareDialog(row: FusedRow, onDismiss: () -> Unit) {
    val point = row.point
    Dialog(onDismissRequest = onDismiss) {
        NoopCard(padding = Metrics.cardPadding) {
            Column(
                modifier = Modifier
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                SectionHeader(title = row.label, overline = "Sources differ")
                Text(
                    "Your bands report different numbers. Here's every source, and the one NOOP is using.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )

                Column {
                    point.contributors.forEachIndexed { index, contrib ->
                        ContributorRow(
                            contrib = contrib,
                            metricKey = point.metric,
                            isWinner = index == 0,
                        )
                        if (index < point.contributors.lastIndex) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }

                point.contributors.firstOrNull()?.let { winner ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Icon(
                            Icons.Outlined.Info,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            "NOOP shows the ${winner.source.displayName} reading because it ${winner.reason} for this metric — a higher-trust source here, not a verdict that the others are wrong.",
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text("Done", style = NoopType.headline, color = Palette.accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun ContributorRow(
    contrib: ContributingSource,
    metricKey: String,
    isWinner: Boolean,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp)
            .semantics {
                contentDescription =
                    "${contrib.source.displayName}, ${FusionFormat.value(contrib.value, metricKey)}" +
                    if (isWinner) ", in use" else ""
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceBadge(
                    contrib.source.displayName,
                    tint = if (isWinner) Palette.accent else Palette.textTertiary,
                )
                if (isWinner) StatePill("Using", tone = StrandTone.Accent, showsDot = true)
            }
            Text(contrib.reason, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Text(
            FusionFormat.value(contrib.value, metricKey),
            style = NoopType.number(18f),
            color = if (isWinner) Palette.textPrimary else Palette.textSecondary,
        )
    }
}

// MARK: - Display formatting (presentation only — the engine returns raw Doubles + raw keys)

/**
 * Formats a fused metric's [Double] value for display by its resolver key. Pure + local to this
 * screen, value-for-value with the Swift `FusionFormat`: the engine deals in numbers, the UI owns
 * units. Sleep/duration keys read as "7h 12m"; temp as "34.1°C"; HR/HRV/steps as integers + unit.
 */
object FusionFormat {
    fun value(v: Double, metricKey: String): String =
        when (MetricArbitrationPolicy.kind(metricKey)) {
            MetricArbitrationPolicy.MetricKind.RESTING_HR,
            MetricArbitrationPolicy.MetricKind.HEART_RATE -> "${v.roundToInt()} bpm"
            MetricArbitrationPolicy.MetricKind.HRV -> "${v.roundToInt()} ms"
            MetricArbitrationPolicy.MetricKind.SPO2 -> "${v.roundToInt()}%"
            MetricArbitrationPolicy.MetricKind.SKIN_TEMP -> String.format("%.1f°C", v)
            MetricArbitrationPolicy.MetricKind.STEPS -> integerGrouped(v)
            MetricArbitrationPolicy.MetricKind.SLEEP -> duration(v)
            MetricArbitrationPolicy.MetricKind.CALORIES -> "${integerGrouped(v)} kcal"
            MetricArbitrationPolicy.MetricKind.OTHER ->
                if (v == Math.floor(v)) v.toInt().toString() else String.format("%.1f", v)
        }

    /** "8,420" — grouped integer. */
    private fun integerGrouped(v: Double): String =
        NumberFormat.getIntegerInstance().format(v.roundToInt())

    /** "7h 12m" from a minutes value; "52m" under an hour; "0m" for nothing. */
    private fun duration(minutes: Double): String {
        val total = maxOf(0, minutes.roundToInt())
        val h = total / 60
        val m = total % 60
        return if (h == 0) "${m}m" else "${h}h ${m}m"
    }
}
