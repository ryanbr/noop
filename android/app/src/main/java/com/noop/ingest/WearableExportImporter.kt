package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.ZipInputStream

/**
 * Offline file-import of a user's OWN Oura / Fitbit / Garmin data export — fully offline, no cloud
 * API, no login. Kotlin twin of the macOS/iOS source of truth
 *   Packages/StrandImport/Sources/StrandImport/WearableExportImporter.swift
 *   (+ OuraExportParser / FitbitExportParser / GarminExportParser)
 * so the three brands decode the same on every platform.
 *
 *   • Oura   : the Account -> Export Data per-category files (CSV, `;`-delimited; or an older JSON
 *              variant): sleep periods (durations/HRV/RHR/breath; a `deleted` type is skipped), daily
 *              readiness (RHR, temperature deviation, score), daily activity (steps/calories/distance),
 *              daily SpO2 (`spo2_percentage.average`), VO2max (`vo2_max`). Field names verified against a
 *              REAL Oura export schema (issue #862). The many health types NOOP doesn't model
 *              (bloodglucose, contraception, medication, ring config, raw sample streams, ...) are skipped
 *              gracefully, since an unknown category/column is ignored, never an error.
 *   • Fitbit — Google Takeout → Fitbit JSON: per-day sleep-*.json / resting_heart_rate-*.json /
 *              steps-*.json.
 *   • Garmin — Garmin Connect "Export Your Data" (GDPR) ZIP wellness JSON: *_sleepData.json + daily
 *              RHR / steps / stress. (The FIT activity files in the same ZIP are wave-1's lane.)
 *
 * Maps onto NOOP's DAILY metrics + sleep sessions (NOT workouts). HONEST DATA: only fields the export
 * carries are written; a brand's OWN score (Oura "readiness", a sleep score) is stored under a
 * reference metricSeries key only — NEVER as NOOP's Charge/Effort/Rest. Every row is written under the
 * brand's source/deviceId ("oura-import" / "fitbit-import" / "garmin-import").
 *
 * SECURITY: every byte is UNTRUSTED. The read/extract is byte-capped (zip-bomb guard, parity with the
 * other importers); JSON numbers are read as finite Doubles and range-checked before narrowing to Int
 * (org.json's optInt/optLong SATURATE a hostile 1e308, so we never store garbage); per-collection
 * counts are bounded. A malformed file yields a failure summary, never a crash.
 *
 * LICENSE: the file shapes are DOCUMENTED format facts. No GPL/AGPL code is copied — NOOP's own code.
 */
object WearableExportImporter {

    enum class Brand(val sourceId: String, val label: String) {
        OURA("oura-import", "Oura"),
        FITBIT("fitbit-import", "Fitbit"),
        GARMIN("garmin-import", "Garmin"),
    }

    private const val MAX_ENTRY_BYTES = 256L shl 20  // per-entry uncompressed ceiling (zip-bomb guard)
    private const val MAX_FILES = 200_000
    private const val MAX_ROWS = 5_000_000

    // Oura CSV detection (#857). Header keys are already HeaderNorm-normalized.
    private val OURA_CSV_DATE_KEYS = setOf("date", "day", "summary_date", "calendar_date")
    // Columns that mark a CSV as an Oura wellness export. Covers BOTH a combined daily-summary CSV and
    // Oura's REAL per-category CSVs, each carrying only its own category's columns (#862): readiness →
    // `temperature_deviation`, activity → `steps`/`active_calories`, vo2max → `vo2_max`, spo2 →
    // `spo2_percentage`, sleep period → `total_sleep_duration`.
    private val OURA_CSV_SIGNAL_COLUMNS = setOf(
        "total_sleep_duration", "rem_sleep_duration", "deep_sleep_duration", "light_sleep_duration",
        "sleep_efficiency", "efficiency", "average_hrv", "average_breath",
        "average_resting_heart_rate", "lowest_resting_heart_rate", "lowest_heart_rate",
        "readiness_score", "sleep_score", "respiratory_rate", "temperature_deviation",
        "active_calories", "total_calories", "equivalent_walking_distance",
        "vo2_max", "spo2_percentage", "breathing_disturbance_index", "contributors",
    )
    // Filename fragments that mark an Oura per-category CSV export (lowercased, substring match).
    private val OURA_CSV_FILENAMES = listOf("heartrate", "heart_rate", "readiness", "sleep_periods")

