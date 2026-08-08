package com.noop.ui

import android.content.Context

/**
 * Per-event toggles for NOOP's IN-SESSION strap-haptic cues (#1115) — the cues that fire while you're
 * actively using a feature (Breathing pacer, Interval timer, Live Session coach cues, workout start/end,
 * biofeedback/resonance).
 *
 * These are feedback to something the user explicitly started, so they DEFAULT ON (opt-OUT): a fresh
 * install buzzes exactly as the features always did, and a user can turn any individual cue off. (The
 * AMBIENT cues — inactivity / stress / calls / notifications — stay opt-in via their OWN keys; that's where
 * "off by default" belongs, since those interrupt you unprompted.)
 *
 * Byte-parity twin of the Apple `HapticPrefs` (same key strings, same default-on).
 */
object HapticPrefs {
    private const val NAME = "noop_haptics_prefs"
    private fun p(ctx: Context) = ctx.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    // In-session cue keys. BREATHING also covers the resonance / biofeedback session cues (on Android those
    // run through the Breathe path). Double-tap is NOT here: it's already opt-in via its DoubleTapAction
    // picker (a second gate would silently kill a configured action).
    const val BREATHING = "haptics.breathing"
    const val INTERVALS = "haptics.intervals"
    const val LIVE_SESSION = "haptics.liveSession"
    const val WORKOUT = "haptics.workout"

    /** Whether an in-session cue may fire. DEFAULT-ON: an unset key reads true, so no migration is needed —
     *  a fresh install buzzes as the features always did, and turning a cue off is an explicit user choice. */
    fun enabled(ctx: Context, key: String): Boolean = p(ctx).getBoolean(key, true)

    fun setEnabled(ctx: Context, key: String, value: Boolean) {
        p(ctx).edit().putBoolean(key, value).apply()
    }
}
