package com.noop.testcentre

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror of the Swift TestCentreActivationTests: same activation semantics, master-implies-all,
 * universal-rides-any, persisted-answer reads, and activation that preserves legacy keys.
 *
 * The project ships NO Robolectric (junit + kotlinx-coroutines-test only, see app/build.gradle.kts and
 * DeviceRegistryTest / MoodStoreTest), so rather than stand up a real Context we run the REAL [TestCentre]
 * over an in-memory [FakeSharedPreferences] that reproduces the SharedPreferences read/write contract.
 */
class TestCentreTest {

    /** A minimal in-memory SharedPreferences: enough of the read/write contract for [TestCentre]. The
     *  editor mutates a shadow map and commits it on apply(), exactly as the platform would persist. */
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

    private fun newCentre() = TestCentre(FakeSharedPreferences())

    @Test fun activateThenActiveThenDeactivate() {
        val tc = newCentre()
        assertFalse(tc.active(TestDomain.SLEEP))
        tc.activate(TestDomain.SLEEP)
        assertTrue(tc.active(TestDomain.SLEEP))
        assertFalse(tc.active(TestDomain.BATTERY))
        tc.deactivate(TestDomain.SLEEP)
        assertFalse(tc.active(TestDomain.SLEEP))
    }

    @Test fun masterImpliesAll() {
        val tc = newCentre()
        tc.activate(TestDomain.MASTER)
        assertTrue(tc.active(TestDomain.SLEEP))
        assertTrue(tc.active(TestDomain.HRV))
    }

    @Test fun universalRidesAnyActive() {
        val tc = newCentre()
        assertFalse(tc.active(TestDomain.UNIVERSAL))
        tc.activate(TestDomain.BATTERY)
        assertTrue(tc.active(TestDomain.UNIVERSAL))
    }

    @Test fun startedAtStampedOnActivate() {
        val tc = newCentre()
        assertNull(tc.startedAt(TestDomain.SLEEP))
        tc.activate(TestDomain.SLEEP)
        assertTrue((tc.startedAt(TestDomain.SLEEP) ?: 0L) > 0L)
    }

    @Test fun answersReadsPersistedQuestionnaire() {
        val prefs = FakeSharedPreferences()
        val tc = TestCentre(prefs)
        assertEquals(emptyMap<String, String>(), tc.answers(TestDomain.BATTERY))
        prefs.edit().putString("testcentre.answers.battery",
            "{\"whoopAppInstalled\":\"yes\",\"batterySaverApps\":\"none\"}").apply()
        assertEquals(mapOf("whoopAppInstalled" to "yes", "batterySaverApps" to "none"), tc.answers(TestDomain.BATTERY))
        assertEquals(emptyMap<String, String>(), tc.answers(TestDomain.SLEEP))
    }

    @Test fun answersRejectsMalformedPersistedQuestionnaire() {
        val prefs = FakeSharedPreferences()
        val tc = TestCentre(prefs)
        for (raw in listOf("not JSON", "[]")) {
            prefs.edit().putString("testcentre.answers.battery", raw).apply()
            assertEquals(raw, emptyMap<String, String>(), tc.answers(TestDomain.BATTERY))
        }
    }

    @Test fun activationPreservesUnrelatedKeys() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putBoolean("unrelated", true).apply()
        val tc = TestCentre(prefs)
        tc.activate(TestDomain.BATTERY)
        tc.deactivate(TestDomain.BATTERY)
        assertTrue(prefs.getBoolean("unrelated", false))
    }
}
