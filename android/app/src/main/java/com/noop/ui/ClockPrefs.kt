package com.noop.ui

import android.content.Context
import android.text.format.DateFormat
import com.noop.analytics.ClockFormat
import com.noop.analytics.ClockFormatPreference

/**
 * #1821: the app-side reader for the Clock format setting - the Android twin of Apple's `AppClock`.
 *
 * The label helpers in `SleepTimeLabels` take an `is24h` flag rather than a `Context`, deliberately, so
 * they stay pure and unit-testable (`axisEdgeLabel` already worked that way). This is the one place that
 * turns a Context into that flag, so no caller has to know how the preference is stored or that "system"
 * means the device switch rather than the region default.
 */
object ClockPrefs {
    /** The stored preference, defaulting to SYSTEM so an upgrade changes nobody's displayed times. */
    fun preference(context: Context): ClockFormatPreference =
        ClockFormatPreference.from(
            NoopPrefs.of(context).getString(NoopPrefs.KEY_CLOCK_FORMAT, null),
        )

    fun setPreference(context: Context, preference: ClockFormatPreference) {
        NoopPrefs.of(context).edit()
            .putString(NoopPrefs.KEY_CLOCK_FORMAT, preference.stored())
            .apply()
    }

    /** Resolved: the reader's explicit choice, or the device's own 12/24h switch when they said SYSTEM. */
    fun uses24Hour(context: Context): Boolean =
        ClockFormat.uses24Hour(preference(context), DateFormat.is24HourFormat(context))
}
