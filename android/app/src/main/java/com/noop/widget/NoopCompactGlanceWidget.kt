package com.noop.widget
import com.noop.ui.uiString

import androidx.compose.ui.res.stringResource
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.MainActivity
import java.text.DateFormat
import java.util.Date

/** Compact home-screen widget: Rest, Charge and Effort icon cells plus live HR and strap battery. */
class NoopCompactGlanceWidget : GlanceAppWidget() {

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
        provideContent { CompactWidgetContent(snap, dark) }
    }

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

private fun compactWidgetSurface(dark: Boolean) =
    ColorProvider(if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA))
private fun compactWidgetTextPrimary(dark: Boolean) =
    ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
private fun compactWidgetTextSecondary(dark: Boolean) =
    ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))

private fun compactBandColor(recovery: Int, dark: Boolean): ColorProvider = ColorProvider(
    when {
        recovery >= 67 -> if (dark) Color(0xFFE8B84B) else Color(0xFFB07D17)
        recovery >= 34 -> if (dark) Color(0xFFD98A3D) else Color(0xFFC2792E)
        else -> if (dark) Color(0xFFE0662F) else Color(0xFFC84E1E)
    },
)

private fun compactEffortColor(dark: Boolean): ColorProvider =
    ColorProvider(if (dark) Color(0xFF4FB6A8) else Color(0xFF2E7D74))

@Composable
private fun CompactWidgetContent(snap: WidgetSnapshot, dark: Boolean) {
    val surface = compactWidgetSurface(dark)
    val textPrimary = compactWidgetTextPrimary(dark)
    val textSecondary = compactWidgetTextSecondary(dark)
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(surface)
            .cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>())
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.Bottom,
        ) {
            CompactScoreCell(
                label = uiString(R.string.l10n_noop_compact_glance_widget_rest_cbaaa181),
                iconRes = R.drawable.ic_widget_rest,
                pct = snap.restPct,
                color = snap.restPct?.let { compactBandColor(it, dark) } ?: textSecondary,
                modifier = GlanceModifier.defaultWeight(),
            )
            CompactScoreCell(
                label = uiString(R.string.l10n_noop_compact_glance_widget_charge_49a8cb83),
                iconRes = R.drawable.ic_widget_charge,
                pct = snap.recoveryPct,
                color = snap.recoveryPct?.let { compactBandColor(it, dark) } ?: textSecondary,
                modifier = GlanceModifier.defaultWeight(),
            )
            CompactScoreCell(
                label = uiString(R.string.l10n_noop_compact_glance_widget_effort_660752e7),
                iconRes = R.drawable.ic_widget_effort,
                pct = snap.effortPct,
                color = snap.effortPct?.let { compactEffortColor(dark) } ?: textSecondary,
                modifier = GlanceModifier.defaultWeight(),
            )
        }
        Spacer(modifier = GlanceModifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = snap.heartRate?.let { "♥ $it" } ?: "♥ - ",
                // Dim a carried-over reading so a stale HR can't masquerade as a live one.
                style = TextStyle(color = if (snap.heartRateStale) textSecondary else textPrimary, fontSize = 13.sp),
            )
            Spacer(modifier = GlanceModifier.width(10.dp))
            Image(
                provider = ImageProvider(R.drawable.ic_widget_strap_battery),
                contentDescription = uiString(R.string.l10n_noop_compact_glance_widget_strap_battery_a6c7f09c),
                modifier = GlanceModifier.width(14.dp).height(14.dp),
                colorFilter = ColorFilter.tint(textPrimary),
            )
            Spacer(modifier = GlanceModifier.width(3.dp))
            Text(
                text = snap.batteryPct?.let { "$it%" } ?: "-",
                style = TextStyle(color = textPrimary, fontSize = 13.sp),
            )
        }
        Spacer(modifier = GlanceModifier.height(1.dp))
        Text(
            text = when {
                snap.connected -> "Connected"
                snap.updatedAtMs > 0L ->
                    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(snap.updatedAtMs))
                else -> "Open NOOP to connect"
            },
            style = TextStyle(color = textSecondary, fontSize = 11.sp),
        )
    }
}

@Composable
private fun CompactScoreCell(
    label: String,
    iconRes: Int,
    pct: Int?,
    color: ColorProvider,
    modifier: GlanceModifier = GlanceModifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            provider = ImageProvider(iconRes),
            contentDescription = label,
            modifier = GlanceModifier.width(18.dp).height(18.dp),
            colorFilter = ColorFilter.tint(color),
        )
        Text(
            text = pct?.let { "$it%" } ?: "—",
            style = TextStyle(color = color, fontSize = 21.sp, fontWeight = FontWeight.Bold),
        )
    }
}
