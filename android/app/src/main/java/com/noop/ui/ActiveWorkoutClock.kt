package com.noop.ui

/**
 * The ONE pause-aware elapsed calculation for an in-flight workout, shared by every surface that shows
 * its clock.
 *
 * #1533 added Pause/Resume to the full-screen live workout screen and taught THAT screen's timer to
 * subtract the paused time. The Today "workout in progress" card and the Live tab's active-workout card
 * were not part of it: both still read `now - startMs`. So pausing froze one clock and left two others
 * counting up, and a wearer who paused and left the screen saw the session apparently still running. The
 * saved duration was correct the whole time, which is what made it confusing rather than merely wrong —
 * the only evidence on screen contradicted the button that had just been pressed.
 *
 * Kept pure and in one place so a new surface cannot reintroduce the divergence by open-coding the
 * subtraction again. Twin of Swift `ActiveWorkoutClock`.
 */
object ActiveWorkoutClock {

    /**
     * Seconds of ACTIVE time: wall time since [startMs], minus every completed pause
     * ([pausedDurationMs]), minus the one still open when [pausedAtMs] is non-null.
     *
     * Clamped at zero so a clock-skew negative reads 0:00 rather than counting backwards. The open-pause
     * term is deliberately NOT clamped on its own: the single clamp on the result is what the Swift twin
     * does, and two clamps would disagree with it for a [pausedAtMs] in the future.
     *
     * Twin of Swift `ActiveWorkoutClock.activeElapsed` — the NAMES differ (that one takes
     * `Date`/`TimeInterval`, this one Long milliseconds), so neither turns up in a grep for the other.
     * Same arithmetic and the same single clamp.
     */
    fun activeElapsedSeconds(
        startMs: Long,
        pausedAtMs: Long?,
        pausedDurationMs: Long,
        nowMs: Long,
    ): Long {
        val openPauseMs = pausedAtMs?.let { nowMs - it } ?: 0L
        return ((nowMs - startMs - pausedDurationMs - openPauseMs) / 1000).coerceAtLeast(0L)
    }
}
