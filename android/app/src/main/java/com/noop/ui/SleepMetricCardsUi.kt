package com.noop.ui

import com.noop.R
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.analytics.SleepDebtLedger
import com.noop.data.SleepSession
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

// Sleep metric grid, debt ledger, stage comparison, trend cards + shared chart helpers.
// Extracted from SleepScreen.kt (behavioral no-op; pure UI code-motion).

/**
 * #today-hosted-cards: the "Night detail" metric grid rendered from the shared [SleepModel]. `internal` so
 * the Today host (TodayScreen) can render the SAME grid the Sleep tab does (a mirror, not a copy); lives
 * here so its [MetricGrid]/[SparkTile] siblings stay in-file. Twin of the iOS `NightDetailCard`. The Sleep
 * tab passes an [onMetricClick] to open per-metric detail; the Today host omits it (no detail sheet there),
 * so the tiles render read-only when hosted.
 */
@Composable
internal fun NightDetailHostCard(m: SleepModel, onMetricClick: (String) -> Unit = {}) {
    MetricGrid(m, onMetricClick = onMetricClick)
}

@Composable
private fun MetricGrid(m: SleepModel, onMetricClick: (String) -> Unit = {}) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { mod ->
            SparkTile(
                mod, "Rest",
                value = pctValue(m.performance.latest),
                caption = vsTypical(m.performance.latest, m.performance.typical, "%"),
                accent = m.performance.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.performance.series, sparkColor = Palette.restColor,
                onClick = { onMetricClick("performance") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Efficiency",
                value = pctValue(m.efficiency.latest),
                caption = vsTypical(m.efficiency.latest, m.efficiency.typical, "%"),
                accent = Palette.statusPositive,
                spark = m.efficiency.series, sparkColor = Palette.statusPositive,
                onClick = { onMetricClick("efficiency") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Consistency",
                value = pctValue(m.consistency.latest),
                caption = vsTypical(m.consistency.latest, m.consistency.typical, "%"),
                accent = m.consistency.latest?.let { Palette.recoveryColor(it) } ?: Palette.textPrimary,
                spark = m.consistency.series, sparkColor = Palette.metricCyan,
                onClick = { onMetricClick("consistency") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Hours vs Needed",
                value = pctValue(m.hoursVsNeeded.latest),
                caption = vsTypical(m.hoursVsNeeded.latest, m.hoursVsNeeded.typical, "%"),
                accent = m.hoursVsNeeded.latest?.let { Palette.recoveryColor(minOf(100.0, it)) } ?: Palette.textPrimary,
                spark = m.hoursVsNeeded.series, sparkColor = Palette.restColor,
                onClick = { onMetricClick("hours_vs_needed") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Restorative",
                value = pctValue(m.restorative.latest),
                caption = vsTypical(m.restorative.latest, m.restorative.typical, "%"),
                accent = Palette.sleepREM,
                spark = m.restorative.series, sparkColor = Palette.sleepREM,
                onClick = { onMetricClick("restorative") },
            )
        },
        { mod ->
            SparkTile(
                mod, "Respiratory",
                value = m.respiratory.latest?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                caption = vsTypical(m.respiratory.latest, m.respiratory.typical, " rpm", decimals = 1),
                accent = Palette.metricPurple,
                spark = m.respiratory.series, sparkColor = Palette.metricPurple,
                onClick = { onMetricClick("respiratory") },
            )
        },
    )

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Night detail", overline = "Metrics", trailing = "vs typical")

        // Sleep Debt is the actionable summary for the section, so it leads at the full
        // two-column width. The remaining six peer metrics keep the established 2 × 3 grid.
        SparkTile(
            Modifier.fillMaxWidth(), "Sleep Debt",
            value = m.sleepDebt.latest?.let { durationText(it) } ?: "—",
            caption = debtCaption(m.sleepDebt.latest),
            accent = debtColor(m.sleepDebt.latest),
            spark = m.sleepDebt.series, sparkColor = Palette.metricRose,
            onClick = { onMetricClick("sleep_debt") },
        )

        // Two-up rows; IntrinsicSize.Max + fillMaxHeight keep row neighbors equal height even when
        // large font scales grow one tile past the tileHeight floor. No empty cells.
        tiles.chunked(2).forEach { rowTiles ->
            Row(
                modifier = Modifier.height(IntrinsicSize.Max),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                rowTiles.forEach { it(Modifier.weight(1f).fillMaxHeight()) }
            }
        }
    }
}

// MARK: - 2b. Sleep-debt ledger (rolling 14-night running balance)

/**
 * A running balance of (slept − personal need) across the recent fortnight, surfaced as one
 * card: the net debt/surplus headline, a plain-English read, and a diverging bar of each
 * night's delta (surplus above the centre line, deficit below). Honest: a simple accumulator
 * — a surplus night offsets a deficit one — capped at 14 nights, no-data nights skipped.
 * Mirrors the macOS SleepDebtLedgerCard section-for-section. `internal` and keyed on the shared
 * [SleepModel] so the Today host (TodayScreen) can render the SAME view the Sleep tab does (a mirror,
 * not a copy); the nap-credited ledger is read from `m.sleepDebtLedger`, never recomputed here. Twin of
 * the iOS `SleepDebtLedgerCard`. (#242) (#today-hosted-cards)
 */
@Composable
internal fun SleepDebtLedgerHostCard(m: SleepModel) {
    val ledger = m.sleepDebtLedger
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Sleep-debt ledger", overline = "Last 14 nights", trailing = "running balance")
        NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
            if (ledger.nightCount == 0) {
                Text(
                    uiString(R.string.l10n_sleep_screen_no_nights_with_sleep_data_yet_fa71b6b3),
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                    // Headline: net balance + the short tag (sleep debt / surplus / balanced).
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            debtHeadline(ledger),
                            style = NoopType.tileValueLarge,
                            color = debtBalanceColor(ledger),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            debtTag(ledger),
                            style = NoopType.captionNumber,
                            color = debtBalanceColor(ledger),
                        )
                    }
                    // Plain-English read.
                    Text(
                        debtRead(ledger),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                    // Per-night diverging delta bars (surplus up, deficit down).
                    DebtDeltaBars(ledger)
                    SleepHairline()
                    SleepChartFooter(
                        listOf(
                            "Balance" to debtSigned(ledger.balanceMin),
                            "Per-night need" to durationText(ledger.needMin),
                            "Nights" to "${ledger.nightCount}",
                        ),
                    )
                }
            }
        }
    }
}

