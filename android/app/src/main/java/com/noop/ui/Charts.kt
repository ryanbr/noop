package com.noop.ui

import com.noop.analytics.StagePercentages
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Charts (pure Compose Canvas — dark, instrument-grade, no external library)
//
// Implements the shared chart contract used across the port. Every chart is
// null/empty-safe: with no usable data it renders nothing but a faint baseline
// (or, for the hypnogram, the inset well) so layouts never collapse or crash.
//
//   Sparkline  — tiny inline trend line, no axes
//   LineChart  — line with optional soft gradient fill, height driven by Modifier
//   BarChart   — vertical bars from a zero baseline
//   Hypnogram  — proportional sleep-stage strip (deep / rem / light / awake)

// MARK: - Accessibility summaries
//
// Each chart primitive contributes exactly ONE semantics node via `Modifier.clearAndSetSemantics`, so the
// Compose accessibility delegate never walks a per-bar/per-band/per-point subtree (the giant semantics
// tree the a11y walk re-copied on every scroll was a contributor to the #707 OOM). The node carries a
// concise spoken summary (count + latest/low/high, or per-stage totals) — O(1) instead of O(elements).
// These are pure helpers; they change NO drawing.

/** One-line spoken summary of a numeric series: count + latest + low/high. Empty → "No data". */
private fun seriesSummary(values: List<Double>, noun: String): String {
    val clean = values.filter { it.isFinite() }
    if (clean.isEmpty()) return "$noun, no data"
    val last = clean.last()
    val lo = clean.min()
    val hi = clean.max()
    return "$noun, ${clean.size} points, latest ${formatLineValue(last)}, " +
        "low ${formatLineValue(lo)}, high ${formatLineValue(hi)}"
}

/** Per-stage total summary for the Hypnogram (deep · REM · light · awake, naming only stages present). */
private fun hypnogramSummary(stages: List<Pair<String, Float>>): String {
    if (stages.isEmpty()) return "Sleep stages, no data"
    // Weights are relative widths, not minutes, so report the share of the night in each stage.
    val total = stages.map { if (it.second.isFinite() && it.second > 0f) it.second else 0f }.sum()
    if (total <= 0f) return "Sleep stages, no data"
    val order = listOf("deep", "rem", "light", "awake")
    val byStage = LinkedHashMap<String, Float>()
    for (key in order) byStage[key] = 0f
    stages.forEach { (name, w) ->
        val v = if (w.isFinite() && w > 0f) w else 0f
        val key = when (name.trim().lowercase()) {
            "deep" -> "deep"; "rem" -> "rem"; "light" -> "light"; "awake", "wake" -> "awake"; else -> "light"
        }
        byStage[key] = (byStage[key] ?: 0f) + v
    }
    // One apportionment (largest-remainder) over the four stages so the read-out shares sum to 100 rather
    // than 99/101 — same helper the visible breakdown rows use; absent stages get 0 and are skipped below.
    val shares = StagePercentages.wholePercentages(order.map { (byStage[it] ?: 0f).toDouble() })
    val parts = order.mapIndexedNotNull { i, key ->
        val v = byStage[key] ?: 0f
        if (v <= 0f || shares == null) null else {
            val label = if (key == "rem") "REM" else key.replaceFirstChar { it.uppercase() }
            "${shares[i]} percent $label"
        }
    }
    return if (parts.isEmpty()) "Sleep stages, no data" else "Sleep stages, " + parts.joinToString(", ")
}

// MARK: - Shared geometry helpers

/** Map a list of values into evenly-spaced points within [bounds], scaling y to the
 *  value range. A flat series (min == max) is centered vertically. Returns an empty
 *  list when there are fewer than two finite points. */
private fun pointsFor(
    values: List<Double>,
    width: Float,
    height: Float,
    topPad: Float,
    bottomPad: Float,
): List<Offset> {
    val clean = values.filter { it.isFinite() }
    if (clean.size < 2 || width <= 0f || height <= 0f) return emptyList()
    return pointsFor(clean, width, height, topPad, bottomPad, clean.min(), clean.max())
}

private fun pointsFor(
    values: List<Double>,
    width: Float,
    height: Float,
    topPad: Float,
    bottomPad: Float,
    minV: Double,
    maxV: Double,
): List<Offset> {
    if (values.size < 2 || width <= 0f || height <= 0f) return emptyList()

    val span = (maxV - minV)
    val usableH = (height - topPad - bottomPad).coerceAtLeast(1f)
    val stepX = if (values.size > 1) width / (values.size - 1) else width

    return values.mapIndexed { i, v ->
        val x = stepX * i
        val norm = if (span > 0.0) ((v - minV) / span).toFloat() else 0.5f
        val y = topPad + (1f - norm) * usableH
        Offset(x, y)
    }
}

/** Draw the faint zero/empty baseline used when there is nothing to plot. */
private fun DrawScope.drawBaseline(color: Color = Palette.hairline) {
    val y = size.height / 2f
    drawLine(
        color = color.copy(alpha = StrandAlpha.subtleLine),
        start = Offset(0f, y),
        end = Offset(size.width, y),
        strokeWidth = 1f,
        cap = StrokeCap.Round,
    )
}

// MARK: - Sparkline

