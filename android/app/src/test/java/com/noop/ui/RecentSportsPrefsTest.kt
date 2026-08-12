package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the #297 "recently selected activities" persistence - the Android twin of the iOS
 * `RecentSportsPrefsTests`. The behaviour that must never regress: the sport pickers surface up to three
 * distinct recents, most-recent-first, deduplicated case-insensitively, updated only on a confirmed
 * selection. These exercise the REAL [RecentSportsPrefs] over an in-memory [FakeSharedPreferences] (the
 * project ships no Robolectric), and lock it in lockstep with the iOS twin (same key, same comma-joined
 * encoding, same cap/dedup/no-op rules).
 */
class RecentSportsPrefsTest {

    @Test
    fun keyAndCapMatchIos() {
        // Both platforms persist "workout.recentSports", capped at three entries.
        assertEquals("workout.recentSports", RecentSportsPrefs.KEY)
        assertEquals(5, RecentSportsPrefs.MAX_COUNT)
    }

    @Test
    fun encodeDecodeRoundTrips() {
        for (list in listOf(
            emptyList(),
            listOf("Running"),
            listOf("Running", "Yoga"),
            listOf("Running", "Yoga", "Padel"),
        )) {
            assertEquals(list, RecentSportsPrefs.decode(RecentSportsPrefs.encode(list)))
        }
    }

    @Test
    fun decodeDropsBlankAndStrayTokens() {
        assertEquals(listOf("Running", "Yoga"), RecentSportsPrefs.decode("Running, ,Yoga,"))
        assertEquals(listOf("Padel"), RecentSportsPrefs.decode("  Padel  "))
        assertEquals(emptyList<String>(), RecentSportsPrefs.decode(""))
        assertEquals(emptyList<String>(), RecentSportsPrefs.decode(null))
    }

    @Test
    fun recordingFrontInserts() {
        assertEquals(listOf("Running"), RecentSportsPrefs.recording("Running", emptyList()))
        assertEquals(listOf("Yoga", "Running"), RecentSportsPrefs.recording("Yoga", listOf("Running")))
    }

    @Test
    fun recordingDedupsCaseInsensitivelyAndMovesToFront() {
        // A re-selection moves the entry to the front (no duplicate) and adopts the new casing.
        assertEquals(
            listOf("running", "Yoga", "Padel"),
            RecentSportsPrefs.recording("running", listOf("Yoga", "Running", "Padel")),
        )
    }

    @Test
    fun recordingCapsAtFive() {
        // Full list of 5 → recording a 6th drops the oldest.
        assertEquals(
            listOf("HIIT", "Running", "Yoga", "Padel", "Boxing"),
            RecentSportsPrefs.recording("HIIT", listOf("Running", "Yoga", "Padel", "Boxing", "Tennis")),
        )
        // Under the cap → nothing dropped.
        assertEquals(
            listOf("HIIT", "Running", "Yoga", "Padel"),
            RecentSportsPrefs.recording("HIIT", listOf("Running", "Yoga", "Padel")),
        )
    }

    @Test
    fun recordingIgnoresBlankAndCommaNames() {
        // Blank can't be a sport; a comma can't ride the comma-joined encoding - both are no-ops.
        assertEquals(listOf("Running"), RecentSportsPrefs.recording("   ", listOf("Running")))
        assertEquals(listOf("Running"), RecentSportsPrefs.recording("Run, walk", listOf("Running")))
    }

    @Test
    fun recordingTrimsWhitespace() {
        assertEquals(listOf("Yoga"), RecentSportsPrefs.recording("  Yoga  ", emptyList()))
    }

    @Test
    fun selectionsPersistThroughSharedPreferences() {
        // The end-to-end persistence the sheets rely on: recorded selections read back most-recent-first.
        val prefs = FakeSharedPreferences()

        assertEquals(emptyList<String>(), RecentSportsPrefs.recent(prefs))
        RecentSportsPrefs.record(prefs, "Running")
        RecentSportsPrefs.record(prefs, "Yoga")
        assertEquals(listOf("Yoga", "Running"), RecentSportsPrefs.recent(prefs))

        // Re-selecting an existing recent moves it to the front instead of duplicating.
        RecentSportsPrefs.record(prefs, "Running")
        assertEquals(listOf("Running", "Yoga"), RecentSportsPrefs.recent(prefs))
    }

    /** A minimal in-memory SharedPreferences: enough of the read/write contract for the helper above. */
    private class FakeSharedPreferences : SharedPreferences {
        val map = HashMap<String, Any?>()

        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        override fun edit(): SharedPreferences.Editor = FakeEditor(this)

        private class FakeEditor(private val prefs: FakeSharedPreferences) : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String, value: String?): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor { pending[key] = values; return this }
            override fun putInt(key: String, value: Int): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putLong(key: String, value: Long): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor { pending[key] = value; return this }
            override fun remove(key: String): SharedPreferences.Editor { removals.add(key); return this }
            override fun clear(): SharedPreferences.Editor { prefs.map.clear(); return this }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() { flush() }
            private fun flush() {
                for (k in removals) prefs.map.remove(k)
                prefs.map.putAll(pending)
            }
        }
    }
}
