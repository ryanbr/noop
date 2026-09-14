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

    /**
     * Also on every APPWIDGET_UPDATE, which is what closes the gap this feature would otherwise leave
     * in its own purpose. `onEnabled` fires once, when the FIRST widget is placed, so a widget that was
     * already there when this shipped never sees it; the app-start call catches those, but only once
     * NOOP has been opened, and "you should not have to open the app" is the whole point. Android
     * broadcasts APPWIDGET_UPDATE to providers after a package replace, so an update activates the
     * schedule without the app being launched at all.
     *
     * Cheap to repeat: `ensureScheduled` enqueues with KEEP, so every call after the first is a no-op.
     */
    override fun onUpdate(
        context: Context,
        appWidgetManager: android.appwidget.AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        StressWidgetRefresh.ensureScheduled(context)
    }

    /** Last widget removed: stop paying for a rescore nothing will render. */
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        StressWidgetRefresh.cancel(context)
    }
}
