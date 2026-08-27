package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the pause-aware workout clock every live surface now shares.
 *
 * #1533 added Pause/Resume but only the full-screen live workout screen's timer subtracted the paused
 * time; the Today card and the Live card kept reading `now - startMs`, so pausing froze one clock and
 * left two counting. These cases are the twin of Swift `ActiveWorkoutClockTests` — same scenarios, same
 * expected seconds — so the two platforms cannot drift on what "elapsed" means for a paused session.
 */
class ActiveWorkoutClockTest {

    private val startMs = 1_000_000L

    private fun elapsed(pausedAtS: Long? = null, pausedDurationS: Long = 0, nowS: Long): Long =
        ActiveWorkoutClock.activeElapsedSeconds(
            startMs = startMs,
            pausedAtMs = pausedAtS?.let { startMs + it * 1000 },
            pausedDurationMs = pausedDurationS * 1000,
            nowMs = startMs + nowS * 1000,
        )

    @Test fun activeElapsedSubtractsCompletedAndOpenPauses() {
        assertEquals(65L, elapsed(nowS = 65))                                        // never paused
        assertEquals(45L, elapsed(pausedDurationS = 20, nowS = 65))                  // one finished pause
        assertEquals(30L, elapsed(pausedAtS = 30, nowS = 65))                        // paused at 30s, still paused
        assertEquals(40L, elapsed(pausedAtS = 50, pausedDurationS = 10, nowS = 65))  // both
    }

    /**
     * The whole point of the fix: while paused the number must not move, however much wall time passes.
     * This is what the two card surfaces got wrong, and a clock that merely subtracts a CONSTANT would
     * still tick — so the open pause has to grow with `now`.
     */
    @Test fun clockIsFrozenWhilePaused() {
        assertEquals(30L, elapsed(pausedAtS = 30, nowS = 65))
        assertEquals(30L, elapsed(pausedAtS = 30, nowS = 99))
        assertEquals(30L, elapsed(pausedAtS = 30, nowS = 4_000))
    }

    @Test fun neverCountsBackwards() {
        assertEquals(0L, elapsed(nowS = -5))                          // clock skew
        assertEquals(0L, elapsed(pausedDurationS = 70, nowS = 65))    // paused longer than the session
    }

    /** The shared formatter, unchanged by this work but pinned beside its Swift twin. */
    @Test fun clockFormatRollsOverAtAnHour() {
        assertEquals("0:00", elapsedClock(0))
        assertEquals("1:05", elapsedClock(65))
        assertEquals("1:00:00", elapsedClock(3_600))
        assertEquals("1:30:00", elapsedClock(5_400))
        assertEquals("2:05:09", elapsedClock(2 * 3_600 + 5 * 60 + 9L))
        assertEquals("0:00", elapsedClock(-5))
    }
}
