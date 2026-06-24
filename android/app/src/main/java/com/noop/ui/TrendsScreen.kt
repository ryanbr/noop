package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Trends
//
// The longitudinal view, ported from Strand/Screens/TrendsView.swift onto the locked
// Android component system so every surface, height and gap matches: one
// SegmentedPillControl for the range (W / M / 3M / 6M / 1Y / ALL), a hero Recovery
// ChartCard, and a uniform set of HRV / Resting HR / Day-strain ChartCards (all
// Metrics.chartHeight tall), followed by a recovery history strip.
//
// Windows are taken relative to the phone's actual local day, with the macOS auto-expand
// rule: if the selected window holds zero points for a metric, the smallest larger range
// that does is used and the card caption notes the widening.
//
// Data: full history is loaded once via repo.days("my-whoop"); until it arrives the
// reactive recentDays flow backs the charts, so the screen is never empty when data exists.
//
// Difference from macOS: the macOS Trends footer carries a YearHeatStrip calendar
// (a bespoke 53-week heat grid) that has no Android foundation equivalent. Rather than
// fake it, the "Recovery history" card renders the real per-day recovery series as a
// bar strip over the same window, with a short note pointing at the macOS calendar view.

@Composable
fun TrendsScreen(vm: AppViewModel) {
    // Reactive cache (oldest → newest) as the immediate backing.
    val reactiveDays by vm.recentDays.collectAsStateWithLifecycle()

    // Full history loaded once for the long (1Y / ALL) ranges; falls back to the flow
    // until it lands so the screen is populated on first frame when any data exists.
    var fullHistory by remember { mutableStateOf<List<DailyMetric>?>(null) }
    LaunchedEffect(Unit) {
        // Merged: imported WHOOP days win; on-device computed days gap-fill the trends.
        fullHistory = vm.repo.daysMerged("my-whoop")
    }
    val days = fullHistory ?: reactiveDays

    // Effort display scale (#268) — routes the Effort small-multiple's numbers + unit. Display-only.
    val effortScale = UnitPrefs.effortScale(LocalContext.current)

    var range by remember { mutableStateOf(TrendsRange.Quarter) }

    // Resolve each metric's window ONCE per composition and reuse below — mirrors the macOS resolve(_:)
    // so caption / widened / points aren't recomputed per use. HOISTED above the lazy scaffold: these
    // are @Composable `remember` hooks, which can't run inside the LazyListScope content lambda. They're
    // cheap memoized resolves (no-ops over an empty `days`), so the empty branch below simply ignores
    // them — same as Intelligence's hoisted range/filter. Mirrors the eager body's per-composition resolve.
    val recovery = remember(days, range) { resolveMetric(days, range) { it.recovery } }
    val hrv = remember(days, range) { resolveMetric(days, range) { it.avgHrv } }
    val rhr = remember(days, range) { resolveMetric(days, range) { it.restingHr?.toDouble() } }
    val strain = remember(days, range) { resolveMetric(days, range) { it.strain } }
    // Rest = the sleep_performance COMPOSITE (0–100) — the SAME metric the Today Rest score/tile and the
    // Sleep Rest-detail plot (#614 follow-up), NOT raw efficiency, which is a different number under the
    // same "Rest" label and made the Trends Rest graph disagree with the Today Rest score (#732).
    // sleep_performance is a metricSeries (imported-wins resolved), not a DailyMetric column, so fetch the
    // resolved series and key it by day for the existing windowing/widening below. Mirrors the source
    // TodayScreen's restScore reads, so the two screens now plot the same number.
    var sleepPerfByDay by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    LaunchedEffect(days) {
        sleepPerfByDay = runCatching {
            vm.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99")
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
    }
    val rest = remember(days, range, sleepPerfByDay) {
        resolveMetric(days, range) { d -> sleepPerfByDay[d.day] }
    }
    val recAvg = recovery.values.averageOrNull()

    LazyScreenScaffold(title = "Trends", subtitle = "The thread of you over time.") {
        if (days.isEmpty()) {
            item { EmptyTrends() }
            return@LazyScreenScaffold
        }

        // The main card list ripples in once on appear (Reduce-Motion safe), mirroring the iOS
        // staggeredAppear sequence — each top-level section is one staggered child.

        // --- Week-in-review digest (#208) — self-hides when this week has no data. ---
        item { Column(modifier = Modifier.staggeredAppear(index = 0)) { WeeklyDigestCard(vm) } }

        // --- Week in review — the Charge / Effort / Rest trio in NOOP's pip language (PipBar +
        // CountUpText), mirroring the iOS TrendsView.weekInReview card. White count-up numbers over
        // segmented count-up bars; self-hides when none of the three carry a window mean. ---
        item {
            WeekInReviewCard(
                charge = recovery,
                effort = strain,
                rest = rest,
                effortScale = effortScale,
                modifier = Modifier.staggeredAppear(index = 1),
            )
        }

        // --- Range control ---
        item {
            Column(
                modifier = Modifier.staggeredAppear(index = 2),
                verticalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SegmentedPillControl(
                        items = TrendsRange.entries.toList(),
                        selection = range,
                        label = { it.label },
                        onSelect = { range = it },
                    )
                    Spacer(Modifier.weight(1f))
                    Overline(range.subtitle, color = Palette.textTertiary)
                }
                Text(
                    recovery.caption,
                    style = NoopType.footnote,
                    color = if (recovery.widened) Palette.statusWarning else Palette.textTertiary,
                )
            }
        }

        // --- Hero — charge over time. Charge (green) world: domain card wash, a crisp flat line with a
        // bright "now" end-cap, and a TrendChip for the window's move. ---
        item {
            ChartCard(
                modifier = Modifier.staggeredAppear(index = 3),
                title = "Charge",
                // The range bar above already prints the authoritative reading-count caption;
                // the hero only names its window so the count isn't doubled in one card height.
                subtitle = range.subtitle,
                trailing = recAvg?.let { "${it.roundToInt()}" },
                color = Palette.chargeColor,
                tipColor = Palette.chargeBright,
                tint = Palette.chargeColor,
                values = recovery.values,
                dates = recovery.dates,
                formatY = { "${it.roundToInt()}" },
                change = periodChange(recovery.values),
                higherIsBetter = true,
                changeFmt = { "${it.roundToInt()}" },
                // Lift the ceiling ~6% so a near-100 peak and the now-cap halo clear the top gridline —
                // mirrors the iOS hero's `valueRange: 0...106`.
                chartHeadroom = 0.06f,
                footer = listOf(
                    "Avg" to (recAvg?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    "Peak" to (recovery.values.maxOrNull()?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    "Low" to (recovery.values.minOrNull()?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    "Days" to "${recovery.values.size}",
                ),
            )
        }

        // --- Small multiples — HRV / Resting HR / Effort. HRV/RHR are Charge sub-signals → the green
        // card world (each line keeps its metric hue); Effort is the WHOOP blue strain world. ---
        // No trailing window label — the range bar's overline already states it.
        item {
            Column(
                modifier = Modifier.staggeredAppear(index = 4),
                verticalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                SectionHeader("Daily signals", overline = "Trends")
                MetricTrendCard(
                    title = "Heart rate variability", unit = "ms",
                    color = Palette.metricPurple,
                    tint = Palette.chargeColor,
                    higherIsBetter = true,
                    resolved = hrv,
                    fmt = { "${it.roundToInt()}" },
                )
                MetricTrendCard(
                    title = "Resting heart rate", unit = "bpm",
                    color = Palette.metricRose,
                    tint = Palette.chargeColor,
                    higherIsBetter = false,
                    resolved = rhr,
                    fmt = { "${it.roundToInt()}" },
                )
                MetricTrendCard(
                    // Plotted values stay on the stored 0–100 scale (line shape unchanged); only the displayed
                    // numbers + unit follow the Effort-scale toggle, converted inside `fmt`. (#268)
                    title = "Effort", unit = "/ ${UnitFormatter.effortScaleMax(effortScale)}",
                    // WHOOP: Effort/Strain is always BLUE — a deep→bright blue line, not the amber ramp.
                    color = Palette.effortColor,
                    tint = Palette.effortColor,
                    tipColor = Palette.effortBright,
                    higherIsBetter = null,
                    resolved = strain,
                    fmt = { UnitFormatter.effortDisplay(it, effortScale) },
                )
            }
        }

        // --- Recovery history strip (stands in for the macOS YearHeatStrip) ---
        item {
            Column(modifier = Modifier.staggeredAppear(index = 5)) {
                RecoveryHistoryCard(days = days, range = range)
            }
        }

        // --- Export trends report (#436) — the shareable offline PDF exporter. Mirrors the iOS
        // TrendsView.exportReportRow footer; the same composable Settings hosts, so both surfaces
        // offer it. Routed through NoopButton like every other CTA (no gold). ---
        item {
            Column(modifier = Modifier.staggeredAppear(index = 6)) {
                TrendsReportExportSection(vm)
            }
        }
    }
}

// MARK: - Week in review — the Charge / Effort / Rest trio in pip language
//
// The three daily scores as NOOP pip rows over the resolved window: Charge (recovery, 0–100),
// Effort (strain, shown on the WHOOP 0–21 / 0–100 scale per the unit toggle) and Rest (sleep
// efficiency, 0–100). Each value ticks up via CountUpText; the segmented PipBar cascades on appear.
// Self-hides when none of the three carry a window mean. Mirrors iOS TrendsView.weekInReview.

@Composable
private fun WeekInReviewCard(
    charge: ResolvedMetric,
    effort: ResolvedMetric,
    rest: ResolvedMetric,
    effortScale: EffortScale,
    modifier: Modifier = Modifier,
) {
    val chargeAvg = charge.values.averageOrNull()
    val effortAvg = effort.values.averageOrNull() // stored 0–100 internal Effort scale
    val restAvg = rest.values.averageOrNull()
    if (chargeAvg == null && effortAvg == null && restAvg == null) return

    NoopCard(modifier = modifier, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionHeader("Week in review", overline = "Charge · Effort · Rest")
            if (chargeAvg != null) {
                PipScoreRow(
                    label = "Charge", value = chargeAvg, range = 0f..100f,
                    tint = Palette.chargeColor, format = { "${it.roundToInt()}" },
                )
            }
            if (effortAvg != null) {
                // Effort is stored 0–100 but reads on the user's chosen scale: convert the displayed
                // number AND the bar position so the pip fill and the count-up value agree. On WHOOP's
                // 0–21 scale Effort reads to one decimal; on 0–100 it's a whole number.
                val display = UnitFormatter.effortValue(effortAvg, effortScale)
                val maxV = UnitFormatter.effortValue(100.0, effortScale)
                val oneDecimal = effortScale == EffortScale.WHOOP
                PipScoreRow(
                    label = "Effort", value = display, range = 0f..maxV.toFloat(),
                    tint = Palette.effortColor,
                    format = { if (oneDecimal) String.format(Locale.US, "%.1f", it) else "${it.roundToInt()}" },
                )
            }
            if (restAvg != null) {
                PipScoreRow(
                    label = "Rest", value = restAvg, range = 0f..100f,
                    tint = Palette.restColor, format = { "${it.roundToInt()}" },
                )
            }
        }
    }
}

/**
 * One pip row matching PipBarRow's layout, but with the value driven by [CountUpText] so the big
 * number ticks up. UPPERCASE label + big white count-up value over the segmented count-up bar.
 * Mirrors iOS TrendsView.pipScoreRow.
 */
@Composable
private fun PipScoreRow(
    label: String,
    value: Double,
    range: ClosedFloatingPointRange<Float>,
    tint: Color,
    format: (Double) -> String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Text(
            text = label.uppercase(),
            style = NoopType.overline,
            color = Palette.textSecondary,
        )
        CountUpText(
            value = value,
            format = format,
            style = NoopType.number(30f, weight = FontWeight.Bold),
            color = Palette.textPrimary,
        )
        PipBar(value = value.toFloat(), range = range, tint = tint)
    }
}

// MARK: - Range control model (ported from TrendsView.Range)

/** W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL. */
private enum class TrendsRange(val days: Int?, val label: String, val longName: String) {
    Week(7, "W", "week"),
    Month(30, "M", "month"),
    Quarter(90, "3M", "3 months"),
    Half(180, "6M", "6 months"),
    Year(365, "1Y", "year"),
    All(null, "ALL", "all history");

    /** "Trailing 90 days" / "All history" — the card/range subtitle. */
    val subtitle: String get() = days?.let { "Trailing $it days" } ?: "All history"

    /** This range plus every LARGER range, ascending — the auto-expand search order. */
    val widening: List<TrendsRange>
        get() = entries.dropWhile { it != this }
}

// MARK: - Resolved metric (mirrors TrendsView.ResolvedMetric / resolve)

/** A metric's window: its plotted values + the day-string of each point, the range it
 *  resolved to, whether the selection was widened to find data, and the caption to show. */
private data class ResolvedMetric(
    val values: List<Double>,
    val dates: List<String>,
    val effective: TrendsRange,
    val widened: Boolean,
    val caption: String,
)

/**
 * Walk the widening order once: take the smallest range ≥ selected whose window holds
 * ≥1 non-null point for [value]; if none do, fall back to ALL. Windows are taken
 * relative to the LATEST recorded day, exactly like the macOS `days(for:)`.
 */
private fun resolveMetric(
    days: List<DailyMetric>,
    selected: TrendsRange,
    value: (DailyMetric) -> Double?,
): ResolvedMetric {
    for (r in selected.widening) {
        val pts = windowPoints(days, r, value)
        if (pts.isNotEmpty()) {
            return ResolvedMetric(
                values = pts.map { it.second },
                dates = pts.map { it.first },
                effective = r,
                widened = r != selected,
                caption = caption(pts.size, r, selected),
            )
        }
    }
    val pts = windowPoints(days, TrendsRange.All, value)
    return ResolvedMetric(
        values = pts.map { it.second },
        dates = pts.map { it.first },
        effective = TrendsRange.All,
        widened = TrendsRange.All != selected,
        caption = caption(pts.size, TrendsRange.All, selected),
    )
}

/**
 * Non-null metric points (day, value) within [range]'s trailing window, taken relative to
 * the latest recorded day (oldest → newest). `days` is the full oldest-first history. A null
 * `range.days` (ALL) returns every non-null point. The day string is carried alongside each
 * value so the chart can draw a real date X-axis.
 */
private fun windowPoints(
    days: List<DailyMetric>,
    range: TrendsRange,
    value: (DailyMetric) -> Double?,
): List<Pair<String, Double>> {
    if (days.isEmpty()) return emptyList()
    val sliced = when (val n = range.days) {
        null -> days
        // Trailing N CALENDAR days ending today — anchored to the phone's date, NOT the last N rows
        // (which on a stale import made months-old data fill the W/M/3M windows, looking current — #23).
        // ISO yyyy-MM-dd sorts chronologically. Empty short windows auto-widen via resolveMetric, so old
        // imports surface under a wider range / All history rather than masquerading as recent.
        else -> {
            val cutoff = LocalDate.now().minusDays((n - 1).toLong()).toString()
            days.filter { it.day >= cutoff }
        }
    }
    return sliced.mapNotNull { d -> value(d)?.let { d.day to it } }
}

/** Caption text, mirroring TrendsView.caption(count:eff:). */
private fun caption(count: Int, eff: TrendsRange, selected: TrendsRange): String {
    val unit = if (count == 1) "reading" else "readings"
    return if (eff != selected) {
        "$count $unit · sparse — widened to ${eff.longName}"
    } else {
        "$count $unit · ${selected.longName}"
    }
}

// MARK: - ChartCard — the uniform fixed-height trend card
//
// A NoopCard holding a header (overline-styled title + caption + trailing read-out), a
// fixed-height LineChart, and a divided footer of labelled stats. Mirrors the macOS
// ChartCard used across Trends so every card is Metrics.chartHeight-class and identical.

@Composable
private fun ChartCard(
    title: String,
    subtitle: String?,
    trailing: String?,
    color: Color,
    values: List<Double>,
    footer: List<Pair<String, String>>,
    modifier: Modifier = Modifier,
    dates: List<String> = emptyList(),
    formatY: (Double) -> String = { "${it.roundToInt()}" },
    // Bevel: a domain card wash, a bright end-cap "now" colour, and an optional window-change TrendChip.
    tint: Color? = null,
    tipColor: Color = color,
    change: Double? = null,
    higherIsBetter: Boolean? = null,
    changeFmt: (Double) -> String = { "${it.roundToInt()}" },
    // Fraction of the plot height left empty above the peak — the Android stand-in for the iOS
    // hero's `valueRange: 0...106` padded ceiling, so the peak + now-cap halo clear the top
    // gridline. 0 keeps the curve filling the full height (the small multiples). (#458/parity)
    chartHeadroom: Float = 0f,
) {
    NoopCard(modifier = modifier, padding = Metrics.cardPadding, tint = tint) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header.
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(title)
                    if (subtitle != null) {
                        Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
                if (trailing != null) {
                    // Neutral 15pt readout (matches iOS TrendsView) — not the 22sp tinted figure.
                    Text(trailing, style = NoopType.bodyNumber, color = Palette.textPrimary)
                }
            }

            // Chart (fixed height) or sparse placeholder. The chart is flanked by a max/avg/min
            // Y-axis column on the left and a first/mid/last date X-axis row underneath, so the
            // line reads against real numbers and dates instead of a bare unlabelled curve.
            if (values.size >= 2) {
                ChartWithAxes(
                    values = values,
                    dates = dates,
                    color = color,
                    tipColor = tipColor,
                    formatY = formatY,
                    headroom = chartHeadroom,
                )
            } else {
                SparsePlaceholder()
            }

            // Footer stats + a window-change chip aligned to the trailing edge.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.weight(1f)) { ChartFooter(footer) }
                ChangeChip(change, higherIsBetter, changeFmt)
            }
        }
    }
}

