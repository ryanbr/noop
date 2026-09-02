package com.noop.analytics

/**
 * #1821: which clock the UI shows times in. Twin of the Apple `ClockFormatPreference`.
 *
 * NOOP had no such setting: every user-facing time came from the device region's convention, and on
 * Apple the region identifier discards the user's explicit "24-Hour Time" switch entirely. A reader in a
 * 24-hour region who prefers 12-hour had no way to say so, which is the report this exists to answer.
 */
enum class ClockFormatPreference {
    /** Follow the device's own clock switch. The default, so nobody's display changes on upgrade. */
    SYSTEM,
    TWELVE_HOUR,
    TWENTY_FOUR_HOUR,
    ;

    companion object {
        /** Persistence key, shared with the Apple @AppStorage binding so the two cannot drift apart. */
        const val PREFS_KEY = "clockFormatPreference"

        /** Stored as the Apple rawValue strings, so one documented vocabulary spans both platforms. */
        fun from(stored: String?): ClockFormatPreference = when (stored) {
            "twelveHour" -> TWELVE_HOUR
            "twentyFourHour" -> TWENTY_FOUR_HOUR
            // Unknown/absent must not silently pin every reader to one clock.
            else -> SYSTEM
        }
    }

    /** The value written to storage - the Apple rawValue, not the Kotlin enum name. */
    fun stored(): String = when (this) {
        SYSTEM -> "system"
        TWELVE_HOUR -> "twelveHour"
        TWENTY_FOUR_HOUR -> "twentyFourHour"
    }
}

object ClockFormat {
    /**
     * Resolve the preference against what the device reports. [systemUses24Hour] is injected rather than
     * read here so this stays pure and identically testable on both platforms - Android supplies
     * `DateFormat.is24HourFormat(context)`, Apple `Locale.autoupdatingCurrent`.
     */
    fun uses24Hour(preference: ClockFormatPreference, systemUses24Hour: Boolean): Boolean =
        when (preference) {
            ClockFormatPreference.SYSTEM -> systemUses24Hour
            ClockFormatPreference.TWELVE_HOUR -> false
            ClockFormatPreference.TWENTY_FOUR_HOUR -> true
        }

    /**
     * The SimpleDateFormat pattern for a wall-clock time at minute precision. Explicit patterns, not a
     * localised template: once the reader has CHOSEN a clock, a template would hand the decision back to
     * the locale and quietly ignore them.
     */
    fun hourMinutePattern(uses24Hour: Boolean): String = if (uses24Hour) "HH:mm" else "h:mm a"

    /**
     * SKELETON template for the same time, the twin of the Apple accessor. Apple feeds this to
     * `setLocalizedDateFormatFromTemplate` so the locale still decides ordering and AM/PM wording while
     * the H-vs-h choice stays ours. Deliberately NOT `j`, which resolves the hour from the locale - the
     * precise mechanism by which a reader's explicit preference was being discarded.
     */
    fun hourMinuteTemplate(uses24Hour: Boolean): String = if (uses24Hour) "Hmm" else "hmm"
}
