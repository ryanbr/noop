package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import java.util.Locale
import kotlin.math.roundToInt

/**
 * The four WHOOP-style stage rows that replace the old "label · value" footer grid, read like WHOOP's
 * sleep detail: a colour swatch, the UPPERCASE stage name, the share-of-night % in the stage colour, a
 * segmented [PipBar] (the NOOP signature) tinted in the stage colour, and the right-aligned duration.
 * Same data as the prior footer (rem / deep / light / awake over total) — no new numbers. Mirrors the
 * macOS SleepView.stageBreakdownRows. (PipBar)
 */
@Composable
internal fun StageBreakdownRows(s: Stages) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
        StageBreakdownRow("REM", s.rem, s.total, Palette.sleepREM)
        StageBreakdownRow("Deep", s.deep, s.total, Palette.sleepDeep)
        StageBreakdownRow("Light", s.light, s.total, Palette.sleepLight)
        StageBreakdownRow("Awake", s.awake, s.total, Palette.sleepAwake)
    }
}

/**
 * One WHOOP-style stage row. `fraction = minutes / total` sets both the % and the PipBar fill, so the
 * coloured percent and the segmented bar always agree. Mirrors the macOS SleepView.stageBreakdownRow.
 */
@Composable
private fun StageBreakdownRow(stage: String, minutes: Double, total: Double, color: Color) {
    val fraction = if (total > 0.0) (minutes / total).coerceIn(0.0, 1.0) else 0.0
    val percent = (fraction * 100.0).roundToInt()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                contentDescription =
                    uiString(R.string.l10n_sleep_screen_stage_durationtext_minutes_percent_percent_of_477dbf14, stage, durationText(minutes), percent)
            },
    ) {
        Box(
            modifier = Modifier
                .size(12.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(color),
        )
        Text(
            stage.uppercase(Locale.getDefault()),
            style = NoopType.overline,
            color = Palette.textPrimary,
            maxLines = 1,
            modifier = Modifier.width(56.dp),
        )
        Text(
            uiString(R.string.l10n_sleep_screen_percent_2281d326, percent),
            style = NoopType.captionNumber,
            color = color,
            maxLines = 1,
            modifier = Modifier.width(38.dp),
        )
        // The stage's share-of-night as a liquid TUBE tinted in the stage colour — a genuine single-value
        // progress bar (minutes / total), so it liquid-ifies cleanly. Posed static (animated = false): a
        // hero card carries many stage rows, so a per-frame slosh per row isn't worth the cost — the tube
        // reads as a filled liquid level, matching the pilot's non-hero tubes. Same fraction the % + the
        // duration carry, so all three agree.
        LiquidTube(
            frac = fraction,
            tint = color,
            animated = false,
            height = 8.dp,
            modifier = Modifier.weight(1f),
        )
        Text(
            durationText(minutes),
            style = NoopType.captionNumber,
            color = Palette.textPrimary,
            textAlign = TextAlign.End,
            maxLines = 1,
            modifier = Modifier.width(60.dp),
        )
    }
}

/**
 * The hero hypnogram strip plus an optional onset · midpoint · wake time axis. Mirrors the Swift
 * Hypnogram(showsTimeAxis:): a proportional stage strip with a per-segment WIDTH floor (so a brief
 * stage — especially a short Awake blip — reads as a rounded block, not a hairline tick), three
 * faint vertical hairlines at frac 0 / 0.5 / 1.0, and a clock-label row underneath. The axis only
 * appears when the session supplies onset/wake timestamps; otherwise this is just the floored strip.
 * Presentation-only — the segment weights and stage→colour mapping are unchanged.
 */
