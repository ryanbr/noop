package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

/** Cross-platform storage-contract tests for the local `noop-cycle` period-start series. */
class CycleTrackingStoreTest {
    private class FakeSeries {
        val rows = LinkedHashMap<Triple<String, String, String>, MetricSeriesRow>()
        fun upsert(newRows: List<MetricSeriesRow>) {
            newRows.forEach { rows[Triple(it.deviceId, it.day, it.key)] = it }
        }
        fun query(deviceId: String, key: String, from: String, to: String): List<MetricSeriesRow> =
            rows.values.filter { it.deviceId == deviceId && it.key == key && it.day in from..to }
        fun delete(deviceId: String, day: String, key: String) {
            rows.remove(Triple(deviceId, day, key))
        }
        fun deleteSeries(deviceId: String, key: String) {
            rows.keys.removeAll { it.first == deviceId && it.third == key }
        }
    }

    private fun store(fake: FakeSeries) = CycleTrackingStore(
        { fake.upsert(it) },
        { deviceId, key, from, to -> fake.query(deviceId, key, from, to) },
        { deviceId, day, key -> fake.delete(deviceId, day, key) },
        { deviceId, key -> fake.deleteSeries(deviceId, key) },
    )

    @Test
    fun usesDedicatedParitySourceAndIdempotentNaturalKey() = runBlocking {
        val fake = FakeSeries()
        val store = store(fake)
        store.logStart("2026-06-12")
        store.logStart("2026-06-12")

        assertEquals(1, fake.rows.size)
        val row = fake.rows.values.single()
        assertEquals("noop-cycle", row.deviceId)
        assertEquals("period_start", row.key)
        assertEquals(1.0, row.value, 0.0)
        assertEquals(listOf("2026-06-12"), store.starts())
    }

    @Test
    fun readsOldestFirstAndDeletesOnlyCycleRows() = runBlocking {
        val fake = FakeSeries()
        val store = store(fake)
        store.logStart("2026-07-20")
        store.logStart("2026-05-25")
        fake.upsert(listOf(MetricSeriesRow("other-source", "2026-05-25", "period_start", 1.0)))

        assertEquals(listOf("2026-05-25", "2026-07-20"), store.starts())
        store.deleteStart("2026-05-25")
        assertEquals(listOf("2026-07-20"), store.starts())
        assertEquals(1.0, fake.rows[Triple("other-source", "2026-05-25", "period_start")]!!.value, 0.0)

        store.deleteAll()
        assertEquals(emptyList<String>(), store.starts())
        assertEquals(1.0, fake.rows[Triple("other-source", "2026-05-25", "period_start")]!!.value, 0.0)
    }

    @Test
    fun todayKeyIsLocalIsoDay() {
        assertEquals("2026-07-21", CycleTrackingStore.todayKey(LocalDate.of(2026, 7, 21)))
    }
}
