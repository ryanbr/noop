package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.analytics.DaytimeStress
import com.noop.ui.MainActivity
import com.noop.ui.uiString
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * Home-screen widget: today's stress as the intraday curve the Stress screen draws (#2040).
 *
 * Renders purely from the [WidgetSnapshotStore] snapshot, like its siblings, so it costs nothing at
 * draw time and survives process death. Tapping opens the app.
 *
 * The curve is an IMAGE for the same reason the heart-rate trace is: Glance compiles to RemoteViews,
 * which cannot draw. [StressTrace] decides where the ink goes and [StressTraceRenderer] puts it on a
 * Bitmap; the labels stay Glance `Text` so they remain crisp, themed and readable to TalkBack.
 *
 * Honest-blank throughout. An unscored hour is a GAP in the line rather than an interpolation across
 * it, an hour the motion gate masked gets a faint mark along the base instead of a score, and a day
 * with nothing scored shows no chart at all rather than a flat line at zero.
 */
class StressGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        val dark = WidgetTheme.isDark(context)
        provideContent { StressWidgetContent(snap, dark) }
    }

    /** Same defence as its siblings: swap Glance's built-in error layout for ours. The widget heals on
     *  the next successful push. */
    override fun onCompositionError(
        context: Context,
        glanceId: GlanceId,
        appWidgetId: Int,
        throwable: Throwable,
    ) {
        runCatching {
            val rv = android.widget.RemoteViews(context.packageName, R.layout.noop_widget_error)
            android.appwidget.AppWidgetManager.getInstance(context).updateAppWidget(appWidgetId, rv)
        }
    }
}

// Local widget colours, mirroring the siblings rather than reading Palette: Glance composes outside the
// app theme, so every widget in this package carries its own copy on purpose.
private fun stressSurfaceColor(dark: Boolean) = if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA)

private fun stressSurface(dark: Boolean) = ColorProvider(stressSurfaceColor(dark))
private fun stressTextPrimary(dark: Boolean) = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
private fun stressTextSecondary(dark: Boolean) = ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))

/**
 * The screen's three-stop ramp, as raw colours the renderer can paint with.
 *
 * These are the same blue / green / amber the Stress screen samples across 0-3, kept as local literals
 * for the reason every colour in this package is one: Glance composes outside the app theme, so the
 * widget cannot read `Palette`. A widget drawing a different ramp from the screen it mirrors would
 * make the same hour look like two different readings.
 */
private fun stressCalm(dark: Boolean) = if (dark) Color(0xFF4C8DFF) else Color(0xFF2D6FE0)
private fun stressSteady(dark: Boolean) = if (dark) Color(0xFF3ECF8E) else Color(0xFF1FA971)
private fun stressTense(dark: Boolean) = if (dark) Color(0xFFE0A62F) else Color(0xFFC8861E)

/** Card padding, both sides. The chart and the axis under it must subtract the SAME figure or the
 *  labels drift out of line with the curve they annotate. */
private const val STRESS_CARD_PADDING_DP = 28f

/** The level scale column plus its gap. One number, read by both the chart and its axis. */
private const val STRESS_SCALE_COLUMN_DP = 20f

/** The height the curve BITMAP is drawn at. The chart box takes the card's leftover height by weight,
 *  so its real height is not knowable here; this is what the bitmap is drawn at and the `Image` scales
 *  from, chosen generously so the common case downscales. */
private const val STRESS_CHART_TARGET_DP = 92f

/** The chart width for a given widget width, the one place that arithmetic happens. */
private fun stressChartWidthDp(widthDp: Float): Float =
    (widthDp - STRESS_CARD_PADDING_DP - STRESS_SCALE_COLUMN_DP).coerceAtLeast(24f)

/** One decimal, the same precision the screen prints a 0-3 score at. */
private fun formatLevel(value: Double): String = String.format(Locale.getDefault(), "%.1f", value)

