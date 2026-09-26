package com.noop.analytics

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One imported body-weight reading: the ISO `yyyy-MM-dd` day it belongs to, in kilograms. */
data class WeightReading(val day: String, val kg: Double)

/**
 * The single resolver behind "Use weight from Health Connect".
 *
 * Two readers need the same fact: the sync that copies the newest Health Connect weight into the
 * profile (which every analytics pass reads), and the Today Weight tile. Both pick it through [newest],
 * so with the sync ON the tile and the profile cannot name different weights. No Android imports, so it
 * runs as a plain JVM test.
 */
object ProfileWeightSync {

    /**
     * The newest reading, or null when there is none. Days are ISO `yyyy-MM-dd`, which sorts
     * chronologically, so the lexically greatest day is the most recent and no date parsing is needed.
     */
    fun newest(readings: List<WeightReading>): WeightReading? = readings.maxByOrNull { it.day }

    /**
     * "25 Sep" in the app language for the Settings caption, verbatim on an unparseable day.
     * [locale] defaults to [Locale.getDefault], which `AppLanguagePrefs` keeps on the selected app
     * language, so an Italian UI reads "25 set" rather than an English month.
     */
    fun captionDate(day: String, locale: Locale = Locale.getDefault()): String =
        runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", locale)) }
            .getOrDefault(day)
}