/** A TrendChip for a window's period change — green/rose by whether the move is good for THIS metric. */
@Composable
private fun ChangeChip(change: Double?, higherIsBetter: Boolean?, fmt: (Double) -> String) {
    if (change == null || kotlin.math.abs(change) <= 0.0001) return
    val sign = if (change >= 0) "+" else "−"
    val color = when (higherIsBetter) {
        null -> Palette.textTertiary
        else -> if ((change > 0) == higherIsBetter) Palette.statusPositive else Palette.metricRose
    }
    TrendChip(text = "$sign${fmt(kotlin.math.abs(change))}", color = color)
}

/**
 * A [LineChart] with a max/avg/min Y-axis label column and a first/mid/last date X-axis row.
 * Shared by the hero + small-multiple trend cards so every chart gets the same axis treatment.
 * Date strings (ISO yyyy-MM-dd) are reformatted to "d MMM"; an unparseable string falls back to
 * its raw value so a non-ISO key never blanks a label.
 */
@Composable
private fun ChartWithAxes(
    values: List<Double>,
    dates: List<String>,
    color: Color,
    formatY: (Double) -> String,
    tipColor: Color = color,
    // See ChartCard.chartHeadroom — fraction of the plot left empty above the peak.
    headroom: Float = 0f,
) {
    val maxV = values.max()
    val avgV = values.average()
    val minV = values.min()
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.height(IntrinsicSize.Min),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Column(
                modifier = Modifier.height(Metrics.chartHeight),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(formatY(maxV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                Text(formatY(avgV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                Text(formatY(minV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
            // The shared LineChart with a glowing "now" end-cap drawn on top — the Bevel idiom from
            // Today's OverviewHRChart. The cap reproduces LineChart's own point geometry (same
            // strokePx/topPad/bottomPad) so the dot lands exactly on the line's final sample.
            //
            // headroom leaves the top fraction of the card empty and pins the plotting Box to the
            // bottom — the Android stand-in for the iOS hero's `valueRange: 0...106` (LineChart has
            // no value-domain hook, so we shrink its drawing box instead). Both LineChart and the
            // GlowEndCap fill this same Box, so the cap stays on the line.
            val plotHeight = Metrics.chartHeight * (1f - headroom.coerceIn(0f, 0.5f))
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(Metrics.chartHeight),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(modifier = Modifier.fillMaxWidth().height(plotHeight)) {
                    LineChart(
                        values = values,
                        modifier = Modifier.fillMaxSize(),
                        color = color,
                        fill = true,
                        selectionEnabled = true,
                    )
                    GlowEndCap(values = values, tipColor = tipColor)
                }
            }
        }
        if (dates.size >= 2) {
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(dates.first(), dates.getOrNull(dates.lastIndex / 2), dates.last()).forEach { d ->
                    Text(
                        prettyAxisDate(d),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/** ISO "yyyy-MM-dd" → "d MMM"; falls back to the raw string (or "" when null) if it doesn't parse. */
private fun prettyAxisDate(day: String?): String =
    day?.let {
        runCatching { LocalDate.parse(it).format(DateTimeFormatter.ofPattern("d MMM", Locale.US)) }
            .getOrDefault(it)
    }.orEmpty()

/** A labelled metric-trend card built from a [ResolvedMetric] with mean / min / max. */
@Composable
private fun MetricTrendCard(
    title: String,
    unit: String,
    color: Color,
    resolved: ResolvedMetric,
    fmt: (Double) -> String,
    tint: Color? = null,
    tipColor: Color = color,
    higherIsBetter: Boolean? = null,
) {
    val avg = resolved.values.averageOrNull()
    ChartCard(
        title = title,
        subtitle = null,
        trailing = avg?.let { fmt(it) },
        color = color,
        tint = tint,
        tipColor = tipColor,
        values = resolved.values,
        dates = resolved.dates,
        formatY = fmt,
        change = periodChange(resolved.values),
        higherIsBetter = higherIsBetter,
        changeFmt = fmt,
        footer = listOf(
            // Plain "Mean" to match the bare Min/Max columns; the unit moves into the value
            // (e.g. "58 ms") so uppercasing can't render a shouty "MEAN MS".
            "Mean" to (avg?.let { "${fmt(it)} $unit" } ?: EM_DASH),
            "Min" to (resolved.values.minOrNull()?.let { fmt(it) } ?: EM_DASH),
            "Max" to (resolved.values.maxOrNull()?.let { fmt(it) } ?: EM_DASH),
        ),
    )
}

/**
 * The window's trend as a signed mean-of-recent-half minus mean-of-earlier-half — drives the card's
 * TrendChip so a glance reads the direction, like Today's deltas. null for a window too short to split.
 */
private fun periodChange(values: List<Double>): Double? {
    if (values.size < 4) return null
    val mid = values.size / 2
    val earlier = values.take(mid)
    val recent = values.drop(mid)
    if (earlier.isEmpty() || recent.isEmpty()) return null
    return recent.average() - earlier.average()
}

/** Evenly-spaced labelled stats under a chart, separated by a hairline rule. */
@Composable
private fun ChartFooter(items: List<Pair<String, String>>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
        HorizontalDivider(color = Palette.hairline)
        Row(modifier = Modifier.fillMaxWidth()) {
            items.forEach { (label, value) ->
                Column(modifier = Modifier.weight(1f)) {
                    Overline(label, color = Palette.textTertiary)
                    Text(value, style = NoopType.bodyNumber, color = Palette.textPrimary)
                }
            }
        }
    }
}

// MARK: - Recovery history strip (stands in for the macOS YearHeatStrip)

/**
 * The recovery history card. macOS shows a YearHeatStrip (a 53-week calendar heat grid);
 * that bespoke component has no Android foundation equivalent, so we plot the real
 * per-day recovery series as a bar strip over the same window and note the difference.
 * Always shows at least a full year of context, like the macOS strip.
 */
@Composable
private fun RecoveryHistoryCard(days: List<DailyMetric>, range: TrendsRange) {
    // PERF (#scroll-jank): memoise the window slice + recovery extraction on (days, range) so the
    // 800+-day takeLast + mapNotNull don't re-run on every recomposition (e.g. the staggered-appear
    // animation frames that drive this whole strip). Same span rule, same values, same order — purely
    // skips redundant re-slicing. NOTE: the bars are NOT caller-downsampled — BarChart already mean-
    // bucket-downsamples internally to ~one bar per horizontal pixel (pixel-identical), so a second,
    // coarser caller-side bucket (e.g. ≤180) would visibly widen the bars and is deliberately avoided.
    val recovery = remember(days, range) {
        // Always show at least a year; expand to all history on ALL.
        val span = (range.days ?: days.size).coerceAtLeast(365)
        days.takeLast(span).mapNotNull { it.recovery }
    }
    val title = if (range == TrendsRange.All && days.size > 365) {
        "Charge — all history"
    } else {
        "Charge — past year"
    }

    NoopCard(tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionHeader(title, overline = "Calendar", trailing = "${recovery.size} days")
            if (recovery.size >= 2) {
                BarChart(
                    values = recovery,
                    modifier = Modifier.height(Metrics.trendStripHeight),
                    color = Palette.accent,
                )
            } else {
                SparsePlaceholder(height = Metrics.trendStripHeight)
            }
            HorizontalDivider(color = Palette.hairline)
            Text(
                "Each bar is one day's Charge score, low to high. The 53-week calendar " +
                    "heat-grid is part of the desktop app.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Shared bits

/**
 * A glowing dot pinned to a LineChart's latest sample — the Bevel "now" end-cap (a soft halo + bright
 * core + white centre), matching Today's OverviewHRChart. Drawn as a sibling overlay so the shared
 * LineChart stays untouched; it reproduces that chart's point geometry exactly (strokePx 2.5, top/
 * bottom pad strokePx+4, finite-value min/max) so the cap sits on the curve's final point.
 */
@Composable
private fun GlowEndCap(values: List<Double>, tipColor: Color) {
    val clean = remember(values) { values.filter { it.isFinite() } }
    if (clean.size < 2) return
    Canvas(modifier = Modifier.fillMaxSize()) {
        val strokePx = 2.5f
        val topPad = strokePx + 4f
        val bottomPad = strokePx + 4f
        val minV = clean.min()
        val maxV = clean.max()
        val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
        val usableH = (size.height - topPad - bottomPad).coerceAtLeast(1f)
        val x = size.width  // the latest point sits at the right edge
        val norm = ((clean.last() - minV) / span).toFloat().coerceIn(0f, 1f)
        val y = topPad + (1f - norm) * usableH
        val center = Offset(x, y)
        drawCircle(color = tipColor.copy(alpha = 0.30f), radius = 9f, center = center)
        drawCircle(color = tipColor.copy(alpha = 0.65f), radius = 5.5f, center = center)
        drawCircle(color = Palette.tipCore, radius = 2.4f, center = center)
    }
}

/** Inset well shown when a window has too few points to plot, mirroring sparsePlaceholder. */
@Composable
private fun SparsePlaceholder(height: Dp = Metrics.chartHeight) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(Palette.surfaceInset),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "Not enough data for this window.",
            style = NoopType.subhead,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun EmptyTrends() {
    DataPendingNote(
        title = "Trends need history to draw",
        body = "Trends need history to draw. Import your WHOOP export in Data Sources " +
            "to see weeks, months and years instantly.",
    )
}

// MARK: - Small numeric helpers

private const val EM_DASH = "—"

private fun List<Double>.averageOrNull(): Double? =
    if (isEmpty()) null else sum() / size
