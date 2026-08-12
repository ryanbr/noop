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
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import android.text.format.DateFormat
import java.util.TimeZone
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
        StageBreakdownRow("REM", s.rem, s.total, Palette.sleepREM, stageSharePercent("REM", s))
        StageBreakdownRow("Deep", s.deep, s.total, Palette.sleepDeep, stageSharePercent("Deep", s))
        StageBreakdownRow("Light", s.light, s.total, Palette.sleepLight, stageSharePercent("Light", s))
        StageBreakdownRow("Awake", s.awake, s.total, Palette.sleepAwake, stageSharePercent("Awake", s))
    }
}

/**
 * One WHOOP-style stage row. `fraction = minutes / total` sets the PipBar fill; `percent` is the night's
 * apportioned share (so the four rows sum to 100). Mirrors the macOS SleepView.stageBreakdownRow.
 */
@Composable
private fun StageBreakdownRow(stage: String, minutes: Double, total: Double, color: Color, percent: Int) {
    val fraction = if (total > 0.0) (minutes / total).coerceIn(0.0, 1.0) else 0.0
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
    // true → each stage FILLS its column to the baseline (the stepped-area look). false → a slim uniform
    // RIBBON at each stage level (the WHOOP-style stepped line), which reads cleaner on a fragmented night.
    filled: Boolean = true,
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
    // Responsive time axis: exact onset/wake at the edges + round-hour marks between, MORE marks on a wider
    // screen. Empty when the night has no clock window (no axis then).
    // ~60dp per label so a phone (~360dp) budgets ~6 -> fills the interior with round-hour marks instead of
    // stranding the axis at just onset/mid/wake; a tablet fans out to the 8-label ceiling. Floor 4 keeps a
    // narrow phone from collapsing back to bare edges.
    val maxAxisLabels = (LocalConfiguration.current.screenWidthDp / 60).coerceIn(4, 8)
    val is24h = DateFormat.is24HourFormat(LocalContext.current)
    val axisTicks = if (showsAxis) hypnogramAxisTicks(onsetTs!!, wakeTs!!, maxAxisLabels, is24h) else emptyList()
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
            // FILLED: each stage from its level DOWN to the baseline (sharp rects tile seamlessly into one
            // continuous staircase). RIBBON: a slim uniform band centred at the stage level — the WHOOP-style
            // stepped line, lighter on a fragmented night where full columns amplify the noise.
            val ribbonThickness = 10.dp.toPx()
            intervals.forEach { iv ->
                val x0 = xOf(iv.startSec)
                val x1 = xOf(iv.endSec)
                val y = levelY(rankOf(iv.stage))
                val segW = (x1 - x0).coerceAtLeast(1.5f).coerceAtMost(w - x0)
                if (filled) {
                    drawRect(
                        color = stageColorFor(iv.stage),
                        topLeft = Offset(x0, y),
                        size = Size(segW, (h - y).coerceAtLeast(0f)),
                    )
                } else {
                    drawRect(
                        color = stageColorFor(iv.stage),
                        topLeft = Offset(x0, y - ribbonThickness / 2f),
                        size = Size(segW, ribbonThickness),
                    )
                }
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
            // Time-axis vertical hairlines at each label tick (onset · round hours · wake).
            axisTicks.forEach { (frac, _) ->
                val hx = w * frac
                drawLine(
                    color = Palette.hairline,
                    start = Offset(hx, 0f),
                    end = Offset(hx, h),
                    strokeWidth = 1f,
                )
            }
        }
        if (axisTicks.isNotEmpty()) {
            HypnogramTimeAxis(axisTicks)
        }
    }
}

/** Display-smoothing floor for [FilledHypnogram] — 5 min, matching the WHOOP-style Swift `Hypnogram`
 *  default (not the classic rows' 90s). The stepped single-chart view reads as a comb of thin spikes on a
 *  fragmented / under-detected night unless brief fragments coalesce into legible blocks; render-only, so
 *  totals/percentages are untouched. */
