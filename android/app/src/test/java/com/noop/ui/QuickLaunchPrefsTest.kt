package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Locks the Android Quick Launch persistence and former-More destination parity. */
class QuickLaunchPrefsTest {

    @Test
    fun persistenceKeyAndDefaultsMatchIos() {
        assertEquals("noop.launchFavourites", QuickLaunchPrefs.KEY)
        assertEquals(9, QuickLaunchPrefs.SLOT_COUNT)
        assertEquals(
            listOf("settings", "backupSync", "workouts", "stress", "coach", "journal", "automations", "alarms", "compare"),
            QuickLaunchPrefs.defaultSlots,
        )
    }

    @Test
    fun decodePreservesEveryEmptyPositionAndNormalizesToNineSlots() {
        assertEquals(
            listOf("settings", null, "workouts", null, null, null, null, null, null),
            QuickLaunchPrefs.decode("settings,,workouts,"),
        )
        assertEquals(List<String?>(9) { null }, QuickLaunchPrefs.decode(""))
        assertEquals((1..9).map { "item$it" }, QuickLaunchPrefs.decode((1..12).joinToString(",") { "item$it" }))
    }

    @Test
    fun encodeDecodeRoundTripKeepsGapsIncludingTrailingOnes() {
        val slots = listOf("settings", null, "workouts", null, "coach", null, null, "alarms", null)
        val encoded = QuickLaunchPrefs.encode(slots)
        assertEquals("settings,,workouts,,coach,,,alarms,", encoded)
        assertEquals(slots, QuickLaunchPrefs.decode(encoded))
    }

    @Test
    fun freshInstallUsesDefaultAndWritesSurviveRelaunch() {
        val prefs = FakeSharedPreferences()
        assertEquals(QuickLaunchPrefs.defaultSlots, QuickLaunchPrefs.read(prefs))

        val changed = listOf("settings", null, "workouts", null, null, null, null, null, null)
        QuickLaunchPrefs.write(prefs, changed)
        assertEquals(changed, QuickLaunchPrefs.read(prefs))
        assertTrue(prefs.contains(QuickLaunchPrefs.KEY))
    }

    @Test
    fun editingOperationsPreserveIdentityAndFixedSlots() {
        val start = listOf("settings", null, "workouts", "stress", null, null, null, null, null)
        val swapped = QuickLaunchPrefs.swap(start, 0, 2)
        assertEquals("workouts", swapped[0])
        assertEquals("settings", swapped[2])

        val movedIntoGap = QuickLaunchPrefs.swap(swapped, 2, 1)
        assertEquals("settings", movedIntoGap[1])
        assertNull(movedIntoGap[2])

        val removed = QuickLaunchPrefs.remove(movedIntoGap, 0)
        assertNull(removed[0])
        assertEquals(9, removed.size)
    }

    @Test
    fun addUsesFirstGapRejectsDuplicatesAndDoesNothingWhenFull() {
        val withGaps = listOf("settings", null, null, null, null, null, null, null, null)
        assertEquals("coach", QuickLaunchPrefs.addFirstEmpty(withGaps, "coach")[1])
        assertEquals(withGaps, QuickLaunchPrefs.addFirstEmpty(withGaps, "settings"))

        val full = (1..9).map { "item$it" }
        assertEquals(full, QuickLaunchPrefs.addFirstEmpty(full, "extra"))
    }

    @Test
    fun catalogueKeepsEveryDestinationFormerlyAvailableFromMore() {
        val expected = setOf(
            Destination.InsightsHub, Destination.Intelligence, Destination.Coach,
            Destination.Insights, Destination.Explore, Destination.Compare,
            Destination.Live, Destination.Workouts, Destination.Health, Destination.VitalSigns,
            Destination.LabBook, Destination.Stress, Destination.Breathe, Destination.Intervals,
            Destination.Rhythm, Destination.FusedRecord, Destination.AppleHealth,
            Destination.DataSources, Destination.BackupSync, Destination.Devices,
            Destination.Automations, Destination.SmartAlarm, Destination.Notifications,
            Destination.TestCentre, Destination.Settings,
        )
        assertEquals(expected, QuickLaunchCatalog.all.mapNotNull(LaunchItem::destination).toSet())
        assertEquals(
            QuickLaunchAction.Updates,
            QuickLaunchCatalog.byId.getValue("updates").action,
        )
        assertTrue(QuickLaunchCatalog.pages.all { it.items.size <= 9 })
        assertEquals(QuickLaunchCatalog.all.size, QuickLaunchCatalog.all.map(LaunchItem::id).toSet().size)
        assertTrue(QuickLaunchPrefs.defaultSlots.filterNotNull().all(QuickLaunchCatalog.byId::containsKey))
        assertFalse(QuickLaunchCatalog.all.isEmpty())
    }

    private class FakeSharedPreferences : SharedPreferences {
        private val values = HashMap<String, Any?>()

        override fun getBoolean(key: String, defValue: Boolean) = values[key] as? Boolean ?: defValue
        override fun getLong(key: String, defValue: Long) = values[key] as? Long ?: defValue
        override fun getString(key: String, defValue: String?) = values[key] as? String ?: defValue
        override fun getInt(key: String, defValue: Int) = values[key] as? Int ?: defValue
        override fun getFloat(key: String, defValue: Float) = values[key] as? Float ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?) =
            values[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(values)
        override fun contains(key: String) = values.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun edit(): SharedPreferences.Editor = Editor(values)

        private class Editor(private val values: HashMap<String, Any?>) : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, value: MutableSet<String>?) = apply { pending[key] = value }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { removals += key }
            override fun clear() = apply { values.clear() }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() = flush()
            private fun flush() {
                removals.forEach(values::remove)
                values.putAll(pending)
            }
        }
    }
}
