package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy

/** Exercise the DAO transaction bodies with recorded writes, without an Android SQLite runtime. */
class ScoreComputationDeviceScopeTest {
    private val stamp = ScoreComputationStamp("android:test+1", 1234)
    private val day = "2026-07-24"

    private class Writes {
        val metrics = mutableListOf<MetricSeriesRow>()
        val stamps = mutableListOf<ScoreComputationProvenanceRow>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java),
        ) { proxy, method, args ->
            when (method.name) {
                "replaceComputedScoreWindow", "upsertMetricSeriesWithProvenance" -> {
                    // Invoke the production Kotlin interface body, retaining its suspend continuation.
                    val body = Class.forName("com.noop.data.WhoopDao\$DefaultImpls")
                        .methods.single { it.name == method.name }
                    try { body.invoke(null, proxy, *args!!) }
                    catch (error: InvocationTargetException) { throw error.targetException }
                }
                "upsertMetricSeries" -> {
                    @Suppress("UNCHECKED_CAST")
                    metrics.addAll(args!![0] as List<MetricSeriesRow>)
                    Unit
                }
                "upsertScoreComputationProvenance" -> {
                    @Suppress("UNCHECKED_CAST")
                    stamps.addAll(args!![0] as List<ScoreComputationProvenanceRow>)
                    Unit
                }
                "deleteDailyMetricsInRange", "deleteScoreInputProvenanceInRange",
                "deleteScoreComputationProvenanceInRange", "deleteMetricSeriesKeyInRange",
                "upsertDailyMetrics", "upsertScoreInputProvenance" -> Unit
                else -> error("Unexpected DAO call: ${method.name}")
            }
        } as WhoopDao
    }

    @Test fun foreignOwnerMarkerIsStoredWithoutStampingTheActiveOwner() = runBlocking {
        val writes = Writes()
        val marker = MetricSeriesRow("ownerB-noop", day, "day_cycle_onset_ts", 100.0)
        val own = MetricSeriesRow("ownerA-noop", day, "sleep_performance", 80.0)
        writes.dao.replaceComputedScoreWindow(
            "ownerA-noop", day, day, listOf(DailyMetric("ownerA-noop", day)),
            listOf(marker, own), listOf(ScoreInputProvenanceRow("ownerA-noop", day, "recovery", "ownerA")), stamp,
        )
        assertEquals(listOf(marker, own), writes.metrics)
        assertEquals(setOf("recovery", "sleep_performance"), writes.stamps.map { it.key }.toSet())
        assertTrue(writes.stamps.all { it.deviceId == "ownerA-noop" && it.scope == "score-window" })
    }

    @Test fun mixedDeviceSeriesStampsOnlyEachDevicesActualCells() = runBlocking {
        val writes = Writes()
        val rows = listOf(
            MetricSeriesRow("ownerB-noop", day, "vo2max_est", 45.0),
            MetricSeriesRow("ownerA-noop", day, "steps_est", 1000.0),
            MetricSeriesRow("ownerB-noop", day, "steps_est", 2000.0),
        )
        writes.dao.upsertMetricSeriesWithProvenance(rows, emptyList(), stamp)
        assertEquals(rows, writes.metrics)
        assertEquals(rows.map { Triple(it.deviceId, it.day, it.key) }.toSet(),
            writes.stamps.map { Triple(it.deviceId, it.day, it.key) }.toSet())
        assertEquals(rows.size, writes.stamps.size)
        assertTrue(writes.stamps.all { it.computedBy == stamp.computedBy && it.computedAt == stamp.computedAt && it.scope == "metric-series" })
    }

    @Test fun emptySeriesCreatesNoComputationStamps() = runBlocking {
        val writes = Writes()
        writes.dao.upsertMetricSeriesWithProvenance(emptyList(), emptyList(), stamp)
        assertTrue(writes.metrics.isEmpty())
        assertTrue(writes.stamps.isEmpty())
    }
}
