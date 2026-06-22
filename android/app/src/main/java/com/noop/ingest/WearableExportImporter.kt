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
 *   • Oura   — the Account → Export Data JSON: sleep periods (stages/durations/HRV/RHR/breath),
 *              daily readiness (RHR, temperature deviation, score), daily activity (steps/calories).
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

    private val DAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    // Cached date formatters for the per-record parse fallbacks below. `DateTimeFormatter.ofPattern` was
    // previously rebuilt PER ROW inside fitbitTime()/dayKey() — a real allocation churn on a multi-year
    // Fitbit/wearable import (tens of thousands of rows). Hoisting them is pure perf; the patterns, order,
    // and the LocalDate-vs-LocalDateTime split are unchanged. Mirrors CsvParser's cached formatters and
    // AppleHealthImporter's "avoid per-record allocation across tens of thousands" note.
    private val FITBIT_TIME_FMTS: List<DateTimeFormatter> = listOf(
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS"),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"),
    )
    // (formatter, isDateOnly) — `isDateOnly` is true ONLY for the bare "yyyy-MM-dd" entry, preserving the
    // original `if (pattern == "yyyy-MM-dd")` LocalDate path exactly (the others stay LocalDateTime).
    private val DAY_KEY_FMTS: List<Pair<DateTimeFormatter, Boolean>> = listOf(
        DateTimeFormatter.ofPattern("MM/dd/yy HH:mm:ss") to false,
        DateTimeFormatter.ofPattern("MM/dd/yy") to false,
        DAY_FMT to true,
    )

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
            return ImportSummary.failure(brand.label, "${brand.label} export held no sleep or daily wellness data.")
        }
        return persist(repo, brand, parsed)
    }

    // ------------------------------------------------------------------------
    // Intermediate accumulators (mirror the Swift WearableDailyRow / WearableSleepSession)
    // ------------------------------------------------------------------------

    internal class DayAcc(val day: String) {
        var steps: Int? = null; var distanceM: Double? = null; var activeKcal: Double? = null; var totalKcal: Double? = null
        var restingHr: Int? = null; var avgHrvMs: Double? = null; var skinTempDevC: Double? = null
        var spo2Pct: Double? = null; var avgStress: Int? = null
        var totalSleepMin: Double? = null; var deepMin: Double? = null; var lightMin: Double? = null
        var remMin: Double? = null; var awakeMin: Double? = null; var efficiencyPct: Double? = null
        var readinessScore: Int? = null; var sleepScore: Int? = null
    }

    internal class SleepAcc(
        val startTs: Long, val endTs: Long,
        val deepMin: Double?, val lightMin: Double?, val remMin: Double?, val awakeMin: Double?,
        val totalSleepMin: Double?, val efficiencyPct: Double?,
        val avgHr: Int?, val lowestHr: Int?, val avgHrvMs: Double?,
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

        for (data in files.values.take(8)) brandFromJsonShape(data)?.let { return it }
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
                }
            }
        }
        return Parsed(byDay.values.sortedBy { it.day }, sleeps.sortedBy { it.startTs })
    }

    private fun ouraSleep(s: JSONObject): SleepAcc? {
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
            avgHrvMs = s.posDbl("average_hrv"), sleepScore = null, stagesJson = null,
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
            avgHr = null, lowestHr = null, avgHrvMs = null, sleepScore = null,
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
            return listOf("sleep", "heart", "step", "stress", "activit", "readiness", "wellness", "rhr").any { name.contains(it) }
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
        for (fmt in FITBIT_TIME_FMTS) {
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
        for ((fmt, isDateOnly) in DAY_KEY_FMTS) {
            runCatching {
                val ld = if (isDateOnly) java.time.LocalDate.parse(t, fmt)
                else LocalDateTime.parse(t, fmt).toLocalDate()
                return ld.format(DAY_FMT)
            }
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
