package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the offline file-import of a user's OWN Oura / Fitbit / Garmin data export onto NOOP's daily
 * metrics + sleep sessions. Kotlin twin of the macOS WearableExportImporterTests — same arithmetic,
 * same brand detection, same honesty rules (a brand's own score is reference-only, never Charge).
 *
 * Tests the pure parse functions directly (no Room) with tiny inline fixtures.
 */
class WearableExportImporterTest {

    private fun bytes(s: String) = s.trimIndent().toByteArray()

    // ---------------- Oura ----------------

    @Test
    fun ouraSleepReadinessActivityFold() {
        val json = """
            {
              "sleep": [
                { "day": "2026-06-01", "bedtime_start": "2026-05-31T23:15:00+00:00",
                  "bedtime_end": "2026-06-01T06:30:00+00:00", "total_sleep_duration": 25200,
                  "deep_sleep_duration": 5400, "light_sleep_duration": 13800, "rem_sleep_duration": 6000,
                  "awake_time": 900, "efficiency": 92, "average_heart_rate": 54, "lowest_heart_rate": 48,
                  "average_hrv": 65 } ],
              "daily_readiness": [
                { "day": "2026-06-01", "score": 81, "temperature_deviation": -0.2,
                  "contributors": { "resting_heart_rate": 49 } } ],
              "daily_activity": [
                { "day": "2026-06-01", "steps": 8421, "active_calories": 520 } ]
            }
        """
        val files = mapOf("oura_2026.json" to bytes(json))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseOura(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(420.0, s.totalSleepMin!!, 1e-6)   // 25200s → 420 min
        assertEquals(90.0, s.deepMin!!, 1e-6)
        assertEquals(100.0, s.remMin!!, 1e-6)
        assertEquals(65.0, s.avgHrvMs!!, 1e-6)
        assertEquals(48, s.lowestHr)

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(49, d.restingHr)                   // readiness contributor wins
        assertEquals(-0.2, d.skinTempDevC!!, 1e-6)
        assertEquals(8421, d.steps)
        assertEquals(520.0, d.activeKcal!!, 1e-6)
        assertEquals(420.0, d.totalSleepMin!!, 1e-6)
        // Oura's OWN readiness score is kept as REFERENCE only — never a NOOP score.
        assertEquals(81, d.readinessScore)
    }

    @Test
    fun importedNightRespReachesDailyRow() {
        // #17: the night's resp rate (Oura `average_breath`) lives on the SESSION; it must also fold onto
        // the day's rollup so the imported day carries respRateBpm (which feeds NOOP's Charge), not null.
        val json = """
            {
              "sleep": [
                { "day": "2026-06-07", "bedtime_start": "2026-06-06T23:00:00+00:00",
                  "bedtime_end": "2026-06-07T06:00:00+00:00", "total_sleep_duration": 25200,
                  "average_breath": 15.3 } ]
            }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        val s = p.sleeps.first { it.respRateBpm != null }
        assertEquals(15.3, s.respRateBpm!!, 1e-6)        // the session still carries it
        val d = p.days.first { it.day == "2026-06-07" }
        assertEquals("the night's resp must fold onto the day rollup, not stay null",
            15.3, d.respRateBpm!!, 1e-6)
    }

    @Test
    fun ouraAcceptsDataWrapperAndDetectsByContent() {
        val json = """
            { "sleep": { "data": [
                { "day": "2026-06-02", "bedtime_start": "2026-06-01T22:00:00+00:00",
                  "bedtime_end": "2026-06-02T05:00:00+00:00", "total_sleep_duration": 21600 } ] } }
        """
        val files = mapOf("export.json" to bytes(json))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseOura(files)
        assertEquals(1, p.sleeps.size)
        assertEquals(360.0, p.sleeps[0].totalSleepMin!!, 1e-6)
    }

    // ---------------- Oura CSV (#857) ----------------

    @Test
    fun ouraDailySummaryCsvFoldsDays() {
        // Representative Oura daily-summary CSV: header + two days. Sleep durations are SECONDS (like the
        // JSON); headers mix spaces/case so HeaderNorm has to normalize them.
        val csv = """
            date,Total Sleep Duration,Deep Sleep Duration,REM Sleep Duration,Light Sleep Duration,Awake Time,Sleep Efficiency,Average Resting Heart Rate,Average HRV,Temperature Deviation,Readiness Score,Sleep Score,Steps,Activity Burn
            2026-06-01,25200,5400,6000,13800,900,92,49,65,-0.2,81,84,8421,520
            2026-06-02,21600,4800,5400,11400,600,90,51,58,0.1,76,79,9300,610
        """
        val files = mapOf("oura_daily.csv" to bytes(csv))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))

        val p = WearableExportImporter.parseOura(files)
        assertEquals(2, p.days.size)
        val byDay = p.days.associateBy { it.day }

        val d1 = byDay["2026-06-01"]!!
        assertEquals(420.0, d1.totalSleepMin!!, 1e-6)   // 25200s → 420 min
        assertEquals(90.0, d1.deepMin!!, 1e-6)
        assertEquals(100.0, d1.remMin!!, 1e-6)
        assertEquals(92.0, d1.efficiencyPct!!, 1e-6)
        assertEquals(49, d1.restingHr)
        assertEquals(65.0, d1.avgHrvMs!!, 1e-6)
        assertEquals(-0.2, d1.skinTempDevC!!, 1e-6)
        assertEquals(8421, d1.steps)
        assertEquals(520.0, d1.activeKcal!!, 1e-6)
        // Oura's OWN scores stay REFERENCE only.
        assertEquals(81, d1.readinessScore)
        assertEquals(84, d1.sleepScore)

        assertEquals(360.0, byDay["2026-06-02"]!!.totalSleepMin!!, 1e-6)
        assertEquals(51, byDay["2026-06-02"]!!.restingHr)
    }

    @Test
    fun loneHeartRateCsvRoutesToOuraButImportsNothing() {
        // The exact #857 input: a single raw heartrate.csv (timestamped samples, no daily summary).
        val csv = """
            timestamp,heart_rate
            2026-06-01T09:00:00+00:00,62
            2026-06-01T09:01:00+00:00,64
        """
        val files = mapOf("heartrate.csv" to bytes(csv))
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))
        assertTrue(WearableExportImporter.onlyHeartRateCsv(files))
        val p = WearableExportImporter.parseOura(files)
        assertTrue(p.days.isEmpty())
        assertTrue(p.sleeps.isEmpty())
    }

    @Test
    fun ouraRealSchemaSemicolonPerCategoryCsvs() {
        // The REAL Oura account export (issue #862): SEPARATE per-category CSVs, each `;`-delimited, each
        // carrying ONLY its own category's columns. Field names verbatim from the real schema. A `deleted`
        // sleep row, a women's-health file, and an unknown ring-config column are all ignored gracefully.
        val sleepCsv = """
            id;average_breath;average_heart_rate;average_hrv;awake_time;bedtime_end;bedtime_start;day;deep_sleep_duration;efficiency;light_sleep_duration;lowest_heart_rate;rem_sleep_duration;total_sleep_duration;type
            a1;14.2;54;65;900;2026-06-01T06:30:00+00:00;2026-05-31T23:15:00+00:00;2026-06-01;5400;92;13800;48;6000;25200;long_sleep
            a2;0;0;0;0;2026-06-02T01:00:00+00:00;2026-06-02T00:30:00+00:00;2026-06-02;0;0;0;0;0;0;deleted
        """
        val readinessCsv = """
            id;contributors;day;score;temperature_deviation;timestamp
            b1;{};2026-06-01;81;-0.2;2026-06-01T07:00:00+00:00
        """
        val activityCsv = """
            id;active_calories;day;equivalent_walking_distance;score;steps;total_calories
            c1;520;2026-06-01;6200;88;8421;2450
        """
        val spo2Csv = """
            id;breathing_disturbance_index;day;spo2_percentage
            d1;3;2026-06-01;97.4
        """
        val vo2Csv = """
            id;day;timestamp;vo2_max
            e1;2026-06-01;2026-06-01T07:00:00+00:00;44.6
        """
        val glucoseCsv = """
            timestamp;value
            2026-06-01T12:00:00+00:00;5.4
        """
        val ringCsv = """
            id;color;design;firmware_version;hardware_type;set_up_at;size
            f1;titanium;horizon;3.4.3;gen3;2026-01-01T00:00:00+00:00;10
        """
        val files = mapOf(
            "sleep.csv" to bytes(sleepCsv),
            "dailyreadiness.csv" to bytes(readinessCsv),
            "dailyactivity.csv" to bytes(activityCsv),
            "dailyspo2.csv" to bytes(spo2Csv),
            "vo2max.csv" to bytes(vo2Csv),
            "bloodglucose.csv" to bytes(glucoseCsv),
            "ringconfiguration.csv" to bytes(ringCsv),
        )
        assertEquals(WearableExportImporter.Brand.OURA, WearableExportImporter.detectBrand(files))

        val p = WearableExportImporter.parseOura(files)
        // The deleted sleep period is dropped; only the real night survives.
        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(420.0, s.totalSleepMin!!, 1e-6)    // 25200s → 420 min
        assertEquals(90.0, s.deepMin!!, 1e-6)
        assertEquals(100.0, s.remMin!!, 1e-6)
        assertEquals(92.0, s.efficiencyPct!!, 1e-6)
        assertEquals(65.0, s.avgHrvMs!!, 1e-6)
        assertEquals(48, s.lowestHr)

        val d = p.days.first { it.day == "2026-06-01" }
        assertEquals(48, d.restingHr)                    // sleep lowest HR ≈ resting (no RHR column)
        assertEquals(-0.2, d.skinTempDevC!!, 1e-6)       // readiness temperature_deviation
        assertEquals(81, d.readinessScore)               // bare `score` in the readiness CSV
        assertNull(d.sleepScore)                         // no dailysleep CSV here → stays null
        assertEquals(8421, d.steps)                      // activity CSV
        assertEquals(520.0, d.activeKcal!!, 1e-6)
        assertEquals(2450.0, d.totalKcal!!, 1e-6)
        assertEquals(6200.0, d.distanceM!!, 1e-6)        // equivalent_walking_distance (m)
        assertEquals(97.4, d.spo2Pct!!, 1e-6)            // dailyspo2 spo2_percentage
        assertEquals(44.6, d.vo2max!!, 1e-6)             // vo2max vo2_max → Fitness Age
    }

    @Test
    fun ouraNestedSpo2AndVo2FromJson() {
        // JSON variant: SpO2 NESTED as spo2_percentage:{average} (not flat); vo2max under `vo2_max`; a
        // `deleted` sleep skipped (#862).
        val json = """
            {
              "sleep": [
                { "day": "2026-06-05", "type": "deleted", "bedtime_start": "2026-06-04T23:00:00+00:00",
                  "bedtime_end": "2026-06-05T06:00:00+00:00", "total_sleep_duration": 21600 } ],
              "daily_spo2": [ { "day": "2026-06-05", "spo2_percentage": { "average": 96.8 } } ],
              "vo2max":     [ { "day": "2026-06-05", "vo2_max": 41.2 } ],
              "daily_activity": [ { "day": "2026-06-05", "steps": 5000,
                                    "equivalent_walking_distance": 3800 } ]
            }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        assertEquals(0, p.sleeps.size)                   // the only sleep was `deleted`
        val d = p.days.first { it.day == "2026-06-05" }
        assertEquals(96.8, d.spo2Pct!!, 1e-6)            // nested spo2_percentage.average
        assertEquals(41.2, d.vo2max!!, 1e-6)
        assertEquals(3800.0, d.distanceM!!, 1e-6)        // equivalent_walking_distance
        assertEquals(5000, d.steps)
    }

    @Test
    fun semicolonDelimiterDetection() {
        // The CSV reader sniffs the delimiter per file: `;` splits into real columns, `,` stays comma so
        // the WHOOP path is unchanged. A quoted value with the other separator must not flip detection.
        assertEquals(';', CsvTable.detectDelimiter("a;b;c\n1;2;3"))
        assertEquals(',', CsvTable.detectDelimiter("a,b,c\n1,2,3"))
        assertEquals(';', CsvTable.detectDelimiter("\"x,y\";b;c\n1;2;3"))
        val t = CsvTable.fromText("day;score\n2026-06-01;81")
        assertEquals(listOf("day", "score"), t.normalizedHeaders)
        assertEquals("81", t.rows.first()["score"])
    }

    // ---------------- Fitbit ----------------

    @Test
    fun fitbitSleepRestingHrSteps() {
        val sleep = """
            [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
                "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20,
                "efficiency": 94,
                "levels": { "summary": {
                  "deep": { "minutes": 80 }, "light": { "minutes": 220 },
                  "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        val rhr = """
            [ { "dateTime": "2026-06-01T00:00:00.000", "value": { "date": "2026-06-01", "value": 51.5 } } ]
        """
        val steps = """
            [ { "dateTime": "2026-06-01 08:00:00", "value": "1200" },
              { "dateTime": "2026-06-01 09:00:00", "value": "800" } ]
        """
        val files = mapOf(
            "sleep-2026-06-01.json" to bytes(sleep),
            "resting_heart_rate-2026-06-01.json" to bytes(rhr),
            "steps-2026-06-01.json" to bytes(steps),
        )
        assertEquals(WearableExportImporter.Brand.FITBIT, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseFitbit(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(400.0, s.totalSleepMin!!, 1e-6)
        assertEquals(80.0, s.deepMin!!, 1e-6)
        assertEquals(100.0, s.remMin!!, 1e-6)
        assertEquals(94.0, s.efficiencyPct!!, 1e-6)

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(51, d.restingHr)                   // nested value.value, narrowed
        assertEquals(2000, d.steps)                     // intraday steps summed
        assertEquals(400.0, d.totalSleepMin!!, 1e-6)
    }

    // ---------------- Garmin ----------------

    @Test
    fun garminWellnessSleepAndDaily() {
        val startMs = 1_780_272_000_000L            // 2026-06-01 00:00:00 UTC
        val endMs = startMs + 7 * 3600 * 1000
        val sleepData = """
            [ { "calendarDate": "2026-06-01", "sleepStartTimestampGMT": $startMs,
                "sleepEndTimestampGMT": $endMs,
                "deepSleepSeconds": 4800, "lightSleepSeconds": 14400, "remSleepSeconds": 5400,
                "awakeSleepSeconds": 600, "overallSleepScore": 78 } ]
        """
        val daily = """
            [ { "calendarDate": "2026-06-01", "restingHeartRate": 47, "totalSteps": 9100,
                "totalDistanceMeters": 7300.5, "averageStressLevel": 31 } ]
        """
        val files = mapOf(
            "di_connect/di_connect_wellness/2026_sleepdata.json" to bytes(sleepData),
            "di_connect/di_connect_wellness/2026_dailysummary.json" to bytes(daily),
        )
        assertEquals(WearableExportImporter.Brand.GARMIN, WearableExportImporter.detectBrand(files))
        val p = WearableExportImporter.parseGarmin(files)

        assertEquals(1, p.sleeps.size)
        val s = p.sleeps[0]
        assertEquals(80.0, s.deepMin!!, 1e-6)           // 4800s
        assertEquals(240.0, s.lightMin!!, 1e-6)         // 14400s
        assertEquals(90.0, s.remMin!!, 1e-6)            // 5400s
        assertEquals(410.0, s.totalSleepMin!!, 1e-6)
        assertEquals(78, s.sleepScore)                   // reference, never Charge

        assertEquals(1, p.days.size)
        val d = p.days[0]
        assertEquals("2026-06-01", d.day)
        assertEquals(47, d.restingHr)
        assertEquals(9100, d.steps)
        assertEquals(7300.5, d.distanceM!!, 1e-6)
        assertEquals(31, d.avgStress)
    }

    @Test
    fun garminImportedNightRespReachesDailyRow() {
        // #17 parity: Garmin's `averageRespirationValue` on the night must reach the day's resp rollup.
        val startMs = 1_780_272_000_000L            // 2026-06-01 00:00:00 UTC
        val endMs = startMs + 7 * 3600 * 1000
        val sleepData = """
            [ { "calendarDate": "2026-06-01", "sleepStartTimestampGMT": $startMs,
                "sleepEndTimestampGMT": $endMs,
                "deepSleepSeconds": 4800, "lightSleepSeconds": 14400, "remSleepSeconds": 5400,
                "averageRespirationValue": 13.7 } ]
        """
        val p = WearableExportImporter.parseGarmin(
            mapOf("di_connect/di_connect_wellness/2026_sleepdata.json" to bytes(sleepData)),
        )
        val d = p.days.first { it.day == "2026-06-01" }
        assertEquals("the Garmin night's resp must fold onto the day rollup",
            13.7, d.respRateBpm!!, 1e-6)
    }

    // ---------------- Date formatter caching (PR #583) ----------------
    //
    // The Fitbit/dayKey formatters were hoisted to cached fields; these pin that the parse behaviour —
    // and crucially the isDateOnly LocalDate-vs-LocalDateTime split in dayKey — is unchanged.

    @Test
    fun fitbitTimeParsesAllCachedDateTimePatterns() {
        // ISO-with-offset goes through WhoopTime; the three offsetless local patterns go through the
        // cached FITBIT_DT_FMTS list (millis / seconds / minute precision), interpreted at UTC.
        val withMillis = WearableExportImporter.fitbitTime("2026-06-01T23:00:00.000")
        val withSeconds = WearableExportImporter.fitbitTime("2026-06-01 23:00:00")
        val withMinutes = WearableExportImporter.fitbitTime("2026-06-01 23:00")
        assertEquals(withMillis, withSeconds)            // .000 and :00 are the same instant
        assertEquals(withSeconds, withMinutes)           // minute precision lands on the same :00
        assertNull(WearableExportImporter.fitbitTime("not a date"))
        assertNull(WearableExportImporter.fitbitTime(null))
    }

    @Test
    fun dayKeySplitHoldsAcrossMonthDayYearAndIsoDate() {
        // dateTime is the MM/dd/yy HH:mm:ss form (a DAYKEY_DATETIME_FMTS LocalDateTime parse): the RHR
        // row must still fold onto the 2026-06-01 day. A bare yyyy-MM-dd would take the LocalDate branch.
        val rhr = """
            [ { "dateTime": "06/01/26 08:30:00", "value": 53 } ]
        """
        val files = mapOf("resting_heart_rate-2026.json" to bytes(rhr))
        val p = WearableExportImporter.parseFitbit(files)
        val d = p.days.firstOrNull { it.day == "2026-06-01" }
        assertEquals(53, d?.restingHr)                   // MM/dd/yy datetime → correct day, RHR set
    }

    // ---------------- Safety / honesty ----------------

    @Test
    fun junkIsNotMistakenForAWearable() {
        assertNull(WearableExportImporter.detectBrand(mapOf("random.json" to bytes("{\"foo\":1}"))))
    }

    @Test
    fun zeroAndBadValuesProduceNoFabricatedRows() {
        val json = """
            { "sleep": [
                { "day": "2026-06-03", "bedtime_start": "bad", "bedtime_end": "also-bad",
                  "total_sleep_duration": 0, "average_heart_rate": 0 } ],
              "daily_readiness": [
                { "day": "2026-06-03", "score": 0, "contributors": { "resting_heart_rate": 0 } } ] }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        assertEquals(0, p.sleeps.size)                  // unparseable times → dropped
        val d = p.days.firstOrNull { it.day == "2026-06-03" }
        if (d != null) {
            assertNull(d.restingHr)                     // 0 RHR → nil
            assertNull(d.readinessScore)                // 0 score → nil
        }
    }

    @Test
    fun hugeOutOfRangeNumberDoesNotTrapOrStoreGarbage() {
        // org.json's optInt SATURATES a huge value; the finite/range guard must drop it. The valid
        // sibling field still imports.
        val json = """
            { "daily_activity": [ { "day": "2026-06-04", "steps": 1e19, "active_calories": 500 } ] }
        """
        val p = WearableExportImporter.parseOura(mapOf("oura.json" to bytes(json)))
        val d = p.days.first { it.day == "2026-06-04" }
        assertNull(d.steps)                              // 1e19 out of Int range → dropped
        assertEquals(500.0, d.activeKcal!!, 1e-6)
    }

    @Test
    fun nonWellnessFilesAreFilteredOut() {
        assertTrue(WearableExportImporter.isWellnessFile("sleep-2026-06-01.json", bytes("[]")))
        assertTrue(WearableExportImporter.isWellnessFile("2026_sleepdata.json", bytes("[]")))
        assertTrue(!WearableExportImporter.isWellnessFile("device_settings.json", bytes("{}")))
        assertTrue(!WearableExportImporter.isWellnessFile("readme.txt", bytes("hi")))
    }
}