/**
 * Tiny inline line, no axes — for use inside tiles and list rows. Draws a single
 * smooth-capped stroke spanning the full width. Empty/flat data renders a baseline.
 */
@Composable
fun Sparkline(
    values: List<Double>,
    modifier: Modifier = Modifier,
    color: Color = Palette.accent,
) {
    // PERF (#scroll-jank): the point mapping + Path were rebuilt inside the Canvas draw lambda EVERY
    // frame. drawWithCache tessellates the Path ONCE (keyed on the values + size — the cache block
    // re-runs only when those change) and the cached draw lambda just replays it on every scroll frame.
    // Pixel-identical: same pointsFor geometry, same strokePx/cap/join, same empty→drawBaseline state.
    // ONE collapsed semantics node (see "Accessibility summaries"): the delegate reads a single trend
    // summary instead of walking the canvas. clearAndSetSemantics drops any child nodes (there are none
    // here) and contributes exactly this contentDescription. Changes no drawing.
    val axSummary = seriesSummary(values, "Trend")
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(Metrics.sparklineHeight)
            .clearAndSetSemantics { contentDescription = axSummary }
            .drawWithCache {
                val strokePx = 2f
                val pad = strokePx
                val pts = pointsFor(values, size.width, size.height, pad, pad)
                if (pts.isEmpty()) {
                    onDrawBehind { drawBaseline() }
                } else {
                    val path = Path().apply {
                        moveTo(pts.first().x, pts.first().y)
                        for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                    }
                    val stroke = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round)
                    onDrawBehind {
                        drawPath(path = path, color = color, style = stroke)
                    }
                }
            },
    )
}

// MARK: - LineChart

/**
 * Line chart with an optional soft vertical gradient fill under the curve. Height is
 * taken from [modifier] (e.g. `Modifier.height(Metrics.chartHeight)`). A faint
 * baseline shows when data is empty. No axes/labels — the surrounding card supplies
 * context, keeping the chart instrument-grade.
 */
