package com.noop.ui

import com.noop.R
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.MetricRangeStat
import com.noop.analytics.RangeReport
import com.noop.analytics.RangeReportEngine
import com.noop.analytics.ReportDisplayUnits
import com.noop.analytics.ReportMetric
import com.noop.analytics.ReportTrend
import com.noop.data.DailyMetric
import java.io.File
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Trends Report (#436)
//
// Kotlin parity for the macOS/iOS shareable offline trends report. Builds the five
// metric day→value maps from the merged DailyMetric history, calls the pure, unit-tested
// RangeReportEngine for a chosen range, renders a clean one-page PDF with android.graphics
// (a deterministic native Canvas — no Compose-window dependency), saves it to the app's
// cache via the existing FileProvider, and fires an ACTION_SEND share intent. No network.
//
// Honesty: an empty range (no metric carried a reading) renders a friendly "not enough
// data in this range yet" page, never a blank or fabricated sheet.

// MARK: - Range options (mirror Swift ReportRange)

/** The export window choices: trailing N days, or all history. */
enum class ReportRange(val days: Int?, val label: String, val longName: String) {
    Days30(30, "30d", "Last 30 days"),
    Days90(90, "90d", "Last 90 days"),
    Days180(180, "6M", "Last 6 months"),
    Days365(365, "1Y", "Last year"),
    All(null, "All", "All history"),
}

// MARK: - Data builder (pure glue over the engine)

object TrendsReportData {

    /**
     * The nine day→value maps the engine consumes, keyed by ReportMetric.
     *
     * [stressByDay] is the persisted daily stress series ("yyyy-MM-dd" → 0–3), the same
     * stored series the Stress screen prioritises (#457). It isn't carried on DailyMetric, so
     * the caller loads it (via metricSeries) and passes it in; absent days stay out.
     */
    fun metricMaps(
        days: List<DailyMetric>,
        stressByDay: Map<String, Double> = emptyMap(),
    ): Map<ReportMetric, Map<String, Double>> {
        val workouts = HashMap<String, Double>()
        val recovery = HashMap<String, Double>()
        val sleepHours = HashMap<String, Double>()
        val hrv = HashMap<String, Double>()
        val restingHr = HashMap<String, Double>()
        val strain = HashMap<String, Double>()
        val respRate = HashMap<String, Double>()
        val skinTempDev = HashMap<String, Double>()
        for (d in days) {
            // Workouts logged that day (#457). Present on a recorded day (0 on a rest day), so
            // the row reflects the full window's activity cadence.
            d.exerciseCount?.let { workouts[d.day] = it.toDouble() }
            d.recovery?.let { recovery[d.day] = it }
            // Sleep reported in HOURS (the metric's unit); totalSleepMin is minutes asleep.
            // Days with no in-bed sleep stay absent.
            d.totalSleepMin?.let { if (it > 0) sleepHours[d.day] = it / 60.0 }
            d.avgHrv?.let { hrv[d.day] = it }
            d.restingHr?.let { restingHr[d.day] = it.toDouble() }
            d.strain?.let { strain[d.day] = it }
            // In-sleep physiology (v7 columns). Absent on days the strap didn't measure them.
            d.respRateBpm?.let { respRate[d.day] = it }
            d.skinTempDevC?.let { skinTempDev[d.day] = it }
        }
        // Daily stress score (#457), clamped to its 0–3 scale. Stored-only — the report never
        // re-derives a stress value (unlike the live Stress screen).
        val stress = stressByDay.mapValues { it.value.coerceIn(0.0, 3.0) }
        return mapOf(
            ReportMetric.WORKOUTS to workouts,
            ReportMetric.STRESS to stress,
            ReportMetric.RECOVERY to recovery,
            ReportMetric.SLEEP_HOURS to sleepHours,
            ReportMetric.HRV to hrv,
            ReportMetric.RESTING_HR to restingHr,
            ReportMetric.STRAIN to strain,
            ReportMetric.RESP_RATE to respRate,
            ReportMetric.SKIN_TEMP_DEV to skinTempDev,
        )
    }

    /**
     * The inclusive [start, end] "yyyy-MM-dd" window for a range, anchored to today's local
     * day (so a 30-day export is the last 30 calendar days, not the last 30 rows — matching
     * TrendsScreen's window rule). For [ReportRange.All], start is the earliest day present.
     */
    fun window(range: ReportRange, days: List<DailyMetric>, today: String): Pair<String, String> {
        val n = range.days ?: return Pair(days.minOfOrNull { it.day } ?: today, today)
        // Trailing N calendar days ending today; ISO yyyy-MM-dd sorts chronologically.
        val start = LocalDate.parse(today).minusDays((n - 1).toLong()).toString()
        return Pair(start, today)
    }

    /** Build the full report for a range from a DailyMetric history (+ stored stress — #457). */
    fun report(
        range: ReportRange,
        days: List<DailyMetric>,
        today: String,
        stressByDay: Map<String, Double> = emptyMap(),
        units: ReportDisplayUnits = ReportDisplayUnits.STORED,
    ): RangeReport {
        val (start, end) = window(range, days, today)
        return RangeReportEngine.build(metricMaps(days, stressByDay), start, end, units)
    }

    /** The in-range sparkline series (chronological values) for one metric. */
    fun series(
        metric: ReportMetric,
        days: List<DailyMetric>,
        start: String,
        end: String,
        stressByDay: Map<String, Double> = emptyMap(),
    ): List<Double> {
        val map = metricMaps(days, stressByDay)[metric] ?: emptyMap()
        return map.filter { it.key in start..end }.toList().sortedBy { it.first }.map { it.second }
    }
}

// MARK: - Metric → colour (mirror Swift's per-metric hue; raw ARGB for the native Canvas)

private fun ReportMetric.accentArgb(): Int = when (this) {
    ReportMetric.WORKOUTS -> 0xFFD98A3D.toInt()       // activity → the Effort (amber) world
    ReportMetric.STRESS -> 0xFFF0A020.toInt()         // the Stress world hue (matches stressColor)
    ReportMetric.RECOVERY -> 0xFF03E095.toInt()       // charge — WHOOP green (matches chargeColor)
    ReportMetric.STRAIN -> 0xFF4090E0.toInt()         // effort — WHOOP blue (matches effortColor)
    ReportMetric.SLEEP_HOURS -> 0xFF83A0B8.toInt()    // rest — slate (matches restColor)
    ReportMetric.HRV -> 0xFF4A90E2.toInt()            // HRV shares the rest/blue world
    ReportMetric.RESTING_HR -> 0xFFE0662F.toInt()     // burnt-orange risk hue
    ReportMetric.RESP_RATE -> 0xFF3FA9C9.toInt()      // breath / air — teal (metricCyan)
    ReportMetric.SKIN_TEMP_DEV -> 0xFFE0662F.toInt()  // temperature — warm (shares RHR's hue)
}

// MARK: - Formatting (mirror the Swift page)

/**
 * The report's pure value formatting, deliberately OUTSIDE [TrendsReportRenderer].
 *
 * That object builds `Typeface`s at class-init, so touching it from a JVM unit test throws
 * `ExceptionInInitializerError` — which left the metric-card row, the exact string #1637 was filed
 * about, impossible to assert. The formatting has no Android dependency, so it lives here and the
 * renderer delegates. Swift keeps these on `TrendsReportPage`, where a SwiftUI struct is already
 * constructible in a test; the STRINGS are what parity pins, not where the helper sits.
 */
internal object TrendsReportFormat {

    /**
     * One row's value + unit, exactly as the PDF prints it.
     *
     * One decimal for sleep hours, respiratory rate, skin-temp Δ and the 0–3 stress score
     * ([ReportMetric.usesOneDecimal]); whole numbers for the scores + bpm + ms + workout count.
     * Skin temp is a signed deviation, so a positive reading gets an explicit "+" to keep it from
     * reading as an absolute temperature.
     *
     * Both the value and its unit go through [RangeReportEngine] (#1637) — the same conversion the
     * headline sentences use — so the exported page cannot print a unit the app disagrees with.
     * Effort gains a decimal once rescaled to the 0–21 axis, where a whole number would throw away
     * most of the resolution the 0–100 value carried.
     */
    fun valueText(v: Double, metric: ReportMetric, units: ReportDisplayUnits): String {
        val unit = RangeReportEngine.displayUnit(metric, units)
        val shown = RangeReportEngine.displayValue(v, metric, units)
        val oneDecimal = metric.usesOneDecimal ||
            (metric == ReportMetric.STRAIN && units.effortFactor != 1.0)
        // The whole-number branch keeps `roundToInt` (ties toward +∞) where Swift rounds away from
        // zero. The two agree for every NON-NEGATIVE input, and this branch only ever serves
        // Recovery / HRV / Resting HR / Effort — all non-negative by construction — so it cannot
        // diverge today. A signed whole-number metric would break that: give it one decimal, or
        // round it away from zero the way [round1] does.
        var num = if (oneDecimal) round1(shown) else "${shown.roundToInt()}"
        if (metric == ReportMetric.SKIN_TEMP_DEV && shown > 0) num = "+$num"
        return if (unit.isEmpty()) num else "$num $unit"
    }

    /** The card's headline read-out: the range mean through [valueText]. */
    fun meanText(stat: MetricRangeStat, units: ReportDisplayUnits): String =
        valueText(stat.mean, stat.metric, units)

    /**
     * One decimal, rounded the SAME way the engine and the Swift page round.
     *
     * This used `roundToInt`, which breaks ties toward positive infinity, while Swift's `round1Text`
     * uses `.rounded()` — half away from zero. Positive values agree; every negative tie did not, so
     * a stored −0.25 Δ°C printed −0.3 on iOS and −0.2 on Android, and −0.05 printed −0.1 against a
     * sign-losing 0.0. Skin temp is the report's only signed metric, so it was the only row that
     * could reach it. [RangeReportEngine.round1] already implements away-from-zero for exactly this
     * reason; delegating leaves ONE rounding rule per platform instead of a second one to drift.
     */
    fun round1(x: Double): String =
        String.format(Locale.US, "%.1f", RangeReportEngine.round1(x))
}

// MARK: - PDF renderer (deterministic native Canvas → PdfDocument)

object TrendsReportRenderer {

    // Page geometry — A4-ish portrait at the same ~612pt width the Swift page uses, so the
    // two platforms produce visually matched sheets.
    private const val PAGE_W = 612
    private const val PAGE_H = 850
    private const val MARGIN = 28f

    // Palette (raw ARGB — the same hex tokens as Theme.kt's Palette / StrandPalette dark, WHOOP-reset).
    private const val SURFACE_BASE = 0xFF121518.toInt()
    private const val CARD_TOP = 0xFF15243C.toInt()
    private const val CARD_BOTTOM = 0xFF0B1424.toInt()
    private const val HAIRLINE = 0xFF21304A.toInt()
    private const val TEXT_PRIMARY = 0xFFF4F6F8.toInt()
    private const val TEXT_SECONDARY = 0xFFC8CFD8.toInt()
    private const val TEXT_TERTIARY = 0xFF8A94A4.toInt()
    private const val ACCENT = 0xFF60A0E0.toInt()     // WHOOP blue accent (gold killed 2026-06-22)
    private const val POSITIVE = 0xFF03E095.toInt()   // WHOOP green (matches statusPositive)
    private const val NEGATIVE = 0xFFE0662F.toInt()

    private val sans = Typeface.create("sans-serif", Typeface.NORMAL)
    private val sansBold = Typeface.create("sans-serif", Typeface.BOLD)
    private val sansMedium = Typeface.create("sans-serif-medium", Typeface.NORMAL)

    /**
     * Render [report] (+ its sparkline [series]) to a one-page PDF file in the cache and
     * return it, or null on failure. Pure drawing — no view tree, so it's safe off the main
     * thread and never depends on a window.
     */
    fun renderPdf(
        context: Context,
        report: RangeReport,
        range: ReportRange,
        series: Map<ReportMetric, List<Double>>,
        generatedOn: String,
        units: ReportDisplayUnits = ReportDisplayUnits.STORED,
    ): File? = runCatching {
        val doc = PdfDocument()
        val pageInfo = PdfDocument.PageInfo.Builder(PAGE_W, PAGE_H, 1).create()
        val page = doc.startPage(pageInfo)
        val canvas = page.canvas
        canvas.drawColor(SURFACE_BASE)

        var y = MARGIN
        y = drawHeader(canvas, report, range, y)
        y += 18f
        if (report.isEmpty) {
            drawEmptyState(canvas, range, y)
        } else {
            y = drawHeadlines(canvas, report, y)
            y += 18f
            drawMetrics(canvas, report, series, y, units)
        }
        drawFooter(canvas, generatedOn)

        doc.finishPage(page)

        val dir = File(context.cacheDir, "reports").apply { mkdirs() }
        val file = File(dir, "NOOP-trends-${report.start}_to_${report.end}.pdf")
        file.outputStream().use { doc.writeTo(it) }
        doc.close()
        file
    }.getOrNull()

    // --- Header ---

    private fun drawHeader(canvas: Canvas, report: RangeReport, range: ReportRange, top: Float): Float {
        val cardTop = top
        val cardH = 92f
        drawCard(canvas, MARGIN, cardTop, PAGE_W - MARGIN, cardTop + cardH, ACCENT)

        val left = MARGIN + 16f
        var ty = cardTop + 26f
        text(canvas, "NOOP", left, ty, 11f, sansBold, ACCENT, letterSpacing = 0.12f)
        textRight(canvas, range.longName.uppercase(), PAGE_W - MARGIN - 16f, ty, 10f, sansBold, TEXT_TERTIARY)
        ty += 30f
        text(canvas, "Trends report", left, ty, 26f, sansBold, TEXT_PRIMARY)
        ty += 22f
        val span = report.totalDays
        val dayWord = if (span == 1) "day" else "days"
        text(
            canvas,
            "${prettyDate(report.start)}-${prettyDate(report.end)}   ·   $span $dayWord",
            left, ty, 12f, sans, TEXT_SECONDARY,
        )
        return cardTop + cardH
    }

    // --- Headlines ---

    private fun drawHeadlines(canvas: Canvas, report: RangeReport, top: Float): Float {
        val lineH = 18f
        val pad = 16f
        val headlineCount = report.headlines.size
        val cardH = 30f + headlineCount * lineH + pad
        drawCard(canvas, MARGIN, top, PAGE_W - MARGIN, top + cardH, ACCENT)

        val left = MARGIN + 16f
        var ty = top + 22f
        text(canvas, "SUMMARY", left, ty, 10f, sansBold, ACCENT, letterSpacing = 0.1f)
        ty += 8f
        text(canvas, "What changed", left, ty + 10f, 16f, sansBold, TEXT_PRIMARY)
        ty += 28f
        for (line in report.headlines) {
            text(canvas, "•  $line", left, ty, 12f, sans, TEXT_PRIMARY, maxWidth = PAGE_W - MARGIN - left - 16f)
            ty += lineH
        }
        return top + cardH
    }

    // --- Metric cards ---

    private fun drawMetrics(
        canvas: Canvas,
        report: RangeReport,
        series: Map<ReportMetric, List<Double>>,
        top: Float,
        units: ReportDisplayUnits,
    ): Float {
        var y = top
        text(canvas, "BY THE NUMBERS", MARGIN, y + 4f, 10f, sansBold, TEXT_TERTIARY, letterSpacing = 0.1f)
        y += 10f
        text(canvas, "Metrics", MARGIN, y + 14f, 16f, sansBold, TEXT_PRIMARY)
        y += 26f

        for (stat in report.metrics) {
            y = drawMetricCard(canvas, stat, series[stat.metric] ?: emptyList(), y, units)
            y += 10f
        }
        return y
    }

    private fun drawMetricCard(
        canvas: Canvas,
        stat: MetricRangeStat,
        spark: List<Double>,
        top: Float,
        units: ReportDisplayUnits,
    ): Float {
        val cardH = 96f
        val accent = stat.metric.accentArgb()
        drawCard(canvas, MARGIN, top, PAGE_W - MARGIN, top + cardH, accent)

        val left = MARGIN + 16f
        val right = PAGE_W - MARGIN - 16f
        var ty = top + 24f

        // Title + mean + trend chip.
        text(canvas, stat.metric.label.uppercase(), left, ty, 11f, sansBold, accent, letterSpacing = 0.08f)
        val meanStr = TrendsReportFormat.meanText(stat, units)
        textRight(canvas, meanStr, right, ty, 14f, sansMedium, TEXT_PRIMARY)

        // Sparkline (decorative) below the title row.
        val sparkTop = top + 34f
        val sparkBottom = top + 60f
        if (spark.size >= 2) {
            drawSparkline(canvas, spark, left, sparkTop, right - 8f, sparkBottom, accent)
        } else {
            text(canvas, "Single reading in range", left, sparkTop + 16f, 11f, sans, TEXT_TERTIARY)
        }

        // Divider.
        line(canvas, left, top + 66f, right, top + 66f, HAIRLINE)

        // Footer stats: Avg / Min(day) / Max(day) / Days, evenly spaced.
        val cols = listOf(
            "AVG" to TrendsReportFormat.valueText(stat.mean, stat.metric, units),
            "MIN" to "${TrendsReportFormat.valueText(stat.min.value, stat.metric, units)} · ${prettyDate(stat.min.day)}",
            "MAX" to "${TrendsReportFormat.valueText(stat.max.value, stat.metric, units)} · ${prettyDate(stat.max.day)}",
            "DAYS" to "${stat.n}",
        )
        val colW = (right - left) / cols.size
        cols.forEachIndexed { i, (label, value) ->
            val cx = left + i * colW
            text(canvas, label, cx, top + 80f, 9f, sansBold, TEXT_TERTIARY, letterSpacing = 0.06f)
            text(canvas, value, cx, top + 91f, 11f, sansMedium, TEXT_SECONDARY)
        }

        // Trend chip drawn last so it sits above the divider, right-aligned under the mean.
        drawTrendChip(canvas, stat, right, top + 58f, units)

        return top + cardH
    }

    /**
     * The trend pill beside the mean read-out.
     *
     * Its magnitude must be on the SAME axis as the numbers around it (#1637) — a °C delta next to
     * °F values reads as a contradiction. Both conversions are pure multiplications, so
     * [RangeReportEngine.displayValue] is correct for a delta as well as a level (a °F offset would
     * NOT be, which is why this metric never adds one).
     *
     * The steady/moving decision and the good/bad colour stay on the STORED delta, matching the
     * trend verdict itself — a cosmetic toggle must not turn a "steady" chip into a moving one.
     */
    private fun drawTrendChip(
        canvas: Canvas,
        stat: MetricRangeStat,
        right: Float,
        baselineY: Float,
        units: ReportDisplayUnits,
    ) {
        val d = stat.halfDelta
        val (label, color) = if (stat.trend == ReportTrend.FLAT || abs(d) < 0.05) {
            "steady" to TEXT_TERTIARY
        } else {
            val up = d > 0
            val sign = if (up) "+" else "−"
            // Signed-deviation metric (skin-temp Δ): show the move, no good/bad verdict.
            val c = if (stat.metric.framesGoodBad) {
                if (up == stat.metric.higherIsBetter) POSITIVE else NEGATIVE
            } else {
                TEXT_TERTIARY
            }
            val shown = abs(RangeReportEngine.displayValue(d, stat.metric, units))
            "$sign${TrendsReportFormat.round1(shown)}" to c
        }
        // A small tinted pill.
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = sansMedium
            textSize = 10f
            this.color = color
        }
        val tw = paint.measureText(label)
        val padX = 7f
        val pillRight = right
        val pillLeft = pillRight - tw - padX * 2
        val pillTop = baselineY - 12f
        val pillBottom = baselineY + 3f
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = withAlpha(color, 0.14f) }
        canvas.drawRoundRect(RectF(pillLeft, pillTop, pillRight, pillBottom), 8f, 8f, bg)
        canvas.drawText(label, pillLeft + padX, baselineY, paint)
    }

    // --- Empty state ---

    private fun drawEmptyState(canvas: Canvas, range: ReportRange, top: Float) {
        val cardH = 110f
        drawCard(canvas, MARGIN, top, PAGE_W - MARGIN, top + cardH, null)
        val left = MARGIN + 16f
        text(canvas, "Not enough data in this range yet", left, top + 30f, 16f, sansBold, TEXT_PRIMARY)
        val body = "No workout, stress, recovery, sleep, HRV, resting-HR, strain, respiratory-rate or " +
            "skin-temp readings fell inside ${range.longName.lowercase()}. Wear your strap a few more days, " +
            "or pick a wider range, then export again."
        drawWrapped(canvas, body, left, top + 52f, PAGE_W - MARGIN - left - 16f, 16f, 12f, sans, TEXT_SECONDARY)
    }

    // --- Footer ---

    private fun drawFooter(canvas: Canvas, generatedOn: String) {
        val y = PAGE_H - MARGIN - 12f
        // Provenance legend (#457): make clear which numbers are measured vs. NOOP's own derived scores,
        // so a clinician reading the PDF isn't misled into treating Recovery/Strain as clinical measures.
        // Sits above the hairline; wraps to the page width (~4 lines at this size).
        val legend = "How to read this: HRV, Resting HR, Sleep duration, Respiratory rate and Skin " +
            "temperature are measured from the strap (skin temp is shown as the deviation from your own " +
            "baseline). Workouts is the count of activities you logged or that were detected. Recovery, " +
            "Strain and Stress are NOOP's own on-device scores, not clinical measures - Recovery is a daily " +
            "readiness composite (HRV, resting HR, sleep and skin-temp trend), Strain is cardiovascular load " +
            "derived from heart rate, and Stress is a 0-3 autonomic-load index from resting HR and HRV."
        drawWrapped(canvas, legend, MARGIN, y - 52f, PAGE_W - 2 * MARGIN, 11f, 9f, sans, TEXT_TERTIARY)
        line(canvas, MARGIN, y - 14f, PAGE_W - MARGIN, y - 14f, HAIRLINE)
        text(
            canvas,
            "Generated by NOOP on $generatedOn · all on-device, no account, no cloud.",
            MARGIN, y, 10f, sans, TEXT_TERTIARY,
        )
        text(canvas, "Informational only - not medical advice.", MARGIN, y + 12f, 10f, sans, TEXT_TERTIARY)
    }

    // --- Primitives ---

    private fun drawCard(canvas: Canvas, l: Float, t: Float, r: Float, b: Float, tint: Int?) {
        val rect = RectF(l, t, r, b)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = android.graphics.LinearGradient(
                l, t, r, b, CARD_TOP, CARD_BOTTOM, android.graphics.Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRoundRect(rect, 18f, 18f, fill)
        if (tint != null) {
            // Faint diagonal hue wash, mirroring the frosted-card surface.
            val wash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = android.graphics.LinearGradient(
                    l, t, r, b,
                    intArrayOf(withAlpha(tint, 0.10f), withAlpha(tint, 0.03f), AndroidColor.TRANSPARENT),
                    floatArrayOf(0f, 0.5f, 1f),
                    android.graphics.Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRoundRect(rect, 18f, 18f, wash)
        }
        val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1f
            color = if (tint != null) withAlpha(tint, 0.22f) else HAIRLINE
        }
        canvas.drawRoundRect(rect, 18f, 18f, border)
    }

    private fun drawSparkline(canvas: Canvas, values: List<Double>, l: Float, t: Float, r: Float, b: Float, color: Int) {
        val minV = values.min()
        val maxV = values.max()
        val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
        val w = (r - l).coerceAtLeast(1f)
        val h = (b - t).coerceAtLeast(1f)
        val path = Path()
        values.forEachIndexed { i, v ->
            val x = l + (i.toFloat() / (values.size - 1)) * w
            val norm = ((v - minV) / span).toFloat().coerceIn(0f, 1f)
            val y = b - norm * h
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            this.color = color
        }
        canvas.drawPath(path, paint)
        // Bright head dot at the latest sample (the "now" idiom).
        val lastX = r
        val lastNorm = ((values.last() - minV) / span).toFloat().coerceIn(0f, 1f)
        val lastY = b - lastNorm * h
        canvas.drawCircle(lastX, lastY, 3f, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
    }

    private fun line(canvas: Canvas, x0: Float, y0: Float, x1: Float, y1: Float, color: Int) {
        canvas.drawLine(x0, y0, x1, y1, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; strokeWidth = 1f })
    }

    private fun text(
        canvas: Canvas, s: String, x: Float, y: Float, size: Float, tf: Typeface, color: Int,
        letterSpacing: Float = 0f, maxWidth: Float = 0f,
    ) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = tf; textSize = size; this.color = color; this.letterSpacing = letterSpacing
        }
        val str = if (maxWidth > 0f) ellipsize(paint, s, maxWidth) else s
        canvas.drawText(str, x, y, paint)
    }

    private fun textRight(canvas: Canvas, s: String, right: Float, y: Float, size: Float, tf: Typeface, color: Int) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = tf; textSize = size; this.color = color; textAlign = Paint.Align.RIGHT
        }
        canvas.drawText(s, right, y, paint)
    }

    /** Word-wrap [s] into lines, drawing up to the card's height. */
    private fun drawWrapped(
        canvas: Canvas, s: String, x: Float, y: Float, maxWidth: Float, lineH: Float,
        size: Float, tf: Typeface, color: Int,
    ) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = tf; textSize = size; this.color = color }
        var ty = y
        val current = StringBuilder()
        for (word in s.split(" ")) {
            val trial = if (current.isEmpty()) word else "$current $word"
            if (paint.measureText(trial) > maxWidth && current.isNotEmpty()) {
                canvas.drawText(current.toString(), x, ty, paint)
                ty += lineH
                current.clear()
                current.append(word)
            } else {
                if (current.isNotEmpty()) current.append(" ")
                current.append(word)
            }
        }
        if (current.isNotEmpty()) canvas.drawText(current.toString(), x, ty, paint)
    }

    private fun ellipsize(paint: Paint, s: String, maxWidth: Float): String {
        if (paint.measureText(s) <= maxWidth) return s
        var end = s.length
        while (end > 1 && paint.measureText(s.substring(0, end) + "…") > maxWidth) end--
        return s.substring(0, end) + "…"
    }

    private fun withAlpha(color: Int, alpha: Float): Int {
        val a = (alpha * 255).roundToInt().coerceIn(0, 255)
        return (a shl 24) or (color and 0x00FFFFFF)
    }

    // --- Formatting: see TrendsReportFormat (kept out of this object so it is unit-testable) ---

    /** "Jun 15" from "2026-06-15" via the engine's pure parse (no Calendar/locale). */
    private fun prettyDate(ymd: String): String {
        val p = RangeReportEngine.parseYMD(ymd) ?: return ymd
        val months = arrayOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
        val name = if (p.second in 1..12) months[p.second - 1] else "${p.second}"
        return "$name ${p.third}"
    }
}

