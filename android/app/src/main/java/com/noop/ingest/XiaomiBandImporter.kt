package com.noop.ingest

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.ZipInputStream
import com.noop.analytics.SleepStageVocabulary

/**
 * Imports a **Xiaomi Smart Band (Mi Band)** history from the Mi Fitness app's on-device
 * SQLite store — fully offline, no Bluetooth, no Xiaomi account.
 *
 * Android port of the macOS source of truth
 * `Packages/StrandImport/Sources/StrandImport/XiaomiBandImporter.swift` (+ the app glue in
 * `Strand/Data/XiaomiImporter.swift`). The table/field mapping and the sleep-stage
 * reconstruction are re-derived from the public `artyomxx/xiaomi-band-ios-export` tool and
 * verified against a real Mi Band 10 export — **no GPL/AGPL code is copied**.
 *
 * Input is the Mi Fitness sandbox shared as a `.zip`, or the bare `<user_id>.db`. The health
 * metrics live in `DataBase/<user_id>/de/<user_id>.db`, one row per sample with a JSON `value`
 * column. We open it READ-ONLY and never write to it.
 *
 * Sink (all under deviceId "xiaomi-band"):
 *  - day rollups  -> DailyMetric + MetricSeriesRow
 *  - `sleep` rows -> SleepSession with the real per-epoch hypnogram (`items[]`)
 *
 * Sleep-stage `state` codes: 1=awake, 2=light, 3=deep, 4=REM, 5=awake-in-bed.
 * Not in the export (left null): HRV, recovery, respiration, skin temperature.
 */
object XiaomiBandImporter {

    const val SOURCE_LABEL = "Xiaomi Smart Band"
    const val DEFAULT_DEVICE_ID = "xiaomi-band"

    /** Day-rollup tables, keyed by NOOP day. `goal_day` is skipped (targets, not measurements). */
    private val DAY_TABLES = listOf(
        "steps_day", "calories_day", "heart_rate_day", "sleep_day",
        "stress_day", "spo2_day", "intensity_day", "valid_stand_day", "vitality",
    )

    private val DAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")
    private const val MAX_ENTRY_BYTES = 512L shl 20  // zip-bomb guard

    suspend fun importExport(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = DEFAULT_DEVICE_ID,
    ): ImportSummary {
        val dbFile = try {
            resolveDatabase(context, uri)
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, e.message ?: "Couldn't read the export.")
        } ?: return ImportSummary.failure(
            SOURCE_LABEL, "No Mi Fitness database found (looked for DataBase/<id>/de/<id>.db).")