/**
 * The diverging per-night delta strip: each night a bar from the centre line — up (accent)
 * for a surplus, down (rose) for a deficit — scaled to the largest |delta|.
 */
@Composable
private fun DebtDeltaBars(ledger: SleepDebtLedger) {
    val deltas = ledger.nights.map { it.deltaMin }
    val scale = max(deltas.maxOfOrNull { abs(it) } ?: 1.0, 1.0)
    val accentColor = Palette.accent
    val deficitColor = Palette.metricRose
    val centreColor = Palette.hairline
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp)
            .semantics {
                contentDescription =
                    uiString(R.string.l10n_sleep_screen_per_night_sleep_balance_ledger_nightcount_f339d0ab, ledger.nightCount, debtSigned(ledger.balanceMin))
            }
            .drawBehind {
                val n = max(deltas.size, 1)
                val slot = size.width / n
                val barW = max(2f, slot * 0.6f)
                val midY = size.height / 2f
                // Centre (zero) line.
                drawLine(
                    color = centreColor,
                    start = Offset(0f, midY),
                    end = Offset(size.width, midY),
                    strokeWidth = 1f,
                )
                deltas.forEachIndexed { i, d ->
                    val frac = (abs(d) / scale).toFloat().coerceIn(0f, 1f)
                    val h = max(2f, frac * (midY - 2f))
                    val cx = slot * i + slot / 2f
                    // Surplus grows upward from the centre, deficit downward.
                    val top = if (d >= 0.0) midY - h else midY
                    drawRoundRect(
                        color = if (d >= 0.0) accentColor else deficitColor,
                        topLeft = Offset(cx - barW / 2f, top),
                        size = Size(barW, h),
                        cornerRadius = CornerRadius(2f, 2f),
                    )
                }
            },
    )
}

// MARK: - Stages (read-only latest-night host card)

/**
 * #today-hosted-cards: the READ-ONLY "Stages" card hosted in Today — the latest night's stage chart +
 * breakdown rendered from the shared [SleepModel] (the SAME stages the Sleep tab hero shows). Unlike the
 * Sleep tab hero it carries NONE of the interaction: no night ◀/▶ navigation, no wake-time edit, no nap
 * add/edit/delete — only the display is mirrored. It reuses the SAME StageTimeline / FilledHypnogram /
 * HypnogramWithAxis + StageBreakdownRows renderers the hero uses (each owns its own transient tap-
 * highlight), so the stage split can never diverge between the two surfaces. `internal` so the Today host
 * (TodayScreen) can render it; lives here so its private [StageTimeline] sibling is in-file. Twin of the
 * iOS `StagesCard`.
 *
 * NOTE (feature-level parity): the Kotlin [SleepModel] carries no session timestamps or nap blocks (those
 * ride [HeroNight]/[HeroDisplay] on the Sleep tab), so — unlike iOS, whose `SleepModel.night` carries the
 * session + source blocks — this card shows no clock-window row and no Main/Nap(s)/Total split. The stage
 * chart + breakdown is the shared data both platforms mirror.
 */
