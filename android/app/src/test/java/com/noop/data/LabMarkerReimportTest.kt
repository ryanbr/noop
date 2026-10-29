package com.noop.data

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Runs the production DAO orchestration with recorded primitive writes; Swift pins real SQLite rollback. */
class LabMarkerReimportTest {
    private class Fixture {
        val rows = linkedMapOf<String, LabMarkerRow>()
        val series = linkedMapOf<Triple<String, String, String>, Double>()
        val dao = Proxy.newProxyInstance(WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java)) { proxy, method, args ->
            val a = args!!
            when (method.name) {
                "upsertLabMarkers", "reprojectCell" -> {
                    val body = Class.forName("com.noop.data.WhoopDao\$DefaultImpls").methods.single { it.name == method.name }
                    try { body.invoke(null, proxy, *a) }
                    catch (error: InvocationTargetException) { throw error.targetException }
                }
                "markerKeysPresent" -> rows.values.filter { it.deviceId == a[0] }.map { it.markerKey }.distinct().sorted()
                "labMarkersByKey" -> rows.values.filter { it.deviceId == a[0] && it.markerKey == a[1] }.sortedBy { it.takenAt }
                "rekeyLegacyLabMarkers" -> {
                    val matching = rows.values.filter { it.deviceId == a[0] && it.markerKey == a[1] }
                    matching.forEach { rows[it.id] = it.copy(markerKey = a[2] as String) }
                    matching.size
                }
                "insertLabMarkersRaw" -> {
                    (a[0] as List<*>).forEach { item ->
                        val row = item as LabMarkerRow
                        rows.values.filter { it.deviceId == row.deviceId && it.markerKey == row.markerKey &&
                            it.takenAt == row.takenAt && it.source == row.source }.forEach { rows.remove(it.id) }
                        rows[row.id] = row
                    }
                    Unit
                }
                "latestNumericForCell" -> rows.values.filter {
                    it.deviceId == a[0] && it.markerKey == a[1] && it.day == a[2] && it.value != null
                }.maxByOrNull { it.takenAt }?.value
                "upsertMetricSeries" -> {
                    (a[0] as List<*>).forEach { item ->
                        val row = item as MetricSeriesRow
                        series[Triple(row.deviceId, row.day, row.key)] = row.value
                    }
                    Unit
                }
                "deleteMetricSeriesPoint" -> { series.remove(Triple(a[0] as String, a[1] as String, a[2] as String)); Unit }
                else -> error("Unexpected DAO call ${method.name}")
            }
        } as WhoopDao
    }

    private fun row(id: String, key: String, day: Int, value: Double? = 90.0) = LabMarkerRow(
        id, "my-whoop", key, "other", "2026-01-%02d".format(java.util.Locale.ROOT, day), day * 100L,
        value, if (value == null) "original text" else null, "unit", "lab-csv", "original note", "user range",
    )

    @Test fun rekeyPreservesHistoryAndProjectionsAndRepeatImportIds() = runBlocking {
        val f = Fixture()
        val old = "custom_egfr_ml_min_1_73m"; val new = old + "²"
        val history = listOf(row("one", old, 1), row("two", old, 2, 92.0).copy(source = "manual"), row("text", old, 3, null))
        val foreign = history[0].copy(id = "foreign", deviceId = "other-device", day = "2025-01-01")
        f.dao.upsertLabMarkers(history + foreign)
        val imported = row("new", new, 4, 95.0)
        f.dao.upsertLabMarkers(listOf(imported), mapOf(old to new))
        assertEquals(history.map { it.copy(markerKey = new) } + imported,
            f.rows.values.filter { it.deviceId == "my-whoop" }.sortedBy { it.takenAt })
        assertEquals(foreign, f.rows[foreign.id])
        assertFalse(f.series.keys.any { it.third == old && it.second.startsWith("2026-") })
        assertEquals(listOf(90.0, 92.0, 95.0), f.series.filterKeys { it.third == new }.toSortedMap(compareBy { it.second }).values.toList())
        val before = f.rows.toMap()
        f.dao.upsertLabMarkers(listOf(imported.copy(id = "reimport")), mapOf(old to new))
        assertEquals(before, f.rows)
    }

    @Test fun conflictingOrEmptyLegacyKeysDoNotMoveHistory() = runBlocking {
        for (alias in listOf("custom_old", "", "custom_")) {
            val f = Fixture()
            val old = row("old", alias, 1)
            val target = row("target", "custom_new", 2).copy(source = "other-source")
            val existing = if (alias == "custom_old") listOf(target) else emptyList()
            f.dao.upsertLabMarkers(listOf(old) + existing)
            val imported = row("import", "custom_new", 3)
            f.dao.upsertLabMarkers(listOf(imported), mapOf(alias to "custom_new"))
            assertEquals(old, f.rows[old.id])
            assertEquals(existing + imported, f.rows.values.filter { it.markerKey == "custom_new" }.sortedBy { it.takenAt })
        }
    }

    @Test fun anExplicitlyImportedLegacyKeyIsNotReassigned() = runBlocking {
        val f = Fixture()
        val old = row("old", "custom_old", 1)
        f.dao.upsertLabMarkers(listOf(old))
        f.dao.upsertLabMarkers(listOf(row("new", "custom_new", 2), row("same", "custom_old", 3)),
            mapOf("custom_old" to "custom_new"))
        assertEquals(old, f.rows[old.id])
    }
}
