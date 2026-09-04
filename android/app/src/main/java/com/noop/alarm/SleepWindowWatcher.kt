package com.noop.alarm

/**
 * The light-sleep detector for the smart alarm (#207) — PURE so it can be reasoned about and tested.
 *
 * It never touches AlarmManager itself; it only DECIDES whether the current overnight HR pattern
 * looks like a lighter sleep phase (or an arousal) within the wake window. The caller (the BLE
 * foreground service) feeds it the live heart rate once it's inside the window and, if [shouldWake]
 * returns true, asks [SmartAlarmScheduler.advanceTo] to move the guaranteed alarm EARLIER. The
 * scheduler clamps that to the window and can never push the wake later or drop it, so this detector
 * is advisory only — the hard deadline remains the floor of safety.
 *
 * HONEST signal, no over-claiming: during deep sleep heart rate sits near its nightly trough and is
 * steady; in lighter sleep / on an arousal it lifts above that trough. We track the lowest smoothed
 * HR seen overnight (the trough proxy) and fire when the current HR rises a meaningful margin above
 * it AND is itself not at the floor. This is a coarse "you're stirring" heuristic — it is NOT a sleep
 * stage classifier and makes no clinical claim. If the strap streams nothing (BLE down, not worn),
 * the detector simply never fires and the hard deadline wakes the user.
 */
class SleepWindowWatcher(
    /** How far above the nightly trough (bpm) counts as "lighter / stirring". */
    private val riseBpm: Int = 6,
    /** Don't trust the trough until we've seen at least this many samples this night. */
    private val minSamples: Int = 30,
    /** Ignore obviously-awake-high HR as a trough candidate (e.g. the user got up briefly). */
    private val troughCeilingBpm: Int = 90,
) {
    private var troughBpm: Int = Int.MAX_VALUE
    private var sampleCount: Int = 0
    /** Set once we've advanced the alarm so we don't keep re-advancing every sample. */
    private var fired: Boolean = false

    /**
     * The trough established so far, or null while no reading has qualified as a candidate. READ-ONLY
     * diagnostics (#1858) — the detector's own decisions do not consult it.
     *
     * Null is the interesting value: it means no reading has ever been BELOW [troughCeilingBpm], which
     * is what happens when the user is awake for the whole window, and it is the state [shouldWake]
     * treats as "no reference yet" and refuses to fire on.
     */
    val trough: Int? get() = if (troughBpm == Int.MAX_VALUE) null else troughBpm

    /** Readings folded in since [reset]. READ-ONLY diagnostics: distinguishes "no live HR" from
     *  "HR arrived but the heuristic never fired". */
    val samples: Int get() = sampleCount

    /** Whether the alarm has already been advanced this window. READ-ONLY diagnostics. */
    val hasFired: Boolean get() = fired

    /** Reset for a fresh night (called when the watcher (re)enters a window). */
    fun reset() {
        troughBpm = Int.MAX_VALUE
        sampleCount = 0
        fired = false
    }

    /**
     * Feed one smoothed HR reading. Returns true exactly once — when the reading first looks like a
     * lighter phase inside the window — so the caller advances the alarm a single time. All later
     * calls return false until [reset]. A non-positive HR (no live data) is ignored.
     */
    fun shouldWake(bpm: Int): Boolean {
        if (bpm <= 0) return false
        sampleCount++
        if (bpm <= troughCeilingBpm && bpm < troughBpm) troughBpm = bpm
        if (fired) return false
        if (sampleCount < minSamples || troughBpm == Int.MAX_VALUE) return false
        // Rise of >= riseBpm above the trough, and the current reading itself is off the floor.
        if (bpm >= troughBpm + riseBpm && bpm > troughBpm) {
            fired = true
            return true
        }
        return false
    }
}