@Composable
internal fun StagesHostCard(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Read-only header: the night's span label in the trailing slot — NO ◀/▶ nav controls.
        SectionHeader("Stages", overline = "Last night", trailing = m.clockLabel)
        // Verbatim of the Sleep tab Hero's stage-chart block, read from the shared model with a null
        // session window (no clock axis) and no motion strip — the fractions/segments are identical.
        val subtitle = "${durationText(s.total)} in bed · ${m.efficiencyText} efficiency" +
            (if (m.realSegments != null) " · approx. stages (on-device)" else "")
        val real = m.realSegments?.takeIf { it.size >= 2 }
        if (real != null) {
            val chartStyle = UnitPrefs.sleepChartStyle(LocalContext.current)
            val filledSegments = m.hypnogramSegments?.takeIf { it.size >= 2 }
            if (chartStyle != SleepChartStyle.CLASSIC && filledSegments != null) {
                SleepChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    // #1536: the stage LEGEND that used to sit here is gone, and the rows below now
                    // take the chart's ramp. Those two go together. The legend decoded the hypnogram
                    // above it, which is real work — but it listed the stages in a different order than
                    // the rows, and the rows were drawing FIXED theme tokens while the chart drew ramp
                    // colours, so on Oura/Garmin three things in one card disagreed. Making the rows
                    // ramp-aware leaves them naming and colouring every stage correctly, which IS the
                    // key; a separate legend above a correct key is the redundancy that was reported.
                    footer = { StageBreakdownRows(s, chartStyle.stagePalette) },
                ) {
                    FilledHypnogram(
                        segments = filledSegments,
                        onsetTs = null,
                        wakeTs = null,
                        filled = chartStyle.isFilled,
                        palette = chartStyle.stagePalette,
                    )
                }
            } else {
                SleepChartCard(
                    title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                    subtitle = subtitle,
                    trailing = durationText(s.asleep),
                    tint = Palette.restColor,
                    footer = {},
                ) {
                    StageTimeline(
                        realSegments = real,
                        s = s,
                        onsetTs = null,
                        wakeTs = null,
                        motionEpochs = emptyList(),
                    )
                }
            }
        } else {
            SleepChartCard(
                title = uiString(R.string.l10n_sleep_screen_stage_breakdown_e9b714f9),
                subtitle = subtitle,
                trailing = durationText(s.asleep),
                tint = Palette.restColor,
                footer = { StageBreakdownRows(s) },
            ) {
                val segments = stageSegments(s)
                if (segments.isNotEmpty()) {
                    HypnogramWithAxis(stages = segments, onsetTs = null, wakeTs = null)
                } else {
                    Text(
                        uiString(R.string.l10n_sleep_screen_no_stage_breakdown_for_this_night_b74bf9c3),
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - 3. Stages vs typical

/**
 * #today-hosted-cards: the "Stages vs typical" card — last night's Deep/REM/Light against the wearer's
 * personal per-stage means from the shared [SleepModel]. `internal` so the Today host (TodayScreen) can
 * render the SAME view the Sleep tab does (a mirror, not a copy); lives here so its StageRow/SleepHairline
 * siblings are in-file. Twin of the iOS `StagesVsTypicalCard`.
 */
@Composable
internal fun StagesVsTypicalHostCard(m: SleepModel) {
    val s = m.stages
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Stages vs typical", overline = "Selected night", trailing = "marker = your mean")
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                StageRow("Deep", last = s.deep, typical = m.typicalDeepMin, color = Palette.sleepDeep)
                SleepHairline()
                StageRow("REM", last = s.rem, typical = m.typicalRemMin, color = Palette.sleepREM)
                SleepHairline()
                StageRow("Light", last = s.light, typical = m.typicalLightMin, color = Palette.sleepLight)
            }
        }
    }
}

@Composable
internal fun SleepHairline() {
    Box(modifier = Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
}

/** One stage bar: last-night minutes filled, with a vertical marker at the typical mean. */
@Composable
private fun StageRow(label: String, last: Double, typical: Double?, color: Color) {
    val scaleMax = max(last, typical ?: 0.0) * 1.18
    val scale = if (scaleMax > 0.0) scaleMax else 1.0
    val deltaText: String = run {
        if (typical == null || typical <= 0.0) {
            ""
        } else {
            val diff = last - typical
            val sign = if (diff >= 0) "+" else "−"
            "$sign${durationText(abs(diff))} vs typ"
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(durationText(last), style = NoopType.captionNumber, color = Palette.textPrimary)
            if (deltaText.isNotEmpty()) {
                Text(
                    deltaText,
                    style = NoopType.footnote,
                    color = if (last >= (typical ?: last)) Palette.statusPositive else Palette.statusWarning,
                    modifier = Modifier.padding(start = Metrics.space8),
                )
            }
        }
        // Track + last-night fill + typical marker.
        val fillFrac = (last / scale).coerceIn(0.0, 1.0).toFloat()
        val markerFrac = typical?.takeIf { it > 0.0 }?.let { (it / scale).coerceIn(0.0, 1.0).toFloat() }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(Metrics.progressHeight)
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(Palette.surfaceInset)
                .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_label_minutes_vs_your_typical_bar_b8f6a482, label) }
                .drawBehind {
                    // last-night fill
                    if (fillFrac > 0f) {
                        drawRoundRectFill(color, fillFrac)
                    }
                    // typical marker
                    if (markerFrac != null) {
                        val x = (size.width * markerFrac).coerceIn(1f, size.width - 1f)
                        drawLine(
                            color = Palette.textPrimary,
                            start = Offset(x, 0f),
                            end = Offset(x, size.height),
                            strokeWidth = 2f,
                            cap = StrokeCap.Round,
                        )
                    }
                },
        )
    }
}

private fun DrawScope.drawRoundRectFill(color: Color, frac: Float) {
    val w = (size.width * frac).coerceAtLeast(size.height)
    val r = size.height / 2f
    drawRoundRect(
        color = color,
        size = Size(w, size.height),
        cornerRadius = CornerRadius(r, r),
    )
}