@Composable
internal fun HypnogramWithAxis(
    stages: List<Pair<String, Float>>,
    onsetTs: Long?,
    wakeTs: Long?,
) {
    val showsAxis = onsetTs != null && wakeTs != null
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Canvas(modifier = Modifier.fillMaxWidth().height(Metrics.stageStripHeight)) {
            val w = size.width
            val h = size.height
            if (w <= 0f || h <= 0f) return@Canvas

            // Inset well so the strip reads as a recessed track (matches the shared Hypnogram).
            drawLine(
                color = Palette.surfaceInset,
                start = Offset(0f, h / 2f),
                end = Offset(w, h / 2f),
                strokeWidth = h,
                cap = StrokeCap.Round,
            )

            val weights = stages.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
            val total = weights.sum()
            if (stages.isEmpty() || total <= 0f) return@Canvas

            // WIDTH floor: a segment narrower than this reads as a hairline, so floor short stages to a
            // legible block. But the FLOORED widths can sum past the canvas on a fragmented night (many
            // short segments), and the old loop advanced `x` by the floored width — so the tail ran off
            // the canvas and clipped, leaving only the first ~w/h segments visible as a row of circles
            // (#36). Fix: floor every segment, then if the floored total overflows, scale them ALL to fit
            // so the strip stays a continuous bar for the WHOLE night. Draw rounded RECTS (not round-capped
            // lines, whose h-wide round cap turned any sub-h segment into a full circle) advancing by the
            // SAME width we draw, so `x` can never exceed the canvas.
            val minSegW = h / 2f
            val floored = weights.map { wt -> if (wt > 0f) maxOf(w * (wt / total), minSegW) else 0f }
            val flooredSum = floored.sum()
            val scale = if (flooredSum > w) w / flooredSum else 1f
            val radius = CornerRadius(2.dp.toPx(), 2.dp.toPx())
            var x = 0f
            stages.forEachIndexed { i, (name, _) ->
                val segW = floored[i] * scale
                if (segW <= 0f) return@forEachIndexed
                drawRoundRect(
                    color = stageColorFor(name),
                    topLeft = Offset(x, 0f),
                    size = Size(segW.coerceAtMost(w - x), h),
                    cornerRadius = radius,
                )
                x += segW
            }

            // Time-axis vertical hairlines: onset · midpoint · wake.
            if (showsAxis) {
                listOf(0f, 0.5f, 1f).forEach { frac ->
                    val hx = w * frac
                    drawLine(
                        color = Palette.hairline,
                        start = Offset(hx, 0f),
                        end = Offset(hx, h),
                        strokeWidth = 1f,
                    )
                }
            }
        }
        if (showsAxis && onsetTs != null && wakeTs != null) {
            ClockLabelRow(onsetTs, wakeTs)
        }
    }
}

/**
 * #sleep-chart-style — the opt-in FILLED stepped hypnogram (the WHOOP-style single chart): stages stacked
 * by depth (Awake top → REM → Light → Deep bottom), each stage's column FILLED from its level down to the
 * baseline, with thin vertical risers tracing the transitions and an onset · midpoint · wake time axis.
 *
 * Unlike the classic proportional views this plots the night's REAL timestamps, so [segments] must be the
 * timestamped `PersistedSegment` array (`SleepModel.hypnogramSegments`); the caller only routes here when
 * the pref is FILLED and that array is present. Sub-90s fragments are display-smoothed (shared
 * [displaySmoothed], render-only — totals/percentages are untouched) so the night reads as a clean
 * staircase rather than a comb. One collapsed a11y node.
 */
