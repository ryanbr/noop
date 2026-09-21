package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.ScoreInputProvenanceRow
import org.junit.Assert.*
import org.junit.Test

class SleepWearHistoryWindowTest {
    @Test fun repairNeverWidensWritesAcrossUnscoredHistory() {
        val source = "test-noop"
        val days = listOf("2024-02-01", "2024-04-01")
        val window = IntelligencePersistence.ComputedWindow(
            deviceId = source, from = "2020-01-01", to = "2026-01-01",
            dailies = days.reversed().map { DailyMetric(source, it, totalSleepMin = 400.0) },
            metricRows = (days + "2024-03-01").map { MetricSeriesRow(source, it, "sleep_performance", 80.0) },
            provenance = days.map { ScoreInputProvenanceRow(source, it, "recovery", "test") },
            markerSourceIds = listOf(source, "test"),
        )
        val writes = IntelligencePersistence.byScoredDay(window)
        assertEquals(days, writes.map { it.from })
        for (write in writes) {
            assertEquals(write.from, write.to)
            assertTrue(write.dailies.all { it.day == write.from })
            assertTrue(write.metricRows.all { it.day == write.from })
            assertTrue(write.provenance.all { it.day == write.from })
            assertEquals(window.markerSourceIds, write.markerSourceIds)
        }
        assertTrue(writes.none { "2024-03-01" in it.from..it.to })
        assertTrue(IntelligencePersistence.byScoredDay(window.copy(dailies = emptyList())).isEmpty())
    }
}
