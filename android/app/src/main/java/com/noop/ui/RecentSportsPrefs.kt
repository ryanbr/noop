package com.noop.ui

import android.content.Context
import android.content.SharedPreferences

// MARK: - Recently selected workout types (#297)
//
// Picking a workout type meant scanning/searching the full catalogue every time, even though most
// people cycle through the same 2-3 activities. Both sport pickers (the manual add/edit field and the
// live "Start a workout" sheet) now surface the user's most recent selections above the full list.
//
// Stored as a single comma-joined string of sport names in SharedPreferences, most-recent-first,
// capped at three, deduplicated case-insensitively — the same mechanism as the other display prefs
// (KeyMetricPrefs / MoreSectionPrefs). Mirrors the macOS/iOS RecentSportsPrefs.swift (UserDefaults
// "workout.recentSports"). Display-only: no WorkoutRow, analytics value or migration changes, so like
// the other layout prefs it stays OUT of the .noopbak settings whitelist.

/**
 * Persistence for the "Recent" section of the sport pickers. The stored value is an ordered,
 * comma-joined list of sport-name strings exactly as selected — free-typed, off-catalogue sports
 * included (each picker decides what it can display; see the callers).
 */
object RecentSportsPrefs {
    /** SharedPreferences key. The macOS/iOS twin persists the same "workout.recentSports" name. */
    const val KEY = "workout.recentSports"

    /** Most-recent-first cap. Bumped 3 → 5 now the catalogue is large (~78 sports): a wider rotation
     *  surfaces without scrolling, still short enough to stay above the full list. Twin of iOS. */
    const val MAX_COUNT = 5

    /** Encode an ordered list of names into the stored comma-joined string. */
    fun encode(names: List<String>): String = names.joinToString(",")

    /**
     * Decode the stored string back to the ordered name list. Blank tokens are dropped; an
     * empty/unset string yields no recents (the section simply doesn't render).
     */
    fun decode(raw: String?): List<String> =
        raw?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()

    /**
     * Pure fold of one selection into the list: front-inserted, deduplicated case-insensitively
     * (a re-selection moves the entry to the front and adopts the new casing), capped at [MAX_COUNT].
     * A blank name is a no-op; so is a name containing a comma — it can't ride the comma-joined
     * encoding, and skipping the record beats corrupting the whole list for a theoretical edge case.
     */
    fun recording(name: String, current: List<String>): List<String> {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.contains(",")) return current
        val list = current.filterNot { it.equals(trimmed, ignoreCase = true) }.toMutableList()
        list.add(0, trimmed)
        return list.take(MAX_COUNT)
    }

    /** The persisted recents, most-recent-first. */
    fun recent(context: Context): List<String> = recent(NoopPrefs.of(context))

    fun recent(prefs: SharedPreferences): List<String> = decode(prefs.getString(KEY, null))

    /**
     * Fold a confirmed selection into the persisted list. Called on confirm (Save / Start / Merge),
     * never on keystrokes or list taps, so an abandoned sheet leaves the recents untouched.
     */
    fun record(context: Context, name: String) = record(NoopPrefs.of(context), name)

    fun record(prefs: SharedPreferences, name: String) {
        prefs.edit().putString(KEY, encode(recording(name, recent(prefs)))).apply()
    }
}
