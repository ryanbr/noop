package com.noop.alarm

import android.content.SharedPreferences
import com.noop.data.DailyMetric
import com.noop.ui.debtNeedMin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wind-down nudge is timed from the sleep need the Sleep screen states ([debtNeedMin]), not from a fixed
 * 8 h nothing ever set. Pins the rounding rule byte-identically with Swift `WindDownNudge.needMinutes`, that
 * the need is adopted only when it moves, and that the nudge minute follows it. Twin of the Swift
 * `WindDownSleepNeedTests`.
 */
class WindDownSleepNeedTest {

    /**
     * Expected values are the verbatim stdout of the Swift `WindDownNudge.needMinutes(fromNormativeNeedMin:)`
     * body compiled standalone (`swiftc -O twin.swift main.swift`) over these exact inputs, in this order.
     */
    @Test
    fun needRoundsAndClampsLikeTheSwiftTwin() {
        val inputs = listOf(
            -1e300, -5.0, 0.0, 299.4, 299.5, 300.0, 300.5, 479.49, 479.5, 480.0, 480.4999, 480.5, 495.75,
            504.4999999, 504.5, 517.25, 539.99, 559.5, 570.0, 659.4, 659.5, 660.0, 660.4, 700.0, 1e300,
            Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY,
        )
        val swiftOracle = "300, 300, 300, 300, 300, 300, 301, 479, 480, 480, 480, 481, 496, 504, 505, 517, 540, " +
            "560, 570, 659, 660, 660, 660, 660, 660, 480, 480, 480"
        assertEquals(swiftOracle, inputs.joinToString(", ") { WindDownStore.needMinutes(it).toString() })
    }

    @Test
    fun needIsAdoptedOnlyWhenItMoves() {
        val store = WindDownStore(MemoryPrefsForWindDown())
        assertEquals("nothing adopted yet: the cold-start 8 h", 480, store.sleepNeedMinutes)
        assertTrue(store.adoptSleepNeed(517.25))
        assertEquals(517, store.sleepNeedMinutes)
        assertFalse("same rounded need: no write", store.adoptSleepNeed(517.4))
        assertTrue(store.adoptSleepNeed(480.0))
        assertEquals(480, store.sleepNeedMinutes)
    }

    /** Ten nights whose upper quartile is 8 h 40 m give the Sleep screen's 520-minute need; a 07:00 wake's
     *  nudge moves from 22:30 (the old fixed 8 h, minus the 30-minute lead) to 21:50. */
    @Test
    fun nudgeFollowsTheSleepScreenNeed() {
        val totals = listOf(420.0, 450.0, 470.0, 480.0, 500.0, 510.0, 520.0, 520.0, 530.0, 540.0)
        val rows = totals.mapIndexed { i, minutes ->
            DailyMetric(deviceId = "my-whoop", day = "2026-10-" + (i + 1).toString().padStart(2, '0'), totalSleepMin = minutes)
        }
        val sleepScreenNeed = debtNeedMin(rows)
        assertEquals(520.0, sleepScreenNeed, 1e-6)
        val store = WindDownStore(MemoryPrefsForWindDown())
        assertEquals(22 * 60 + 30, store.nudgeMinuteOfDay(7 * 60))
        store.adoptSleepNeed(sleepScreenNeed)
        assertEquals(520, store.sleepNeedMinutes)
        assertEquals(21 * 60 + 50, store.nudgeMinuteOfDay(7 * 60))
    }

    /** In-memory SharedPreferences, enough for [WindDownStore] (same shape as the other prefs tests' fake). */
    private class MemoryPrefsForWindDown : SharedPreferences {
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
        override fun edit(): SharedPreferences.Editor = Editor(this)

        private class Editor(private val prefs: MemoryPrefsForWindDown) : SharedPreferences.Editor {
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
