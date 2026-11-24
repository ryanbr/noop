package com.noop.ingest

import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * `dailyMetric.efficiency` and `sleepSession.efficiency` hold the 0–1 fraction the native pipeline writes.
 * The Oura-export / Fitbit / Garmin and Mi Band importers wrote a percentage into them, and Rest clamps
 * efficiency to 0–1, so every such night scored a perfect efficiency component. Twin of the Swift
 * `ImportedEfficiencyUnitTests`: same exports, same literals.
 */
class ImportedEfficiencyUnitTest {

    private class Written {
        val days = ArrayList<DailyMetric>()
        val sleeps = ArrayList<SleepSession>()
    }

    /** Run the importer's own persist step and capture the rows it hands the store. */
    private fun persisted(brand: WearableExportImporter.Brand, parsed: WearableExportImporter.Parsed): Written {
        val written = Written()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "device", "sleepSession" -> null
                "upsertDevice", "upsertMetricSeries" -> Unit
                "upsertDailyMetrics" -> {
                    @Suppress("UNCHECKED_CAST")
                    written.days.addAll(args!![0] as List<DailyMetric>)
                    Unit
                }
                "insertSleepSession" -> {
                    written.sleeps.add(args!![0] as SleepSession)
                    1L
                }
                else -> throw UnsupportedOperationException("persist must not call ${method.name}")
            }
        } as WhoopDao
        runBlocking { WearableExportImporter.persist(WhoopRepository(dao), brand, parsed) }
        return written
    }

    private fun oura(): Written {
        val json = """
            { "sleep": [
                { "day": "2026-06-01", "bedtime_start": "2026-05-31T23:15:00+00:00",
                  "bedtime_end": "2026-06-01T06:30:00+00:00", "total_sleep_duration": 25200,
                  "deep_sleep_duration": 5400, "light_sleep_duration": 13800, "rem_sleep_duration": 6000,
                  "awake_time": 900, "efficiency": 92, "lowest_heart_rate": 48, "average_hrv": 65 } ] }
        """
        val files = mapOf("oura_2026.json" to json.trimIndent().toByteArray())
        return persisted(WearableExportImporter.Brand.OURA, WearableExportImporter.parseOura(files))
    }

    private fun fitbit(efficiency: String): Written {
        val json = """
            [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
                "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20, $efficiency
                "levels": { "summary": { "deep": { "minutes": 80 }, "light": { "minutes": 220 },
                  "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        val files = mapOf("sleep-2026-06-01.json" to json.trimIndent().toByteArray())
        return persisted(WearableExportImporter.Brand.FITBIT, WearableExportImporter.parseFitbit(files))
    }

    @Test
    fun ouraExport_storesTheFraction() {
        val written = oura()
        assertEquals(0.92, written.days.single().efficiency!!, 0.0)
        assertEquals(0.92, written.sleeps.single().efficiency!!, 0.0)
    }

    @Test
    fun fitbitExport_storesTheFraction() {
        val written = fitbit("\"efficiency\": 94,")
        assertEquals(0.94, written.days.single().efficiency!!, 0.0)
        assertEquals(0.94, written.sleeps.single().efficiency!!, 0.0)
    }

    /** The export that names no efficiency falls back to asleep ÷ in-bed, on the same scale. */
    @Test
    fun fallbackFromDailyMinutes_isAFraction() {
        val written = fitbit("")
        assertEquals(0.9523809523809523, written.days.single().efficiency!!, 0.0)
        assertNull(
            "no hypnogram and no stated efficiency: nothing to derive it from",
            written.sleeps.single().efficiency,
        )
    }

    /** Rest is the figure the scale reached: 92% and 100% efficiency must not score the same night alike. */
    @Test
    fun rest_noLongerSaturatesOnAnImportedNight() {
        val stored = oura().days.single()
        val rest = RestScorer.restFromDaily(stored)!!
        val asPercent = RestScorer.restFromDaily(stored.copy(efficiency = 92.0))!!
        // 50% x 0.875 of need + 20% x 0.92 + 20% x restorative + 10% x neutral consistency.
        assertEquals(85.25, rest, 0.0)
        assertEquals("20% of the missing 8 points of efficiency", 1.6, asPercent - rest, 0.011)
    }

    @Test
    fun miBandEfficiency_isAFraction() {
        assertEquals(0.9523809523809523, XiaomiBandImporter.sleepEfficiency(400.0, 20.0)!!, 0.0)
        assertEquals(1.0, XiaomiBandImporter.sleepEfficiency(400.0, null)!!, 0.0)
        assertNull(XiaomiBandImporter.sleepEfficiency(0.0, 20.0))
        val stages = """[{"start":0,"end":24000,"stage":"light"},{"start":24000,"end":25200,"stage":"wake"}]"""
        assertEquals(0.9523809523809523, XiaomiBandImporter.efficiency(stages, 0L, 25_200L)!!, 0.0)
    }
}
