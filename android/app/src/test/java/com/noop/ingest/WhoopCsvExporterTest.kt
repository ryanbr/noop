package com.noop.ingest

import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.zip.ZipInputStream

/**
 * The round-trip contract, Android side: serialize with WhoopCsvExporter, re-parse the bytes with
 * the REAL CsvTable parser (the same one WhoopCsvImporter feeds), and assert the normalized columns
 * the importer reads carry the original values back. This proves the exported zip is re-importable
 * by NOOP itself; the macOS suite mirrors it through the full WhoopExportImporter parse functions.
 *
 * Stage/zone fidelity is checked through the exporter's own tolerant decoders, which the importer's
 * persisted JSON shapes also feed — so a decode here is the same decode the dashboards rely on.
 */
class WhoopCsvExporterTest {

    @Test
    fun cyclesRoundTripThroughRealParser() {
        val daily = listOf(
            DailyMetric(
                deviceId = "my-whoop", day = "2026-06-01", totalSleepMin = 420.0, efficiency = 0.923,
                deepMin = 95.0, remMin = 115.0, lightMin = 210.0, disturbances = 35, restingHr = 52,
                avgHrv = 68.4, recovery = 72.0, strain = 12.5, exerciseCount = null,
                spo2Pct = 96.0, skinTempDevC = 33.1, respRateBpm = 14.2,
            ),
        )
        val series = mapOf(
            "2026-06-01" to mapOf(
                "sleep_performance" to 85.0, "sleep_consistency" to 88.0,
                "sleep_need_min" to 480.0, "sleep_debt_min" to 60.0,
            ),
        )
        val csv = WhoopCsvExporter.cyclesCsv(daily, series, mapOf("2026-06-01" to "import"))
        val table = CsvTable.fromData(csv.toByteArray())
        assertEquals(1, table.rows.size)
        val row = table.rows[0]
        // The normalized keys the importer's parseCycles reads must carry the values back.
        assertEquals("72", row["recovery_score_pct"])
        assertEquals("52", row["resting_heart_rate_bpm"])
        assertEquals("68.4", row["heart_rate_variability_ms"])
        assertEquals("33.1", row["skin_temp_celsius"])
        assertEquals("96", row["blood_oxygen_pct"])
        // CSV is WHOOP 0–21 scale: 12.5 Effort × 21/100 = 2.625 (re-import scales back up).
        assertEquals("2.625", row["day_strain"])
        assertEquals("14.2", row["respiratory_rate_rpm"])
        assertEquals("420", row["asleep_duration_min"])
        assertEquals("210", row["light_sleep_duration_min"])
        assertEquals("95", row["deep_sws_duration_min"])
        assertEquals("115", row["rem_duration_min"])
        // Awake duration is MINUTES and the Android daily row doesn't carry it — the cell must be
        // EMPTY, not the disturbance count (a wrong unit that round-tripped on reimport; PR #97
        // review, tigercraft4).
        assertEquals("", row["awake_duration_min"].orEmpty())
        assertEquals("92.3", row["sleep_efficiency_pct"])
        // Source column is present but ignored on import.
        assertEquals("import", row["source"])
        // The four sleep figures re-parse as metricSeries rows under their original keys.
        val s = WhoopCsvImporter.parseCycleSeries(table, "my-whoop").associate { it.key to it.value }
        assertEquals(mapOf(
            "sleep_performance" to 85.0, "sleep_consistency" to 88.0,
            "sleep_need_min" to 480.0, "sleep_debt_min" to 60.0,
        ), s)
    }