@Composable
fun LineChart(
    values: List<Double>,
    modifier: Modifier,
    color: Color = Palette.accent,
    fill: Boolean = true,
    // Default OFF so the long-standing static LineCharts across the app (Today HR, Stress, Apple
    // Health, Trends Explore, the Health HR section) stay static; the screens that want the new
    // tap/swipe-to-inspect interaction opt in explicitly (Sleep, Trends, the Vital Signs detail).
    selectionEnabled: Boolean = false,
    dragSelectionEnabled: Boolean = true,
    // Selection-label formatter (#463): the tap/drag pinpoint read-out draws the RAW plotted value by
    // default; screens whose surrounding chrome converts values for display (Trends' Effort chart on
    // the 0-21 scale) pass their axis formatter so the label can't leak the stored scale as a bare
    // unconverted number. Default null keeps every other caller byte-identical.
    formatValue: ((Double) -> String)? = null,
    // Optional per-point unix-second timestamps, index-aligned with [values]: when supplied, the
    // tap/drag pinpoint read-out prefixes the selected sample's local clock time ("14:32 · 87 bpm").
    timestamps: List<Long>? = null,
    // Optional per-point display labels, index-aligned with [values]. Daily charts use this for a
    // human-readable date prefix ("16 Jul · 87"); live charts keep using [timestamps].
    selectionLabels: List<String>? = null,
) {
    val cleanValues = remember(values) { values.filter { it.isFinite() } }
    // Timestamps filtered by the SAME finiteness cut as cleanValues so indices stay aligned;
    // dropped entirely on a length mismatch rather than mislabelling times.
    val cleanTimestamps = remember(values, timestamps) {
        if (timestamps == null || timestamps.size != values.size) null
        else values.indices.filter { values[it].isFinite() }.map { timestamps[it] }
    }
    val cleanSelectionLabels = remember(values, selectionLabels) {
        if (selectionLabels == null || selectionLabels.size != values.size) null
        else values.indices.filter { values[it].isFinite() }.map { selectionLabels[it] }
    }
    var selectedIndex by remember(cleanValues) { mutableIntStateOf(-1) }
    val interactiveModifier = if (selectionEnabled) {
        Modifier
            .pointerInput(cleanValues) {
                detectTapGestures(
                    onTap = { offset ->
                        if (cleanValues.size >= 2 && size.width > 0) {
                            selectedIndex = nearestIndexForX(
                                count = cleanValues.size,
                                width = size.width.toFloat(),
                                x = offset.x,
                            )
                        }
                    },
                )
            }
            .then(
                if (dragSelectionEnabled) {
                    Modifier.pointerInput(cleanValues) {
                        detectHorizontalDragGestures(
                            onDragStart = { start ->
                                if (cleanValues.size < 2 || size.width <= 0f) return@detectHorizontalDragGestures
                                selectedIndex = nearestIndexForX(
                                    count = cleanValues.size,
                                    width = size.width.toFloat(),
                                    x = start.x,
                                )
                            },
                            onHorizontalDrag = { change, _ ->
                                if (cleanValues.size < 2 || size.width <= 0f) return@detectHorizontalDragGestures
                                selectedIndex = nearestIndexForX(
                                    count = cleanValues.size,
                                    width = size.width.toFloat(),
                                    x = change.position.x,
                                )
                                change.consume()
                            },
                        )
                    }
                } else {
                    Modifier
                },
            )
    } else {
        Modifier
    }

    // ONE collapsed semantics node for the whole chart (line + fill + selection marker subtree) so the
    // accessibility delegate reads a single trend summary rather than descending into the canvas. The
    // summary uses the same finite-filtered values the line draws. Changes no drawing or interaction.
    val axSummary = seriesSummary(cleanValues, "Trend")
    Box(
        modifier = modifier
            .fillMaxWidth()
            // Clip drawing to the chart bounds so the gradient fill (which runs to
            // size.height with no bottom pad) and the round-capped stroke can't bleed
            // past the edges. Compose Canvas does NOT clip by default — macOS parity for
            // TrendChart.swift's `.chartPlotStyle { $0.clipped() }` + `.clipped()`.
            .clipToBounds()
            .clearAndSetSemantics { contentDescription = axSummary }
            .then(interactiveModifier),
    ) {
        // PERF (#scroll-jank): the fill Path, the line Path AND the verticalGradient Brush were all
        // rebuilt inside the draw lambda every frame. Hoist the whole STATIC chart (baseline / fill /
        // line) into drawWithCache, keyed on (cleanValues, color, fill) + the implicit size — it
        // tessellates once and replays on scroll. The fast-moving SELECTION marker stays in a thin
        // separate drawWithContent overlay so a cursor drag re-issues only the marker, never the chart.
        // The pre-laid Paint for the value label is remembered, not allocated per draw. Pixel-identical:
        // same pointsFor geometry, same strokePx/pads, same gradient stops, same marker + label drawing.
        val markerPaint = remember(color) {
            android.graphics.Paint().apply {
                isAntiAlias = true
                textSize = 30f
                this.color = color.copy(alpha = StrandAlpha.chartLabel).toArgb()
                typeface = android.graphics.Typeface.create(
                    android.graphics.Typeface.DEFAULT,
                    android.graphics.Typeface.BOLD,
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawWithCache {
                    val strokePx = 2.5f
                    val topPad = strokePx + 4f
                    val bottomPad = strokePx + 4f
                    val pts = pointsFor(cleanValues, size.width, size.height, topPad, bottomPad)
                    if (pts.isEmpty()) {
                        onDrawBehind { drawBaseline() }
                    } else {
                        val fillPath = if (fill) {
                            Path().apply {
                                moveTo(pts.first().x, size.height)
                                lineTo(pts.first().x, pts.first().y)
                                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                                lineTo(pts.last().x, size.height)
                                close()
                            }
                        } else {
                            null
                        }
                        val fillBrush = if (fill) {
                            Brush.verticalGradient(
                                colors = listOf(
                                    color.copy(alpha = StrandAlpha.chartFillStrong),
                                    color.copy(alpha = StrandAlpha.chartFillSoft),
                                    Color.Transparent,
                                ),
                                startY = 0f,
                                endY = size.height,
                            )
                        } else {
                            null
                        }
                        val linePath = Path().apply {
                            moveTo(pts.first().x, pts.first().y)
                            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                        }
                        val lineStroke = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round)
                        onDrawBehind {
                            // Soft gradient fill under the curve.
                            if (fillPath != null && fillBrush != null) {
                                drawPath(path = fillPath, brush = fillBrush)
                            }
                            // The line itself.
                            drawPath(path = linePath, color = color, style = lineStroke)
                        }
                    }
                }
                // Tap-to-pinpoint marker — a thin per-frame overlay so a drag rebuilds only this, not
                // the chart. Recomputes the single selected point from the same pointsFor geometry.
                .drawWithContent {
                    drawContent()
                    if (selectionEnabled && selectedIndex >= 0) {
                        val strokePx = 2.5f
                        val topPad = strokePx + 4f
                        val bottomPad = strokePx + 4f
                        val pts = pointsFor(cleanValues, size.width, size.height, topPad, bottomPad)
                        if (selectedIndex in pts.indices) {
                            val p = pts[selectedIndex]
                            drawLine(
                                color = color.copy(alpha = StrandAlpha.chartMarker),
                                start = Offset(p.x, 0f),
                                end = Offset(p.x, size.height),
                                strokeWidth = 1.5f,
                                cap = StrokeCap.Round,
                            )
                            drawCircle(color = color, radius = 5f, center = p)
                            drawCircle(color = Palette.surfaceBase.copy(alpha = StrandAlpha.chartShadow), radius = 9f, center = p)
                            drawCircle(color = color, radius = 4.5f, center = p)
                            drawContext.canvas.nativeCanvas.apply {
                                val label = lineChartSelectionLabel(
                                    value = cleanValues[selectedIndex],
                                    formatValue = formatValue,
                                    epochSec = cleanTimestamps?.getOrNull(selectedIndex),
                                    pointLabel = cleanSelectionLabels?.getOrNull(selectedIndex),
                                )
                                drawText(label, 8f, 32f, markerPaint)
                            }
                        }
                    }
                },
        )
    }
}

data class LineSeries(
    val values: List<Double>,
    val color: Color,
)

@Composable
fun MultiLineChart(
    series: List<LineSeries>,
    modifier: Modifier,
) {
    val cleanSeries = remember(series) {
        series.map { it.copy(values = it.values.filter { value -> value.isFinite() }) }
            .filter { it.values.size >= 2 }
    }

    // ONE collapsed semantics node: summarise across all series (count of lines + overall low/high) so
    // the a11y delegate reads a single line rather than walking the canvas. Changes no drawing.
    val axSummary = run {
        val all = cleanSeries.flatMap { it.values }
        if (all.isEmpty()) "Trends, no data"
        else "Trends, ${cleanSeries.size} series, low ${formatLineValue(all.min())}, high ${formatLineValue(all.max())}"
    }

    Canvas(modifier = modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = axSummary }) {
        if (cleanSeries.isEmpty()) {
            drawBaseline()
            return@Canvas
        }

        val allValues = cleanSeries.flatMap { it.values }
        val minV = allValues.minOrNull() ?: return@Canvas
        val maxV = allValues.maxOrNull() ?: return@Canvas
        val strokePx = 2.5f
        val topPad = strokePx + 4f
        val bottomPad = strokePx + 4f

        cleanSeries.forEach { line ->
            val pts = pointsFor(line.values, size.width, size.height, topPad, bottomPad, minV, maxV)
            if (pts.isEmpty()) return@forEach
            val path = Path().apply {
                moveTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            }
            drawPath(
                path = path,
                color = line.color,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

private fun nearestIndexForX(count: Int, width: Float, x: Float): Int {
    if (count <= 1 || width <= 0f) return 0
    val step = width / (count - 1)
    val clampedX = x.coerceIn(0f, width)
    val raw = (clampedX / step).roundToInt()
    return raw.coerceIn(0, count - 1)
}

/** The tap/drag pinpoint label: the caller's display formatter when supplied (#463), else the raw
 *  near-integer-collapsing default. A non-blank [pointLabel] prefixes the formatted value; otherwise
 *  [epochSec] prefixes its local clock time ("14:32 · 87 bpm"). Split out so each choice is
 *  JVM-testable. */
internal fun lineChartSelectionLabel(
    value: Double,
    formatValue: ((Double) -> String)?,
    epochSec: Long? = null,
    zone: ZoneId = ZoneId.systemDefault(),
    pointLabel: String? = null,
): String {
    val base = formatValue?.invoke(value) ?: formatLineValue(value)
    pointLabel?.takeIf { it.isNotBlank() }?.let { return "$it · $base" }
    if (epochSec == null) return base
    val time = Instant.ofEpochSecond(epochSec).atZone(zone).format(chartTickTimeFormat)
    return "$time · $base"
}

private fun formatLineValue(value: Double): String {
    if (!value.isFinite()) return "-"
    val rounded = value.roundToInt().toDouble()
    return if (abs(value - rounded) < 0.05) {
        rounded.toInt().toString()
    } else {
        String.format(Locale.US, "%.1f", value)
    }
}

private fun nearestBarIndexForX(count: Int, width: Float, x: Float): Int {
    if (count <= 1 || width <= 0f) return 0
    val slot = width / count
    val clampedX = x.coerceIn(0f, width)
    return (clampedX / slot).toInt().coerceIn(0, count - 1)
}

// MARK: - BarChart

/**
 * Vertical bars from a zero baseline. Bars are scaled to the maximum value so the
 * tallest fills the plot height. Negative/non-finite values are treated as zero.
 * Empty data renders a faint baseline.
 */
@Composable
fun BarChart(
    values: List<Double>,
    modifier: Modifier,
    color: Color = Palette.accent,
    selectionEnabled: Boolean = false,
    // Optional per-point display labels index-aligned with [values]; when supplied, a tap shows
    // "<label> · <value>" (e.g. "16 Jul · 87") instead of the bare value — parity with LineChart (#691).
    selectionLabels: List<String>? = null,
) {
    val cleanValues = remember(values) { values.map { if (it.isFinite() && it > 0.0) it else 0.0 } }
    // cleanValues ZEROES (never drops) non-finite bars, so indices stay aligned with [values] and the
    // labels only need a size match — null when absent/mismatched so selection falls back to value-only.
    val cleanSelectionLabels = remember(values, selectionLabels) {
        if (selectionLabels == null || selectionLabels.size != values.size) null else selectionLabels
    }
    var selectedIndex by remember(cleanValues) { mutableIntStateOf(-1) }
    // Pre-laid value-label Paint, remembered rather than allocated inside the draw block (the old code
    // built a fresh android.graphics.Paint every draw). Keyed on color so it tracks a tint change.
    val barLabelPaint = remember(color) {
        android.graphics.Paint().apply {
            isAntiAlias = true
            textSize = 30f
            this.color = color.copy(alpha = StrandAlpha.chartLabel).toArgb()
            typeface = android.graphics.Typeface.create(
                android.graphics.Typeface.DEFAULT,
                android.graphics.Typeface.BOLD,
            )
        }
    }
    val unselectedColor = remember(color) { color.copy(alpha = StrandAlpha.unselectedBar) }

    // ONE collapsed semantics node so the a11y delegate reads a single bar-series summary instead of
    // walking every bar. Summarises the (zeroed-non-finite) source values the bars are scaled from.
    val axSummary = seriesSummary(cleanValues, "Bars")
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = axSummary }
            .then(
                if (selectionEnabled) {
                    Modifier.pointerInput(cleanValues) {
                        detectTapGestures(
                            onTap = { offset ->
                                if (cleanValues.isNotEmpty() && size.width > 0) {
                                    selectedIndex = nearestBarIndexForX(
                                        count = cleanValues.size,
                                        width = size.width.toFloat(),
                                        x = offset.x,
                                    )
                                }
                            },
                        )
                    }
                } else {
                    Modifier
                },
            )
            // PERF (#scroll-jank): the per-bar geometry (max, slot, bar width/height, x positions) was
            // recomputed inside the Canvas draw lambda every frame. Hoist the geometry into
            // drawWithCache (keyed on cleanValues + the implicit size) into a list of bar segments; the
            // onDrawBehind just replays them — and reads selectedIndex per-frame so a tap re-tints one
            // bar without rebuilding geometry. When values can exceed the pixel width the source is
            // mean-bucket-downsampled to ~one bar per horizontal pixel first (visually identical: a 0.64×
            // bar at sub-pixel slots was an unreadable smear; the bucket mean preserves the silhouette).
            .drawWithCache {
                val w = size.width
                val h = size.height
                // Mean-bucket-downsample so there is at most ~one bar per horizontal pixel. Above that the
                // 0.64×-slot bars overlap into a solid block anyway, so the bucket mean is pixel-identical
                // while cutting the bar count (and the per-frame work) to the visible resolution.
                // Only downsample when selection is OFF: an interactive BarChart maps the user's tapped
                // selectedIndex against the FULL-resolution cleanValues, so collapsing the drawn bars
                // would desync the highlight + label. Interactive charts carry small bounded counts
                // (days), so they never hit this path anyway; the downsample targets dense static bars.
                val maxBars = w.toInt().coerceAtLeast(1)
                val clean = if (!selectionEnabled && cleanValues.size > maxBars && maxBars >= 1) {
                    meanBucketDownsample(cleanValues, maxBars)
                } else {
                    cleanValues
                }
                val maxV = clean.maxOrNull() ?: 0.0
                if (clean.isEmpty() || maxV <= 0.0 || w <= 0f || h <= 0f) {
                    onDrawBehind { drawBaseline() }
                } else {
                    val topPad = 4f
                    val usableH = (h - topPad).coerceAtLeast(1f)
                    val slot = w / clean.size
                    val barWidth = (slot * 0.64f).coerceAtLeast(1f)
                    val capRadius = (barWidth / 2f)
                    // Precompute each bar's x centre + top y once.
                    data class BarSeg(val cx: Float, val top: Float)
                    val bars = ArrayList<BarSeg>(clean.size)
                    clean.forEachIndexed { i, v ->
                        val norm = (v / maxV).toFloat().coerceIn(0f, 1f)
                        val barHeight = (norm * usableH).coerceAtLeast(if (v > 0.0) 1f else 0f)
                        if (barHeight <= 0f) return@forEachIndexed
                        val cx = slot * i + slot / 2f
                        val top = h - barHeight
                        bars.add(BarSeg(cx, top))
                    }
                    onDrawBehind {
                        bars.forEachIndexed { i, seg ->
                            drawLine(
                                color = if (selectionEnabled && i == selectedIndex) color else unselectedColor,
                                start = Offset(seg.cx, h),
                                end = Offset(seg.cx, (seg.top + capRadius).coerceAtMost(h)),
                                strokeWidth = barWidth,
                                cap = StrokeCap.Round,
                            )
                        }
                        if (selectionEnabled && selectedIndex in clean.indices) {
                            drawContext.canvas.nativeCanvas.apply {
                                drawText(
                                    lineChartSelectionLabel(
                                        value = clean[selectedIndex],
                                        formatValue = null,
                                        pointLabel = cleanSelectionLabels?.getOrNull(selectedIndex),
                                    ),
                                    8f, 32f, barLabelPaint,
                                )
                            }
                        }
                    }
                }
            },
    )
}

/** Mean-bucket-downsample [values] to about [target] buckets, averaging each contiguous run. Used so a
 *  BarChart with more values than horizontal pixels collapses to ~one bar per pixel without changing the
 *  visible silhouette. Returns the input unchanged when it already fits. */
private fun meanBucketDownsample(values: List<Double>, target: Int): List<Double> {
    val n = values.size
    if (target < 1 || n <= target) return values
    val out = ArrayList<Double>(target)
    for (b in 0 until target) {
        val lo = (b.toLong() * n / target).toInt()
        val hi = (((b + 1).toLong() * n / target).toInt()).coerceAtMost(n)
        if (hi <= lo) { out.add(values[lo.coerceIn(0, n - 1)]); continue }
        var sum = 0.0
        for (i in lo until hi) sum += values[i]
        out.add(sum / (hi - lo))
    }
    return out
}

// MARK: - Hypnogram

/**
 * Proportional sleep-stage strip. [stages] is an ordered list of (stageName,
 * fractionOfWidth) where fractions are taken as relative weights and normalized to
 * fill the available width. Stage names are matched case-insensitively to the
 * design-system sleep palette:
 *
 *   "deep"  → Palette.sleepDeep      "rem"   → Palette.sleepREM
 *   "light" → Palette.sleepLight     "awake" → Palette.sleepAwake
 *
 * Unknown names fall back to the light tone. Empty/zero-weight input renders the
 * inset well so the row keeps its height.
 */
@Composable
fun Hypnogram(
    stages: List<Pair<String, Float>>,
    modifier: Modifier,
) {
    // PERF (#scroll-jank): the weights sum + per-segment fraction/width geometry was recomputed inside
    // the Canvas draw lambda every frame. Hoist it into drawWithCache (keyed on stages + the implicit
    // size) as a list of (color,left,width) segments; the onDrawBehind just replays them. The inset
    // well + the empty/zero-weight state are preserved exactly.
    // ONE collapsed semantics node (per-stage share) so the a11y delegate reads a single sleep-stage
    // summary instead of walking each band — the Android twin of the iOS Hypnogram's single node.
    val axSummary = hypnogramSummary(stages)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(Metrics.segmentBarHeight)
            .clearAndSetSemantics { contentDescription = axSummary }
            .drawWithCache {
                val w = size.width
                val h = size.height
                val weights = stages.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
                val total = weights.sum()
                if (w <= 0f || h <= 0f || stages.isEmpty() || total <= 0f) {
                    // Inset well only (or nothing if degenerate) — matches the old baseline-only state.
                    onDrawBehind {
                        if (w > 0f && h > 0f) drawRoundedTrack(Palette.surfaceInset)
                    }
                } else {
                    val segs = ArrayList<Triple<Color, Float, Float>>(stages.size)
                    var x = 0f
                    val gap = if (stages.size > 1) 1.5f else 0f
                    stages.forEachIndexed { i, (name, _) ->
                        val frac = weights[i] / total
                        val segW = (w * frac)
                        if (segW <= 0f) return@forEachIndexed
                        val drawW = (segW - if (i < stages.size - 1) gap else 0f).coerceAtLeast(0f)
                        if (drawW > 0f) segs.add(Triple(stageColor(name), x, drawW))
                        x += segW
                    }
                    onDrawBehind {
                        // Inset well background so the strip reads as a recessed track.
                        drawRoundedTrack(Palette.surfaceInset)
                        segs.forEach { (c, left, width) ->
                            drawSegment(color = c, left = left, width = width, height = h)
                        }
                    }
                }
            },
    )
}

// MARK: - SegmentBar

/**
 * Generic proportional color strip (the Hypnogram geometry with caller-supplied colors).
 * [segments] is an ordered list of (color, weight); weights are normalized to fill the
 * width. Zero/NaN weights are skipped. Empty/zero input renders the inset well so rows
 * keep their height.
 */
@Composable
fun SegmentBar(
    segments: List<Pair<Color, Float>>,
    modifier: Modifier,
    height: Dp = Metrics.segmentBarHeight,
) {
    // PERF (#scroll-jank): same hoist as Hypnogram — the weight sum + per-segment widths move into
    // drawWithCache (keyed on segments + the implicit size); the draw lambda replays the segment list.
    // ONE collapsed semantics node so the a11y delegate doesn't walk each segment. The segments are a
    // caller-supplied colour breakdown with no inherent label, so the summary is just the segment count.
    val axSummary = if (segments.isEmpty()) "Breakdown, no data" else "Breakdown, ${segments.size} segments"
    Box(modifier = modifier.fillMaxWidth().height(height).clearAndSetSemantics { contentDescription = axSummary }.drawWithCache {
        val w = size.width
        val h = size.height
        val weights = segments.map { it.second }.map { if (it.isFinite() && it > 0f) it else 0f }
        val total = weights.sum()
        if (w <= 0f || h <= 0f || segments.isEmpty() || total <= 0f) {
            onDrawBehind {
                if (w > 0f && h > 0f) drawRoundedTrack(Palette.surfaceInset)
            }
        } else {
            val segs = ArrayList<Triple<Color, Float, Float>>(segments.size)
            var x = 0f
            val gap = if (segments.size > 1) 1.5f else 0f
            segments.forEachIndexed { i, (color, _) ->
                val frac = weights[i] / total
                val segW = w * frac
                if (segW <= 0f) return@forEachIndexed
                val drawW = (segW - if (i < segments.size - 1) gap else 0f).coerceAtLeast(0f)
                if (drawW > 0f) segs.add(Triple(color, x, drawW))
                x += segW
            }
            onDrawBehind {
                drawRoundedTrack(Palette.surfaceInset)
                segs.forEach { (c, left, width) -> drawSegment(color = c, left = left, width = width, height = h) }
            }
        }
    })
}

private fun DrawScope.drawRoundedTrack(color: Color) {
    drawLine(
        color = color,
        start = Offset(0f, size.height / 2f),
        end = Offset(size.width, size.height / 2f),
        strokeWidth = size.height,
        cap = StrokeCap.Round,
    )
}

private fun DrawScope.drawSegment(color: Color, left: Float, width: Float, height: Float) {
    val cap = (height / 2f).coerceAtMost(width / 2f)
    drawLine(
        color = color,
        start = Offset(left + cap, height / 2f),
        end = Offset((left + width - cap).coerceAtLeast(left + cap), height / 2f),
        strokeWidth = height,
        cap = StrokeCap.Round,
    )
}

/** Map a stage name to its design-system sleep tone (case-insensitive). */
private fun stageColor(name: String): Color = when (name.trim().lowercase()) {
    "deep" -> Palette.sleepDeep
    "rem" -> Palette.sleepREM
    "light" -> Palette.sleepLight
    "awake", "wake" -> Palette.sleepAwake
    else -> Palette.sleepLight
}

// MARK: - Deep Timeline chart (#575) — time-indexed, zoom + pan
//
// A time-aware line (each point carries its own unix-second timestamp, unlike the evenly-spaced
// LineChart) over a visible [windowStart, windowEnd] window, with pinch-to-zoom + drag-to-pan via
// detectTransformGestures. The Swift twin is OverviewHRChart's zoom binding. The point COUNT stays low
// because the read layer downsamples to the zoom window (TimelinePoint list is ~targetPoints) — the
// chart never receives ~86k points. Mirrors macOS OverviewHRChart's gesture-driven x-domain.

/** One timeline sample: a unix-second timestamp + a value (bpm, °C, ms, …). */
data class TimelinePoint(val ts: Long, val value: Double)

/**
 * Pure adaptive-resolution decision shared with the macOS `Repository.timelineBucketSeconds`: the bucket
 * width (seconds) to read for a `[from, to]` window that should yield ABOUT [targetPoints] points. A
 * bucket of 1 means "read raw per-second rows". A day-scale window picks a coarse bucket (never raw); a
 * few-minute zoom drops to 1. Kept in Charts.kt so it's unit-testable without Room or a clock.
 */
fun timelineBucketSeconds(spanSeconds: Long, targetPoints: Int): Long {
    val span = spanSeconds.coerceAtLeast(1L)
    val target = targetPoints.coerceAtLeast(1)
    val ideal = span / target
    if (ideal <= 1L) return 1L
    val steps = longArrayOf(2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600)
    for (s in steps) if (s >= ideal) return s
    return steps.last()
}

/**
 * Scale [base] window about [anchorFraction] (0…1) by [scale] (>1 zooms in), clamped into [bounds] and
 * floored at [minSpan] seconds. Pure — the Compose twin of OverviewHRChart.zoomed.
 */
fun zoomedWindow(
    base: LongRange,
    scale: Float,
    anchorFraction: Float,
    bounds: LongRange,
    minSpan: Long = 60L,
): LongRange {
    val span = (base.last - base.first).coerceAtLeast(1L)
    if (scale <= 0f) return base
    val pivot = base.first + (span * anchorFraction.coerceIn(0f, 1f)).toLong()
    val boundsSpan = (bounds.last - bounds.first).coerceAtLeast(minSpan)
    val newSpan = (span / scale).toLong().coerceIn(minSpan, boundsSpan)
    var newLo = pivot - ((pivot - base.first).toDouble() * newSpan / span).toLong()
    var newHi = newLo + newSpan
    if (newLo < bounds.first) { newLo = bounds.first; newHi = newLo + newSpan }
    if (newHi > bounds.last) { newHi = bounds.last; newLo = newHi - newSpan }
    newLo = newLo.coerceAtLeast(bounds.first)
    return newLo..(newLo + newSpan).coerceAtLeast(newLo + 1)
}

// MARK: - Round-time x-axis ticks (prototype hr-chart-time-axis)

/** Shared "HH:mm" tick/readout clock format — one instance, DateTimeFormatter is thread-safe. */
private val chartTickTimeFormat = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

/**
 * Round wall-clock x-axis ticks for a `[startEpochSec, endEpochSec]` window: (epochSec, "HH:mm")
 * pairs at fixed round intervals chosen by the visible span (a full day ticks every 6h, a 1h zoom
 * every 15min). Ticks step in LOCAL wall-clock time from the window's local midnight — a window
 * crossing midnight labels "00:00" and DST labels stay round; java.time resolves the spring-forward
 * gap to a valid time and the epoch-dedupe drops the resulting double tick. Pure and clock-free
 * (ChartTimeTicksTest).
 */
fun chartTimeTicks(startEpochSec: Long, endEpochSec: Long, zone: ZoneId): List<Pair<Long, String>> {
    if (endEpochSec <= startEpochSec) return emptyList()
    val spanHours = (endEpochSec - startEpochSec) / 3600.0
    // Thresholds sit below the nominal Today-card windows (24h/12h/6h/3h/1h) so a window whose
    // banked data covers slightly less than nominal still lands on its intended interval.
    val stepMinutes = when {
        spanHours >= 20.0 -> 360L
        spanHours >= 10.0 -> 180L
        spanHours >= 5.0 -> 120L
        spanHours >= 2.0 -> 60L
        else -> 15L
    }
    var tick = Instant.ofEpochSecond(startEpochSec).atZone(zone).toLocalDate().atStartOfDay()
    val out = ArrayList<Pair<Long, String>>()
    var lastEpoch = Long.MIN_VALUE
    // Bounded walk: even a multi-day window at 15-min steps stays well under the guard.
    var guard = 0
    while (guard++ < 4096) {
        val zoned = tick.atZone(zone)
        val epoch = zoned.toEpochSecond()
        if (epoch > endEpochSec) break
        if (epoch in startEpochSec..endEpochSec && epoch > lastEpoch) {
            out.add(epoch to zoned.format(chartTickTimeFormat))
            lastEpoch = epoch
        }
        tick = tick.plusMinutes(stepMinutes)
    }
    return out
}

/**
 * Where wall-clock [ts] falls (0…1) across an INDEX-spaced line, interpolating between the
 * per-point [timestamps] exactly like OverviewHRChart's marker mapping — so a tick's gridline and
 * its axis label land on the same pixel even when the series has gaps. Null when [ts] is outside
 * the plotted extent (an off-window tick draws nothing rather than pinning to an edge).
 */
fun timestampFraction(timestamps: List<Long>, ts: Long): Float? {
    val n = timestamps.size
    if (n < 2) return null
    if (ts < timestamps.first() || ts > timestamps.last()) return null
    val hi = timestamps.indexOfFirst { it >= ts }
    if (hi <= 0) return 0f
    val lo = hi - 1
    val t0 = timestamps[lo]
    val t1 = timestamps[hi]
    val f = if (t1 > t0) (ts - t0).toFloat() / (t1 - t0).toFloat() else 0f
    return (lo + f) / (n - 1)
}

/** Pan [base] by [deltaSeconds], clamped into [bounds] (span preserved). Pure — twin of OverviewHRChart.panned. */
fun pannedWindow(base: LongRange, deltaSeconds: Long, bounds: LongRange): LongRange {
    val span = base.last - base.first
    var newLo = base.first + deltaSeconds
    newLo = newLo.coerceIn(bounds.first, (bounds.last - span).coerceAtLeast(bounds.first))
    return newLo..(newLo + span)
}

/**
 * The Deep Timeline chart: a line over [points] within the visible [windowStart, windowEnd], pinch to
 * zoom + drag to pan (both clamped to [bounds]). Reports the settled window via [onWindowChange] so the
 * host can re-read at the new resolution. Empty-safe: with no points it draws a faint baseline.
 */
@Composable
fun TimelineChart(
    points: List<TimelinePoint>,
    windowStart: Long,
    windowEnd: Long,
    bounds: LongRange,
    color: Color,
    modifier: Modifier,
    onWindowChange: (LongRange) -> Unit,
) {
    val span = (windowEnd - windowStart).coerceAtLeast(1L)
    val vis = remember(points, windowStart, windowEnd) {
        points.filter { it.ts in windowStart..windowEnd && it.value.isFinite() }
    }

    // ONE collapsed semantics node (summary of the VISIBLE window) so the a11y delegate reads a single
    // line instead of walking the canvas; recomputes as the zoom/pan window changes. Changes no drawing.
    val axSummary = seriesSummary(vis.map { it.value }, "Timeline")
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clipToBounds()
            .clearAndSetSemantics { contentDescription = axSummary }
            .pointerInput(bounds) {
                detectTransformGestures { centroid, pan, zoom, _ ->
                    val width = size.width.toFloat().coerceAtLeast(1f)
                    var window = windowStart..windowEnd
                    // Pinch zooms about the gesture centroid; pan shifts the window.
                    if (zoom != 1f) {
                        val frac = (centroid.x / width).coerceIn(0f, 1f)
                        window = zoomedWindow(window, zoom, frac, bounds)
                    }
                    if (pan.x != 0f) {
                        val curSpan = window.last - window.first
                        val secPerPx = curSpan.toDouble() / width
                        window = pannedWindow(window, (-pan.x * secPerPx).toLong(), bounds)
                    }
                    onWindowChange(window)
                }
            },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokePx = 2.5f
            val topPad = strokePx + 4f
            val bottomPad = strokePx + 4f
            if (vis.size < 2 || size.width <= 0f || size.height <= 0f) {
                drawBaseline()
                return@Canvas
            }
            val minV = vis.minOf { it.value }
            val maxV = vis.maxOf { it.value }
            val range = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
            val usable = (size.height - topPad - bottomPad).coerceAtLeast(1f)

            fun px(ts: Long): Float = ((ts - windowStart).toFloat() / span) * size.width
            fun py(v: Double): Float = topPad + ((maxV - v) / range).toFloat() * usable

            val linePath = Path().apply {
                moveTo(px(vis.first().ts), py(vis.first().value))
                for (i in 1 until vis.size) lineTo(px(vis[i].ts), py(vis[i].value))
            }
            // Soft gradient fill under the curve.
            val fillPath = Path().apply {
                moveTo(px(vis.first().ts), size.height)
                lineTo(px(vis.first().ts), py(vis.first().value))
                for (i in 1 until vis.size) lineTo(px(vis[i].ts), py(vis[i].value))
                lineTo(px(vis.last().ts), size.height)
                close()
            }
            drawPath(
                path = fillPath,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        color.copy(alpha = StrandAlpha.chartFillStrong),
                        color.copy(alpha = StrandAlpha.chartFillSoft),
                        Color.Transparent,
                    ),
                    startY = 0f,
                    endY = size.height,
                ),
            )
            drawPath(
                path = linePath,
                color = color,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}
