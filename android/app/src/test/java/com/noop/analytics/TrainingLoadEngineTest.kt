package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrainingLoadEngineTest {
    @Test
    fun constantLoadConvergesExactlyToLoadAndZeroBalance() {
        val result = TrainingLoadEngine.evaluateDense(List(42) { 50.0 })
        assertEquals(TrainingLoadEngine.State.ESTABLISHED, result.state)
        assertNull(result.unavailableReason)
        assertEquals(42, result.contiguousDays)
        assertEquals(36, result.points.size)
        assertEquals(50.0, result.ctl!!, 1e-12)
        assertEquals(50.0, result.atl!!, 1e-12)
        assertEquals(0.0, result.tsb!!, 1e-12)
    }

    @Test
    fun stepUpRaisesAcuteLoadFasterThanChronicLoad() {
        val result = TrainingLoadEngine.evaluateDense(List(7) { 50.0 } + List(7) { 100.0 })
        assertEquals(TrainingLoadEngine.State.BUILDING, result.state)
        assertEquals(57.67591375546929, result.ctl!!, 1e-10)
        assertEquals(81.6060279414279, result.atl!!, 1e-10)
        assertEquals(-23.930114185958608, result.tsb!!, 1e-10)
        assertTrue(result.atl!! > result.ctl!!)
        assertTrue(result.tsb!! < 0.0)
    }

    @Test
    fun stepDownProducesPositiveBalanceAsAcuteLoadFallsFaster() {
        val result = TrainingLoadEngine.evaluateDense(List(7) { 100.0 } + List(14) { 20.0 })
        assertTrue(result.ctl!! > result.atl!!)
        assertTrue(result.tsb!! > 0.0)
    }

    @Test
    fun minimumAndEstablishedBoundariesAreExplicit() {
        val thirteen = TrainingLoadEngine.evaluateDense(List(13) { 40.0 })
        assertEquals(TrainingLoadEngine.State.UNAVAILABLE, thirteen.state)
        assertEquals(TrainingLoadEngine.UnavailableReason.NOT_ENOUGH_CONTIGUOUS_DAYS, thirteen.unavailableReason)
        assertTrue(thirteen.points.isEmpty())

        assertEquals(
            TrainingLoadEngine.State.BUILDING,
            TrainingLoadEngine.evaluateDense(List(14) { 40.0 }).state,
        )
        assertEquals(
            TrainingLoadEngine.State.ESTABLISHED,
            TrainingLoadEngine.evaluateDense(List(42) { 40.0 }).state,
        )
    }

    @Test
    fun zeroIsARealRestDayButMissingLoadBreaksHistory() {
        val zeroLoads = MutableList(14) { 50.0 }.also { it[13] = 0.0 }
        val zero = TrainingLoadEngine.evaluateDense(zeroLoads)
        assertTrue(zero.isAvailable)
        assertEquals(0.0, zero.points.last().load, 0.0)
        assertTrue(zero.atl!! < 50.0)

        val days = (1..20).map { day ->
            TrainingLoadEngine.DailyLoad("2026-07-%02d".format(day), if (day == 12) null else 50.0)
        }
        val missing = TrainingLoadEngine.evaluate(days)
        assertFalse(missing.isAvailable)
        assertEquals(8, missing.contiguousDays)
        assertEquals("2026-07-13", missing.startDay)
    }

    @Test
    fun missingCalendarDayBreaksSuffix() {
        val days = (1..20).filter { it != 15 }.map { day ->
            TrainingLoadEngine.DailyLoad("2026-06-%02d".format(day), 50.0)
        }
        val result = TrainingLoadEngine.evaluate(days)
        assertEquals(5, result.contiguousDays)
        assertEquals("2026-06-16", result.startDay)
        assertEquals(TrainingLoadEngine.UnavailableReason.NOT_ENOUGH_CONTIGUOUS_DAYS, result.unavailableReason)
    }

    @Test
    fun explicitTargetIgnoresFutureRowsAndMissingTargetFailsClosed() {
        val days = (1..25).map { day ->
            TrainingLoadEngine.DailyLoad("2026-05-%02d".format(day), day.toDouble())
        }
        val result = TrainingLoadEngine.evaluate(days, through = "2026-05-20")
        assertEquals(20, result.contiguousDays)
        assertEquals("2026-05-20", result.endDay)
        assertEquals("2026-05-20", result.points.last().day)

        val missing = TrainingLoadEngine.evaluate(days, through = "2026-05-30")
        assertEquals(TrainingLoadEngine.UnavailableReason.MISSING_TARGET_DAY, missing.unavailableReason)
    }

    @Test
    fun inputOrderDoesNotChangeResult() {
        val days = (1..20).map { day ->
            TrainingLoadEngine.DailyLoad("2026-03-%02d".format(day), (20 + day).toDouble())
        }
        assertEquals(TrainingLoadEngine.evaluate(days), TrainingLoadEngine.evaluate(days.reversed()))
    }

    @Test
    fun invalidInputsFailClosed() {
        assertEquals(
            TrainingLoadEngine.UnavailableReason.INVALID_DAY,
            TrainingLoadEngine.evaluate(listOf(TrainingLoadEngine.DailyLoad("2026-02-30", 10.0))).unavailableReason,
        )
        assertEquals(
            TrainingLoadEngine.UnavailableReason.DUPLICATE_DAY,
            TrainingLoadEngine.evaluate(
                listOf(
                    TrainingLoadEngine.DailyLoad("2026-02-01", 10.0),
                    TrainingLoadEngine.DailyLoad("2026-02-01", 11.0),
                ),
            ).unavailableReason,
        )
        assertEquals(
            TrainingLoadEngine.UnavailableReason.INVALID_LOAD,
            TrainingLoadEngine.evaluate(listOf(TrainingLoadEngine.DailyLoad("2026-02-01", -1.0))).unavailableReason,
        )
        assertEquals(
            TrainingLoadEngine.UnavailableReason.INVALID_LOAD,
            TrainingLoadEngine.evaluate(listOf(TrainingLoadEngine.DailyLoad("2026-02-01", Double.NaN))).unavailableReason,
        )
        assertEquals(
            TrainingLoadEngine.UnavailableReason.INVALID_CONFIGURATION,
            TrainingLoadEngine.evaluateDense(
                List(42) { 50.0 },
                TrainingLoadEngine.Configuration(chronicTimeConstantDays = 0.0),
            ).unavailableReason,
        )
    }

    @Test
    fun leapDayAndMonthBoundaryStayContiguous() {
        val dates = listOf(
            "2024-02-22", "2024-02-23", "2024-02-24", "2024-02-25", "2024-02-26", "2024-02-27",
            "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02", "2024-03-03", "2024-03-04",
            "2024-03-05", "2024-03-06",
        )
        val result = TrainingLoadEngine.evaluate(dates.map { TrainingLoadEngine.DailyLoad(it, 30.0) })
        assertEquals(TrainingLoadEngine.State.BUILDING, result.state)
        assertEquals(14, result.contiguousDays)
        assertEquals(30.0, result.ctl!!, 1e-12)
        assertEquals(30.0, result.atl!!, 1e-12)
    }
}
