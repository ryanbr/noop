package com.noop.ui

import android.content.Context
import com.noop.analytics.ResonanceEngine
import com.noop.analytics.StressOnsetDetector

/**
 * BiofeedbackPrefs — the small, on-device pref surface for the haptic-biofeedback pillar (the Kotlin twin
 * of Strand/Screens/BiofeedbackPrefs.swift): the locked resonance pace + its date (L1), the
 * "stress check-ins (haptic)" master/sub toggles + the replay-safe StressOnsetDetector state (L3).
 *
 * SharedPreferences-backed via [NoopPrefs.of] (the same store the rest of the app uses), single-user,
 * on-device — nothing here leaves the device. Toggles default OFF / safe (opt-in, manual-first). A
 * Settings group (Wave 3) writes the same keys; this object is the single reader/writer so the engine
 * config stays consistent. Key strings MATCH the Swift twin so the two platforms read the same prefs.
 *
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
 */
object BiofeedbackPrefs {

    private const val KEY_LOCKED_PACE = "biofeedback.resonanceBpm"
    private const val KEY_LOCKED_DATE = "biofeedback.resonanceLockedAt"
    private const val KEY_CHECK_IN = "biofeedback.stressCheckIn"
    private const val KEY_AUTO_NUDGE = "biofeedback.stressAutoNudge"
    private const val KEY_QUIET_HOURS = "biofeedback.stressQuietHours"
    private const val KEY_USE_RESONANCE = "biofeedback.stressUseResonancePace"
    private const val KEY_QUIET_START = "biofeedback.stressQuietStartMin"
    private const val KEY_QUIET_END = "biofeedback.stressQuietEndMin"
    private const val KEY_ST_BASELINE = "biofeedback.stOnsetBaseline"
    private const val KEY_ST_WAS_BELOW = "biofeedback.stOnsetWasBelow"
    private const val KEY_ST_LAST_FIRE = "biofeedback.stOnsetLastFire"

    // ── L1 locked resonance pace ──────────────────────────────────────────────

    /** The user's locked resonance pace (br/min), or null if they've never locked one. */
    fun lockedPace(context: Context): Double? {
        val v = NoopPrefs.of(context).getFloat(KEY_LOCKED_PACE, 0f).toDouble()
        return if (v > 0.0) v else null
    }

    /** Epoch-millis when the pace was measured (0 = never) — shown dated; the pace drifts. */
    fun lockedPaceDateMs(context: Context): Long = NoopPrefs.of(context).getLong(KEY_LOCKED_DATE, 0L)

    fun saveLockedPace(context: Context, bpm: Double, dateMs: Long) {
        NoopPrefs.of(context).edit()
            .putFloat(KEY_LOCKED_PACE, bpm.toFloat())
            .putLong(KEY_LOCKED_DATE, dateMs)
            .apply()
    }

    // ── L3 toggles → engine Config ────────────────────────────────────────────

    fun checkInEnabled(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_CHECK_IN, false)
    fun setCheckInEnabled(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_CHECK_IN, on).apply()

    fun autoNudge(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_AUTO_NUDGE, false)
    fun setAutoNudge(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_AUTO_NUDGE, on).apply()

    fun quietHoursEnabled(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_QUIET_HOURS, true)
    fun setQuietHoursEnabled(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_QUIET_HOURS, on).apply()

    fun useResonancePace(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_USE_RESONANCE, true)
    fun setUseResonancePace(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(KEY_USE_RESONANCE, on).apply()

    private fun quietStartMin(context: Context): Int = NoopPrefs.of(context).getInt(KEY_QUIET_START, 22 * 60)
    private fun quietEndMin(context: Context): Int = NoopPrefs.of(context).getInt(KEY_QUIET_END, 7 * 60)

    /** Build the engine config from the persisted toggles for the central L3 hook (Wave 3). */
    fun stressConfig(context: Context): StressOnsetDetector.Config = StressOnsetDetector.Config(
        enabled = checkInEnabled(context),
        autoNudge = autoNudge(context),
        quietHoursEnabled = quietHoursEnabled(context),
        quietStartMinutes = quietStartMin(context),
        quietEndMinutes = quietEndMin(context),
        buzzLoops = 1,
    )

    // ── L3 replay-safe state ──────────────────────────────────────────────────

    fun loadStressState(context: Context): StressOnsetDetector.State {
        val p = NoopPrefs.of(context)
        return StressOnsetDetector.State(
            baselineRMSSD = p.getFloat(KEY_ST_BASELINE, 0f).toDouble(),
            wasBelow = p.getBoolean(KEY_ST_WAS_BELOW, false),
            lastFireAt = p.getLong(KEY_ST_LAST_FIRE, 0L),
        )
    }

    fun saveStressState(context: Context, s: StressOnsetDetector.State) {
        NoopPrefs.of(context).edit()
            .putFloat(KEY_ST_BASELINE, s.baselineRMSSD.toFloat())
            .putBoolean(KEY_ST_WAS_BELOW, s.wasBelow)
            .putLong(KEY_ST_LAST_FIRE, s.lastFireAt)
            .apply()
    }

    /** The coherence fallback pace, re-exported so UI code reads it from one place. */
    val fallbackBpm: Double get() = ResonanceEngine.FALLBACK_BPM
}
