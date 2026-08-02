package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #146: age is derived from a stored date of birth so it advances on its own, instead of the old
 * manually-entered number that silently went stale. These pin the migration + derivation contract,
 * the exact twin of the Apple `ProfileStore` behaviour.
 *
 * The critical anti-regression is [dobIsAuthoritative_notRefrozenByStaleAgeMirror]: an earlier
 * attempt derived DOB back from the mirrored age whenever they disagreed, which re-froze age every
 * birthday (the very staleness this fixes). DOB must always win.
 *
 * No Robolectric (junit only) — the real [ProfileStore] runs over an in-memory [FakeSharedPreferences]
 * that reproduces the SharedPreferences read/write contract.
 */
class ProfileStoreAgeMigrationTest {

    @Test fun optionalPreferredNameTrimsForGreetingAndRoundTripsThroughBackup() {
        val prefs = FakeSharedPreferences()
        val profile = ProfileStore(prefs)

        assertNull(profile.greetingName)
        profile.preferredName = "  Alex  "
        assertEquals("Alex", profile.greetingName)
        assertEquals("Alex", profile.backupSnapshot()["profile.name"])

        profile.preferredName = "   "
        assertNull(profile.greetingName)
        assertNull(profile.backupSnapshot()["profile.name"])
    }

    @Test fun restoredBackupWithoutNameKeepsOptionalNameEmpty() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.applyBackup(mapOf("profile.age" to 41))
        assertNull(profile.greetingName)
    }

    @Test fun personalizedGreetingAddsCommaOnlyWhenNameExists() {
        val formatWithName = { greeting: String, name: String -> "$greeting, $name" }
        assertEquals("Good morning", personalizedGreeting("Good morning", null, formatWithName))
        assertEquals("Good morning", personalizedGreeting("Good morning", "   ", formatWithName))
        assertEquals("Good morning, Alex", personalizedGreeting("Good morning", " Alex ", formatWithName))
    }

    @Test
    fun freshInstall_defaultsTo30_andPersistsADob() {
        val prefs = FakeSharedPreferences()
        val profile = ProfileStore(prefs)
        assertEquals(30, profile.age)
        // Reading age materialises and persists a DOB so the derivation is stable next launch.
        assertTrue("a DOB must be persisted after the first read", prefs.contains("date_of_birth"))
    }

    @Test
    fun pre146Install_migratesStoredAgeIntoADob() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putInt("age", 40).apply()   // a pre-#146 install: only the legacy Int age exists
        val profile = ProfileStore(prefs)
        assertEquals(40, profile.age)
        assertTrue("migration persists a derived DOB", prefs.contains("date_of_birth"))
    }

    @Test
    fun dobIsAuthoritative_notRefrozenByStaleAgeMirror() {
        // A DOB for age 36 with a STALE mirrored age of 35 (as if a birthday passed since it was
        // written). Age MUST read 36 from the DOB — never re-derive DOB from the stale 35, which would
        // freeze age forever. This is the #167 bug this reimplementation exists to avoid.
        val prefs = FakeSharedPreferences()
        prefs.edit()
            .putLong("date_of_birth", ProfileStore.dobForAge(36))
            .putInt("age", 35)
            .apply()
        val profile = ProfileStore(prefs)
        assertEquals(36, profile.age)
    }

    @Test
    fun setAge_roundTripsAndMirrorsLegacyKey() {
        val prefs = FakeSharedPreferences()
        val profile = ProfileStore(prefs)
        profile.setAge(50)
        assertEquals(50, profile.age)
        assertEquals("legacy age key stays mirrored for the backup whitelist", 50, prefs.getInt("age", -1))
    }

    @Test
    fun setAge_clampsToRange() {
        val prefs = FakeSharedPreferences()
        val profile = ProfileStore(prefs)
        profile.setAge(5);   assertEquals(13, profile.age)
        profile.setAge(200); assertEquals(100, profile.age)
    }

    @Test
    fun backupRestore_reanchorsDobFromRestoredAge() {
        // A device with its own DOB (age 36) restores a backup carrying age 45: the restored age wins
        // and re-anchors the DOB, then advances on its own — the twin of the Apple apply clearing the
        // stale DOB.
        val prefs = FakeSharedPreferences()
        prefs.edit().putLong("date_of_birth", ProfileStore.dobForAge(36)).putInt("age", 36).apply()
        val profile = ProfileStore(prefs)
        profile.applyBackup(mapOf("profile.age" to 45))
        assertEquals(45, profile.age)
    }

    @Test
    fun backupSnapshot_exportsDerivedAgeUnderLegacyKey() {
        val prefs = FakeSharedPreferences()
        val profile = ProfileStore(prefs)
        profile.setAge(45)
        assertEquals(45, (profile.backupSnapshot()["profile.age"] as? Int))
    }

    @Test
    fun backupSnapshot_omitsAgeForAnUntouchedProfile() {
        // Neither DOB nor legacy age set → age stays OUT of the snapshot so a restore doesn't stamp a
        // default 30 over the target's real value.
        val prefs = FakeSharedPreferences()
        assertNull(ProfileStore(prefs).backupSnapshot()["profile.age"])
    }

    @Test
    fun dateHelpers_roundTrip() {
        for (age in intArrayOf(13, 25, 40, 67, 100)) {
            assertEquals(age, ProfileStore.yearsFromDob(ProfileStore.dobForAge(age)))
        }
    }

    // In-memory SharedPreferences reproducing the read/write contract ProfileStore relies on.
    private class FakeSharedPreferences : SharedPreferences {
        private val map = HashMap<String, Any?>()
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun edit(): SharedPreferences.Editor = FakeEditor()

        private inner class FakeEditor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removed = HashSet<String>()
            override fun putString(key: String, value: String?): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor { pending[key] = values; return this }
            override fun putInt(key: String, value: Int): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putLong(key: String, value: Long): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor { pending[key] = value; return this }
            override fun remove(key: String): SharedPreferences.Editor { removed.add(key); return this }
            override fun clear(): SharedPreferences.Editor { map.clear(); return this }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() { flush() }
            private fun flush() {
                for (k in removed) map.remove(k)
                map.putAll(pending)
                pending.clear(); removed.clear()
            }
        }
    }
}
