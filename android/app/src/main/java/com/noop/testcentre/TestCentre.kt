package com.noop.testcentre

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * The Test Centre orchestration surface (Kotlin twin of the Swift TestCentre).
 *
 * Backed by a SINGLE SharedPreferences file "noop_testcentre" for all NEW Test Centre flags,
 * consolidating what used to be scattered across noop_prefs / noop_experiments / noop_debug_export and
 * ~10 non-reactive mutableStateOf mirrors in SettingsScreen. The legacy experiment + debug-export keys
 * are PRESERVED in their own files (read through their existing accessors), so activation never changes a
 * legacy setting (spec section 10). [active] is the zero-cost gate engines check before emitting a tagged line.
 *
 * The constructor takes a [SharedPreferences] directly so the surface is exercisable on the plain JVM
 * (no Robolectric, matching the rest of the suite, see DeviceRegistryTest / MoodStoreTest); production
 * uses [from] to bind the real "noop_testcentre" file.
 */
class TestCentre internal constructor(private val prefs: SharedPreferences) {

    /** The zero-cost gate. `if (testCentre.active(TestDomain.SLEEP)) client.log(line, TestDomain.SLEEP)`. */
    fun active(d: TestDomain): Boolean {
        if (d == TestDomain.UNIVERSAL) return anyActive()        // universal rides whatever mode is on
        if (prefs.getBoolean(ACTIVE_PREFIX + TestDomain.MASTER.id, false)) return true  // master = all on
        return prefs.getBoolean(ACTIVE_PREFIX + d.id, false)
    }

    /** True when ANY non-universal mode is on (drives the testing-on banner plus the universal traces). */
    fun anyActive(): Boolean = TestDomain.values().any {
        it != TestDomain.UNIVERSAL && prefs.getBoolean(ACTIVE_PREFIX + it.id, false)
    }

    fun activate(d: TestDomain) {
        prefs.edit()
            .putBoolean(ACTIVE_PREFIX + d.id, true)
            .putLong(STARTED_PREFIX + d.id, System.currentTimeMillis() / 1000L)
            .apply()
    }

    fun deactivate(d: TestDomain) {
        prefs.edit().putBoolean(ACTIVE_PREFIX + d.id, false).apply()
    }

    /** Unix seconds the mode was last activated, or null if never. */
    fun startedAt(d: TestDomain): Long? {
        val t = prefs.getLong(STARTED_PREFIX + d.id, 0L)
        return if (t > 0L) t else null
    }

    fun answers(d: TestDomain): Map<String, String> {
        val raw = prefs.getString(ANSWERS_PREFIX + d.id, null) ?: return emptyMap()
        return runCatching {
            val o = JSONObject(raw)
            buildMap { for (k in o.keys()) put(k, o.getString(k)) }
        }.getOrDefault(emptyMap())
    }

    // All-time drained-rows tally (#990) - twin of the Swift TestCentre accessors. Sits in the
    // testcentre.* namespace because the Connection readout is its consumer, but it accrues
    // UNCONDITIONALLY (the Backfiller session summary is not test-mode gated), so it answers "has this
    // install ever drained anything" across sessions - the per-session counter resets on every
    // reconnect, so a strap stuck in a pull-restart loop looked like it never progressed even when rows
    // were landing.

    /** Fold one session's drained rows into the persisted all-time tally. Called from the log sink when
     *  the Backfiller's "session persisted N rows" summary lands (the single emit point). */
    fun noteDrainedRows(rows: Int) {
        if (rows <= 0) return
        prefs.edit().putLong(CUMULATIVE_DRAINED_KEY, cumulativeDrainedRows() + rows).apply()
    }

    /** The all-time drained-rows tally (0 before anything ever drained). Shown beside the per-session
     *  count on the Connection readout (#990). */
    fun cumulativeDrainedRows(): Long = prefs.getLong(CUMULATIVE_DRAINED_KEY, 0L)

    companion object {
        private const val PREFS = "noop_testcentre"
        private const val ACTIVE_PREFIX = "testcentre.active."
        private const val STARTED_PREFIX = "testcentre.startedAt."
        private const val ANSWERS_PREFIX = "testcentre.answers."
        private const val CUMULATIVE_DRAINED_KEY = "testcentre.cumulativeDrainedRows"

        fun from(context: Context): TestCentre =
            TestCentre(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
