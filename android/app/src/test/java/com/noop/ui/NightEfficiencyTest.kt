package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class NightEfficiencyTest {
    @Test
    fun swiftOracle() {
        val cases = listOf(
            listOf(0.87, 0.92, 400.0, 500.0),
            listOf(87.0, 92.0, 400.0, 500.0),
            listOf(null, 0.92, 400.0, 500.0),
            listOf(null, 92.0, 400.0, 500.0),
            listOf(null, null, 400.0, 500.0),
            listOf(null, null, 600.0, 500.0),
            listOf(null, null, 0.0, 0.0),
            listOf(null, null, 10.0, -1.0),
            listOf(1.0, 92.0, 0.0, 0.0),
            listOf(1.01, null, 0.0, 0.0),
            listOf(0.0, 92.0, 400.0, 500.0),
        )
        // Verbatim stdout from swiftc -O NightEfficiency.swift main.swift; same vectors in StrandTests.
        val expected = """
            87.0
            87.0
            92.0
            92.0
            80.0
            100.0
            nil
            nil
            100.0
            1.01
            0.0
        """.trimIndent()
        assertEquals(expected, cases.joinToString("\n") {
            nightEfficiencyPct(it[0], it[1], it[2]!!, it[3]!!)?.toString() ?: "nil"
        })
    }

    @Test
    fun selectedNightUsesSessionThenMatchingDayWhileHistoryStaysDaily() {
        val days = listOf(
            DailyMetric(deviceId = "d", day = "2026-06-01", efficiency = 0.92,
                totalSleepMin = 400.0, lightMin = 200.0, deepMin = 100.0, remMin = 100.0),
            DailyMetric(deviceId = "d", day = "2026-06-02", efficiency = 0.99,
                totalSleepMin = 400.0, lightMin = 200.0, deepMin = 100.0, remMin = 100.0),
        )
        val wake = LocalDate.parse("2026-06-01").atStartOfDay(ZoneId.systemDefault())
            .plusHours(7).toEpochSecond()
        val session = SleepSession(deviceId = "d", startTs = wake - 8 * 3600, endTs = wake, efficiency = 0.87)
        val model = buildSleepModel(days, session, selectedDay = "2026-06-01", todayKey = "2026-06-02")!!
        assertEquals("87%", model.efficiencyText)
        assertEquals("87%", heroDisplay(model, null)!!.efficiencyText)
        assertEquals(listOf(92.0, 99.0), model.efficiency.series)
        assertEquals(99.0, model.efficiency.latest!!, 0.0)
        val fallback = buildSleepModel(days, session.copy(efficiency = null),
            selectedDay = "2026-06-01", todayKey = "2026-06-02")!!
        assertEquals("92%", fallback.efficiencyText)
        val otherNight = buildSleepModel(days, session.copy(endTs = wake + 2 * 86400),
            selectedDay = "2026-06-01", todayKey = "2026-06-02")!!
        assertEquals("92%", otherNight.efficiencyText)
    }

    @Test
    fun heroWithoutDayRowUsesSameSessionAndStageFallbacks() {
        val session = SleepSession(deviceId = "d", startTs = 0, endTs = 500 * 60, efficiency = 0.87)
        val night = HeroNight(session, "2026-06-01",
            listOf("light" to 400f, "awake" to 100f), "")
        assertEquals("87%", heroDisplay(null, night)!!.efficiencyText)
        assertEquals("80%", heroDisplay(null, night.copy(session = session.copy(efficiency = null)))!!.efficiencyText)
    }
}
