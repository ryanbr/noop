package com.noop.widget

import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/** Manifest entry point for the stress widget — all rendering lives in [StressGlanceWidget]. */
class StressWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = StressGlanceWidget()
}
