package com.noop.ui

import android.content.SharedPreferences
import com.noop.analytics.WeightReading
import com.noop.data.AppleDaily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * "Use weight from Health Connect": the profile write behind it. No Robolectric (junit only), the real
 * [ProfileStore] over an in-memory [FakeSharedPreferences].
 */
class HealthConnectWeightSyncTest {

    private fun hcDay(day: String, kg: Double?) = AppleDaily(deviceId = "health-connect", day = day, weightKg = kg)

    @Test
    fun toggleDefaultsOff_andTheSyncIsANoOp() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.weightKg = 80.0
        assertFalse(profile.useHealthConnectWeight)
        assertNull(HealthConnectWeightSync.apply(profile, listOf(hcDay("2026-09-25", 72.4))))
        assertEquals(80.0, profile.weightKg, 1e-4)
        assertNull(profile.healthConnectWeightDay)
    }

    @Test
    fun toggleOn_writesTheNewestHealthConnectWeightAndItsDay() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.weightKg = 80.0
        profile.useHealthConnectWeight = true
        val rows = listOf(hcDay("2026-09-20", 73.0), hcDay("2026-09-25", 72.4), hcDay("2026-09-26", null))
        assertEquals(WeightReading("2026-09-25", 72.4), HealthConnectWeightSync.apply(profile, rows))
        assertEquals(72.4, profile.weightKg, 1e-4)
        assertEquals("2026-09-25", profile.healthConnectWeightDay)
    }

    @Test
    fun toggleOn_withoutAnyHealthConnectWeight_leavesTheProfileUntouched() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.weightKg = 80.0
        profile.useHealthConnectWeight = true
        assertNull(HealthConnectWeightSync.apply(profile, listOf(hcDay("2026-09-25", null))))
        assertEquals(80.0, profile.weightKg, 1e-4)
        assertNull(profile.healthConnectWeightDay)
    }

    @Test
    fun toggleOff_keepsTheLastSyncedWeightForManualEditing() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.useHealthConnectWeight = true
        HealthConnectWeightSync.apply(profile, listOf(hcDay("2026-09-25", 72.4)))
        profile.useHealthConnectWeight = false
        assertNull(HealthConnectWeightSync.apply(profile, listOf(hcDay("2026-09-27", 71.0))))
        assertEquals(72.4, profile.weightKg, 1e-4)
    }

    @Test
    fun theNewKeysStayOutOfTheBackup() {
        val profile = ProfileStore(FakeSharedPreferences())
        profile.useHealthConnectWeight = true
        HealthConnectWeightSync.apply(profile, listOf(hcDay("2026-09-25", 72.4)))
        val snapshot = profile.backupSnapshot()
        assertEquals(72.4, snapshot["profile.weightKg"] as Double, 1e-4)
        assertFalse(snapshot.keys.any { it.contains("health", ignoreCase = true) })
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
