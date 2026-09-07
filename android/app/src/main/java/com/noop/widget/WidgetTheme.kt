package com.noop.widget

import android.content.Context
import android.content.res.Configuration

/**
 * Whether a widget should draw dark, resolved the way every widget in this package resolves it.
 *
 * This lived as four byte-identical copies, one per widget. It is extracted because a FIFTH reader
 * arrived that must not disagree with them: [RenderedGate] decides whether a push is worth sending, and
 * the appearance is an input the widgets read at composition rather than one the snapshot carries. A
 * gate that resolved the theme even slightly differently would decline a push the widgets needed, and
 * the widget would sit in the wrong colours until something unrelated moved.
 *
 * The in-app override wins; "system" falls back to the configuration's night mode. Defaults to dark on
 * any failure, matching what the four copies did.
 */
internal object WidgetTheme {

    fun isDark(context: Context): Boolean = runCatching {
        when (context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
            .getString("theme.appearance", "system")) {
            "light" -> false
            "dark" -> true
            else -> (context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
    }.getOrDefault(true)
}
