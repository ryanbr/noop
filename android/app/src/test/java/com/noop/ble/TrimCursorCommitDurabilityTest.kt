package com.noop.ble

import android.content.SharedPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #8: the `strap_trim` cursor must not report success when its write did not land.
 *
 * [PrefsTrimCursorStore.set] uses `SharedPreferences.commit()` for durability before the strap is
 * acked, but `commit()` signals a failed write (full storage, unwritable prefs file) by RETURNING
 * false — it does not throw. Discarding that result made a failed persist indistinguishable from a
 * successful one, so the Backfiller's try/catch guard never fired and the strap was acked without a
 * durable cursor, breaking the safe-trim invariant. `set` must surface the false as a throw, which
 * is what the existing guard (Backfiller.finishChunk) already converts into "hold the ack".
 *
 * No Robolectric (junit only) — the real store runs over an in-memory [FakeSharedPreferences] whose
 * `commit()` result is scriptable, the same fake-prefs convention as ProfileStoreAgeMigrationTest.
 */
class TrimCursorCommitDurabilityTest {

    /** A failed commit must throw, so the caller holds the ack instead of trimming the strap. */
    @Test
    fun set_throwsWhenCommitReturnsFalse() {
        val prefs = FakeSharedPreferences(commitResult = false)
        val store = PrefsTrimCursorStore(prefs)
        var thrown: Throwable? = null
        try {
            runBlocking { store.set(Backfiller.STRAP_TRIM_CURSOR, 12_345L) }
        } catch (t: Throwable) {
            thrown = t
        }
        assertTrue("a commit() that returned false must surface as a throw, got $thrown", thrown != null)
    }

    /** Storage-full surfacing as an exception from the editor stays an exception (guard still fires). */
    @Test
    fun set_propagatesWhenCommitThrows() {
        val prefs = FakeSharedPreferences(commitResult = true, commitThrows = true)
        val store = PrefsTrimCursorStore(prefs)
        var thrown: Throwable? = null
        try {
            runBlocking { store.set(Backfiller.STRAP_TRIM_CURSOR, 7L) }
        } catch (t: Throwable) {
            thrown = t
        }
        assertTrue("an exception from commit() must reach the caller, got $thrown", thrown != null)
    }

    /** Happy path unchanged: a successful commit persists and reads back without throwing. */
    @Test
    fun set_persistsWhenCommitSucceeds() {
        val prefs = FakeSharedPreferences(commitResult = true)
        val store = PrefsTrimCursorStore(prefs)
        runBlocking { store.set(Backfiller.STRAP_TRIM_CURSOR, 4_294_967_295L) }
        assertEquals(4_294_967_295L, runBlocking { store.get(Backfiller.STRAP_TRIM_CURSOR) })
    }

    /** An unset cursor still reads as absent (the "no cursor yet" sentinel path). */
    @Test
    fun get_returnsNullWhenUnset() {
        val store = PrefsTrimCursorStore(FakeSharedPreferences(commitResult = true))
        assertNull(runBlocking { store.get(Backfiller.STRAP_TRIM_CURSOR) })
    }

    /** In-memory SharedPreferences whose `commit()` outcome the test scripts. */
    private class FakeSharedPreferences(
        private val commitResult: Boolean,
        private val commitThrows: Boolean = false,
    ) : SharedPreferences {
        val map = HashMap<String, Any?>()
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
            override fun commit(): Boolean {
                if (prefs.commitThrows) throw java.io.IOException("simulated storage failure")
                // The platform commits to the in-memory map FIRST and returns only the disk-write
                // result, so a false commit is still visible to an in-process get(); only durability
                // across a restart is lost. Model that: apply, then report the failure.
                flush()
                return prefs.commitResult
            }
            override fun apply() { flush() }
            private fun flush() {
                for (k in removals) prefs.map.remove(k)
                prefs.map.putAll(pending)
                pending.clear(); removals.clear()
            }
        }
    }
}
