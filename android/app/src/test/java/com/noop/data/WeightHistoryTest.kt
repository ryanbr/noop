package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class WeightHistoryTest {
    // Verbatim stdout from the standalone Swift WeightHistory oracle; see the matching Swift suite.
    @Test fun validationMatchesSwiftOracle() {
        val days = listOf("2024-02-29", "2026-02-29", "2000-02-29", "1900-02-29", "2100-02-29", "2026-04-31", "2026-04-30", "0001-01-01", "0000-01-01", "9999-12-31", "2026-13-01", "2026-00-10", "2026-09-00", "2026-09-31", "2026-9-25", " 2026-09-25", "２０２６-09-25", "2026-09-25")
        assertEquals("101000110100000001", days.joinToString("") { if (WeightHistory.validDay(it)) "1" else "0" })
        assertEquals("00000111", listOf(-1.0, 0.0, Double.NaN, Double.POSITIVE_INFINITY, 1000.1, 0.1, 80.5, 1000.0)
            .joinToString("") { if (WeightHistory.validKilograms(it)) "1" else "0" })
    }

    @Test fun resolutionMatchesSwiftOracle() {
        val entries = listOf(WeightEntry("2026-09-25", 80.0, "health-connect"), WeightEntry("2026-09-24", 82.0, "health-connect"),
            WeightEntry("2026-09-25", 81.0, "apple-health"), WeightEntry("2026-09-25", 79.5, "noop-weight"),
            WeightEntry("2026-09-26", 78.0, "noop-weight"), WeightEntry("2026-09-23", 0.0, "noop-weight"),
            WeightEntry("2026-09-22", 90.0, "unknown"))
        val result = WeightHistory.resolve(entries, "2026-09-25")
        assertEquals("2026-09-24|82.0|health-connect\n2026-09-25|79.5|noop-weight",
            result.joinToString("\n") { "${it.day}|${it.kilograms}|${it.source}" })
        assertEquals(result, WeightHistory.resolve(entries.reversed(), "2026-09-25"))
        assertEquals(WeightHistory.sources, WhoopRepository.sourceCandidates("weight", "apple-health", "whoop-test").map { it.source })
    }

    private class Database {
        val rows = mutableMapOf<Triple<String, String, String>, MetricSeriesRow>()
        val daily = mutableListOf<AppleDaily>()
        fun put(row: MetricSeriesRow) { rows[Triple(row.deviceId, row.day, row.key)] = row }
        val store = WeightHistoryStore(
            upsert = { it.forEach(::put) },
            query = { source, key, from, to -> rows.values.filter { it.deviceId == source && it.key == key && it.day in from..to } },
            delete = { source, day, key -> rows.remove(Triple(source, day, key)); Unit },
            queryDaily = { source, from, to -> daily.filter { it.deviceId == source && it.day in from..to } },
        )
    }

    @Test fun editingReimportAndDeletePreserveIndependentSources() = runBlocking {
        val db = Database()
        db.put(MetricSeriesRow("health-connect", "2026-09-25", "weight", 81.0))
        db.put(MetricSeriesRow("noop-mood", "2026-09-25", "mood", 4.0))
        db.store.save("2026-09-25", 80.0)
        db.store.save("2026-09-25", 79.5)
        assertEquals(listOf(WeightEntry("2026-09-25", 79.5, "noop-weight")), db.store.history("2026-09-25"))
        db.put(MetricSeriesRow("health-connect", "2026-09-25", "weight", 82.0))
        assertEquals(79.5, db.store.history("2026-09-25").single().kilograms, 0.0)
        assertEquals(3, db.rows.size)
        db.store.delete("2026-09-25")
        db.store.delete("2026-09-25")
        assertEquals(listOf(WeightEntry("2026-09-25", 82.0, "health-connect")), db.store.history("2026-09-25"))
        assertEquals(4.0, db.rows.values.single { it.key == "mood" }.value, 0.0)
    }

    @Test fun invalidWritesCannotReplaceGoodData() = runBlocking {
        val db = Database()
        db.store.save("2026-09-25", 80.0)
        for ((day, value) in listOf("2026-09-25" to Double.NaN, "2026-02-29" to 80.0, "2026-09-25" to 0.0)) {
            try { db.store.save(day, value); fail("Invalid weight was accepted") }
            catch (_: IllegalArgumentException) { }
        }
        assertEquals(80.0, db.store.history("2026-09-25").single().kilograms, 0.0)
    }

    @Test fun storageFailurePropagatesInsteadOfPretendingToSave() = runBlocking {
        val store = WeightHistoryStore({ error("disk full") }, { _, _, _, _ -> emptyList() }, { _, _, _ -> })
        try { store.save("2026-09-25", 80.0); fail("Failure was swallowed") }
        catch (error: IllegalStateException) { assertEquals("disk full", error.message) }
    }
    @Test fun legacyDailyWeightsSurviveOverridesAndOldDates() = runBlocking {
        val db = Database()
        val day = "2026-01-10"
        db.daily += AppleDaily(deviceId = "health-connect", day = day, weightKg = 84.2)
        db.daily += AppleDaily(deviceId = "health-connect", day = "2026-09-27", weightKg = 70.0)
        assertEquals(listOf(WeightEntry(day, 84.2, "health-connect")), db.store.history("2026-09-26"))
        db.put(MetricSeriesRow("health-connect", day, "weight", 83.0))
        assertEquals(83.0, db.store.history("2026-09-26").single().kilograms, 0.0)
        db.store.save(day, 82.0)
        assertEquals(82.0, db.store.history("2026-09-26").single().kilograms, 0.0)
        db.store.delete(day)
        assertEquals(83.0, db.store.history("2026-09-26").single().kilograms, 0.0)
        db.put(MetricSeriesRow("health-connect", day, "weight", Double.NaN))
        assertEquals(84.2, db.store.history("2026-09-26").single().kilograms, 0.0)
        db.daily += AppleDaily(deviceId = "apple-health", day = day, weightKg = 85.0)
        assertEquals(listOf(WeightEntry(day, 85.0, "apple-health")), db.store.history("2026-09-26"))
    }

}
