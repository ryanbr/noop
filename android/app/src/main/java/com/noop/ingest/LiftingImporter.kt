package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.ImportSummary
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Imports strength-training history from a lifting tracker into the local Room store, as one
 * "Strength Training" [WorkoutRow] per workout (source "lifting").
 *
 * Kotlin mirror of the macOS/iOS source of truth
 *   Packages/StrandImport/Sources/StrandImport/LiftingImporter.swift
 * so the same two formats, the same volume-load arithmetic and the same honest labelling apply on
 * every platform:
 *
 *   • Hevy CSV export        — one row per set; grouped into a session by (title + start_time).
 *   • Liftosaur JSON export  — a `history` array of records with `startTime`/`endTime` (ms) and
 *                              nested `entries[].sets[]`.
 *
 * The headline figure is a TRANSPARENT volume load — Σ(weight × reps) across the working sets —
 * surfaced as a training-VOLUME estimate, never a measured cardiovascular strain: the rows carry no
 * `strain`, so imported lifting never feeds the HR-based Effort score. Weights normalise to
 * kilograms (Hevy `weight_kg` is kg; lb columns and Liftosaur's `lb` unit convert). Tolerant
 * throughout: a malformed set / record is skipped and counted, never fatal. Parsing is pure
 * ([parseHevy] / [parseLiftosaur]) so it is JVM unit-testable (LiftingImporterTest).
 */
object LiftingImporter {

    /** Room deviceId / workout source for everything this importer writes — identical to the Swift lane. */
    const val SOURCE_ID = "lifting"

    /** Sport name every imported lifting session is filed under (maps to the dumbbell icon). */
    const val SPORT = "Strength Training"

    private const val SOURCE_LABEL = "Lifting"

    /** Pounds → kilograms (exact avoirdupois definition). */
    internal const val LB_TO_KG = 0.45359237

    /** Input ceiling — a lifting export is small; 64 MB is already generous. */
    private const val MAX_BYTES = 64L shl 20

    enum class Format { HEVY_CSV, LIFTOSAUR_JSON }

    // MARK: - One parsed session (mirrors Swift LiftingSession)

    data class Session(
        val startTs: Long,        // unix seconds, UTC
        val endTs: Long,          // unix seconds, UTC (== startTs when no end)
        val volumeLoadKg: Double, // Σ(weight_kg × reps) over counted sets
        val setCount: Int,
        val exerciseCount: Int,
        val totalReps: Int,
        val topSetKg: Double?,
        val title: String?,
    ) {
        /** Duration in seconds, or null when start == end. */
        val durationS: Double? get() = (endTs - startTs).takeIf { it > 0 }?.toDouble()

        /**
         * The honest one-line note stored on the workout row, e.g.
         * "Strength · volume load 12,400 kg · 18 sets · 5 exercises". Explicitly a training-VOLUME
         * estimate, not a strain — the row carries no `strain`, so it never feeds Effort.
         */
        fun volumeLoadNote(): String {
            val parts = ArrayList<String>(3)
            if (volumeLoadKg > 0) parts.add("volume load ${groupedKg(volumeLoadKg)} kg")
            parts.add("$setCount set${if (setCount == 1) "" else "s"}")
            if (exerciseCount > 0) parts.add("$exerciseCount exercise${if (exerciseCount == 1) "" else "s"}")
            val body = "Strength · " + parts.joinToString(" · ")
            return if (!title.isNullOrEmpty()) "$title: $body" else body
        }
    }

    data class Result(
        val sessions: List<Session>,
        val skipped: Int,
        val firstDay: String?,
        val lastDay: String?,
    )

    // MARK: - Public entry point (UI calls this)

    /**
     * Read the SAF [uri], auto-detect Hevy CSV vs Liftosaur JSON, parse it, upsert one workout per
     * session under [deviceId] (defaults to "lifting"), and return an [ImportSummary].
     */
    suspend fun importExport(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = SOURCE_ID,
    ): ImportSummary {
        val bytes: ByteArray = try {
            context.contentResolver.openInputStream(uri)?.use { it.readCapped(MAX_BYTES) }
                ?: return ImportSummary.failure(SOURCE_LABEL, "Could not open the selected file.")
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read the file: ${e.message ?: "unknown error"}")
        }

        val result = parse(bytes)
        if (result.sessions.isEmpty()) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No workouts found - point at a Hevy CSV export or a Liftosaur JSON export.",
            )
        }

        val rows = result.sessions.map { s ->
            WorkoutRow(
                deviceId = deviceId,
                startTs = s.startTs,
                endTs = s.endTs,
                sport = SPORT,
                source = SOURCE_ID,
                durationS = s.durationS,
                energyKcal = null,
                avgHr = null,
                maxHr = null,
                strain = null,             // never a fabricated cardiovascular strain
                distanceM = null,
                zonesJSON = null,
                notes = s.volumeLoadNote(),
            )
        }

        repo.upsertDevice(deviceId, name = "Lifting log")
        repo.upsertWorkouts(rows)

        val totalVolume = result.sessions.sumOf { it.volumeLoadKg }
        return ImportSummary(
            source = SOURCE_LABEL,
            counts = linkedMapOf("workouts" to rows.size),
            firstDay = result.firstDay,
            lastDay = result.lastDay,
            message = buildString {
                append("Imported ${rows.size} workout")
                if (rows.size != 1) append("s")
                if (totalVolume > 0) append(" (${groupedKg(totalVolume)} kg total volume)")
                if (result.firstDay != null && result.lastDay != null && result.firstDay != result.lastDay) {
                    append(" from ${result.firstDay} to ${result.lastDay}")
                }
                if (result.skipped > 0) append(", ${result.skipped} skipped")
                append(".")
            },
        )
    }

    // MARK: - Detection + dispatch

    /**
     * Best-effort format sniff: a leading `{`/`[` (after whitespace / BOM) reads as JSON (Liftosaur);
     * otherwise it's a Hevy CSV.
     */
    internal fun detectFormat(data: ByteArray): Format {
        for (b in data.take(64)) {
            when (b.toInt() and 0xFF) {
                0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF -> continue // whitespace / UTF-8 BOM
                '{'.code, '['.code -> return Format.LIFTOSAUR_JSON
                else -> return Format.HEVY_CSV
            }
        }
        return Format.HEVY_CSV
    }

    /**
     * Parse raw bytes, auto-detecting the format.
     *
     * [zone] interprets Hevy's zoneless local wall-clock timestamps (#649); defaults to the device
     * timezone. Liftosaur stamps are absolute epoch ms and ignore it.
     */
    internal fun parse(data: ByteArray, zone: ZoneId = ZoneId.systemDefault()): Result =
        when (detectFormat(data)) {
            Format.HEVY_CSV -> parseHevy(CsvTable.fromData(data), zone)
            Format.LIFTOSAUR_JSON ->
                parseLiftosaur(Bom.stripString(String(Bom.stripUtf8(data), Charsets.UTF_8)))
        }

    // MARK: - Hevy CSV

    /**
     * Parse a Hevy CSV (one row per set) into one session per workout.
     *
     * Hevy writes zoneless **local wall-clock** timestamps (e.g. "12 Jun 2026, 18:30"), so a session
     * logged at 18:30 must land at 18:30 in [zone], not 18:30 UTC (#649). The export carries no
     * offset, so the device timezone is the honest interpretation; defaults to [ZoneId.systemDefault]
     * and is injectable for deterministic tests.
     */
    internal fun parseHevy(table: CsvTable, zone: ZoneId = ZoneId.systemDefault()): Result {
        // Grouped by (title, start_time); the start_time string alone is a stable key, title
        // disambiguates the rare same-second back-to-back log.
        val order = ArrayList<String>()
        val byKey = LinkedHashMap<String, HevyAcc>()
        var skipped = 0

        for (row in table.rows) {
            val startRaw = row.cell("start_time", "start", "date")
            val start = startRaw?.let { parseEpochSeconds(it, zone) }
            if (startRaw == null || start == null) { skipped++; continue }

            val title = row.cell("title", "workout_name", "name")
            val exercise = row.cell("exercise_title", "exercise_name", "exercise") ?: ""
            val setType = (row.cell("set_type", "type") ?: "").lowercase()

            val weightKg: Double? = (row.double("weight_kg", "weight", "weight_kgs")
                ?: row.double("weight_lb", "weight_lbs", "weight_lbf")?.let { it * LB_TO_KG })
                ?.takeIf { it.isFinite() }
            // Crafted-import guard (parity with Swift): Kotlin's Double.toInt() SATURATES a
            // non-finite/out-of-range value (NaN→0, +inf→MAX) and would store garbage rather than
            // crash; bound reps to a sane finite range and drop-and-skip otherwise so both platforms
            // reject the same hostile CSV (e.g. reps "1e9999" → +inf).
            val reps = row.double("reps", "rep_count")
                ?.takeIf { it.isFinite() && it >= 0 && it < 1e6 }?.toInt()

            val key = "${title ?: ""}|$startRaw"
            val acc = byKey.getOrPut(key) { order.add(key); HevyAcc(start, title, zone) }
            row.cell("end_time", "end")?.let { acc.endRaw = it }
            acc.add(exercise, setType, weightKg, reps)
        }

        return finish(order.mapNotNull { byKey[it]?.toSession() }, skipped)
    }

    /** Mutable per-session tally while folding Hevy set rows. */
    private class HevyAcc(val start: Long, val title: String?, val zone: ZoneId) {
        var endRaw: String? = null
        var volume = 0.0
        var sets = 0
        var reps = 0
        var top: Double? = null
        val exercises = HashSet<String>()

        /**
         * Count a set. Warm-up sets are excluded from the working-volume figure (Hevy marks them
         * `set_type = "warmup"`); a completed bodyweight/duration set still counts toward set/rep
         * context but adds no volume.
         */
        fun add(exercise: String, setType: String, weightKg: Double?, reps: Int?) {
            if (exercise.isNotEmpty()) exercises.add(exercise.lowercase())
            if (setType == "warmup" || setType == "warm_up" || setType == "warm-up") return
            sets++
            if (reps != null && reps > 0) this.reps += reps
            if (weightKg != null && weightKg > 0) {
                top = maxOf(top ?: 0.0, weightKg)
                if (reps != null && reps > 0) volume += weightKg * reps
            }
        }

        fun toSession(): Session? {
            if (sets == 0) return null
            val end = endRaw?.let { parseEpochSeconds(it, zone) } ?: start
            return Session(
                startTs = start,
                endTs = if (end >= start) end else start,
                volumeLoadKg = volume,
                setCount = sets,
                exerciseCount = exercises.size,
                totalReps = reps,
                topSetKg = top,
                title = title,
            )
        }
    }

    // MARK: - Liftosaur JSON

    /** Parse a Liftosaur JSON export into one session per history record. */
    internal fun parseLiftosaur(text: String): Result {
        val history: JSONArray = locateHistory(text) ?: return Result(emptyList(), 0, null, null)
        val sessions = ArrayList<Session>(history.length())
        var skipped = 0
        for (i in 0 until history.length()) {
            val record = history.optJSONObject(i)
            if (record == null) { skipped++; continue }
            val s = liftosaurSession(record)
            if (s != null) sessions.add(s) else skipped++
        }
        return finish(sessions, skipped)
    }

    /** Dig the `history` array out of a Liftosaur export, tolerating a couple of wrapper shapes. */
    private fun locateHistory(text: String): JSONArray? {
        val trimmed = text.trim()
        if (trimmed.startsWith("[")) return runCatching { JSONArray(trimmed) }.getOrNull()
        val obj = runCatching { JSONObject(trimmed) }.getOrNull() ?: return null
        obj.optJSONArray("history")?.let { return it }
        obj.optJSONObject("storage")?.optJSONArray("history")?.let { return it }
        return null
    }

    private fun liftosaurSession(record: JSONObject): Session? {
        val start = liftosaurDate(record.opt("startTime") ?: record.opt("date") ?: record.opt("ts"))
            ?: return null
        val end = liftosaurDate(record.opt("endTime")) ?: start

        var volume = 0.0
        var sets = 0
        var reps = 0
        var top: Double? = null
        var exercises = 0

        val entries = record.optJSONArray("entries") ?: JSONArray()
        for (e in 0 until entries.length()) {
            val entry = entries.optJSONObject(e) ?: continue
            exercises++
            val entryUnit = entry.optString("unit", "").lowercase().ifEmpty { null }
            val setList = entry.optJSONArray("sets") ?: continue
            for (s in 0 until setList.length()) {
                val set = setList.optJSONObject(s) ?: continue
                // A logged set has completed reps; templates with only planned `reps` are skipped.
                val r = if (set.has("completedReps")) liftosaurInt(set.opt("completedReps")) else null
                if (r == null || r <= 0) continue
                sets++
                reps += r
                val w = liftosaurWeightKg(set, entryUnit)
                if (w != null && w > 0) {
                    top = maxOf(top ?: 0.0, w)
                    volume += w * r
                }
            }
        }

        if (sets == 0) return null
        return Session(
            startTs = start,
            endTs = if (end >= start) end else start,
            volumeLoadKg = volume,
            setCount = sets,
            exerciseCount = exercises,
            totalReps = reps,
            topSetKg = top,
            title = record.optString("programName", "").ifEmpty { record.optString("dayName", "").ifEmpty { null } },
        )
    }

    /**
     * Resolve a Liftosaur set's weight to kilograms. The weight may be a bare number or an object
     * `{ "value": 100, "unit": "lb" }`; `lb` converts, everything else (kg / blank) is taken as kg.
     */
    private fun liftosaurWeightKg(set: JSONObject, entryUnit: String?): Double? {
        val raw = if (set.has("weight")) set.opt("weight") else set.opt("weightValue")
        if (raw is JSONObject) {
            val v = liftosaurDouble(raw.opt("value")) ?: return null
            val unit = raw.optString("unit", "").lowercase().ifEmpty { entryUnit }
            return if (unit == "lb" || unit == "lbs") v * LB_TO_KG else v
        }
        val v = liftosaurDouble(raw) ?: return null
        return if (entryUnit == "lb" || entryUnit == "lbs") v * LB_TO_KG else v
    }

    // MARK: - JSON scalar coercion

    private fun liftosaurDouble(any: Any?): Double? = when (any) {
        is Number -> any.toDouble()
        is String -> any.toDoubleOrNull()
        else -> null
    }?.takeIf { it.isFinite() }   // reject NaN/inf (e.g. "1e9999") rather than carry garbage downstream

    private fun liftosaurInt(any: Any?): Int? = when (any) {
        is Number -> safeInt(any.toDouble())
        is String -> any.toIntOrNull() ?: any.toDoubleOrNull()?.let { safeInt(it) }
        else -> null
    }

    /**
     * Finite + Int-range checked Double→Int conversion (parity with Swift's `safeInt`). Kotlin's
     * `Double.toInt()` SATURATES non-finite/out-of-range values (NaN→0, +inf→Int.MAX_VALUE) and so
     * would silently store garbage from a crafted import; return null instead so the set is dropped
     * and skipped, agreeing with the Swift importer's drop-and-skip.
     */
    private fun safeInt(d: Double): Int? =
        if (d.isFinite() && d >= -9e18 && d <= 9e18) d.toInt() else null

    /**
     * Liftosaur timestamps are epoch milliseconds (number or numeric string); a plain ISO string is
     * tolerated as a fallback. A 13-digit value is ms, a 10-digit value is seconds.
     */
    private fun liftosaurDate(any: Any?): Long? {
        val ms = liftosaurDouble(any)
        if (ms != null && ms > 0) {
            return if (ms > 1_000_000_000_000.0) (ms / 1000).toLong() else ms.toLong()
        }
        // Rare ISO-string fallback: an embedded offset wins; a zoneless string falls back to the
        // device zone (Liftosaur's primary path is absolute epoch ms, so this is an edge case).
        if (any is String) return parseEpochSeconds(any, ZoneId.systemDefault())
        return null
    }

    // MARK: - Shared helpers

    private val HEVY_FORMATTERS: List<DateTimeFormatter> = listOf(
        // Hevy exports an English "d MMM yyyy, HH:mm" form (e.g. "12 Jun 2026, 18:30").
        DateTimeFormatter.ofPattern("d MMM yyyy, HH:mm", Locale.ENGLISH),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.ENGLISH),
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.ENGLISH),
        DateTimeFormatter.ofPattern("yyyy/MM/dd HH:mm:ss", Locale.ENGLISH),
        DateTimeFormatter.ofPattern("MM/dd/yyyy HH:mm:ss", Locale.ENGLISH),
    )

    /**
     * Parse a lifting date string into UTC epoch seconds, interpreting it in [zone].
     *
     * A timestamp carrying its own ISO-8601 offset ("…Z" / "…+01:00") is authoritative and ignores
     * [zone]. Everything else — Hevy's English "d MMM yyyy, HH:mm" and plain "yyyy-MM-dd HH:mm:ss"
     * forms — is **zoneless local wall-clock**, so it is resolved against [zone] (the device timezone),
     * not UTC (#649). `atZone` is DST-correct, unlike a fixed offset.
     */
    internal fun parseEpochSeconds(raw: String, zone: ZoneId): Long? {
        val t = raw.trim()
        if (t.isEmpty()) return null
        // ISO-8601 with an embedded offset wins and is NOT shifted by the device zone.
        WhoopTime.parseIsoWithOffsetEpochSeconds(t)?.let { return it }
        // Zoneless wall-clock → interpret in the device timezone.
        for (fmt in HEVY_FORMATTERS) {
            runCatching {
                return java.time.LocalDateTime.parse(t, fmt).atZone(zone).toEpochSecond()
            }
        }
        return null
    }

    /** Build the result: sort sessions oldest-first and compute the day span. */
    private fun finish(sessions: List<Session>, skipped: Int): Result {
        val sorted = sessions.sortedBy { it.startTs }
        fun day(ts: Long): String =
            Instant.ofEpochSecond(ts).atOffset(ZoneOffset.UTC).toLocalDate().toString()
        return Result(
            sessions = sorted,
            skipped = skipped,
            firstDay = sorted.firstOrNull()?.let { day(it.startTs) },
            lastDay = sorted.lastOrNull()?.let { day(it.startTs) },
        )
    }

    /** Group an integer-kg figure with thousands separators (e.g. 12400 → "12,400"). */
    internal fun groupedKg(kg: Double): String =
        NumberFormat.getIntegerInstance(Locale.US).format(Math.round(kg))
}

// MARK: - Stream helper (file-private; the twin in NutritionCsvImporter.kt is not visible here)

