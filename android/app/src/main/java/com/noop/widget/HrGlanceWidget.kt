package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
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
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
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
import com.noop.ui.MainActivity
import com.noop.ui.uiString
import java.text.DateFormat
import java.util.Date

/**
 * Home-screen widget: the live heart rate with the last [HrTrace.WINDOW_SEC] drawn as a trace (#1957).
 *
 * Renders purely from the [WidgetSnapshotStore] snapshot, like its siblings — no BLE, no DB — so it
 * costs nothing and survives process death. Tapping opens the app.
 *
 * The trace is an IMAGE because Glance compiles to RemoteViews, which cannot draw. [HrTrace] decides
 * where the ink goes and [HrTraceRenderer] puts it on a Bitmap; the labels around it stay Glance `Text`
 * so they remain crisp, themed and readable to TalkBack.
 *
 * Honest-blank throughout: no reading means "—" and no chart, never a flat line at zero. A trace with a
 * single point draws a dot rather than nothing, because a widget placed this minute has exactly one.
 */
class HrGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        val dark = runCatching {
            when (context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
                .getString("theme.appearance", "system")) {
                "light" -> false
                "dark" -> true
                else -> (context.resources.configuration.uiMode and
                    android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                    android.content.res.Configuration.UI_MODE_NIGHT_YES
            }
        }.getOrDefault(true)
        provideContent { HrWidgetContent(snap, dark) }
    }

    /** Same defence as [NoopGlanceWidget.onCompositionError]: swap Glance's built-in error layout for
     *  ours. The widget heals on the next successful push. */
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
private fun hrSurface(dark: Boolean) = ColorProvider(if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA))
private fun hrTextPrimary(dark: Boolean) = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
private fun hrTextSecondary(dark: Boolean) = ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))

/** The trace tint. A heart reads red in this app's language, not the screenshot's blue. */
private fun hrAccent(dark: Boolean) = if (dark) Color(0xFFE0662F) else Color(0xFFC84E1E)

@Composable
private fun HrWidgetContent(snap: WidgetSnapshot, dark: Boolean) {
    val context = LocalContext.current
    val size = LocalSize.current
    val stats = HrTrace.stats(snap.hrSeries)

    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(hrSurface(dark))
            .cornerRadius(16.dp)
            .padding(14.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        Text(
            text = uiString(R.string.l10n_noop_glance_widget_heart_rate_410aa15c),
            style = TextStyle(color = hrTextPrimary(dark), fontSize = 13.sp, fontWeight = FontWeight.Medium),
        )
        Spacer(GlanceModifier.height(6.dp))

        Row(verticalAlignment = Alignment.Vertical.Bottom) {
            Text(
                text = snap.heartRate?.toString() ?: "—",
                style = TextStyle(
                    color = if (snap.heartRateStale) hrTextSecondary(dark) else hrTextPrimary(dark),
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            if (snap.heartRate != null) {
                Spacer(GlanceModifier.width(4.dp))
                Text(
                    // The existing unit resource, not a literal. The audit did not flag one here, but it
                    // has known blind spots and the string already exists translated.
                    text = uiString(R.string.today_unit_bpm),
                    style = TextStyle(color = hrTextSecondary(dark), fontSize = 12.sp),
                )
            }
            if (stats != null) {
                Spacer(GlanceModifier.width(10.dp))
                Text(
                    text = uiString(R.string.l10n_hr_glance_widget_min_lo_max_hi_ef900e49, stats.min, stats.max),
                    style = TextStyle(color = hrTextSecondary(dark), fontSize = 12.sp),
                )
            }
        }

        Spacer(GlanceModifier.height(8.dp))
        HrTraceImage(snap, dark, widthDp = size.width.value, heightDp = 56f)

        if (snap.updatedAtMs > 0) {
            Spacer(GlanceModifier.height(6.dp))
            val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(snap.updatedAtMs))
            Text(
                text = uiString(R.string.l10n_hr_glance_widget_updated_time_1b5feedb, time),
                style = TextStyle(color = hrTextSecondary(dark), fontSize = 10.sp),
            )
        }
    }
}

/**
 * The trace, plus the bpm scale down its right edge.
 *
 * Bitmap construction is wrapped: an OOM or a hostile size must leave the widget without a chart, not
 * without a widget. `size.width` is the WIDGET's width, so the chart is sized from what the launcher
 * actually gave us rather than from a guess.
 */
@Composable
private fun HrTraceImage(snap: WidgetSnapshot, dark: Boolean, widthDp: Float, heightDp: Float) {
    val context = LocalContext.current
    val stats = HrTrace.stats(snap.hrSeries)
    val density = context.resources.displayMetrics.density
    // Leave room for the scale column so the trace is not drawn under its own labels.
    val chartWidthDp = (widthDp - 28f - 34f).coerceAtLeast(24f)
    // ONE box for both the geometry and the bitmap. Sizing them separately let the trace be drawn to
    // coordinates the bitmap did not have room for, clipping its right-hand end (#1957).
    val (wPx, hPx) = HrTrace.fitBox((chartWidthDp * density).toInt(), (heightDp * density).toInt())

    val bmp = runCatching {
        HrTraceRenderer.render(
            points = HrTrace.points(snap.hrSeries, wPx.toFloat(), hPx.toFloat()),
            widthPx = wPx,
            heightPx = hPx,
            lineColor = hrAccent(dark).toArgb(),
            fillTopColor = hrAccent(dark).copy(alpha = 0.35f).toArgb(),
            strokePx = 2f * density,
        )
    }.getOrNull()

    Row(modifier = GlanceModifier.fillMaxWidth()) {
        Box(modifier = GlanceModifier.height(heightDp.dp).width(chartWidthDp.dp)) {
            if (bmp != null) {
                Image(
                    provider = ImageProvider(bmp),
                    contentDescription = null,
                    modifier = GlanceModifier.fillMaxSize(),
                )
            }
        }
        if (stats != null) {
            Spacer(GlanceModifier.width(6.dp))
            Column(
                modifier = GlanceModifier.height(heightDp.dp),
                horizontalAlignment = Alignment.Horizontal.End,
            ) {
                for (tick in HrTrace.bpmTicks(stats)) {
                    Text(
                        text = tick.toString(),
                        style = TextStyle(color = hrTextSecondary(dark), fontSize = 10.sp),
                        modifier = GlanceModifier.semantics { contentDescription = tick.toString() },
                    )
                    Spacer(GlanceModifier.height(6.dp))
                }
            }
        }
    }
}
