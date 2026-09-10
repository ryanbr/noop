package com.noop.widget

import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/** Manifest entry point for the heart-rate widget — all rendering lives in [HrGlanceWidget]. */
class HrWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = HrGlanceWidget()
}