// MARK: - 4. 14-day asleep-hours trend

/**
 * #today-hosted-cards P1: the hosted "Asleep duration" card — the hours-asleep BarChart from [DurationTrend],
 * hours-only (no debt sub-chart, so no nap/session data needed), built from the pure [sleepDurationTrend].
 * `internal` so the Today host (TodayScreen) can render it; lives here so its SleepChartCard/BarChart siblings
 * are in-file. Twin of the iOS `AsleepDurationCard`.
 */
@Composable
internal fun AsleepDurationHostCard(hours: List<Double>, dates: List<String>) {
    val avg = hours.sleepAverageOrNull()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Asleep duration", overline = "Sleep", trailing = "Last 14 days")
        SleepChartCard(
            title = uiString(R.string.l10n_sleep_screen_hours_asleep_06f68993),
            subtitle = "Per night, trailing 14 days",
            trailing = avg?.let { String.format(Locale.US, "%.1f h avg", it) },
            tint = Palette.restColor,
            footer = {
                SleepChartFooter(
                    listOf(
                        "Avg" to (avg?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Min" to (hours.minOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Max" to (hours.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Nights" to "${hours.size}",
                    ),
                )
            },
        ) {
            if (hours.size >= 2) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    BarChart(
                        values = hours,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_hours_trend_chart_a6fbc46d) },
                        color = Palette.restColor,
                        selectionEnabled = true,
                        selectionLabels = dates.map(::shortDayLabel),
                    )
                    DateAxisRow(dates)
                }
            } else {
                TrendPlaceholder()
            }
        }
    }
}

@Composable
internal fun DurationTrend(m: SleepModel) {
    val pts = m.trendHours
    val avg = pts.sleepAverageOrNull()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Trend", overline = "Sleep", trailing = "Last 14 days")
        SleepChartCard(
            title = uiString(R.string.l10n_sleep_screen_hours_asleep_06f68993),
            subtitle = "Per night, trailing 14 days",
            trailing = avg?.let { String.format(Locale.US, "%.1f h avg", it) },
            tint = Palette.restColor,
            footer = {
                SleepChartFooter(
                    listOf(
                        "Avg" to (avg?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Min" to (pts.minOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Max" to (pts.maxOrNull()?.let { String.format(Locale.US, "%.1f h", it) } ?: "—"),
                        "Nights" to "${pts.size}",
                    ),
                )
            },
        ) {
            if (pts.size >= 2) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // #85: sleep duration reads as a per-night histogram (zero-based bars), matching the
                    // iOS Sleep tab's TrendChart(showsBars:) — a BarMark is proportional to hours slept,
                    // clearer than a line for a nightly total. BarChart floors at 0 like the iOS bar domain.
                    BarChart(
                        values = pts,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_hours_trend_chart_a6fbc46d) },
                        color = Palette.restColor,
                        selectionEnabled = true,
                        // #691: on tap, show the DATE alongside the value (the shared chart's tooltip),
                        // matching the other trend graphs. trendDates is index-aligned with the values.
                        selectionLabels = m.trendDates.map(::shortDayLabel),
                    )
                    DateAxisRow(m.trendDates)
                }
            } else {
                TrendPlaceholder()
            }
        }

        SleepChartCard(
            title = uiString(R.string.l10n_sleep_screen_sleep_debt_3aec7d9c),
            subtitle = "Sleep debt per day",
            // #691: sleep debt is usually well under an hour, so decimal hours ("0.6h") reads badly —
            // show hours+minutes. trendDebtHours is in hours; durationText takes minutes.
            trailing = m.trendDebtHours.lastOrNull()?.let { durationText(it * 60.0) },
            tint = Palette.restColor,
            footer = {
                SleepChartFooter(
                    listOf(
                        "Avg" to (m.trendDebtHours.sleepAverageOrNull()?.let { durationText(it * 60.0) } ?: "â€”"),
                        "Max" to (m.trendDebtHours.maxOrNull()?.let { durationText(it * 60.0) } ?: "â€”"),
                        "Days" to "${m.trendDebtHours.size}",
                    ),
                )
            },
        ) {
            if (m.trendDebtHours.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    BarChart(
                        values = m.trendDebtHours,
                        modifier = Modifier.fillMaxWidth().height(Metrics.compactChartHeight)
                            .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_debt_trend_chart_9e178776) },
                        color = Palette.metricRose,
                        selectionEnabled = true,
                        selectionLabels = m.trendDates.map(::shortDayLabel),   // #691: hover shows date + value
                    )
                    DateAxisRow(m.trendDates)
                }
            } else {
                TrendPlaceholder()
            }
        }
    }
}

@Composable
// internal (not private) so the Today hosted-cards duration card (#today-hosted-cards) can reuse it.
internal fun TrendPlaceholder() {
    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center,
    ) {
        InsetChartPlaceholder(message = "Not enough nights yet.")
    }
}