    private val DAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    // Cached date/time formatters — DateTimeFormatter is immutable + thread-safe, so hoisting them out
    // of the per-row parse loops (fitbitTime / dayKey) avoids re-compiling the same pattern on every
    // row of a multi-thousand-entry export. Behaviour-preserving; the order matches the old inline lists.
    private val FITBIT_DT_FMTS: List<DateTimeFormatter> = listOf(
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS"),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"),
    )
    // dayKey patterns — the isDateOnly split is preserved exactly: "yyyy-MM-dd" parses as a bare
    // LocalDate, the date-time patterns parse as LocalDateTime then take .toLocalDate().
    private val DAYKEY_DATETIME_FMTS: List<DateTimeFormatter> = listOf(
        DateTimeFormatter.ofPattern("MM/dd/yy HH:mm:ss"),
        DateTimeFormatter.ofPattern("MM/dd/yy"),
    )
    private val DAYKEY_DATE_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    // ------------------------------------------------------------------------
    // Public entry point (UI calls this)
    // ------------------------------------------------------------------------

    suspend fun importExport(context: Context, uri: Uri, repo: WhoopRepository): ImportSummary {
        val files = try {
            collectFiles(context, uri)
        } catch (e: Exception) {
            return ImportSummary.failure("Wearable export", "Couldn't read the export: ${e.message ?: "unknown error"}")
        }
        if (files.isEmpty()) return ImportSummary.failure("Wearable export", "No readable JSON/CSV in the export.")

        val brand = detectBrand(files)
            ?: return ImportSummary.failure("Wearable export", "Not an Oura, Fitbit or Garmin data export.")

        val parsed = when (brand) {
            Brand.OURA -> parseOura(files)
            Brand.FITBIT -> parseFitbit(files)
            Brand.GARMIN -> parseGarmin(files)
        }
        if (parsed.days.isEmpty() && parsed.sleeps.isEmpty()) {
            // A lone Oura `heartrate.csv` is a raw HR-sample file, not a daily summary, so it carries no
            // recovery/sleep/HRV to map. Say so plainly and point at the right file (#857).
            if (brand == Brand.OURA && onlyHeartRateCsv(files)) {
                return ImportSummary.failure(
                    brand.label,
                    "That file is Oura's raw heart-rate log, which has no daily sleep or recovery values to " +
                        "import. Export your Oura data as JSON (Account -> Export Data), or pick the daily/" +
                        "readiness CSV, and import that instead.",
                )
            }
            return ImportSummary.failure(brand.label, "${brand.label} export held no sleep or daily wellness data.")
        }
        return persist(repo, brand, parsed)
    }

    /** True when every collected file is a raw heart-rate CSV (no daily-summary file): the #857 case. */
    internal fun onlyHeartRateCsv(files: Map<String, ByteArray>): Boolean {
        if (files.isEmpty()) return false
        return files.keys.all { name ->
            name.endsWith(".csv") && (name.contains("heartrate") || name.contains("heart_rate"))
        }
    }

    // ------------------------------------------------------------------------
    // Intermediate accumulators (mirror the Swift WearableDailyRow / WearableSleepSession)
    // ------------------------------------------------------------------------

    internal class DayAcc(val day: String) {
        var steps: Int? = null; var distanceM: Double? = null; var activeKcal: Double? = null; var totalKcal: Double? = null
        var restingHr: Int? = null; var avgHrvMs: Double? = null; var respRateBpm: Double? = null; var skinTempDevC: Double? = null
        var spo2Pct: Double? = null; var avgStress: Int? = null; var vo2max: Double? = null
        var totalSleepMin: Double? = null; var deepMin: Double? = null; var lightMin: Double? = null
        var remMin: Double? = null; var awakeMin: Double? = null; var efficiencyPct: Double? = null
        var readinessScore: Int? = null; var sleepScore: Int? = null
    }

    internal class SleepAcc(
        val startTs: Long, val endTs: Long,
        val deepMin: Double?, val lightMin: Double?, val remMin: Double?, val awakeMin: Double?,
        val totalSleepMin: Double?, val efficiencyPct: Double?,
        val avgHr: Int?, val lowestHr: Int?, val avgHrvMs: Double?, val respRateBpm: Double?,
        val sleepScore: Int?, val stagesJson: String?,
    )

    internal class Parsed(val days: List<DayAcc>, val sleeps: List<SleepAcc>)

    // ------------------------------------------------------------------------
    // Brand detection (by content)
    // ------------------------------------------------------------------------

    internal fun detectBrand(files: Map<String, ByteArray>): Brand? {
        val names = files.keys
        if (names.any { it.contains("sleepdata") || it.contains("di_connect") || it.contains("userbiometric") || it.contains("_summarizedactivities") }) return Brand.GARMIN
        if (names.any { last(it).startsWith("sleep-") || last(it).startsWith("resting_heart_rate-") || last(it).startsWith("steps-") || it.contains("fitbit") }) return Brand.FITBIT
        if (names.any { it.contains("oura") }) return Brand.OURA
        // Oura CSV export (#857): the per-category files (`heartrate.csv` / `readiness.csv` / ...). Routing
        // these to Oura (rather than failing detection) lets the importer give an HONEST per-file outcome:
        // a daily-summary CSV imports, a lone raw heart-rate CSV reports "no daily wellness data".
        if (names.any { name -> OURA_CSV_FILENAMES.any { name.contains(it) } }) return Brand.OURA

        for ((name, data) in files.entries.take(8)) {
            brandFromJsonShape(data)?.let { return it }
            if (name.endsWith(".csv") && looksLikeOuraCsv(CsvTable.fromData(data).normalizedHeaders)) return Brand.OURA
        }
        return null
    }

    private fun brandFromJsonShape(data: ByteArray): Brand? {
        val text = String(Bom.stripUtf8(data), Charsets.UTF_8)
        val obj = runCatching { JSONObject(text) }.getOrNull()
        if (obj != null) {
            val keys = HashSet<String>()
            val it = obj.keys()
            while (it.hasNext()) keys.add(it.next().toString().lowercase())
            if (keys.intersect(setOf("sleep", "daily_readiness", "daily_activity", "readiness", "activity")).isNotEmpty() && looksLikeOura(obj)) return Brand.OURA
            if (obj.has("calendarDate") && (obj.has("deepSleepSeconds") || obj.has("restingHeartRate"))) return Brand.GARMIN
        }
        val arr = runCatching { JSONArray(text) }.getOrNull()
        val first = arr?.optJSONObject(0)
        if (first != null) {
            if (first.has("dateOfSleep") || (first.has("dateTime") && first.has("value"))) return Brand.FITBIT
            if (first.has("sleepStartTimestampGMT") || first.has("deepSleepSeconds")) return Brand.GARMIN
        }
        return null
    }

    private fun looksLikeOura(obj: JSONObject): Boolean {
        for (key in listOf("sleep", "daily_readiness", "daily_activity", "daily_sleep", "readiness", "activity")) {
            val arr = categoryArray(obj, key) ?: continue
            val first = arr.optJSONObject(0) ?: continue
            if (first.has("bedtime_start") || first.has("total_sleep_duration") || first.has("contributors") ||
                first.has("temperature_deviation") || (first.has("day") && (first.has("score") || first.has("steps")))
            ) return true
        }
        return false
    }

    // ------------------------------------------------------------------------
    // Oura
    // ------------------------------------------------------------------------

    internal fun parseOura(files: Map<String, ByteArray>): Parsed {
        val byDay = LinkedHashMap<String, DayAcc>()
        val sleeps = ArrayList<SleepAcc>()
        fun day(key: String) = byDay.getOrPut(key) { DayAcc(key) }

        for (data in files.values) {
            val root = parseObject(data) ?: continue

            categoryArray(root, "sleep")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val s = arr.optJSONObject(i) ?: continue
                    val session = ouraSleep(s) ?: continue
                    if (sleeps.size >= MAX_ROWS) break
                    sleeps.add(session)
                    val key = s.strOpt("day") ?: dayString(session.endTs)
                    val d = day(key)
                    d.totalSleepMin = d.totalSleepMin ?: session.totalSleepMin
                    d.deepMin = d.deepMin ?: session.deepMin
                    d.lightMin = d.lightMin ?: session.lightMin
                    d.remMin = d.remMin ?: session.remMin
                    d.awakeMin = d.awakeMin ?: session.awakeMin
                    d.efficiencyPct = d.efficiencyPct ?: session.efficiencyPct
                    d.avgHrvMs = d.avgHrvMs ?: session.avgHrvMs
                    d.respRateBpm = d.respRateBpm ?: session.respRateBpm   // night resp → day rollup (#17)
                    if (d.restingHr == null) d.restingHr = session.lowestHr
                }
            }
            (categoryArray(root, "daily_readiness") ?: categoryArray(root, "readiness"))?.let { arr ->
                for (i in 0 until arr.length()) {
                    val r = arr.optJSONObject(i) ?: continue
                    val key = r.strOpt("day") ?: continue
                    val d = day(key)
                    r.optJSONObject("contributors")?.let { d.restingHr = it.posInt("resting_heart_rate") ?: d.restingHr }
                    d.restingHr = r.posInt("resting_heart_rate") ?: d.restingHr
                    d.skinTempDevC = r.dblOpt("temperature_deviation") ?: d.skinTempDevC
                    d.readinessScore = r.posInt("score") ?: d.readinessScore
                }
            }
            categoryArray(root, "daily_sleep")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val s = arr.optJSONObject(i) ?: continue
                    val key = s.strOpt("day") ?: continue
                    day(key).sleepScore = s.posInt("score") ?: day(key).sleepScore
                }
            }
            (categoryArray(root, "daily_activity") ?: categoryArray(root, "activity"))?.let { arr ->
                for (i in 0 until arr.length()) {
                    val a = arr.optJSONObject(i) ?: continue
                    val key = a.strOpt("day") ?: continue
                    val d = day(key)
                    d.steps = a.posInt("steps") ?: d.steps
                    d.activeKcal = a.posDbl("active_calories") ?: d.activeKcal
                    d.totalKcal = a.posDbl("total_calories") ?: d.totalKcal
                    // Oura reports walking-equivalent distance in METRES (no GPS path-distance).
                    d.distanceM = a.posDbl("equivalent_walking_distance") ?: d.distanceM
                }
            }
            // Daily SpO2: the value is NESTED, spo2_percentage = { "average": float }, not a flat number,
            // so reading it flat (the old assumption) would always miss it (#862).
            (categoryArray(root, "daily_spo2") ?: categoryArray(root, "spo2"))?.let { arr ->
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val key = o.strOpt("day") ?: continue
                    val d = day(key)
                    val nested = o.optJSONObject("spo2_percentage")?.posDbl("average")
                    val flat = o.posDbl("spo2_percentage") ?: o.posDbl("average")
                    (nested ?: flat)?.let { d.spo2Pct = d.spo2Pct ?: it }
                }
            }
            // VO2max → mL/kg/min (Oura key `vo2_max`). Feeds Fitness Age, same as Apple Health VO2max.
            (categoryArray(root, "vo2max") ?: categoryArray(root, "vo2_max"))?.let { arr ->
                for (i in 0 until arr.length()) {
                    val v = arr.optJSONObject(i) ?: continue
                    val key = v.strOpt("day") ?: continue
                    day(key).let { it.vo2max = it.vo2max ?: (v.posDbl("vo2_max") ?: v.posDbl("vo2max")) }
                }
            }
        }

        // Fold Oura CSV daily-summary rows in too. An export can be JSON, CSV, or a mix; JSON is richer so
        // it WINS field-by-field, CSV only fills a day's gaps (#857). A lone raw `heartrate.csv` folds to
        // nothing here, so the day stays honestly empty and the caller reports it plainly.
        parseOuraCsv(files, byDay, sleeps)

        return Parsed(byDay.values.sortedBy { it.day }, sleeps.sortedBy { it.startTs })
    }

    /**
     * Parse Oura's per-day SUMMARY CSV (the "Export Data" trends CSV) into the same day/sleep accumulators
     * the JSON path fills. Columns are matched after HeaderNorm normalization (so "Average HRV" ->
     * "average_hrv"); sleep durations are SECONDS (like Oura's JSON) -> minutes. Existing (JSON) values are
     * never overwritten; CSV only fills nulls. (#857)
     */
    internal fun parseOuraCsv(
        files: Map<String, ByteArray>,
        byDay: LinkedHashMap<String, DayAcc>,
        sleeps: ArrayList<SleepAcc>,
    ) {
        for ((name, data) in files) {
            if (!name.endsWith(".csv")) continue
            val table = CsvTable.fromData(data)
            if (!looksLikeOuraCsv(table.normalizedHeaders)) continue
            for (cells in table.rows) {
                val rawDay = cells.cell("date", "day", "summary_date", "calendar_date") ?: continue
                val key = normalizeDayKey(rawDay)
                // A `deleted` sleep-period row (Oura's `type` enum) is a night the user removed, so skip it
                // entirely so it neither folds onto the day nor becomes a session (#862).
                if (cells.cell("type")?.lowercase() == "deleted") continue
                val d = byDay.getOrPut(key) { DayAcc(key) }

                fun minutes(vararg keys: String): Double? {
                    val v = cells.double(*keys) ?: return null
                    return if (v > 0) v / 60.0 else null
                }
                val total = minutes("total_sleep_duration", "total_sleep")
                val deep = minutes("deep_sleep_duration", "deep_sleep")
                val light = minutes("light_sleep_duration", "light_sleep")
                val rem = minutes("rem_sleep_duration", "rem_sleep")
                val awake = minutes("awake_time", "awake_duration", "time_awake")

                d.totalSleepMin = d.totalSleepMin ?: total
                d.deepMin = d.deepMin ?: deep
                d.lightMin = d.lightMin ?: light
                d.remMin = d.remMin ?: rem
                d.awakeMin = d.awakeMin ?: awake
                d.efficiencyPct = d.efficiencyPct ?: cells.double("sleep_efficiency", "efficiency")?.takeIf { it > 0 }

                val rhr = cells.double("average_resting_heart_rate", "resting_heart_rate")
                    ?: cells.double("lowest_resting_heart_rate", "lowest_heart_rate")
                if (rhr != null && rhr > 0 && d.restingHr == null) d.restingHr = rhr.toInt()
                cells.double("average_hrv", "hrv")?.takeIf { it > 0 }?.let { d.avgHrvMs = d.avgHrvMs ?: it }
                // Oura's CSV resp column (`respiratory_rate` / `average_breath`) → the day rollup (#17).
                val resp = cells.double("respiratory_rate", "average_breath")?.takeIf { it > 0 }
                resp?.let { d.respRateBpm = d.respRateBpm ?: it }
                cells.double("temperature_deviation", "skin_temperature_deviation")?.let { d.skinTempDevC = d.skinTempDevC ?: it }
                // SpO2: the real `dailyspo2` CSV column is `spo2_percentage` (the average %); keep the older
                // flat aliases too for a combined-summary CSV (#862).
                cells.double("spo2_percentage", "spo2", "blood_oxygen", "average_spo2")?.takeIf { it > 0 }?.let { d.spo2Pct = d.spo2Pct ?: it }
                // VO2max: the real `vo2max` CSV column is `vo2_max` (mL/kg/min) → feeds Fitness Age.
                cells.double("vo2_max", "vo2max")?.takeIf { it > 0 }?.let { d.vo2max = d.vo2max ?: it }
                cells.double("steps")?.takeIf { it >= 0 }?.let { d.steps = d.steps ?: it.toInt() }
                cells.double("active_calories", "activity_burn", "active_burn")?.takeIf { it > 0 }?.let { d.activeKcal = d.activeKcal ?: it }
                cells.double("total_calories", "total_burn")?.takeIf { it > 0 }?.let { d.totalKcal = d.totalKcal ?: it }
                // Oura's walking-equivalent distance (metres); no GPS path distance in the export.
                cells.double("equivalent_walking_distance", "distance_m")?.takeIf { it > 0 }?.let { d.distanceM = d.distanceM ?: it }
                // Oura's OWN scores -> REFERENCE only. The combined-summary CSV labels them `readiness_score`
                // / `sleep_score`; the REAL per-category CSVs use a bare `score`. Both `dailyreadiness` and
                // `dailysleep` carry a `contributors` column, so that alone can't tell them apart; only
                // `dailyreadiness` carries `temperature_deviation`. So: temperature_deviation present ->
                // readiness; else contributors present with no sleep durations / steps -> sleep score; an
                // activity-score row (bare `score` with `steps`) is left out rather than mislabelled (#862).
                cells.double("readiness_score", "readiness")?.takeIf { it > 0 }?.let { d.readinessScore = d.readinessScore ?: it.toInt() }
                cells.double("sleep_score")?.takeIf { it > 0 }?.let { d.sleepScore = d.sleepScore ?: it.toInt() }
                cells.double("score")?.takeIf { it > 0 }?.let { bare ->
                    val isReadiness = cells.cell("temperature_deviation") != null
                    val isSleepScore = !isReadiness && total == null &&
                        cells.cell("steps") == null && cells.cell("contributors") != null
                    when {
                        isReadiness -> d.readinessScore = d.readinessScore ?: bare.toInt()
                        isSleepScore -> d.sleepScore = d.sleepScore ?: bare.toInt()
                    }
                }

                // A bedtime window (when the CSV carries one) lands the night on the Sleep tab too.
                val start = WhoopTime.parseIsoWithOffsetEpochSeconds(cells.cell("bedtime_start", "sleep_start"))
                val end = WhoopTime.parseIsoWithOffsetEpochSeconds(cells.cell("bedtime_end", "sleep_end"))
                if (start != null && end != null && end > start && sleeps.size < MAX_ROWS) {
                    sleeps.add(
                        SleepAcc(
                            startTs = start, endTs = end,
                            deepMin = deep, lightMin = light, remMin = rem, awakeMin = awake,
                            totalSleepMin = total, efficiencyPct = d.efficiencyPct,
                            avgHr = null,
                            lowestHr = rhr?.takeIf { it > 0 }?.toInt(),
                            avgHrvMs = d.avgHrvMs, respRateBpm = resp,
                            sleepScore = null, stagesJson = null,
                        ),
                    )
                }
            }
        }
    }

    /** True if a CSV's normalized header set looks like an Oura per-day summary (date + a wellness col). */
    internal fun looksLikeOuraCsv(normalizedHeaders: List<String>): Boolean {
        val set = normalizedHeaders.toHashSet()
        if (set.none { it in OURA_CSV_DATE_KEYS }) return false
        return set.any { it in OURA_CSV_SIGNAL_COLUMNS }
    }

    /** Reduce an Oura CSV date/datetime cell to the `YYYY-MM-DD` day key (drops any time component). */
    private fun normalizeDayKey(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.length >= 10) {
            val head = trimmed.substring(0, 10)
            if (head.length == 10 && head[4] == '-') return head
        }
        return trimmed
    }

    private fun ouraSleep(s: JSONObject): SleepAcc? {
        // Skip a `deleted` period (Oura's `type` enum marks user-deleted sleeps); folding it would count a
        // night the user removed. Any other type (`long_sleep`/`short_sleep`/missing) is kept (#862).
        if (s.strOpt("type")?.lowercase() == "deleted") return null
        val start = WhoopTime.parseEpochSeconds(s.strOpt("bedtime_start"), 0) ?: return null
        val end = WhoopTime.parseEpochSeconds(s.strOpt("bedtime_end"), 0) ?: return null
        if (end <= start) return null
        fun min(k: String): Double? = s.posDbl(k)?.let { it / 60.0 }
        return SleepAcc(
            startTs = start, endTs = end,
            deepMin = min("deep_sleep_duration"), lightMin = min("light_sleep_duration"),
            remMin = min("rem_sleep_duration"), awakeMin = min("awake_time"),
            totalSleepMin = min("total_sleep_duration"), efficiencyPct = s.posDbl("efficiency"),
            avgHr = s.posInt("average_heart_rate"), lowestHr = s.posInt("lowest_heart_rate"),
            avgHrvMs = s.posDbl("average_hrv"), respRateBpm = s.posDbl("average_breath"),
            sleepScore = null, stagesJson = null,
        )
    }

    private fun categoryArray(root: JSONObject, key: String): JSONArray? {
        root.optJSONArray(key)?.let { return it }
        return root.optJSONObject(key)?.optJSONArray("data")
    }

    // ------------------------------------------------------------------------
    // Fitbit
    // ------------------------------------------------------------------------

    internal fun parseFitbit(files: Map<String, ByteArray>): Parsed {
        val byDay = LinkedHashMap<String, DayAcc>()
        val sleeps = ArrayList<SleepAcc>()
        fun day(key: String) = byDay.getOrPut(key) { DayAcc(key) }

        for ((name, data) in files) {
            val base = last(name)
            when {
                base.startsWith("sleep") || base.contains("sleep") -> {
                    val arr = parseArray(data) ?: continue
                    for (i in 0 until arr.length()) {
                        val log = arr.optJSONObject(i) ?: continue
                        val session = fitbitSleep(log) ?: continue
                        if (sleeps.size >= MAX_ROWS) break
                        sleeps.add(session)
                        val key = log.strOpt("dateOfSleep") ?: dayString(session.endTs)
                        val d = day(key)
                        d.totalSleepMin = d.totalSleepMin ?: session.totalSleepMin
                        d.deepMin = d.deepMin ?: session.deepMin
                        d.lightMin = d.lightMin ?: session.lightMin
                        d.remMin = d.remMin ?: session.remMin
                        d.awakeMin = d.awakeMin ?: session.awakeMin
                        d.efficiencyPct = d.efficiencyPct ?: session.efficiencyPct
                    }
                }
                base.startsWith("resting_heart_rate") || base.contains("resting_heart_rate") -> {
                    val arr = parseArray(data) ?: continue
                    for (i in 0 until arr.length()) {
                        val e = arr.optJSONObject(i) ?: continue
                        val key = dayKey(e.strOpt("dateTime")) ?: continue
                        val rhr = e.optJSONObject("value")?.posInt("value") ?: e.posInt("value") ?: continue
                        day(key).restingHr = rhr
                    }
                }
                base.startsWith("steps") || base.contains("steps") -> {
                    val arr = parseArray(data) ?: continue
                    val totals = HashMap<String, Long>()
                    for (i in 0 until arr.length()) {
                        val e = arr.optJSONObject(i) ?: continue
                        val key = dayKey(e.strOpt("dateTime")) ?: continue
                        val v = e.longOpt("value") ?: continue
                        if (v >= 0) totals[key] = (totals[key] ?: 0L) + v
                    }
                    for ((key, total) in totals) if (total > 0) {
                        val d = day(key); d.steps = (d.steps ?: 0) + total.toInt()
                    }
                }
            }
        }
        return Parsed(byDay.values.sortedBy { it.day }, sleeps.sortedBy { it.startTs })
    }

    private fun fitbitSleep(log: JSONObject): SleepAcc? {
        val start = fitbitTime(log.strOpt("startTime")) ?: return null
        val end = fitbitTime(log.strOpt("endTime")) ?: return null
        if (end <= start) return null

        var deep: Double? = null; var light: Double? = null; var rem: Double? = null; var wake: Double? = null
        val stages = JSONArray()
        log.optJSONObject("levels")?.let { levels ->
            levels.optJSONObject("summary")?.let { sum ->
                deep = sum.optJSONObject("deep")?.posDbl("minutes")
                light = sum.optJSONObject("light")?.posDbl("minutes")
                rem = sum.optJSONObject("rem")?.posDbl("minutes")
                wake = sum.optJSONObject("wake")?.posDbl("minutes")
            }
            levels.optJSONArray("data")?.let { segs ->
                for (i in 0 until minOf(segs.length(), 100_000)) {
                    val seg = segs.optJSONObject(i) ?: continue
                    val s = fitbitTime(seg.strOpt("dateTime")) ?: continue
                    val secs = seg.posDbl("seconds") ?: continue
                    val lvl = seg.strOpt("level") ?: continue
                    val e = s + secs.toLong()
                    if (e > s) stages.put(JSONObject().put("start", s).put("end", e).put("stage", fitbitStage(lvl)))
                }
            }
        }
        val asleep = log.posDbl("minutesAsleep")
        val awakeMin = wake ?: log.posDbl("minutesAwake")
        return SleepAcc(
            startTs = start, endTs = end,
            deepMin = deep, lightMin = light, remMin = rem, awakeMin = awakeMin,
            totalSleepMin = asleep, efficiencyPct = log.posDbl("efficiency"),
            avgHr = null, lowestHr = null, avgHrvMs = null, respRateBpm = null, sleepScore = null,
            stagesJson = if (stages.length() > 0) stages.toString() else null,
        )
    }

    private fun fitbitStage(raw: String): String = when (raw.lowercase()) {
        "deep" -> "deep"; "rem" -> "rem"; "light", "asleep" -> "light"; else -> "wake"
    }

    // ------------------------------------------------------------------------
    // Garmin
    // ------------------------------------------------------------------------

    internal fun parseGarmin(files: Map<String, ByteArray>): Parsed {
        val byDay = LinkedHashMap<String, DayAcc>()
        val sleeps = ArrayList<SleepAcc>()
        fun day(key: String) = byDay.getOrPut(key) { DayAcc(key) }

        for ((name, data) in files) {
            val base = last(name)
            val records = garminRecords(data)
            val isSleep = base.contains("sleepdata") ||
                records.any { it.has("deepSleepSeconds") || it.has("sleepStartTimestampGMT") || it.has("DeepSleepDurationInSeconds") }

            if (isSleep) {
                for (s in records) {
                    val session = garminSleep(s) ?: continue
                    val key = s.strOpt("calendarDate") ?: dayString(session.endTs)
                    if (sleeps.size >= MAX_ROWS) break
                    sleeps.add(session)
                    val d = day(key)
                    d.totalSleepMin = d.totalSleepMin ?: session.totalSleepMin
                    d.deepMin = d.deepMin ?: session.deepMin
                    d.lightMin = d.lightMin ?: session.lightMin
                    d.remMin = d.remMin ?: session.remMin
                    d.awakeMin = d.awakeMin ?: session.awakeMin
                    d.sleepScore = d.sleepScore ?: session.sleepScore
                    d.respRateBpm = d.respRateBpm ?: session.respRateBpm   // night resp → day rollup (#17)
                    if (d.restingHr == null) d.restingHr = session.lowestHr
                }
            } else {
                for (rec in records) {
                    val key = rec.strOpt("calendarDate") ?: rec.strOpt("calendar_date") ?: continue
                    val d = day(key)
                    d.restingHr = rec.posInt("restingHeartRate") ?: rec.posInt("restingHeartRateInBeatsPerMinute") ?: d.restingHr
                    d.steps = rec.posInt("totalSteps") ?: rec.posInt("steps") ?: d.steps
                    d.distanceM = rec.posDbl("totalDistanceMeters") ?: rec.posDbl("totalDistanceInMeters") ?: d.distanceM
                    d.activeKcal = rec.posDbl("activeKilocalories") ?: rec.posDbl("activeCalories") ?: d.activeKcal
                    d.avgStress = rec.posInt("averageStressLevel") ?: rec.posInt("avgStressLevel") ?: d.avgStress
                }
            }
        }
        return Parsed(byDay.values.sortedBy { it.day }, sleeps.sortedBy { it.startTs })
    }

    private fun garminRecords(data: ByteArray): List<JSONObject> {
        parseArray(data)?.let { arr ->
            return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        }
        val obj = parseObject(data) ?: return emptyList()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val v = obj.optJSONArray(keys.next())
            if (v != null) return (0 until v.length()).mapNotNull { v.optJSONObject(it) }
        }
        return listOf(obj)
    }

    private fun garminSleep(s: JSONObject): SleepAcc? {
        val start = garminInstant(s, "sleepStartTimestampGMT", "StartTimeInSeconds") ?: return null
        val end = garminInstant(s, "sleepEndTimestampGMT", "EndTimeInSeconds") ?: return null
        if (end <= start) return null
        fun sec(a: String, b: String): Double? = (s.posDbl(a) ?: s.posDbl(b))?.let { it / 60.0 }
        val deep = sec("deepSleepSeconds", "DeepSleepDurationInSeconds")
        val light = sec("lightSleepSeconds", "LightSleepDurationInSeconds")
        val rem = sec("remSleepSeconds", "RemSleepInSeconds")
        val awake = sec("awakeSleepSeconds", "AwakeDurationInSeconds")
        val total = listOfNotNull(deep, light, rem).sum()
        val score = s.posInt("overallSleepScore")
            ?: s.optJSONObject("sleepScores")?.optJSONObject("overall")?.posInt("value")
        return SleepAcc(
            startTs = start, endTs = end,
            deepMin = deep, lightMin = light, remMin = rem, awakeMin = awake,
            totalSleepMin = if (total > 0) total else null, efficiencyPct = null,
            avgHr = null, lowestHr = s.posInt("restingHeartRate"),
            avgHrvMs = s.posDbl("avgOvernightHrv") ?: s.posDbl("averageHrvValue"),
            respRateBpm = s.posDbl("averageRespirationValue") ?: s.posDbl("averageRespiration"),
            sleepScore = score, stagesJson = null,
        )
    }

    /** A Garmin timestamp may be epoch MILLIS (number), epoch SECONDS, or an ISO string. */
    private fun garminInstant(v: JSONObject, msKey: String, secKey: String): Long? {
        v.dblOpt(msKey)?.let { return if (it >= 1e11) (it / 1000.0).toLong() else it.toLong() }
        v.strOpt(msKey)?.let { WhoopTime.parseEpochSeconds(it, 0)?.let { s -> return s } }
        v.dblOpt(secKey)?.let { return it.toLong() }
        return null
    }

    // ------------------------------------------------------------------------
    // Persist
    // ------------------------------------------------------------------------

    private suspend fun persist(repo: WhoopRepository, brand: Brand, parsed: Parsed): ImportSummary {
        val deviceId = brand.sourceId
        repo.upsertDevice(deviceId, name = "${brand.label} import")

        val dailyMetrics = parsed.days.map { d ->
            DailyMetric(
                deviceId = deviceId, day = d.day,
                totalSleepMin = d.totalSleepMin,
                efficiency = d.efficiencyPct ?: sleepEfficiency(d.totalSleepMin, d.awakeMin),
                deepMin = d.deepMin, remMin = d.remMin, lightMin = d.lightMin,
                restingHr = d.restingHr, avgHrv = d.avgHrvMs,
                respRateBpm = d.respRateBpm,   // imported night resp now reaches the day rollup (#17)
                recovery = null,          // NEVER the brand's readiness score
                strain = null,
                spo2Pct = d.spo2Pct, skinTempDevC = d.skinTempDevC,
                steps = d.steps, activeKcalEst = d.activeKcal,
            )
        }
        if (dailyMetrics.isNotEmpty()) repo.upsertDailyMetrics(dailyMetrics)

        val sleepRows = parsed.sleeps.map { s ->
            SleepSession(
                deviceId = deviceId, startTs = s.startTs, endTs = s.endTs,
                efficiency = s.efficiencyPct ?: efficiencyFromStages(s.stagesJson, s.startTs, s.endTs),
                restingHr = s.lowestHr ?: s.avgHr, avgHrv = s.avgHrvMs, stagesJSON = s.stagesJson,
            )
        }
        if (sleepRows.isNotEmpty()) repo.upsertSleepSessions(sleepRows)

        val series = ArrayList<MetricSeriesRow>()
        fun add(day: String, key: String, v: Double?) { if (v != null) series.add(MetricSeriesRow(deviceId, day, key, v)) }
        for (d in parsed.days) {
            add(d.day, "steps", d.steps?.toDouble()); add(d.day, "distance_m", d.distanceM)
            add(d.day, "energy_kcal", d.activeKcal); add(d.day, "total_kcal", d.totalKcal)
            add(d.day, "rhr", d.restingHr?.toDouble()); add(d.day, "hrv", d.avgHrvMs)
            add(d.day, "skin_temp_dev_c", d.skinTempDevC); add(d.day, "spo2", d.spo2Pct)
            add(d.day, "vo2max", d.vo2max)
            add(d.day, "stress", d.avgStress?.toDouble())
            add(d.day, "sleep_total_min", d.totalSleepMin); add(d.day, "sleep_deep_min", d.deepMin)
            add(d.day, "sleep_light_min", d.lightMin); add(d.day, "sleep_rem_min", d.remMin)
            // Reference-only: the brand's own scores, never a NOOP Charge/Effort/Rest input.
            add(d.day, "ref_readiness_score", d.readinessScore?.toDouble())
            add(d.day, "ref_sleep_score", d.sleepScore?.toDouble())
        }
        if (series.isNotEmpty()) repo.upsertMetricSeries(series)

        val first = parsed.days.firstOrNull()?.day
        val last = parsed.days.lastOrNull()?.day
        val span = if (first != null && last != null && first != last) " · $first – $last" else ""
        return ImportSummary(
            source = brand.label,
            counts = mapOf("dailyMetric" to dailyMetrics.size, "sleepSession" to sleepRows.size, "metricSeries" to series.size),
            firstDay = first, lastDay = last,
            message = "Imported ${parsed.days.size} days, ${sleepRows.size} sleeps from ${brand.label}$span",
        )
    }

    private fun sleepEfficiency(total: Double?, awake: Double?): Double? {
        if (total == null || total <= 0) return null
        val inBed = total + (awake ?: 0.0)
        return if (inBed > 0) minOf(100.0, total / inBed * 100.0) else null
    }

    private fun efficiencyFromStages(stagesJson: String?, start: Long, end: Long): Double? {
        if (stagesJson == null || end <= start) return null
        val arr = runCatching { JSONArray(stagesJson) }.getOrNull() ?: return null
        var asleep = 0L
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optString("stage") == "wake") continue
            asleep += (o.optLong("end") - o.optLong("start")).coerceAtLeast(0)
        }
        return minOf(100.0, asleep.toDouble() / (end - start) * 100.0)
    }

    // ------------------------------------------------------------------------
    // File collection (single file / zip)
    // ------------------------------------------------------------------------

    /** Read the picked content. A `.zip` is extracted (zip-bomb-guarded); anything else is one entry. */
    private fun collectFiles(context: Context, uri: Uri): Map<String, ByteArray> {
        val head = ByteArray(4)
        context.contentResolver.openInputStream(uri)?.use { it.read(head) }
            ?: throw IllegalStateException("Couldn't open the selected file.")
        val isZip = head.size >= 2 && head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte()

        if (!isZip) {
            val bytes = context.contentResolver.openInputStream(uri)?.use { readCapped(it, MAX_ENTRY_BYTES) }
                ?: throw IllegalStateException("Couldn't open the selected file.")
            val name = displayName(context, uri)?.lowercase() ?: "export.json"
            return if (isWellnessFile(name, bytes)) mapOf(name to bytes) else emptyMap()
        }

        val out = LinkedHashMap<String, ByteArray>()
        context.contentResolver.openInputStream(uri)?.use { raw ->
            ZipInputStream(raw).use { zin ->
                var entry = zin.nextEntry
                while (entry != null && out.size < MAX_FILES) {
                    val path = entry.name.lowercase()
                    val base = last(path)
                    if (!entry.isDirectory && (base.endsWith(".json") || base.endsWith(".csv"))) {
                        val bytes = runCatching { readCapped(zin, MAX_ENTRY_BYTES) }.getOrNull()
                        if (bytes != null && bytes.isNotEmpty() && isWellnessFile(base, bytes)) out[path] = bytes
                    }
                    entry = zin.nextEntry
                }
            }
        }
        return out
    }

    /** True if the file is a wellness JSON/CSV we care about (filters out a brand's non-wellness bulk). */
    internal fun isWellnessFile(name: String, data: ByteArray): Boolean {
        if (name.endsWith(".csv")) {
            // Includes Oura's generically-named daily-summary CSV (#857) so it reaches the parser.
            return listOf(
                "sleep", "heart", "step", "stress", "activit", "readiness", "wellness", "rhr",
                "oura", "daily", "trend",
            ).any { name.contains(it) }
        }
        if (!name.endsWith(".json")) return false
        val hints = listOf("sleep", "heart", "rate", "step", "stress", "activit", "readiness", "wellness",
            "rhr", "oura", "calorie", "spo2", "respiration", "temperature", "biometric", "summarizedactivities", "di_connect")
        return hints.any { name.contains(it) }
    }

    private fun readCapped(input: InputStream, cap: Long): ByteArray {
        val buffer = ByteArrayOutputStream(64 * 1024)
        val chunk = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(chunk)
            if (n < 0) break
            total += n
            if (total > cap) throw IllegalStateException("Entry exceeds $cap bytes")
            buffer.write(chunk, 0, n)
        }
        return buffer.toByteArray()
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    private fun last(path: String): String = path.substringAfterLast('/')

    private fun parseObject(data: ByteArray): JSONObject? =
        runCatching { JSONObject(String(Bom.stripUtf8(data), Charsets.UTF_8)) }.getOrNull()

    private fun parseArray(data: ByteArray): JSONArray? =
        runCatching { JSONArray(String(Bom.stripUtf8(data), Charsets.UTF_8)) }.getOrNull()

    private fun dayString(ts: Long): String =
        Instant.ofEpochSecond(ts).atZone(ZoneOffset.UTC).toLocalDate().format(DAY_FMT)

    /** Fitbit local timestamp (offsetless, often `.SSS`) → epoch seconds at UTC. */
    internal fun fitbitTime(raw: String?): Long? {
        val t = raw?.trim() ?: return null
        if (t.isEmpty()) return null
        WhoopTime.parseEpochSeconds(t, 0)?.let { return it }
        val normalized = t.replace("T", " ")
        for (fmt in FITBIT_DT_FMTS) {
            runCatching {
                return LocalDateTime.parse(normalized, fmt).toEpochSecond(ZoneOffset.UTC)
            }
        }
        return null
    }

    private fun dayKey(raw: String?): String? {
        val t = raw?.trim() ?: return null
        if (t.isEmpty()) return null
        fitbitTime(t)?.let { return dayString(it) }
        // Same order + isDateOnly split as before: the two MM/dd/yy* patterns parse as LocalDateTime,
        // then the bare yyyy-MM-dd pattern parses as a LocalDate. Formatters are cached above.
        for (fmt in DAYKEY_DATETIME_FMTS) {
            runCatching {
                return LocalDateTime.parse(t, fmt).toLocalDate().format(DAY_FMT)
            }
        }
        runCatching {
            return java.time.LocalDate.parse(t, DAYKEY_DATE_FMT).format(DAY_FMT)
        }
        if (t.length >= 10) return t.substring(0, 10)
        return null
    }

    private fun displayName(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    }.getOrNull()

    // JSON value coercion (crafted-input safe; org.json saturates, so range-check before narrowing).
    private fun JSONObject.finiteDouble(k: String): Double? =
        if (has(k) && !isNull(k)) optDouble(k).takeIf { it.isFinite() } else null
    private fun JSONObject.dblOpt(k: String): Double? = finiteDouble(k)
    private fun JSONObject.intOpt(k: String): Int? = finiteDouble(k)?.takeIf { it >= -9e18 && it <= 9e18 }?.toLong()?.toInt()
    private fun JSONObject.longOpt(k: String): Long? = finiteDouble(k)?.takeIf { it >= -9e18 && it <= 9e18 }?.toLong()
    private fun JSONObject.posInt(k: String): Int? = intOpt(k)?.takeIf { it > 0 }
    private fun JSONObject.posDbl(k: String): Double? = dblOpt(k)?.takeIf { it > 0 }
    private fun JSONObject.strOpt(k: String): String? = if (has(k) && !isNull(k)) optString(k).ifEmpty { null } else null
}