@Composable
private fun StressWidgetContent(snap: WidgetSnapshot, dark: Boolean) {
    val size = LocalSize.current
    val stats = StressTrace.stats(snap.stressSeries)

    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(stressSurface(dark))
            .cornerRadius(16.dp)
            .padding(14.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        Text(
            text = uiString(R.string.l10n_stress_screen_stress_bad33342),
            style = TextStyle(
                color = stressTextPrimary(dark), fontSize = 13.sp, fontWeight = FontWeight.Medium,
            ),
        )
        Spacer(GlanceModifier.height(6.dp))

        // Built OUT here, not inside the semantics lambda: the i18n audit cannot see copy assigned
        // inside one, so a literal written there would ship English to every locale (#571).
        val stressLabel = uiString(R.string.l10n_stress_screen_stress_bad33342)
        val ofThree = uiString(R.string.l10n_stress_screen_of_3_46203495)
        val latest = snap.stressSeries.lastOrNull { it.level != null }?.level
        // WHY there is no number, in words. A bare dash under a healthy-looking HR widget reads as a
        // broken widget, and the two states behind it are different answers: outside the scored window
        // nothing is coming until morning, whereas inside it the day simply has not produced a scorable
        // hour yet. The Apple sheet already says "Calibrating" for the second; this says which is which.
        // Built OUT here for the same reason `ofThree` is (#571).
        val hourNow = java.time.LocalTime.now().hour
        val outsideScoredWindow = !DaytimeStress.isWakingHourOfDay(hourNow)
        val emptyReason = if (outsideScoredWindow) {
            uiString(R.string.l10n_stress_glance_widget_resumes_in_the_morning_a640b49f)
        } else {
            uiString(R.string.score_state_title_calibrating)
        }
        // Assembled by concatenation rather than as a template, so no English word is ever written
        // here: every part comes from a resource, and the separators carry no letters to translate.
        val spoken = latest?.let { stressLabel + " " + formatLevel(it) + " " + ofThree }
            ?: (stressLabel + " " + emptyReason)

        Row(verticalAlignment = Alignment.Vertical.Bottom) {
            Text(
                text = latest?.let { formatLevel(it) } ?: "—",
                style = TextStyle(
                    color = stressTextPrimary(dark), fontSize = 30.sp, fontWeight = FontWeight.Bold,
                ),
                modifier = GlanceModifier.semantics { contentDescription = spoken },
            )
            if (latest != null) {
                Spacer(GlanceModifier.width(4.dp))
                Text(
                    text = ofThree,
                    style = TextStyle(color = stressTextSecondary(dark), fontSize = 12.sp),
                )
            } else {
                Spacer(GlanceModifier.width(6.dp))
                Text(
                    text = emptyReason,
                    style = TextStyle(color = stressTextSecondary(dark), fontSize = 12.sp),
                )
            }
            if (stats != null) {
                Spacer(GlanceModifier.width(10.dp))
                // A chip, not loose text: it is a summary OF the chart, and the tinted rounded ground
                // separates it from the scale label beside it.
                val peakTime = DateFormat.getTimeInstance(DateFormat.SHORT)
                    .format(Date(stats.peak.ts * 1000))
                Text(
                    text = uiString(R.string.trends_peak) +
                        " ${formatLevel(stats.peak.level ?: 0.0)} · $peakTime",
                    style = TextStyle(color = stressTextPrimary(dark), fontSize = 11.sp),
                    modifier = GlanceModifier
                        .background(ColorProvider(stressTense(dark).copy(alpha = 0.18f)))
                        .cornerRadius(10.dp)
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }

        // No scored hour, no chart row at all. A freshly placed widget, or a day before the first
        // scorable hour, would otherwise reserve the height and show a blank rectangle, and a void
        // reads as broken where a shorter widget reads as new.
        if (stats != null) {
            Spacer(GlanceModifier.height(8.dp))
            StressTraceImage(snap, dark, widthDp = size.width.value,
                             modifier = GlanceModifier.defaultWeight())
            StressTimeAxis(snap, dark)
        }

        if (snap.updatedAtMs > 0) {
            Spacer(GlanceModifier.height(4.dp))
            val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(snap.updatedAtMs))
            Row(
                modifier = GlanceModifier.fillMaxWidth(),
                horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
            ) {
                Text(
                    text = if (stats != null) {
                        uiString(R.string.l10n_stress_screen_avg_a178769d) +
                            " ${formatLevel(stats.mean)} · " +
                            uiString(R.string.l10n_hr_glance_widget_updated_time_1b5feedb, time)
                    } else {
                        uiString(R.string.l10n_hr_glance_widget_updated_time_1b5feedb, time)
                    },
                    style = TextStyle(color = stressTextSecondary(dark), fontSize = 10.sp),
                )
            }
        }
    }
}

/**
 * The curve, plus the 0-3 scale down its right edge.
 *
 * Bitmap construction is wrapped: an OOM or a hostile size must leave the widget without a chart, not
 * without a widget. Sized exactly as the heart-rate trace is, and for the same measured reasons:
 * height as displayed, width with headroom so the `Image` downscales rather than stretching a stroke
 * horizontally on a launcher that under-reports its own width.
 */
@Composable
private fun StressTraceImage(
    snap: WidgetSnapshot,
    dark: Boolean,
    widthDp: Float,
    // Weighted by the CALLER: Glance scopes defaultWeight() to Row/ColumnScope, so a composable cannot
    // claim its own share of the parent from in here.
    modifier: GlanceModifier,
) {
    val context = LocalContext.current
    val density = context.resources.displayMetrics.density
    val chartWidthDp = stressChartWidthDp(widthDp)
    // ONE box for both the geometry and the bitmap, so the curve cannot be drawn to coordinates the
    // bitmap has no room for.
    val hPx = (STRESS_CHART_TARGET_DP * density).toInt().coerceAtLeast(1)
    val wPx = HrTrace.widestAtHeight((chartWidthDp * density).toInt(), hPx)

    // Measured for the same reason the heart-rate trace is: this is a BITMAP rather than a few KB of
    // text, and the widget cost counters are what make "the widget drains the battery" decidable.
    val startedNs = System.nanoTime()
    val bmp = runCatching {
        StressTraceRenderer.render(
            segments = StressTrace.segments(snap.stressSeries, wPx.toFloat(), hPx.toFloat()),
            movingMarks = StressTrace.movingMarks(snap.stressSeries, wPx.toFloat()),
            highPoints = StressTrace.highPoints(snap.stressSeries, wPx.toFloat(), hPx.toFloat()),
            widthPx = wPx,
            heightPx = hPx,
            calmColor = stressCalm(dark).toArgb(),
            steadyColor = stressSteady(dark).toArgb(),
            tenseColor = stressTense(dark).toArgb(),
            backgroundColor = stressSurfaceColor(dark).toArgb(),
            // Composited for the same reason the marks are: the bitmap has no alpha channel, so the
            // translucency has to be resolved against the card before it is handed over.
            fillTopColor = stressSteady(dark).copy(alpha = 0.35f)
                .compositeOver(stressSurfaceColor(dark)).toArgb(),
            // Composited against the card rather than passed as a translucent colour: the bitmap is
            // RGB_565 and has no alpha to fade into, so an alpha here would have drawn solid.
            markColor = stressTextSecondary(dark).getColor(context)
                .copy(alpha = 0.5f).compositeOver(stressSurfaceColor(dark)).toArgb(),
            strokePx = 2f * density,
        )
    }.getOrNull()
    if (bmp != null) {
        WidgetTelemetry.noteRender(
            bytes = wPx * hPx * HrTrace.BYTES_PER_PIXEL,
            elapsedMs = (System.nanoTime() - startedNs) / 1_000_000,
        )
    }

    // Scale FIRST, then the chart: the Stress screen puts the 0-3 labels down the left edge, and a
    // widget that mirrors a screen should not mirror it back to front. (The heart-rate widget puts its
    // scale on the right, which is right for a trace whose numbers are read off the end.)
    Row(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = GlanceModifier.fillMaxHeight(),
            horizontalAlignment = Alignment.Horizontal.End,
        ) {
            val ticks = StressTrace.levelTicks()
            ticks.forEachIndexed { i, tick ->
                Text(
                    text = tick.toString(),
                    style = TextStyle(color = stressTextSecondary(dark), fontSize = 10.sp),
                )
                if (i < ticks.size - 1) Spacer(GlanceModifier.defaultWeight())
            }
        }
        Spacer(GlanceModifier.width(6.dp))
        Box(modifier = GlanceModifier.fillMaxHeight().defaultWeight()) {
            if (bmp != null) {
                Image(
                    provider = ImageProvider(bmp),
                    contentDescription = null,
                    modifier = GlanceModifier.fillMaxSize(),
                    // FillBounds, not the default Fit: the width is drawn with headroom so it
                    // downscales, and Fit would letterbox that headroom back into dead space.
                    contentScale = ContentScale.FillBounds,
                )
            }
        }
    }
}

/**
 * The time labels under the curve: first, middle and last SCORED hour (see [StressTrace.timeTicks]).
 *
 * Spread with weighted spacers rather than fixed gaps, so the middle label sits over the middle of the
 * chart whatever width the launcher gave the widget. Formatted through the locale's short time format,
 * so a 12-hour device reads as one; a widget is not the place to impose a clock convention.
 */
@Composable
private fun StressTimeAxis(snap: WidgetSnapshot, dark: Boolean) {
    val ticks = StressTrace.timeTicks(snap.stressSeries)
    // One scored hour names one instant, and a single label pinned to the left edge reads as a stray
    // rather than an axis, so the axis only appears once there is a span to label.
    if (ticks.size < 2) return
    val fmt = DateFormat.getTimeInstance(DateFormat.SHORT)
    Spacer(GlanceModifier.height(2.dp))
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        ticks.forEachIndexed { i, ts ->
            Text(
                text = fmt.format(Date(ts * 1000)),
                style = TextStyle(color = stressTextSecondary(dark), fontSize = 9.sp),
            )
            if (i < ticks.size - 1) Spacer(GlanceModifier.defaultWeight())
        }
    }
}