@Composable
private fun TrendLegend(items: List<Pair<String, Color>>) {
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
        items.forEach { (label, color) ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .width(Metrics.legendLineWidth)
                        .height(Metrics.legendLineHeight)
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(color),
                )
                Text(label, style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

// internal (not private) so the Today hosted-cards duration card (#today-hosted-cards) can reuse it.
@Composable
internal fun DateAxisRow(days: List<String>) {
    if (days.isEmpty()) return
    val labels = listOf(
        days.firstOrNull(),
        days.getOrNull(days.lastIndex / 2),
        days.lastOrNull(),
    ).map { it?.let(::shortDayLabel).orEmpty() }
    Row(modifier = Modifier.fillMaxWidth()) {
        labels.forEach { label ->
            Text(
                text = label,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// MARK: - SleepChartCard / SleepChartFooter (local — mirror the macOS SleepChartCard the screen used)

/**
 * The chart container the macOS screen leaned on: a NoopCard with a header (overline-
 * style title + subtitle + trailing read-out), the chart body, then a footer row of
 * label/value pairs. Kept local so the shared component set stays minimal.
 */
@Composable
internal fun SleepChartCard(
    title: String,
    subtitle: String,
    trailing: String?,
    footer: @Composable () -> Unit,
    tint: Color? = null,
    chart: @Composable () -> Unit,
) {
    NoopCard(padding = Metrics.cardPadding, tint = tint) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, style = NoopType.headline, color = Palette.textPrimary)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary)
                }
                if (trailing != null) {
                    Text(trailing, style = NoopType.chartValue, color = Palette.textPrimary)
                }
            }
            chart()
            footer()
        }
    }
}

/** A footer strip of label/value pairs, evenly distributed. */
@Composable
private fun SleepChartFooter(items: List<Pair<String, String>>) {
    Row(modifier = Modifier.fillMaxWidth()) {
        items.forEach { (label, value) ->
            Column(modifier = Modifier.weight(1f)) {
                Overline(label, color = Palette.textTertiary)
                // Stage-breakdown values like "1h 23m (24%)" wrapped to a second line in a narrow column,
                // pushing the row taller and clipping against the card edge (#406). Hold them to one line.
                Text(
                    value,
                    style = NoopType.captionNumber,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    softWrap = false,
                )
            }
        }
    }
}

// MARK: - SparkTile (min-height metric tile, stacked: value + caption over a full-width 30-day sparkline)

@Composable
private fun SparkTile(
    modifier: Modifier,
    label: String,
    value: String,
    caption: String?,
    accent: Color,
    spark: List<Double>,
    sparkColor: Color,
    onClick: (() -> Unit)? = null,
) {
    // liquidPress on the tappable tile: it settles inward on press (the pilot's card feel). The SAME
    // interactionSource drives the clickable + the press; indication = null so only the liquid settle shows.
    val interaction = remember { MutableInteractionSource() }
    // heightIn (not height): tileHeight is a floor, matching the Swift StatTile. At normal font scale the
    // tile keeps its 108dp footprint; at large font scales it grows instead of clipping the caption. (#squish)
    val clickMod = if (onClick != null) {
        modifier
            .heightIn(min = Metrics.tileHeight)
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    } else {
        modifier.heightIn(min = Metrics.tileHeight)
    }
    NoopCard(modifier = clickMod, padding = Metrics.space14) {
        // fillMaxHeight so the weight-spacer can pin the sparkline to the card bottom once the
        // MetricGrid row bounds the height (Row height(IntrinsicSize.Max) + tile fillMaxHeight()).
        Column(modifier = Modifier.fillMaxWidth().fillMaxHeight()) {
            Overline(label)
            Text(
                value,
                style = NoopType.tileValue,
                color = accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (caption != null) {
                Text(
                    caption,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    // Full card width now, so the "-3% vs typical" caption fits; ellipsis stays as a
                    // safety net for extreme localized strings.
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = Metrics.space2),
                )
            }
            Spacer(Modifier.weight(1f))
            val tail = spark.takeLast(30)
            if (tail.size >= 2) {
                // Full-width bottom spark. Outer height(sparkHeight) deliberately overrides Sparkline's
                // internal 28dp default down to the 22dp tile spark (same override SparkTailBox does).
                Sparkline(
                    values = tail,
                    color = sparkColor,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = Metrics.space8)
                        .height(Metrics.sparkHeight),
                )
            }
        }
    }
}

// MARK: - Empty state

@Composable
internal fun SleepEmptyState() {
    DataPendingNote(
        title = uiString(R.string.l10n_sleep_screen_no_nights_here_yet_607248f5),
        body = "No nights here yet. Import your WHOOP export in Data Sources to see " +
            "every night, your sleep stages and trends straight away.",
    )
}

// MARK: - Model + derivation (faithful to SleepView.swift)

// MARK: - Model + derivation lives in SleepModels.kt, SleepNightSelection.kt, SleepModelLogic.kt, and SleepStageTimelineLogic.kt

// MARK: - Hours vs Needed card

/**
 * A standalone "Hours vs Needed" card: a gradient slept/needed bar, a stacked component bar
 * (Healthy Minimum / Strain buffer / Debt repayment) and a slept/needed/debt footer. The
 * trend arrow compares the last two nights' hours. (PR #260)
 */
