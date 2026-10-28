package com.noop.ui

import com.noop.R
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - PipBar (the NOOP segmented count-up bar)
//
// Compose port of StrandDesign/PipBar.swift. A horizontal row of N equal rounded segments
// ("pips") separated by small uniform gaps. Segments from the left up to the value's fraction
// are filled with the tint; the rest stay the track colour (`surfaceInset`). The last filled
// segment is a touch brighter (the lead edge). NOOP's signature for a 0…max value — a flat,
// crisp, WHOOP-grade alternative to a smooth progress bar.
//
// COUNT-UP: on first composition AND on every value change, the fill cascades segment-by-segment
// from 0 up to the value in a quick eased sweep (~0.6s). The whole effect is driven by a SINGLE
// animated fraction; each segment derives its own fill from that one value over a short
// per-segment ramp, so the pips appear to light up in sequence (cheap to animate). Reduce Motion
// → the fraction is set instantly and the bar renders static at its final frame.
//
// HARD constraints honoured: NO GLOW (flat fills only), TOKENS only (`Palette.surfaceInset`
// track, `tint` fill), crisp high-contrast, public stable API.

// MARK: - PipBar

/**
 * The segmented count-up bar. Mirrors iOS `PipBar(value:range:segments:tint:height:)`.
 *
 * @param value the value to display, in [range].
 * @param range the value's domain (mapped to 0…1 across the bar). Defaults to a 0…100 scale.
 * @param segments number of pips. Higher = finer resolution. Default 24.
 * @param tint the fill colour for lit segments (a domain / status / score token).
 * @param height bar height. Default 10dp.
 */
@Composable
fun PipBar(
    value: Float,
    range: ClosedFloatingPointRange<Float> = 0f..100f,
    segments: Int = 24,
    tint: Color,
    height: Dp = 10.dp,
    modifier: Modifier = Modifier,
) {
    val reduced = rememberReduceMotion()
    val pipCount = max(1, segments)

    // The target fill fraction (value mapped into 0…1, clamped).
    val targetFraction = run {
        val lo = range.start
        val hi = range.endInclusive
        if (hi <= lo) 0f else min(max((value - lo) / (hi - lo), 0f), 1f)
    }

    // The single animated driver: a 0…1 fraction the whole bar derives from. One eased sweep moves
    // it 0 → target so segments light in sequence; Reduce Motion snaps it with no animation.
    var driver by remember { mutableStateOf(if (reduced) targetFraction else 0f) }
    LaunchedEffect(targetFraction, reduced) { driver = targetFraction }

    val animatedFraction by animateFloatAsState(
        targetValue = driver,
        // Quick eased cascade (~0.6s) so the pips light left→right; instant under Reduce Motion.
        animationSpec = if (reduced) tween(0) else tween(durationMillis = 600, easing = EaseOut),
        label = uiString(R.string.l10n_pip_bar_pipbar_197c22c4),
    )
    val f = if (reduced) targetFraction else animatedFraction

    // Gap scales with height so the bar reads consistently at any size; pips stay rounded (rx ~2.5).
    val gap: Dp = maxOf(2.dp, height * 0.28f)
    val track = Palette.surfaceInset
    val corner = RoundedCornerShape(2.5.dp)

    val axValue = run {
        val v = (value * 10f).roundToInt() / 10f
        if (v % 1f == 0f) v.toInt().toString() else v.toString()
    }

    Row(
        horizontalArrangement = Arrangement.spacedBy(gap),
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .clearAndSetSemantics { contentDescription = axValue },
    ) {
        val n = pipCount.toFloat()
        for (index in 0 until pipCount) {
            val color = pipColor(
                index = index,
                n = n,
                fraction = f,
                targetFraction = targetFraction,
                track = track,
                tint = tint,
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(height)
                    .clip(corner)
                    .background(color),
            )
        }
    }
}

/**
 * The fill for a single segment, derived from the one animated fraction.
 *
 * Each pip owns the sub-range `[index/N, (index+1)/N]`. As [fraction] sweeps up it crosses these
 * edges left→right, so segments fill in sequence. Within a pip the fill ramps over its own span
 * (so the leading pip fades in smoothly rather than snapping); the pip currently holding the lead
 * edge (the target fraction sits inside it) is nudged a touch brighter — the "last filled segment
 * is a touch brighter". Flat — no glow.
 */
private fun pipColor(
    index: Int,
    n: Float,
    fraction: Float,
    targetFraction: Float,
    track: Color,
    tint: Color,
): Color {
    val segStart = index / n
    val segEnd = (index + 1) / n

    // How much of THIS segment is covered by the current fraction (0…1 across the segment span).
    val local: Float = when {
        fraction >= segEnd -> 1f
        fraction <= segStart -> 0f
        else -> (fraction - segStart) / (segEnd - segStart) // span is 1/n, always > 0
    }

    if (local <= 0f) return track

    // Lit pips use the tint; the segment holding the live lead edge is nudged a touch brighter for
    // a crisp leading highlight. Flat — no glow.
    val isLeadEdge = targetFraction > segStart && targetFraction <= segEnd
    val base = if (isLeadEdge) brighten(tint) else tint

    // Partially-covered pip (the moving front of the cascade): blend track → fill by coverage so
    // the sweep edge is smooth, not stepped. Fully covered pips are the solid fill.
    return if (local >= 1f) base else lerp(track, base, local)
}

/** A small, glow-free brightness lift for the lead-edge segment — blend the tint toward white. */
private fun brighten(color: Color): Color = lerp(color, Color.White, 0.22f)

// MARK: - PipBarRow (card-ready WHOOP metric row)

/**
 * A card-ready row: UPPERCASE label + big white value/unit on top, the [PipBar] beneath. Matches
 * the WHOOP metric-row type — bold white number with a smaller-weight unit suffix over a tracked
 * overline label. Drop into a card for an instant metric tile. Mirrors iOS `PipBarRow`.
 *
 * @param label the label (rendered uppercased with overline tracking).
 * @param value the value for the bar, in [range].
 * @param range the value's domain.
 * @param tint lit-segment fill colour.
 * @param valueText the big value string shown on top (already formatted, e.g. "87" or "9.0").
 * @param unit optional smaller-weight unit suffix (e.g. "%", "bpm"). null hides it.
 * @param segments segment count, forwarded to the bar.
 */
@Composable
fun PipBarRow(
    label: String,
    value: Float,
    tint: Color,
    valueText: String,
    range: ClosedFloatingPointRange<Float> = 0f..100f,
    unit: String? = null,
    segments: Int = 24,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clearAndSetSemantics {
                contentDescription = if (unit != null) uiString(R.string.pip_bar_format, label, valueText, unit) else uiString(R.string.l10n_fused_record_screen_other_source_displayname_fusionformat_value_other_207f7548, label, valueText)
            },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // UPPERCASE label.
        Text(
            text = label.uppercase(),
            style = NoopType.overline,
            color = Palette.textSecondary,
        )

        // Big white value + smaller-weight unit suffix.
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = valueText,
                style = NoopType.number(30f, weight = FontWeight.Bold),
                color = Palette.textPrimary,
            )
            if (unit != null) {
                Text(
                    text = unit,
                    style = NoopType.headline,
                    color = Palette.textTertiary,
                    modifier = Modifier.padding(start = 4.dp, bottom = 2.dp),
                )
            }
        }

        // The segmented count-up bar.
        PipBar(value = value, range = range, segments = segments, tint = tint)
    }
}
