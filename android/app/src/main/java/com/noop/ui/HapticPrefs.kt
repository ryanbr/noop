package com.noop.ui

import android.content.Context

/**
 * Per-event toggles for NOOP's IN-SESSION strap-haptic cues (#1115 offshoot) — the cues that used to fire
 * unconditionally whenever the feature was in use (Breathing pacer, Interval timer, Live Session, workout
 * start/end, double-tap actions, biofeedback session).
 *
 * Every key is DEFAULT-OFF (opt-in). To avoid a silent regression for people already using these features,
 * a one-time migration turns them ON for an EXISTING install (one that has ever synced or paired a strap)
 * and leaves them OFF for a fresh install. The ambient cues (inactivity / smart-alarm / stress / zone
 * coaching / calls / notifications) keep their OWN existing keys and are not duplicated here.
 *
 * Byte-parity twin of the Apple `HapticPrefs` (same key strings + same default-off + same migration rule),
 * so a `.noopbak` restore reads identically on either OS.
 */
object HapticPrefs {
    private const val NAME = "noop_haptics_prefs"
    private fun p(ctx: Context) = ctx.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    // In-session cue keys (Group B). New gates, default OFF.
    // BREATHING also covers the resonance / biofeedback session cues (on Android these run through the
    // Breathe path — there is no separate biofeedback buzz). Double-tap is deliberately NOT here: it's
    // already opt-in via the DoubleTapAction selection (NONE = off), so a second default-off gate would
    // silently kill a configured action.
    const val BREATHING = "haptics.breathing"
    const val INTERVALS = "haptics.intervals"
    const val LIVE_SESSION = "haptics.liveSession"
    const val WORKOUT = "haptics.workout"

    /** All in-session keys, in display order — drives both the migration and the settings section. */
    val inSessionKeys = listOf(BREATHING, INTERVALS, LIVE_SESSION, WORKOUT)

    private const val MIGRATED_V1 = "haptics.migratedV1"

    /** Whether an in-session cue may fire. Runs the one-time preserve-existing migration on first access. */
    fun enabled(ctx: Context, key: String): Boolean {
        migrateIfNeeded(ctx)
        return p(ctx).getBoolean(key, false)
    }

    fun setEnabled(ctx: Context, key: String, value: Boolean) {
        p(ctx).edit().putBoolean(key, value).apply()
    }

    /**
     * One-time preserve-existing migration. An EXISTING install (already ONBOARDED — `noop.onboarded`)
     * fired these cues unconditionally, so we default them ON there; a fresh install leaves them OFF.
     *
     * MUST run at app startup (NoopApplication.onCreate), BEFORE this session's onboarding: the onboarded
     * flag is the "has run a prior version" proxy, and reading it at startup is what keeps a fresh install
     * (not yet onboarded on its first launch) OFF — a lazy read after the user onboards would wrongly see
     * onboarded=true and migrate a brand-new user ON. Idempotent + @Synchronized. Byte-parity twin of the
     * Apple `HapticPrefs.migrateIfNeeded` (same `noop.onboarded` signal).
     */
    @Synchronized
    fun migrateIfNeeded(ctx: Context) {
        val prefs = p(ctx)
        if (prefs.getBoolean(MIGRATED_V1, false)) return
        val establishedInstall = NoopPrefs.of(ctx).getBoolean(NoopPrefs.KEY_ONBOARDED, false)
        prefs.edit().apply {
            if (establishedInstall) inSessionKeys.forEach { putBoolean(it, true) }
            putBoolean(MIGRATED_V1, true)
        }.apply()
    }
}