@Composable
internal fun HoursVsNeededCard(m: SleepModel) {
    // trendHours.last() is the most-recent night's ASLEEP total (totalSleepMin / 60) over the
    // full history — the same asleep figure the tiles and the debt ledger read, never an in-bed
    // window. Falls back to the hero stages' asleep sum when no trend rows exist.
    val sleptH = m.trendHours.lastOrNull() ?: (m.stages.asleep / 60.0)
    val neededH = (m.trendNeedHours.lastOrNull() ?: 8.0)
    val debtH = m.trendDebtHours.lastOrNull() ?: 0.0
    // #691: show the TRUE percentage (e.g. 104% when you slept past your need) instead of a capped
    // "100%" that's indistinguishable from exactly meeting it. The progress-bar fill below stays
    // clamped to 1.0 (it can't overfill); only the displayed number is uncapped.
    val score = (sleptH / neededH * 100.0).coerceAtLeast(0.0)
    val trendArrow = if (m.trendHours.size >= 2) {
        val delta = m.trendHours.last() - m.trendHours[m.trendHours.lastIndex - 1]
        when {
            delta > 0.25 -> "↑"
            delta < -0.25 -> "↓"
            else -> "→"
        }
    } else "→"
    val arrowColor = when (trendArrow) {
        "↑" -> Palette.statusPositive
        "↓" -> Palette.statusCritical
        else -> Palette.textTertiary
    }

    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep")
                    Text(uiString(R.string.l10n_sleep_screen_hours_vs_needed_500a0aca), style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(trendArrow, style = NoopType.title2, color = arrowColor)
                Spacer(Modifier.width(Metrics.space6))
                Text(uiString(R.string.l10n_sleep_screen_score_roundtoint_a2d1cc99, score.roundToInt()), style = NoopType.chartValue, color = Palette.restColor)
            }

            // Gradient progress bar: slept / needed.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.progressHeight)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.surfaceInset)
                    .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_hours_vs_needed_progress_bar_score_4baad051, score.roundToInt()) },
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth((sleptH / neededH).coerceIn(0.0, 1.0).toFloat())
                        .height(Metrics.progressHeight)
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(Brush.horizontalGradient(listOf(Palette.restDeep, Palette.restBright))),
                )
            }

            // Stacked component bar: Healthy Min / Strain buffer / Debt repayment.
            val healthyMin = 7.0
            val strainBuffer = (neededH - healthyMin).coerceAtLeast(0.0)
            val debtRepay = debtH.coerceAtLeast(0.0)
            val totalBar = (healthyMin + strainBuffer + debtRepay).coerceAtLeast(1.0)
            Row(modifier = Modifier.fillMaxWidth().height(Metrics.space8).clip(RoundedCornerShape(Metrics.cornerPill))) {
                Box(modifier = Modifier.weight((healthyMin / totalBar).toFloat()).fillMaxHeight().background(Palette.metricPurple))
                if (strainBuffer > 0) Box(modifier = Modifier.weight((strainBuffer / totalBar).toFloat()).fillMaxHeight().background(Palette.strain066))
                if (debtRepay > 0) Box(modifier = Modifier.weight((debtRepay / totalBar).toFloat()).fillMaxHeight().background(Palette.statusCritical))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                SleepLegendDot("Healthy Min", Palette.metricPurple)
                SleepLegendDot("Strain", Palette.strain066)
                SleepLegendDot("Debt", Palette.statusCritical)
            }

            SleepHairline()
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    "Slept" to String.format(Locale.US, "%.1f h", sleptH),
                    "Needed" to String.format(Locale.US, "%.1f h", neededH),
                    "Debt" to if (debtH > 0.05) durationText(debtH * 60.0) else "None",   // #691: h+m, not "0.6 h"
                ).forEach { (lbl, v) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(lbl, color = Palette.textTertiary)
                        Text(v, style = NoopType.captionNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

@Composable
private fun SleepLegendDot(label: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.space4)) {
        Box(modifier = Modifier.size(Metrics.space6).clip(RoundedCornerShape(50)).background(color))
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - Consistency host card (#today-hosted-cards)

/**
 * A SIMPLE standalone "Consistency" score card for the Today host — mirrors the [HoursVsNeededCard]
 * presentation (a NoopCard header with a trend arrow + big % + a sparkline), NOT the rich scatter
 * [SleepConsistencyCard] (which needs raw sessions). Renders `m.consistency` (latest / typical / series) —
 * the SAME shared SleepModel metric the Sleep tab's Night-detail tile reads (bedtime-onset spread, honouring
 * the imported-consistency preference, byte-identical to iOS `SleepModel.consistency`), so the number and the
 * sparkline can never diverge between the two surfaces.
 */
@Composable
internal fun ConsistencyHostCard(m: SleepModel) {
    val cons = m.consistency
    // Uncapped % (consistency is already 0–100); "—" when there is no latest night yet.
    val latest = cons.latest
    // Trend arrow off the last two nights of the consistency series (same idiom as HoursVsNeededCard).
    val trendArrow = if (cons.series.size >= 2) {
        val delta = cons.series.last() - cons.series[cons.series.lastIndex - 1]
        when {
            delta > 0.5 -> "↑"
            delta < -0.5 -> "↓"
            else -> "→"
        }
    } else "→"
    val arrowColor = when (trendArrow) {
        "↑" -> Palette.statusPositive
        "↓" -> Palette.statusCritical
        else -> Palette.textTertiary
    }
    // The simple host card summarizes the trend via the arrow + sparkline rather than a "vs typical"
    // caption (mirrors the Android HoursVsNeeded host presentation, which carries no caption literal).
    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Sleep")
                    Text(uiString(R.string.l10n_sleep_screen_consistency_0ea7b95e), style = NoopType.headline, color = Palette.textPrimary)
                }
                Text(trendArrow, style = NoopType.title2, color = arrowColor)
                Spacer(Modifier.width(Metrics.space6))
                Text(
                    if (latest != null) uiString(R.string.l10n_sleep_screen_score_roundtoint_a2d1cc99, latest.roundToInt()) else "—",
                    style = NoopType.chartValue,
                    color = Palette.restColor,
                )
            }
            // Sparkline of the consistency history, in metricCyan to match the Sleep-tab Night-detail tile.
            if (cons.series.size > 1) {
                Sparkline(values = cons.series.takeLast(30), color = Palette.metricCyan)
            }
        }
    }
}

