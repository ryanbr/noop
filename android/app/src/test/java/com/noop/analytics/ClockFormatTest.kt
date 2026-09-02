package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Apple ClockFormatTests - same cases, same expectations. */
class ClockFormatTest {
    @Test fun systemDefersToTheDevice() {
        assertTrue(ClockFormat.uses24Hour(ClockFormatPreference.SYSTEM, systemUses24Hour = true))
        assertFalse(ClockFormat.uses24Hour(ClockFormatPreference.SYSTEM, systemUses24Hour = false))
    }

    @Test fun anExplicitChoiceOverridesTheDevice() {
        // The whole point of the setting: a reader in a 24-hour region can ask for 12-hour and get it.
        assertFalse(ClockFormat.uses24Hour(ClockFormatPreference.TWELVE_HOUR, systemUses24Hour = true))
        assertTrue(ClockFormat.uses24Hour(ClockFormatPreference.TWENTY_FOUR_HOUR, systemUses24Hour = false))
    }

    @Test fun unknownStoredValuesFallBackToSystemNotToAClock() {
        assertEquals(ClockFormatPreference.SYSTEM, ClockFormatPreference.from(null))
        assertEquals(ClockFormatPreference.SYSTEM, ClockFormatPreference.from(""))
        assertEquals(ClockFormatPreference.SYSTEM, ClockFormatPreference.from("24h"))
        assertEquals(ClockFormatPreference.TWELVE_HOUR, ClockFormatPreference.from("twelveHour"))
        assertEquals(ClockFormatPreference.TWENTY_FOUR_HOUR, ClockFormatPreference.from("twentyFourHour"))
    }

    /**
     * The stored vocabulary is the APPLE rawValue set, not the Kotlin enum names. Pinning the literals
     * means renaming a case cannot silently make the two platforms disagree about a saved preference -
     * and it is why `stored()` exists rather than `name`.
     */
    @Test fun storedVocabularyIsPinned() {
        assertEquals("system", ClockFormatPreference.SYSTEM.stored())
        assertEquals("twelveHour", ClockFormatPreference.TWELVE_HOUR.stored())
        assertEquals("twentyFourHour", ClockFormatPreference.TWENTY_FOUR_HOUR.stored())
        assertEquals("clockFormatPreference", ClockFormatPreference.PREFS_KEY)
        // Round-trip: what we write must be what we read back.
        for (p in ClockFormatPreference.entries) assertEquals(p, ClockFormatPreference.from(p.stored()))
    }

    @Test fun hourMinutePattern() {
        assertEquals("HH:mm", ClockFormat.hourMinutePattern(true))
        assertEquals("h:mm a", ClockFormat.hourMinutePattern(false))
    }

    /** The template must never be `j` - the locale-resolved hour is the bug this setting fixes. */
    @Test fun hourMinuteTemplateNeverDefersToTheLocaleHour() {
        assertEquals("Hmm", ClockFormat.hourMinuteTemplate(true))
        assertEquals("hmm", ClockFormat.hourMinuteTemplate(false))
        assertFalse(ClockFormat.hourMinuteTemplate(true).contains("j"))
        assertFalse(ClockFormat.hourMinuteTemplate(false).contains("j"))
    }
}