// MARK: - Share

object TrendsReportShare {

    /**
     * Build the report for [range] from [days], render the PDF, and fire a share intent via
     * the existing FileProvider. An empty range still produces a valid PDF — the renderer draws
     * an honest "not enough data in this range yet" page rather than a blank or fabricated sheet.
     */
    fun export(
        context: Context,
        days: List<DailyMetric>,
        range: ReportRange,
        stressByDay: Map<String, Double> = emptyMap(),
    ) {
        runCatching {
            val today = LocalDate.now().toString()
            // The user's display settings, resolved once for BOTH the headline sentences (built
            // inside the engine) and the metric cards (drawn by the renderer). Handing the two
            // surfaces different values is how the document would contradict itself (#1637).
            val scale = UnitPrefs.effortScale(context)
            val units = ReportDisplayUnits(
                fahrenheit = UnitPrefs.temperature(context) == TemperatureUnit.FAHRENHEIT,
                // Name the canonical constant rather than deriving it from `effortValue(1.0, )`:
                // the report MULTIPLIES by this, which only agrees while the mapping stays linear.
                effortFactor = if (scale == EffortScale.WHOOP) UnitFormatter.EFFORT_SCALE_FACTOR else 1.0,
            )
            val report = TrendsReportData.report(range, days, today, stressByDay, units)
            val series = ReportMetric.allCases.associateWith {
                TrendsReportData.series(it, days, report.start, report.end, stressByDay)
            }
            val generatedOn = LocalDate.now().format(DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US))
            val file = TrendsReportRenderer.renderPdf(context, report, range, series, generatedOn, units)
                ?: run {
                    Toast.makeText(context, "Couldn't build the report.", Toast.LENGTH_LONG).show()
                    return
                }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP trends report")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share trends report"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the report: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}

// MARK: - Export section (embeddable Composable for Settings / Trends)

/**
 * The trends-report export entry: a short blurb, a range SegmentedPillControl, the resolved
 * range's day-count, and a gold "Export PDF" CTA. Built only from the locked component system.
 * Drop it into Settings (or Trends). Reads the merged history off [vm].
 */
@Composable
fun TrendsReportExportSection(vm: AppViewModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var range by remember { mutableStateOf(ReportRange.Days90) }

    // Stored daily stress series ("yyyy-MM-dd" → 0–3) for the Stress row (#457). Loaded once
    // from the same "my-whoop" series the Stress screen reads; empty until it arrives.
    var stressByDay by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val rows = runCatching {
            vm.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
        }.getOrDefault(emptyList())
        stressByDay = rows.associate { it.day to it.value }
    }

    NoopCard(modifier = modifier, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline("Export")
            Text(uiString(R.string.l10n_trends_report_trends_report_pdf_481e8a5f), style = NoopType.title2, color = Palette.textPrimary)
            Text(
                uiString(R.string.l10n_trends_report_a_clean_shareable_one_page_pdf_a3c4f889) +
                    "and strain over a date range. Built and saved on your phone - nothing leaves the device.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            Overline("Range", color = Palette.textTertiary)
            SegmentedPillControl(
                items = ReportRange.entries.toList(),
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
            Text(range.longName, style = NoopType.footnote, color = Palette.textTertiary)

            // Routed through the unified NoopButton (crisp filled accent, no gold) — the same button
            // system every other CTA uses, mirroring the iOS exportReportRow.
            NoopButton(
                text = uiString(R.string.l10n_trends_report_export_pdf_3dd7d56a),
                leadingIcon = Icons.Filled.IosShare,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                onClick = { TrendsReportShare.export(context, days, range, stressByDay) },
            )

            Text(
                uiString(R.string.l10n_trends_report_the_share_sheet_can_save_the_ecddbca7),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}
