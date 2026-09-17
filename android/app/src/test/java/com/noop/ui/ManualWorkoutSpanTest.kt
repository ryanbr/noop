package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #2034: entering a manual workout by its start and END, not only by a duration.
 *
 * The row has always been stored as `startTs`/`endTs`, so the span is the shape the storage already
 * speaks and the duration was the lossy intermediate. These pin two things: that the span builder keeps
 * the exact end it is given, and that the duration front door still produces byte-identical rows so the
 * auto-workout nudge and every existing caller are unaffected.
 *
 * Twin of Swift `WorkoutSource.buildManualRowFromSpan`, same cases in the same order.
 */
class ManualWorkoutSpanTest {
    private val now = 1_700_000_000L
    private val start = now - 7_200L

    @Test
    fun spanBuilderKeepsTheExactEndItIsGiven() {
        // 45m17s. The duration path cannot express this: it would store 45m00s and silently shorten the
        // session by 17 seconds. This is the whole point of the span form.
        val end = start + 45 * 60 + 17
        val r = WorkoutEditing.buildManualRowFromSpan(
            "my-whoop", start, end, "Run", null, null, now,
        )
        assertNotNull(r)
        assertEquals(start, r!!.startTs)
        assertEquals(end, r.endTs)
        assertEquals((45 * 60 + 17).toDouble(), r.durationS!!, 0.0)
    }

    @Test
    fun durationFrontDoorStillProducesTheIdenticalRow() {
        // The delegation invariant. If these ever diverge, the nudge and the sheet would write different
        // rows for the same session.
        val viaDuration = WorkoutEditing.buildManualRow(
            deviceId = "my-whoop", startSeconds = start, durationMin = 45,
            sport = "Run", avgHr = 140, energyKcal = 400.0, nowSeconds = now, distanceM = 8_000.0,
        )
        val viaSpan = WorkoutEditing.buildManualRowFromSpan(
            deviceId = "my-whoop", startSeconds = start, endSeconds = start + 45 * 60,
            sport = "Run", avgHr = 140, energyKcal = 400.0, nowSeconds = now, distanceM = 8_000.0,
        )
        assertNotNull(viaDuration)
        assertEquals(viaDuration, viaSpan)
    }

    @Test
    fun rejectsAnEndAtOrBeforeTheStart() {
        assertNull(WorkoutEditing.buildManualRowFromSpan("my-whoop", start, start, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRowFromSpan("my-whoop", start, start - 1, "Run", null, null, now))
    }

    @Test
    fun rejectsASpanOverTwentyFourHours() {
        val s = now - WorkoutEditing.MAX_MANUAL_SPAN_SECONDS - 60
        assertNotNull(
            WorkoutEditing.buildManualRowFromSpan(
                "my-whoop", s, s + WorkoutEditing.MAX_MANUAL_SPAN_SECONDS, "Run", null, null, now,
            ),
        )
        assertNull(
            WorkoutEditing.buildManualRowFromSpan(
                "my-whoop", s, s + WorkoutEditing.MAX_MANUAL_SPAN_SECONDS + 1, "Run", null, null, now,
            ),
        )
    }

    @Test
    fun anEndExactlyAtNowIsValidButOneSecondPastIsNot() {
        assertNotNull(WorkoutEditing.buildManualRowFromSpan("my-whoop", start, now, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRowFromSpan("my-whoop", start, now + 1, "Run", null, null, now))
    }

    @Test
    fun spanDurationMinRoundsForDisplayOnly() {
        assertEquals(45, WorkoutEditing.spanDurationMin(start, start + 45 * 60))
        // 45m17s reads as 45, 45m45s reads as 46. The stored end is untouched either way.
        assertEquals(45, WorkoutEditing.spanDurationMin(start, start + 45 * 60 + 17))
        assertEquals(46, WorkoutEditing.spanDurationMin(start, start + 45 * 60 + 45))
    }

    @Test
    fun endForDurationIsTheInverseOfWholeMinutes() {
        assertEquals(start + 45 * 60, WorkoutEditing.endForDuration(start, 45))
        assertEquals(45, WorkoutEditing.spanDurationMin(start, WorkoutEditing.endForDuration(start, 45)))
    }

    @Test
    fun movingTheStartCarriesTheEndAndKeepsTheLength() {
        val end = start + 45 * 60 + 17
        val newStart = start - 3_600
        val newEnd = WorkoutEditing.endAfterStartMove(start, end, newStart)
        assertEquals(newStart + 45 * 60 + 17, newEnd)
        // The length is what survives, including the seconds a duration field cannot show.
        assertEquals(end - start, newEnd - newStart)
    }

    @Test
    fun theDurationFormKeepsItsWholeMinuteBoundsAndOverflowGuard() {
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 0, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 25 * 60, "Run", null, null, now))
        // The overflow guard lives in the duration form because only it does the addition.
        assertNull(WorkoutEditing.buildManualRow("my-whoop", Long.MAX_VALUE - 10, 45, "Run", null, null, now))
    }
}

/**
 * The one-minute floor on manual entry, twin of Swift `WorkoutSource.minManualSpanSeconds`.
 *
 * The duration-shaped front door already enforced this by accident, counting whole minutes and rejecting
 * zero. The SPAN-shaped door did not, and that is the one the Add/Edit sheet uses, so a start and end
 * thirty seconds apart made a row the live path discards. Two doors, two answers, for the same workout.
 */
class ManualWorkoutFloorTest {
    private val now = 1_700_000_000L
    private val start = now - 7_200L

    private fun build(seconds: Long) = WorkoutEditing.buildManualRowFromSpan(
        "my-whoop", start, start + seconds, "Run", null, null, now,
    )

    @Test
    fun `a sub minute manual entry is refused`() {
        assertNull("a 30-second manual entry is refused", build(30))
        assertNull("just under the floor is refused", build(59))
    }

    @Test
    fun `exactly a minute is kept`() {
        // A deliberate one-minute effort is training. The floor is for what falls SHORT of a minute.
        assertNotNull("exactly a minute is kept", build(60))
        assertNotNull("an ordinary session is unaffected", build(3600))
    }

    @Test
    fun `the floor matches the live session gate`() {
        // One rule whether a session was tracked or typed in. AppViewModel.endWorkout reads this same
        // constant, so a change to one cannot leave the two doors disagreeing.
        assertEquals(60L, WorkoutEditing.MIN_MANUAL_SPAN_SECONDS)
    }
}