private const val FILLED_HYPNOGRAM_SMOOTH_SEC = 300.0

/**
 * Time-axis ticks for the stepped hypnogram: the EXACT onset (frac 0) and wake (frac 1) at the edges
 * (minute precision, [axisEdgeLabel]), plus round-hour marks between at a "nice" step chosen so the interior
 * count is ≤ [maxLabels]−2 — so a WIDER screen (larger [maxLabels]) shows MORE marks. Interior marks read as
 * the hour only ([axisHourLabel] — "06:00" / "6 AM"), which is shorter than an edge label, so more fit. Marks
 * within ~18% of either edge are dropped so a round-hour label can't collide with the onset/wake label.
 * [is24h] (from `DateFormat.is24HourFormat`) picks 12/24h formatting. Pure/unit-testable.
 */
internal fun hypnogramAxisTicks(
    onsetTs: Long,
    wakeTs: Long,
    maxLabels: Int,
    is24h: Boolean = true,
): List<Pair<Float, String>> {
    val span = (wakeTs - onsetTs).toDouble()
    if (span <= 0.0) return listOf(0f to axisEdgeLabel(onsetTs, is24h))
    val out = ArrayList<Pair<Float, String>>()
    out.add(0f to axisEdgeLabel(onsetTs, is24h))
    val spanHours = span / 3600.0
    val interiorTarget = (maxLabels - 2).coerceAtLeast(1)
    val stepH = intArrayOf(1, 2, 3, 4, 6, 8, 12).firstOrNull { spanHours / it <= interiorTarget + 0.5 } ?: 12
    val stepSec = stepH * 3600L
    // Align marks to LOCAL hour boundaries, not UNIX-epoch ones: on a half-hour-offset zone (e.g. UTC+5:30)
    // an epoch-aligned 3h step lands at local :30, and axisHourLabel's "HH:00" would then LIE. Local midnight
    // is a whole number of days (a multiple of stepSec for every stepH that divides 24), so shifting into
    // local-epoch space by the zone offset, aligning there, and shifting back puts every mark on a true :00.
    val offset = TimeZone.getDefault().getOffset(onsetTs * 1000L) / 1000L
    var t = (((onsetTs + offset) / stepSec) + 1L) * stepSec - offset // first LOCAL hour boundary after onset
    while (t < wakeTs) {
        val frac = ((t - onsetTs).toDouble() / span).toFloat()
        // Drop marks within ~18% of an edge so a round-hour label can't overlap the onset/wake label — sized
        // for the WIDER 12h edge ("10:25 AM"), plus half the mark's own width, on a phone.
        if (frac > 0.18f && frac < 0.82f) out.add(frac to axisHourLabel(t, is24h))
        t += stepSec
    }
    out.add(1f to axisEdgeLabel(wakeTs, is24h))
    return out
}

/**
 * Places [ticks] (fraction 0..1 → label) along a full-width row, each label CENTRED on its fraction and
 * clamped so the edge labels stay on-screen. A [Layout] (not a weighted Row) so round-hour marks sit at
 * their true time position rather than evenly spaced — the labels line up with the axis hairlines drawn at
 * the same fractions in the chart above.
 */
@Composable
private fun HypnogramTimeAxis(ticks: List<Pair<Float, String>>) {
    Layout(
        modifier = Modifier.fillMaxWidth(),
        content = {
            ticks.forEach { (_, label) ->
                Text(label, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
        },
    ) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0)) }
        val wpx = constraints.maxWidth
        val hpx = placeables.maxOfOrNull { it.height } ?: 0
        layout(wpx, hpx) {
            placeables.forEachIndexed { i, p ->
                val centerX = ticks[i].first * wpx
                val x = (centerX - p.width / 2f).roundToInt().coerceIn(0, (wpx - p.width).coerceAtLeast(0))
                p.place(x, 0)
            }
        }
    }
}

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
