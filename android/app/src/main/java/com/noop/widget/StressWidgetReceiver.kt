package com.noop.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/** Manifest entry point for the stress widget — all rendering lives in [StressGlanceWidget]. */
class StressWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = StressGlanceWidget()

    /**
     * First widget placed: start the periodic rescore (#2185). This is the hook rather than app start
     * because a widget can be added from the launcher without opening NOOP at all, which is precisely
     * the user this fixes.
     */
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        StressWidgetRefresh.ensureScheduled(context)
    }

    /** Last widget removed: stop paying for a rescore nothing will render. */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        StressWidgetRefresh.cancel(context)
    }
}
