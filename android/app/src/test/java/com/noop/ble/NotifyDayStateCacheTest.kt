package com.noop.ble

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class NotifyDayStateCacheTest {

    private fun days(): List<DailyMetric> = (1..14).map { day ->
        DailyMetric(
            deviceId = "my-whoop",
            day = "2026-07-${day.toString().padStart(2, '0')}",
            recovery = day.toDouble(),
            strain = (day + 20).toDouble(),
        )
    }

    @Test
    fun liveTicksReuseDailyProjectionWhileInputsAreUnchanged() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "alert-$illnessCalls"
        }
        val days = days()

        val first = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)
        repeat(1_000) {
            assertSame(first, cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true))
        }

        assertEquals(1, illnessCalls)
        assertEquals(14.0, first.todayRecovery)
        assertEquals(14, first.widgetRecovery)
        assertEquals(34, first.widgetEffort)
    }

    @Test
    fun newRoomEmissionRefreshesEvenWhenRowsCompareEqual() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            null
        }
        val firstDays = days()
        val secondDays = ArrayList(firstDays)

        val first = cache.resolve(firstDays, "2026-07-14", "2026-07-14", illnessEnabled = true)
        val second = cache.resolve(secondDays, "2026-07-14", "2026-07-14", illnessEnabled = true)

        assertNotSame(first, second)
        assertEquals(2, illnessCalls)
        assertSame(secondDays, second.days)
    }

    @Test
    fun preferenceChangeClearsIllnessWithoutWaitingForRoom() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "strained"
        }
        val days = days()

        val enabled = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)
        val disabled = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = false)

        assertEquals("strained", enabled.illness)
        assertNull(disabled.illness)
        assertEquals(1, illnessCalls)
    }

    @Test
    fun logicalDayRolloverRefreshesWithoutWaitingForRoom() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            null
        }
        val days = days()

        val before = cache.resolve(days, "2026-07-13", "2026-07-13", illnessEnabled = true)
        val after = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)

        assertNotSame(before, after)
        assertEquals(13.0, before.todayRecovery)
        assertEquals(14.0, after.todayRecovery)
        assertEquals(2, illnessCalls)
    }
}
