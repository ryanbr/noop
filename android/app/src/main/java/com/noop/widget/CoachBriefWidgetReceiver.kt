package com.noop.widget

import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/** K10: Manifest entry point for the Coach brief home-screen widget. */
class CoachBriefWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CoachBriefGlanceWidget()
}