    @Test
    fun workoutSportWithCommaQuoteNewlineSurvives() {
        val w = WorkoutRow(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_003_600L,
            sport = "Run, \"tempo\"\nintervals", source = "my-whoop", durationS = 3600.0,
            energyKcal = 540.0, avgHr = 158, maxHr = 182, strain = 11.2, distanceM = 8000.0,
            zonesJSON = """{"zone1":10.0,"zone2":20.0,"zone3":40.0,"zone4":20.0,"zone5":10.0}""",
            notes = null,
        )
        val table = CsvTable.fromData(WhoopCsvExporter.workoutsCsv(listOf(w)).toByteArray())
        assertEquals(1, table.rows.size)
        val row = table.rows[0]
        // The quoted activity name with comma/quote/newline must survive RFC-4180 round-trip.
        assertEquals("Run, \"tempo\"\nintervals", row["activity_name"])
        // CSV is WHOOP 0–21 scale: 11.2 Effort × 21/100 = 2.352.
        assertEquals("2.352", row["activity_strain"])
        assertEquals("540", row["energy_burned_cal"])
        assertEquals("158", row["average_hr_bpm"])
        assertEquals("182", row["max_hr_bpm"])
        assertEquals("40", row["hr_zone_3_pct"])
        assertEquals("8000", row["distance_meters"])
        // Timestamps re-parse to the same epoch (UTC encoding).
        assertEquals(1_750_000_000L, WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), 0))
        assertEquals(1_750_003_600L, WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), 0))
    }

    @Test
    fun sleepsRoundTripBothStageShapes() {
        // Android-import shape [{stage,min}] — minutes survive exactly.
        val imported = SleepSession(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_030_000L,
            efficiency = 0.91, restingHr = null, avgHrv = null,
            stagesJSON = """[{"stage":"light","min":210.0},{"stage":"deep","min":95.0},""" +
                """{"stage":"rem","min":115.0},{"stage":"awake","min":35.0}]""",
        )
        // On-device stager shape [{start,end,stage}] — minutes derived from the spans.
        val computed = SleepSession(
            deviceId = "my-whoop-noop", startTs = 2_000_000_000L, endTs = 2_000_007_200L,
            efficiency = null, restingHr = null, avgHrv = null,
            stagesJSON = """[{"start":2000000000,"end":2000003600,"stage":"light"},""" +
                """{"start":2000003600,"end":2000007200,"stage":"deep"}]""",
        )
        val table = CsvTable.fromData(
            WhoopCsvExporter.sleepsCsv(
                listOf(imported, computed),
                cycleStart = { com.noop.analytics.AnalyticsEngine.dayString(it.endTs, 0L) + " 00:00:00" },
            ).toByteArray(),
        )
        val byStart = table.rows.sortedBy { it["sleep_onset"] }
        assertEquals(2, byStart.size)
        // First night: explicit per-stage minutes.
        assertEquals("210", byStart[0]["light_sleep_duration_min"])
        assertEquals("95", byStart[0]["deep_sws_duration_min"])
        assertEquals("115", byStart[0]["rem_duration_min"])
        assertEquals("35", byStart[0]["awake_duration_min"])
        assertEquals("420", byStart[0]["asleep_duration_min"])  // 210+95+115
        assertEquals("false", byStart[0]["nap"])
        // Second night: stager spans → 60 + 60 minutes.
        assertEquals("60", byStart[1]["light_sleep_duration_min"])
        assertEquals("60", byStart[1]["deep_sws_duration_min"])
        assertEquals(2_000_007_200L, WhoopTime.parseEpochSeconds(byStart[1].cell("wake_onset"), 0))
    }

    @Test
    fun journalRoundTripIncludingFalseAnswersAndCommaNotes() {
        val rows = listOf(
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Any alcohol?", answeredYes = false, notes = null),
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Caffeine, after 4pm?", answeredYes = true, notes = "one, big \"mug\""),
        )
        val table = CsvTable.fromData(WhoopCsvExporter.journalCsv(rows).toByteArray())
        val byQuestion = table.rows.sortedBy { it["question_text"] }
        assertEquals(2, byQuestion.size)
        assertEquals("Any alcohol?", byQuestion[0]["question_text"])
        // The importer reads "true"/"false" via parseYesNo — the literal must be exact.
        assertEquals("false", byQuestion[0]["answered_yes_no"])
        assertEquals("2026-06-01 00:00:00", byQuestion[0]["cycle_start_time"])
        assertEquals("Caffeine, after 4pm?", byQuestion[1]["question_text"])
        assertEquals("true", byQuestion[1]["answered_yes_no"])
        assertEquals("one, big \"mug\"", byQuestion[1]["notes"])
    }

    @Test
    fun stageMinutesDecodesAllPersistedShapes() {
        // Dict shape (macOS import).
        val dict = WhoopCsvExporter.stageMinutes("""{"light":210,"deep":95,"rem":115,"awake":35}""")
        assertEquals(210.0, dict.light!!, 1e-9)
        assertEquals(420.0, dict.asleep!!, 1e-9)
        // Segment shape with "wake" alias → awake.
        val seg = WhoopCsvExporter.stageMinutes(
            """[{"start":0,"end":3600,"stage":"light"},{"start":3600,"end":5400,"stage":"wake"}]""",
        )
        assertEquals(60.0, seg.light!!, 1e-9)
        assertEquals(30.0, seg.awake!!, 1e-9)
        // Junk → all-null so the column exports blank.
        val none = WhoopCsvExporter.stageMinutes("not json")
        assertNull(none.light)
        assertNull(none.asleep)
    }

    @Test
    fun zonePercentsDecodesBothKeyShapes() {
        assertEquals(
            listOf(5.0, 20.0, 40.0, 30.0, 5.0),
            WhoopCsvExporter.zonePercents("""{"z1":5,"z2":20,"z3":40,"z4":30,"z5":5}"""),
        )
        assertEquals(
            listOf(10.0, 20.0, 40.0, 20.0, 10.0),
            WhoopCsvExporter.zonePercents("""{"zone1":10,"zone2":20,"zone3":40,"zone4":20,"zone5":10}"""),
        )
        assertNull(WhoopCsvExporter.zonePercents(null))
        assertNull(WhoopCsvExporter.zonePercents("""{"z1":0,"z2":0,"z3":0,"z4":0,"z5":0}"""))
    }

    @Test
    fun utcTimestampParsesBackToSameEpoch() {
        val ts = 1_751_234_567L
        assertEquals(ts, WhoopTime.parseEpochSeconds(WhoopCsvExporter.utc(ts), 0))
    }

    @Test
    fun numbersAreLocaleProof() {
        assertEquals("72", WhoopCsvExporter.num(72.0))
        assertEquals("68.4", WhoopCsvExporter.num(68.4))
        assertEquals("", WhoopCsvExporter.num(null as Double?))
        assertTrue(!WhoopCsvExporter.num(12345.678).contains(","))
    }

    @Test
    fun metricSeriesJsonIsSortedAndComplete() {
        val json = WhoopCsvExporter.metricSeriesJson(
            listOf(
                MetricSeriesRow("my-whoop-noop", "2026-06-02", "recovery", 60.0),
                MetricSeriesRow("my-whoop", "2026-06-01", "strain", 12.5),
            ),
        )
        // Sorted by (deviceId, day, key): "my-whoop" sorts before "my-whoop-noop".
        assertTrue(json.indexOf("\"my-whoop\"") < json.indexOf("\"my-whoop-noop\""))
        assertTrue(json.contains("\"strain\""))
        assertTrue(json.contains("\"recovery\""))
    }

    @Test
    fun zipBytesReadBackByName() {
        val zip = WhoopCsvExporter.zipBytes(
            linkedMapOf(
                "a.csv" to "x,y\r\n".toByteArray(),
                "noop_metric_series.json" to "[]".toByteArray(),
            ),
        )
        val names = ArrayList<String>()
        ZipInputStream(zip.inputStream()).use { zis ->
            var e = zis.nextEntry
            while (e != null) { names.add(e.name); e = zis.nextEntry }
        }
        assertEquals(listOf("a.csv", "noop_metric_series.json"), names)
    }

    @Test
    fun theSkinColumnCarriesTheAbsoluteNeverTheDeviation() {
        fun row(dev: Double?, celsius: Double?) =
            DailyMetric(deviceId = "my-whoop", day = "2026-06-01", skinTempDevC = dev, skinTempC = celsius)
        assertEquals(33.4, WhoopCsvExporter.exportedSkinTempCelsius(row(0.2, 33.4))!!, 1e-9)
        assertEquals(null, WhoopCsvExporter.exportedSkinTempCelsius(row(0.2, null)))
        assertEquals(33.1, WhoopCsvExporter.exportedSkinTempCelsius(row(33.1, null))!!, 1e-9)
    }
}
