package com.noop.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
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
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.MainActivity
import java.text.DateFormat
import java.util.Date

/**
 * K10: Home-screen widget showing the stored Coach morning brief (Android twin of the iOS
 * `CoachBriefWidget`). Renders purely from the `noop_widget` SharedPreferences — no network,
 * no DB. The brief is generated on a schedule by [com.noop.ui.CoachBriefScheduler] (K5) and
 * mirrored into the widget's prefs via `publishToWidget`. Tap → opens the app.
 *
 * Design contract (PRD-K10 + D8): the widget reads STORED brief text, NEVER calls the network.
 * The brief text is generated on-device on a schedule, not live-networked in the widget.
 */
class CoachBriefGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val prefs = context.getSharedPreferences("noop_widget", Context.MODE_PRIVATE)
        val briefText = prefs.getString("coachBriefText", null)
        val briefDateMs = prefs.getLong("coachBriefDateMs", 0L)
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
        provideContent { CoachBriefWidgetContent(briefText, briefDateMs, dark) }
    }
}

@Composable
private fun CoachBriefWidgetContent(briefText: String?, briefDateMs: Long, dark: Boolean) {
    val context = LocalContext.current
    val surface = ColorProvider(if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA))
    val textPrimary = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
    val textSecondary = ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))
    val accent = ColorProvider(if (dark) Color(0xFFE8B84B) else Color(0xFFB07D17))

    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(surface)
            .cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>())
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.Start,
        verticalAlignment = Alignment.Top,
    ) {
        // Header: "Coach Brief" + time
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            horizontalAlignment = Alignment.Start,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = context.getString(R.string.coach_brief_widget_title),
                style = TextStyle(color = accent, fontSize = 13.sp, fontWeight = FontWeight.Bold),
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            if (briefDateMs > 0L) {
                val timeStr = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(briefDateMs))
                Text(
                    text = timeStr,
                    style = TextStyle(color = textSecondary, fontSize = 11.sp),
                )
            }
        }
        Spacer(modifier = GlanceModifier.height(8.dp))
        if (briefText == null) {
            Text(
                text = context.getString(R.string.coach_brief_widget_empty),
                style = TextStyle(color = textSecondary, fontSize = 14.sp, fontWeight = FontWeight.Medium),
            )
            Spacer(modifier = GlanceModifier.height(4.dp))
            Text(
                text = context.getString(R.string.coach_brief_widget_enable),
                style = TextStyle(color = textSecondary, fontSize = 11.sp),
            )
        } else {
            // Show the first few lines of the brief, capped so it fits the widget.
            val displayText = briefText.lines().filter { it.isNotBlank() }.take(4).joinToString("\n")
            Text(
                text = displayText,
                style = TextStyle(color = textPrimary, fontSize = 12.sp),
            )
        }
    }
}