        try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                val days = readDays(db)
                val sleeps = readSleeps(db)
                if (days.isEmpty() && sleeps.isEmpty()) {
                    return ImportSummary.failure(SOURCE_LABEL, "No Mi Fitness health rows found.")
                }
                return persist(repo, deviceId, days, sleeps)
            }
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Import failed: ${e.message}")
        } finally {
            // Clean up only files we extracted into our own cache dir.
            if (dbFile.absolutePath.startsWith(context.cacheDir.absolutePath)) {
                dbFile.parentFile?.takeIf { it.absolutePath.startsWith(context.cacheDir.absolutePath) }
                    ?.deleteRecursively() ?: dbFile.delete()
            }
        }
    }

    // ------------------------------------------------------------------------
    // Locate / materialize the health DB
    // ------------------------------------------------------------------------

    /** Copy the picked content to cache (a zip is extracted) and return the health `.db` file. */
    private fun resolveDatabase(context: Context, uri: Uri): File? {
        val work = File(context.cacheDir, "xiaomi-${System.nanoTime()}").apply { mkdirs() }
        val head = ByteArray(16)
        context.contentResolver.openInputStream(uri)?.use { it.read(head) }
            ?: throw IllegalStateException("Couldn't open the selected file.")

        val isZip = head.size >= 2 && head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte()
        if (!isZip) {
            // Treat as a bare SQLite file — copy it whole.
            val out = File(work, "mifitness.db")
            context.contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { input.copyTo(it) }
            }
            return if (looksLikeHealthDB(out)) out else { work.deleteRecursively(); null }
        }

        // A zip of the Mi Fitness sandbox: extract every `.db` and pick the richest.
        context.contentResolver.openInputStream(uri)?.use { raw ->
            ZipInputStream(raw).use { zin ->
                var entry = zin.nextEntry
                var i = 0
                while (entry != null) {
                    val name = entry.name
                    if (!entry.isDirectory && name.lowercase().endsWith(".db") &&
                        name.lowercase().contains("/de/")
                    ) {
                        val out = File(work, "db_${i++}.db")
                        out.outputStream().use { copyBounded(zin, it) }
                    }
                    entry = zin.nextEntry
                }
            }
        }
        val best = work.listFiles()?.filter { it.extension == "db" }
            ?.maxByOrNull { stepsRowCount(it) }
        if (best == null || stepsRowCount(best) == 0) { work.deleteRecursively(); return null }
        return best
    }

    private fun copyBounded(input: InputStream, out: java.io.OutputStream) {
        val buf = ByteArray(64 * 1024); var total = 0L; var n: Int
        while (input.read(buf).also { n = it } >= 0) {
            total += n
            if (total > MAX_ENTRY_BYTES) throw IllegalStateException("Entry too large.")
            out.write(buf, 0, n)
        }
    }

    private fun looksLikeHealthDB(f: File): Boolean = stepsRowCount(f) >= 0 && hasTable(f, "steps")

    private fun stepsRowCount(f: File): Int = try {
        SQLiteDatabase.openDatabase(f.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            if (!hasTable(db, "steps")) 0
            else db.rawQuery("SELECT COUNT(*) FROM steps", null).use { c ->
                if (c.moveToFirst()) c.getInt(0) else 0
            }
        }
    } catch (e: Exception) { 0 }

    private fun hasTable(f: File, name: String): Boolean = try {
        SQLiteDatabase.openDatabase(f.path, null, SQLiteDatabase.OPEN_READONLY).use { hasTable(it, name) }
    } catch (e: Exception) { false }

    private fun hasTable(db: SQLiteDatabase, name: String): Boolean =
        db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", arrayOf(name)).use {
            it.moveToFirst()
        }

    // ------------------------------------------------------------------------
    // Read day rollups + sleep
    // ------------------------------------------------------------------------

    private class DayAcc(val day: String) {
        var steps: Int? = null; var distanceM: Double? = null; var activeKcal: Double? = null
        var intensityMin: Double? = null; var standCount: Int? = null
        var restingHr: Int? = null; var avgHr: Int? = null; var minHr: Int? = null; var maxHr: Int? = null
        var totalSleepMin: Double? = null; var deepMin: Double? = null; var lightMin: Double? = null
        var remMin: Double? = null; var awakeMin: Double? = null; var sleepScore: Int? = null
        var avgStress: Int? = null; var avgSpo2: Double? = null; var vitality: Int? = null
    }

    private fun readDays(db: SQLiteDatabase): Map<String, DayAcc> {
        val byDay = LinkedHashMap<String, DayAcc>()
        for (table in DAY_TABLES) {
            if (!hasTable(db, table)) continue
            db.rawQuery(
                "SELECT time, value, zone_offset FROM \"$table\" WHERE deleted=0 ORDER BY time", null
            ).use { c ->
                val ti = c.getColumnIndexOrThrow("time")
                val vi = c.getColumnIndexOrThrow("value")
                val zi = c.getColumnIndexOrThrow("zone_offset")
                while (c.moveToNext()) {
                    val v = parseJson(c.getString(vi)) ?: continue
                    val key = dayKey(c.getLong(ti), c.getLong(zi))
                    val acc = byDay.getOrPut(key) { DayAcc(key) }
                    apply(table, v, acc)
                }
            }
        }
        return byDay
    }

    private fun apply(table: String, v: JSONObject, a: DayAcc) {
        when (table) {
            "steps_day" -> { v.intOpt("steps")?.let { a.steps = it }; v.dblOpt("distance")?.let { a.distanceM = it } }
            "calories_day" -> v.dblOpt("calories")?.let { a.activeKcal = it }
            "heart_rate_day" -> {
                v.intPos("avg_rhr")?.let { a.restingHr = it }; v.intPos("avg_hr")?.let { a.avgHr = it }
                v.intPos("min_hr")?.let { a.minHr = it }; v.intPos("max_hr")?.let { a.maxHr = it }
            }
            "sleep_day" -> {
                v.dblOpt("total_duration")?.let { a.totalSleepMin = it }
                v.dblOpt("sleep_deep_duration")?.let { a.deepMin = it }
                v.dblOpt("sleep_light_duration")?.let { a.lightMin = it }
                v.dblOpt("sleep_rem_duration")?.let { a.remMin = it }
                v.dblOpt("sleep_awake_duration")?.let { a.awakeMin = it }
                v.intPos("sleep_score")?.let { a.sleepScore = it }
            }
            "stress_day" -> v.intPos("avg_stress")?.let { a.avgStress = it }
            "spo2_day" -> v.dblPos("avg_spo2")?.let { a.avgSpo2 = it }
            "intensity_day" -> v.dblOpt("duration")?.let { a.intensityMin = it }
            "valid_stand_day" -> v.intOpt("count")?.let { a.standCount = it }
            "vitality" -> v.intPos("latest_accumulated_vitality")?.let { a.vitality = it }
        }
    }

    private class SleepAcc(
        val startTs: Long, val endTs: Long, val deepMin: Double?, val lightMin: Double?,
        val remMin: Double?, val awakeMin: Double?, val minHr: Int?, val stagesJson: String?,
    )

    private fun readSleeps(db: SQLiteDatabase): List<SleepAcc> {
        if (!hasTable(db, "sleep")) return emptyList()
        val out = ArrayList<SleepAcc>()
        val seen = HashSet<Long>()
        db.rawQuery("SELECT time, value FROM sleep WHERE deleted=0 ORDER BY time", null).use { c ->
            val ti = c.getColumnIndexOrThrow("time"); val vi = c.getColumnIndexOrThrow("value")
            while (c.moveToNext()) {
                val v = parseJson(c.getString(vi)) ?: continue
                val bed = v.longOpt("bedtime") ?: v.longOpt("device_bedtime") ?: v.longOpt("bed_timestamp") ?: continue
                val wake = v.longOpt("wake_up_time") ?: v.longOpt("device_wake_up_time")
                    ?: v.longOpt("out_bed_timestamp") ?: c.getLong(ti)
                if (wake <= bed || !seen.add(bed)) continue

                val segs = org.json.JSONArray()
                v.optJSONArray("items")?.let { items ->
                    for (i in 0 until items.length()) {
                        val it = items.optJSONObject(i) ?: continue
                        val s = it.longOpt("start_time") ?: continue
                        val e = it.longOpt("end_time") ?: continue
                        if (e <= s) continue
                        segs.put(JSONObject().put("start", s).put("end", e).put("stage", stageName(it.intOpt("state") ?: 0)))
                    }
                }
                out.add(SleepAcc(
                    startTs = bed, endTs = wake,
                    deepMin = v.dblOpt("sleep_deep_duration"), lightMin = v.dblOpt("sleep_light_duration"),
                    remMin = v.dblOpt("sleep_rem_duration"), awakeMin = v.dblOpt("sleep_awake_duration"),
                    minHr = v.intPos("min_hr"),
                    stagesJson = if (segs.length() > 0) segs.toString() else null))
            }
        }
        return out.sortedBy { it.startTs }
    }

    // ------------------------------------------------------------------------
    // Persist
    // ------------------------------------------------------------------------

    private suspend fun persist(
        repo: WhoopRepository, deviceId: String,
        daysMap: Map<String, DayAcc>, sleeps: List<SleepAcc>,
    ): ImportSummary {
        repo.upsertDevice(deviceId, name = SOURCE_LABEL)
        val days = daysMap.values.sortedBy { it.day }

        val dailyMetrics = days.map { d ->
            DailyMetric(
                deviceId = deviceId, day = d.day,
                totalSleepMin = d.totalSleepMin,
                efficiency = sleepEfficiency(d.totalSleepMin, d.awakeMin),
                deepMin = d.deepMin, remMin = d.remMin, lightMin = d.lightMin,
                restingHr = d.restingHr, spo2Pct = d.avgSpo2, steps = d.steps,
                activeKcalEst = d.activeKcal,
            )
        }
        if (dailyMetrics.isNotEmpty()) repo.upsertDailyMetrics(dailyMetrics)

        val sleepRows = sleeps.map { s ->
            SleepSession(
                deviceId = deviceId, startTs = s.startTs, endTs = s.endTs,
                efficiency = efficiency(s.stagesJson, s.startTs, s.endTs),
                restingHr = s.minHr, stagesJSON = s.stagesJson,
            )
        }
        if (sleepRows.isNotEmpty()) repo.upsertSleepSessions(sleepRows)

        val series = ArrayList<MetricSeriesRow>()
        fun add(day: String, key: String, v: Double?) { if (v != null) series.add(MetricSeriesRow(deviceId, day, key, v)) }
        for (d in days) {
            add(d.day, "steps", d.steps?.toDouble()); add(d.day, "distance_m", d.distanceM)
            add(d.day, "energy_kcal", d.activeKcal); add(d.day, "rhr", d.restingHr?.toDouble())
            add(d.day, "avg_hr", d.avgHr?.toDouble()); add(d.day, "max_hr", d.maxHr?.toDouble())
            add(d.day, "min_hr", d.minHr?.toDouble()); add(d.day, "spo2", d.avgSpo2)
            add(d.day, "stress", d.avgStress?.toDouble()); add(d.day, "vitality", d.vitality?.toDouble())
            add(d.day, "intensity_min", d.intensityMin); add(d.day, "stand_count", d.standCount?.toDouble())
            add(d.day, "sleep_total_min", d.totalSleepMin); add(d.day, "sleep_deep_min", d.deepMin)
            add(d.day, "sleep_light_min", d.lightMin); add(d.day, "sleep_rem_min", d.remMin)
            add(d.day, "sleep_score", d.sleepScore?.toDouble())
        }
        if (series.isNotEmpty()) repo.upsertMetricSeries(series)

        val first = days.firstOrNull()?.day
        val last = days.lastOrNull()?.day
        val span = if (first != null && last != null && first != last) " · $first-$last" else ""
        return ImportSummary(
            source = SOURCE_LABEL,
            counts = mapOf("dailyMetric" to dailyMetrics.size, "sleepSession" to sleepRows.size, "metricSeries" to series.size),
            firstDay = first, lastDay = last,
            message = "Imported ${days.size} days, ${sleepRows.size} sleeps$span",
        )
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    private fun stageName(state: Int): String = when (state) {
        3 -> "deep"; 4 -> "rem"; 2 -> "light"; else -> "wake"   // 1=awake, 5=awake-in-bed -> wake
    }

    private fun sleepEfficiency(total: Double?, awake: Double?): Double? {
        if (total == null || total <= 0) return null
        val inBed = total + (awake ?: 0.0)
        return if (inBed > 0) minOf(100.0, total / inBed * 100.0) else null
    }

    private fun efficiency(stagesJson: String?, start: Long, end: Long): Double? {
        if (stagesJson == null || end <= start) return null
        val arr = try { org.json.JSONArray(stagesJson) } catch (e: Exception) { return null }
        var asleep = 0L
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (SleepStageVocabulary.isWake(o.optString("stage"))) continue
            asleep += (o.optLong("end") - o.optLong("start")).coerceAtLeast(0)
        }
        return minOf(100.0, asleep.toDouble() / (end - start) * 100.0)
    }

    private fun dayKey(time: Long, zoneOffset: Long): String =
        Instant.ofEpochSecond(time + zoneOffset).atZone(ZoneOffset.UTC).toLocalDate().format(DAY_FMT)

    private fun parseJson(s: String?): JSONObject? =
        if (s.isNullOrEmpty()) null else try { JSONObject(s) } catch (e: Exception) { null }

    // Mi Fitness stores numbers as Int or Double; read tolerantly and treat 0 as "not measured".
    //
    // Crafted-import guard (parity with Swift's `safeInt`): a hostile `value` JSON can carry a
    // non-finite or out-of-range number (e.g. 1e9999 → +inf, or 1e308). `org.json`'s optInt/optLong
    // SATURATE/truncate such a value instead of crashing — so without this guard Android would
    // silently store garbage (steps/hr/sleep_score/…) where Swift drops-and-skips. We read the field
    // as a Double first, reject non-finite / out-of-Long-range, then narrow; null = not measured.
    private fun JSONObject.finiteDouble(k: String): Double? =
        if (has(k) && !isNull(k)) optDouble(k).takeIf { it.isFinite() } else null

    private fun JSONObject.intOpt(k: String): Int? =
        finiteDouble(k)?.takeIf { it >= -9e18 && it <= 9e18 }?.toLong()?.toInt()
    private fun JSONObject.dblOpt(k: String): Double? = finiteDouble(k)
    private fun JSONObject.longOpt(k: String): Long? =
        finiteDouble(k)?.takeIf { it >= -9e18 && it <= 9e18 }?.toLong()
    private fun JSONObject.intPos(k: String): Int? = intOpt(k)?.takeIf { it > 0 }
    private fun JSONObject.dblPos(k: String): Double? = dblOpt(k)?.takeIf { it > 0 }
}