// MARK: - Sleep Consistency card

/** One night's bed/wake fold for [SleepConsistencyCard], memoized off `sleeps` (#perf). */
private data class SleepNightTiming(val label: String, val bedHour: Float, val wakeHour: Float)

/**
 * Sleep-consistency chart: for the trailing 14 sessions, draws each night's bed→wake window
 * as a vertical bar against a time-of-day axis, with dashed overlays at the typical bed and
 * wake times. The headline score is the share of nights whose bed AND wake fell within 45 min
 * of the personal typical. (PR #260)
 */
@Composable
internal fun SleepConsistencyCard(
    sleeps: List<SleepSession>,
    habitualMidsleepSec: Long? = null,
    // #sleep-consistency-parity: the iOS-canonical onset-spread score (model.consistency, which also
    // honours the imported-consistency preference). Passed in so the card headline matches iOS + the tile
    // instead of the old local "share of nights within 45 min" count (a third, divergent value).
    consistencyScore: Double? = null,
) {
    // #perf: building the per-night fold allocates 2 Calendars + a SimpleDateFormat per session (~28
    // objects for 14 nights). It's a pure derivation of `sleeps` (no wall-clock input), so memoize it on
    // `sleeps` — scrolling the Sleep screen then reuses it instead of rebuilding it every recompose frame.
    val timings = remember(sleeps, habitualMidsleepSec) {
        val sdf = SimpleDateFormat("EEE", Locale.US)
        // #699: bridged bed→wake spans (one per day, night-tail fragments folded in), not raw sessions —
        // see consistencyNightSpans.
        consistencyNightSpans(sleeps, habitualMidsleepSec).map { (onsetTs, wakeTs) ->
            val bedCal = Calendar.getInstance().apply { timeInMillis = onsetTs * 1000L } // edited bedtime (PR #395)
            val wakeCal = Calendar.getInstance().apply { timeInMillis = wakeTs * 1000L }
            val bedH = bedCal.get(Calendar.HOUR_OF_DAY) + bedCal.get(Calendar.MINUTE) / 60f
            // Fold an evening bedtime to a negative hour so it sorts ABOVE the next-day wake on the axis.
            val bedNorm = if (bedH > 12f) bedH - 24f else bedH
            val wakeH = wakeCal.get(Calendar.HOUR_OF_DAY) + wakeCal.get(Calendar.MINUTE) / 60f
            SleepNightTiming(sdf.format(Date(wakeTs * 1000L)), bedNorm, wakeH)
        }
    }
    if (timings.size < 3) return

    fun sd(vals: List<Float>): Float {
        val m = vals.average().toFloat()
        return kotlin.math.sqrt(vals.sumOf { ((it - m) * (it - m)).toDouble() }.toFloat() / vals.size)
    }
    val bedSdH = sd(timings.map { it.bedHour })
    val wakeSdH = sd(timings.map { it.wakeHour })
    val typicalBed = timings.map { it.bedHour }.average().toFloat()
    val typicalWake = timings.map { it.wakeHour }.average().toFloat()
    // #sleep-consistency-parity: the headline is the shared onset-spread score (iOS-canonical), not the
    // old "share of nights within 45 min of typical" count. The bed/wake scatter + SD labels below are
    // unchanged (they visualise the same onsets). Falls back to 0 only when the score is unavailable.
    val consistencyPct = consistencyScore?.toFloat()?.coerceIn(0f, 100f) ?: 0f
    val typicalBedLabel = run {
        val h = ((typicalBed + 24f) % 24f).toInt()
        String.format(Locale.US, "%02d:00", h)
    }
    val typicalWakeLabel = String.format(Locale.US, "%02d:00", typicalWake.toInt().coerceIn(0, 23))

    // Y from −4h (20:00) to 18h (18:00 next day) — matches the 6 PM sensor-read window cap.
    val yMin = -4f; val yMax = 18f; val yRange = yMax - yMin

    fun hourToLabel(h: Float): String {
        val norm = ((h % 24f) + 24f) % 24f
        return String.format(Locale.US, "%02d:00", norm.toInt())
    }

    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            // Header: title + trend-score.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Schedule")
                    Text(uiString(R.string.l10n_sleep_screen_bedtime_wake_time_b2a22c32), style = NoopType.headline, color = Palette.textPrimary)
                    Text(uiString(R.string.l10n_sleep_screen_sleep_window_over_recent_nights_cc5fd9b8), style = NoopType.footnote, color = Palette.textSecondary)
                }
                Text(uiString(R.string.l10n_sleep_screen_consistencypct_roundtoint_b23a9d40, consistencyPct.roundToInt()), style = NoopType.chartValue, color = Palette.restColor)
            }

            // Canvas chart — clipped so bars never bleed outside the 160dp box. The nightly
            // sleep-window bars + wake marker read in the Rest world's indigo; the bed marker keeps
            // the periwinkle (metricPurple) so the two overlays stay distinguishable. (Bevel)
            val accentColor = Palette.restColor
            val purpleColor = Palette.metricPurple
            val hairlineColor = Palette.hairline
            val labelArgb = Palette.textTertiary.toArgb()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .clip(RoundedCornerShape(Metrics.cornerSm))
                    .semantics { contentDescription = uiString(R.string.l10n_sleep_screen_sleep_consistency_nightly_bed_and_wake_14526f89) }
                    .drawBehind {
                        val yAxisW = 52f
                        val chartW = size.width - yAxisW
                        val chartH = size.height

                        val gridHours = listOf(-4f, 0f, 4f, 8f, 12f, 16f)
                        // The top "20:00" was drawn at x=0 with its baseline pinned to y=20, so its
                        // glyphs bled above the chart top and into the card's rounded top-left corner and
                        // got cropped (#443). Fix: a smaller label that fits the 52px gutter, and a
                        // baseline that's CENTRED on each gridline then clamped so the full glyph
                        // (ascent..descent) clears the rounded corners (cornerSm, in px) top and bottom.
                        val cornerPx = Metrics.cornerSm.toPx()
                        val paint = android.graphics.Paint().apply {
                            color = labelArgb
                            textSize = 20f
                            isAntiAlias = true
                        }
                        val fm = paint.fontMetrics
                        gridHours.forEach { h ->
                            val y = (chartH * ((h - yMin) / yRange)).coerceIn(0f, chartH)
                            drawLine(color = hairlineColor, start = Offset(yAxisW, y), end = Offset(size.width, y), strokeWidth = 1f)
                            val baseline = (y - (fm.ascent + fm.descent) / 2f)
                                .coerceIn(cornerPx - fm.ascent, chartH - fm.descent)
                            // Small left inset (4px) keeps the text off the very edge; at these clamped
                            // baselines every label sits clear of the rounded corner arc.
                            drawContext.canvas.nativeCanvas.drawText(hourToLabel(h), 4f, baseline, paint)
                        }

                        // Per-night bars (bed → wake), coordinates clamped to [0, chartH].
                        val barW = (chartW / timings.size * 0.6f).coerceAtLeast(4f)
                        val step = chartW / timings.size
                        timings.forEachIndexed { i, t ->
                            val cx = yAxisW + step * i + step / 2f
                            val rawBedY = chartH * ((t.bedHour - yMin) / yRange)
                            val rawWakeY = chartH * ((t.wakeHour - yMin) / yRange)
                            val topY = minOf(rawBedY, rawWakeY).coerceIn(0f, chartH)
                            val botY = maxOf(rawBedY, rawWakeY).coerceIn(0f, chartH)
                            val barH = (botY - topY).coerceAtLeast(4f)
                            drawRoundRect(
                                color = accentColor.copy(alpha = 0.65f),
                                topLeft = Offset(cx - barW / 2f, topY),
                                size = Size(barW, barH),
                                cornerRadius = CornerRadius(barW / 4f),
                            )
                        }

                        // Dashed typical bed (purple) / wake (accent) overlay lines.
                        val dashLen = 12f; val gapLen = 8f
                        listOf(typicalBed to purpleColor, typicalWake to accentColor).forEach { (h, col) ->
                            val y = (chartH * ((h - yMin) / yRange)).coerceIn(0f, chartH)
                            var x = yAxisW
                            while (x < size.width) {
                                drawLine(col.copy(alpha = 0.7f), Offset(x, y), Offset(minOf(x + dashLen, size.width), y), strokeWidth = 2f)
                                x += dashLen + gapLen
                            }
                        }
                    },
            ) {}

            // X-axis day labels (first, mid, last).
            Row(modifier = Modifier.fillMaxWidth().padding(start = 52.dp)) {
                val xLabels = listOf(
                    timings.firstOrNull()?.label.orEmpty(),
                    timings.getOrNull(timings.size / 2)?.label.orEmpty(),
                    timings.lastOrNull()?.label.orEmpty(),
                )
                xLabels.forEach { lbl ->
                    Text(lbl, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                SleepLegendDot("Typical bedtime  $typicalBedLabel", Palette.metricPurple)
                SleepLegendDot("Wake  $typicalWakeLabel", Palette.restColor)
            }

            SleepHairline()
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    "Score" to "${consistencyPct.roundToInt()}%",
                    "Typical" to "${((bedSdH + wakeSdH) / 2f * 60f).roundToInt()} min SD",
                    "Nights" to "${timings.size}",
                ).forEach { (lbl, v) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(lbl, color = Palette.textTertiary)
                        Text(v, style = NoopType.captionNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