@Composable
internal fun FilledHypnogram(
    segments: List<PersistedSegment>,
    onsetTs: Long?,
    wakeTs: Long?,
) {
    if (segments.isEmpty()) return
    val originSec = (onsetTs?.toDouble()) ?: segments.minOf { it.start }.toDouble()
    val endSec = (wakeTs?.toDouble()) ?: segments.maxOf { it.end }.toDouble()
    val spanSec = (endSec - originSec).coerceAtLeast(1.0)
    val intervals = remember(segments, originSec, spanSec) {
        // Sort by start BEFORE smoothing: displaySmoothed's coalesce assumes chronological order (it
        // bridges seams via startSec − last.endSec), exactly like the Swift Hypnogram sorts before
        // displaySmoothed. Group segments are normally already ordered, but a fragmented-night
        // concatenation must not be trusted to be.
        displaySmoothed(
            segments.sortedBy { it.start }
                .map { StageInterval(it.stage, it.start - originSec, it.end - originSec) },
            FILLED_HYPNOGRAM_SMOOTH_SEC,
        )
    }
    val showsAxis = onsetTs != null && wakeTs != null
    val axSummary = hypnogramSummaryFor(intervals)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(Metrics.compactChartHeight)
                .semantics { contentDescription = axSummary },
        ) {
            val w = size.width
            val h = size.height
            if (w <= 0f || h <= 0f || intervals.isEmpty()) return@Canvas
            val rowStep = h / 4f
            fun levelY(rank: Int): Float = rowStep * (rank + 0.5f)
            fun rankOf(stage: String): Int = when (canonicalStage(stage)) {
                "awake" -> 0
                "rem" -> 1
                "light" -> 2
                "deep" -> 3
                else -> 2
            }
            fun xOf(sec: Double): Float = (w * (sec / spanSec)).toFloat().coerceIn(0f, w)

            // Faint per-stage lane guides so height → stage reads even across gaps (mirrors the iOS lanes).
            for (rank in 0 until 4) {
                val y = levelY(rank)
                drawLine(
                    color = Palette.hairline.copy(alpha = 0.25f),
                    start = Offset(0f, y),
                    end = Offset(w, y),
                    strokeWidth = 1f,
                )
            }
            // Filled columns: each stage from its level DOWN to the baseline. Sharp rects (not rounded) so
            // adjacent columns TILE seamlessly into one continuous staircase — the 2dp rounding left dark
            // notch-gaps between blocks that read as a comb on a fragmented night.
            intervals.forEach { iv ->
                val x0 = xOf(iv.startSec)
                val x1 = xOf(iv.endSec)
                val top = levelY(rankOf(iv.stage))
                drawRect(
                    color = stageColorFor(iv.stage),
                    topLeft = Offset(x0, top),
                    size = Size((x1 - x0).coerceAtLeast(1.5f).coerceAtMost(w - x0), (h - top).coerceAtLeast(0f)),
                )
            }
            // Connecting risers tracing the staircase between consecutive column tops.
            for (i in 0 until intervals.size - 1) {
                val a = intervals[i]
                val b = intervals[i + 1]
                val x = xOf(b.startSec)
                drawLine(
                    color = Palette.textTertiary.copy(alpha = 0.5f),
                    start = Offset(x, levelY(rankOf(a.stage))),
                    end = Offset(x, levelY(rankOf(b.stage))),
                    strokeWidth = 1.5f,
                    cap = StrokeCap.Round,
                )
            }
            // Time-axis vertical hairlines: onset · midpoint · wake.
            if (showsAxis) {
                listOf(0f, 0.5f, 1f).forEach { frac ->
                    val hx = w * frac
                    drawLine(
                        color = Palette.hairline,
                        start = Offset(hx, 0f),
                        end = Offset(hx, h),
                        strokeWidth = 1f,
                    )
                }
            }
        }
        if (showsAxis && onsetTs != null && wakeTs != null) {
            ClockLabelRow(onsetTs, wakeTs)
        }
    }
}

/** Display-smoothing floor for [FilledHypnogram] — 5 min, matching the WHOOP-style Swift `Hypnogram`
 *  default (not the classic rows' 90s). The stepped single-chart view reads as a comb of thin spikes on a
 *  fragmented / under-detected night unless brief fragments coalesce into legible blocks; render-only, so
 *  totals/percentages are untouched. */
private const val FILLED_HYPNOGRAM_SMOOTH_SEC = 300.0

/** One-line a11y summary of the smoothed hypnogram (stage count) — the collapsed node for [FilledHypnogram]. */
private fun hypnogramSummaryFor(intervals: List<StageInterval>): String =
    if (intervals.isEmpty()) "Sleep stages, no data" else "Sleep stage timeline, ${intervals.size} segments"

/**
 * The onset · midpoint · wake clock-label row under a night timeline. Extracted from
 * [HypnogramWithAxis] so the #988 stage-timeline rows share the exact same axis rendering.
 */
@Composable
internal fun ClockLabelRow(onsetTs: Long, wakeTs: Long) {
    val onset = clockTimeLabel(onsetTs)
    val mid = clockTimeLabel((onsetTs + wakeTs) / 2L)
    val wake = clockTimeLabel(wakeTs)
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            onset,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Start,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Text(
            mid,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Text(
            wake,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.End,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
    }
}

/** Map a stage name to its design-system sleep tone (case-insensitive). Keys off [canonicalStage]
 *  rather than repeating the trim/lowercase/"wake"-fold, so a new alias added there is picked up
 *  here automatically instead of needing a matching edit. Unknown stages fall back to the Light
 *  tone, as they did before. */
private fun stageColorFor(name: String): Color = when (canonicalStage(name)) {
    "deep" -> Palette.sleepDeep
    "rem" -> Palette.sleepREM
    "light" -> Palette.sleepLight
    "awake" -> Palette.sleepAwake
    else -> Palette.sleepLight
}
