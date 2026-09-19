package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.analytics.VitalBands
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round

/**
 * Serializes NOOP's own cached rows back into WHOOP's 4-CSV export shape so NOOP's OWN importer
 * (WhoopCsvImporter here, WhoopExportImporter on macOS) re-imports them losslessly. The round-trip
 * is the point and is pinned by the test suite (Android exporter test + the macOS suite, which
 * re-parses this output with the REAL importer) so header/format drift fails a test rather than
 * silently producing an un-reimportable zip.
 *
 * Header strings are byte-identical to a real WHOOP export — the importer normalises them down to
 * keys like `recovery_score_pct`, so they must match exactly. Everything is emitted in UTC with a
 * literal "UTC+00:00" timezone column: NOOP stores epoch seconds and tz-less day strings, so UTC is
 * the only encoding that round-trips a timestamp back to the same instant. A trailing "Source"
 * column (which both parsers provably ignore — they key off named columns, never position) marks
 * on-device computed rows as "noop (APPROXIMATE)" per the house rules. A noop_metric_series.json
 * sidecar carries the full metricSeries for fidelity and is deliberately NOT re-imported — the
 * .noopdb backup remains the lossless restore path; this zip is the portable, WHOOP-shaped one.
 */
object WhoopCsvExporter {

    private val UTC_FMT: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
            .withZone(java.time.ZoneOffset.UTC)

    internal fun utc(epochSeconds: Long): String =
        UTC_FMT.format(java.time.Instant.ofEpochSecond(epochSeconds))

    /**
     * RFC-4180: only quote when the field carries a comma, quote, CR or LF; escape `"` by doubling.
     *
     * Formula-injection guard: a free-text value starting with `=`, `+`, `-`, `@`, tab or CR is
     * executed as a formula by Excel/Sheets/LibreOffice when the CSV is opened there (quoting alone
     * does NOT prevent that). Neutralise with a leading apostrophe — the spreadsheet convention for
     * "literal text". Numbers never pass through csvField (they use num()), so this only ever
     * touches free text such as source names. Mirrors the Swift exporter's field().
     */
    internal fun csvField(raw: String?): String {
        if (raw.isNullOrEmpty()) return ""
        val safe = if (raw.first() in "=+-@\t\r") "'$raw" else raw
        if (safe.none { it == ',' || it == '"' || it == '\n' || it == '\r' }) return safe
        return "\"" + safe.replace("\"", "\"\"") + "\""
    }

    /** Locale-proof numbers: integral Doubles print without a trailing ".0"; Double.toString uses
     *  '.' regardless of locale, so the importer's parse can't be defeated by a comma decimal. */
    internal fun num(v: Double?): String = when {
        v == null -> ""
        v == floor(v) && abs(v) < 1e12 -> v.toLong().toString()
        else -> v.toString()
    }

    internal fun num(v: Int?): String = v?.toString() ?: ""

    // --- Tolerant decoders for the cache's polymorphic JSON columns ---

    internal data class StageMinutes(
        val light: Double?, val deep: Double?, val rem: Double?, val awake: Double?,
    ) {
        /** Asleep = light+deep+rem, but only when at least one is present. */
        val asleep: Double? get() =
            if (light == null && deep == null && rem == null) null
            else (light ?: 0.0) + (deep ?: 0.0) + (rem ?: 0.0)
    }

    /**
     * Stage minutes recovered from any persisted stagesJSON shape NOOP has ever written:
     *   {"light":min,…}            — macOS WHOOP import
     *   [{"stage","min"}]          — Android import / demo seeds
     *   [{"start","end","stage"}]  — the on-device sleep stager ("wake" == awake)
     * Unusable / empty input → all-null, so the column exports blank rather than a bogus zero.
     */
    internal fun stageMinutes(stagesJSON: String?): StageMinutes {
        val none = StageMinutes(null, null, null, null)
        if (stagesJSON.isNullOrBlank()) return none
        return runCatching {
            val t = stagesJSON.trim()
            if (t.startsWith("{")) {
                val o = JSONObject(t)
                fun g(k: String): Double? =
                    if (o.has(k)) o.optDouble(k).takeIf { !it.isNaN() } else null
                StageMinutes(g("light"), g("deep"), g("rem"), g("awake") ?: g("wake"))
            } else if (t.startsWith("[")) {
                val arr = JSONArray(t)
                var l = 0.0; var d = 0.0; var r = 0.0; var a = 0.0; var any = false
                for (i in 0 until arr.length()) {
                    val seg = arr.optJSONObject(i) ?: continue
                    val stage = seg.optString("stage", "").lowercase()
                    val min: Double = if (seg.has("min")) {
                        seg.optDouble("min", 0.0)
                    } else if (seg.has("start") && seg.has("end")) {
                        (seg.optLong("end") - seg.optLong("start")) / 60.0
                    } else {
                        continue
                    }
                    any = true
                    when (stage) {
                        "light" -> l += min
                        "deep", "sws" -> d += min
                        "rem" -> r += min
                        "awake", "wake" -> a += min
                        else -> {}   // unknown stage: counted as nothing
                    }
                }
                if (any) StageMinutes(l, d, r, a) else none
            } else {
                none
            }
        }.getOrDefault(none)
    }

    /**
     * Z1–Z5 percents from zonesJSON. macOS import writes "z1"…"z5"; Android writes "zone1"…"zone5".
     * Self-contained on purpose (own decoder, not the Workouts-screen helper) so the exporter is
     * decoupled from the UI layer. null when there's no usable zone data → the columns export blank.
     */
    internal fun zonePercents(zonesJSON: String?): List<Double>? {
        if (zonesJSON.isNullOrBlank()) return null
        return runCatching {
            val o = JSONObject(zonesJSON.trim())
            val out = MutableList(5) { i ->
                val k1 = "z${i + 1}"; val k2 = "zone${i + 1}"
                when {
                    o.has(k1) -> o.optDouble(k1, 0.0)
                    o.has(k2) -> o.optDouble(k2, 0.0)
                    else -> 0.0
                }
            }
            if (out.any { it > 0.0 }) out else null
        }.getOrNull()
    }

    // --- The four CSVs (headers byte-identical to a real WHOOP export) ---

    /**
     * physiological_cycles.csv. [seriesByDay] is day -> (metricSeries key -> value), carrying the
     * cycles-only columns DailyMetric doesn't store (sleep performance/consistency/need/debt). The
     * Android daily row also lacks energy / avg-HR / max-HR / in-bed, which export blank and
     * re-import as null by design. [sourceByDay] feeds the trailing, parser-ignored Source column.
     */
    internal fun cyclesCsv(
        daily: List<DailyMetric>,
        seriesByDay: Map<String, Map<String, Double>>,
        sourceByDay: Map<String, String> = emptyMap(),
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle end time,Cycle timezone,Recovery score %,")
            .append("Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),")
            .append("Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),")
            .append("Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),")
            .append("Asleep duration (min),In bed duration (min),Light sleep duration (min),")
            .append("Deep (SWS) duration (min),REM duration (min),Awake duration (min),")
            .append("Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),Source\r\n")
        for (d in daily.sortedBy { it.day }) {
            val s = seriesByDay[d.day].orEmpty()
            sb.append(
                listOf(
                    d.day + " 00:00:00", "", "UTC+00:00",
                    num(d.recovery), num(d.restingHr), num(d.avgHrv), num(exportedSkinTempCelsius(d)),
                    // Day Strain column is WHOOP's 0–21 scale → down-convert our 0–100 Effort so the CSV
                    // is WHOOP-format and a NOOP→NOOP round-trip is lossless (import scales back ×100/21).
                    // Divide by the SAME 100.0/21.0 constant the importer multiplies by (and that Swift's
                    // whoopDayStrainFromEffort uses) so the byte output matches macOS/iOS exactly.
                    num(d.spo2Pct), num(d.strain?.let { it / (100.0 / 21.0) }),
                    "", "", "",            // energy / max HR / avg HR — not on the Android daily row
                    "", "",                // sleep/wake onset live in sleeps.csv
                    num(s["sleep_performance"]), num(d.respRateBpm), num(d.totalSleepMin),
                    "",                    // in-bed not stored on the Android daily row
                    num(d.lightMin), num(d.deepMin), num(d.remMin),
                    // "Awake duration (min)" is MINUTES — the daily row doesn't carry it, so leave
                    // the cell empty. (Writing the disturbance COUNT here exported a wrong unit
                    // that round-tripped on reimport — PR #97 review, tigercraft4. Swift parity.)
                    "",
                    // "Sleep efficiency %" is WHOOP's 0–100 column → lift the stored 0–1 fraction,
                    // rounded to 4 decimals of a percent so num()'s shortest-round-trip Double
                    // printing can't leak FP dust into the cell. Keep byte-identical to Swift
                    // (WhoopExportImporter.whoopEfficiencyPctFromFraction).
                    num(d.efficiency?.let { round(it * 100.0 * 10_000) / 10_000 }),
                    num(s["sleep_consistency"]), num(s["sleep_need_min"]),
                    num(s["sleep_debt_min"]), csvField(sourceByDay[d.day]),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /**
     * sleeps.csv. Stage durations from the tolerant decoder; in-bed derived from the span.
     *
     * [cycleStart] returns the "Cycle start time" for a session — the LOCAL day-midnight of the cycle the
     * sleep belongs to (the caller passes `AnalyticsEngine.dayString(endTs, offset) + " 00:00:00"`, the same
     * end-day key analyze/mergeSleep use). It MUST match the corresponding physiological_cycles row's
     * "Cycle start time" so the two CSVs reconcile by cycle; the previous `utc(startTs)` put a non-UTC user's
     * night on a different date than its cycle (#715). Onset/Wake stay the real UTC session times, so the
     * NOOP→NOOP round-trip is unchanged (the importer keys on sleep_onset, not Cycle start time).
     */
    internal fun sleepsCsv(
        sessions: List<SleepSession>,
        cycleStart: (SleepSession) -> String,
        sourceBySession: (SleepSession) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,")
            .append("Respiratory rate (rpm),Asleep duration (min),In bed duration (min),")
            .append("Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),")
            .append("Awake duration (min),Sleep efficiency %,Sleep consistency %,")
            .append("Sleep need (min),Sleep debt (min),Source\r\n")
        for (s in sessions.sortedBy { it.startTs }) {
            val stages = stageMinutes(s.stagesJSON)
            val inBedMin = if (s.endTs > s.startTs) (s.endTs - s.startTs) / 60.0 else null
            sb.append(
                listOf(
                    cycleStart(s), utc(s.startTs), utc(s.endTs), "UTC+00:00",
                    // NOOP never stores a nap flag — everything exports as a main sleep so the
                    // importer keeps it (it drops nap rows).
                    "false", "", "",
                    num(stages.asleep), num(inBedMin),
                    num(stages.light), num(stages.deep), num(stages.rem), num(stages.awake),
                    num(s.efficiency?.let { round(it * 100.0 * 10_000) / 10_000 }), "", "", "",
                    csvField(sourceBySession(s)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** workouts.csv. [sourceLabel] classifies each row for the trailing Source column. */
    internal fun workoutsCsv(
        rows: List<WorkoutRow>,
        sourceLabel: (WorkoutRow) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Workout start time,Workout end time,Cycle timezone,")
            .append("Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),")
            .append("Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,")
            .append("HR Zone 5 %,Distance (meters),Source\r\n")
        for (w in rows.sortedBy { it.startTs }) {
            val zones = zonePercents(w.zonesJSON)
            sb.append(
                listOf(
                    utc(w.startTs), utc(w.startTs), utc(w.endTs), "UTC+00:00",
                    csvField(w.sport), num(w.strain?.let { it / (100.0 / 21.0) }), num(w.energyKcal), num(w.maxHr), num(w.avgHr),
                    num(zones?.get(0)), num(zones?.get(1)), num(zones?.get(2)),
                    num(zones?.get(3)), num(zones?.get(4)),
                    num(w.distanceM), csvField(sourceLabel(w)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** journal_entries.csv. The importer reads the answer as a yes/no parse where "true" → true,
     *  so the answer column MUST be the literal "true"/"false" — never prettify it to Yes/No. */
    internal fun journalCsv(rows: List<JournalEntry>): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes\r\n")
        for (e in rows.sortedWith(compareBy({ it.day }, { it.question }))) {
            sb.append(
                listOf(
                    e.day + " 00:00:00", "UTC+00:00", csvField(e.question),
                    if (e.answeredYes) "true" else "false",
                    csvField(e.notes),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** Full-fidelity metricSeries dump ({deviceId, day, key, value}). Sidecar only — the importers
     *  deliberately ignore it (they read only the four CSVs). Sorted for a stable, diffable file. */
    internal fun metricSeriesJson(rows: List<MetricSeriesRow>): String {
        val arr = JSONArray()
        for (r in rows.sortedWith(compareBy({ it.deviceId }, { it.day }, { it.key }))) {
            arr.put(
                JSONObject()
                    .put("deviceId", r.deviceId)
                    .put("day", r.day)
                    .put("key", r.key)
                    .put("value", r.value),
            )
        }
        return arr.toString(2)
    }

    /** Zip the named entries into a single byte array (everything is already in memory). */
    internal fun zipBytes(entries: Map<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            for ((name, bytes) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    /**
     * UI entry point: serialize the merged WHOOP history (imported wins per day — exactly what the
     * dashboards show; Apple Health / Health Connect rows are deliberately EXCLUDED so a re-import
     * can't mis-attribute them as WHOOP data) and write a zip to [uri]. Returns a human summary for
     * the toast.
     *
     * [deviceId] is the registry's ACTIVE strap id (SPINE / #814) and has NO default on purpose
     * (#458): the old `= "my-whoop"` default meant a live-BLE install — whose engine banks computed
     * scores under `"<strapId>-noop"` — exported `0 days, 0 sleeps, 0 journal entries` while the app
     * displayed months of history. It survived the #359 sweep because that grep targeted the
     * hardcoded `"my-whoop-noop"` string, not default parameters. Every read below goes through the
     * active∪canonical union resolvers ([WhoopRepository.importedSourceIds] /
     * [WhoopRepository.computedSourceIds]), so BOTH install shapes export in full: live-BLE rows
     * under the strap id AND canonical `"my-whoop"` rows from a prior CSV import (a single-canonical
     * install collapses to one id, byte-identical to before).
     */
    suspend fun exportZip(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String,
    ): String {
        val hi = System.currentTimeMillis() / 1000 + 86_400
        // physiological_cycles keys each row by the LOCAL calendar day (analyze, #277); the sleeps
        // "Cycle start time" must use the SAME local end-day so the two CSVs reconcile by cycle — else a
        // non-UTC user's night lands on a different date in each file (#715). Current device offset,
        // matching how analyze bucketed the stored days.
        val tzOffsetSec = java.time.ZoneId.systemDefault().rules.getOffset(java.time.Instant.now()).totalSeconds.toLong()

        // The active∪canonical union ids (#458): active strap FIRST, so a per-row dedup keeps the
        // live/measured copy; a single-canonical install collapses to one id each.
        val importedIds = repo.importedSourceIds(deviceId)
        val computedIds = repo.computedSourceIds(deviceId)

        // Daily: the same imported-wins merge the dashboards show (daysMerged resolves the union
        // internally); a day present under ANY imported source is "import", otherwise it came from
        // the on-device computed source.
        val daily = repo.daysMerged(deviceId)
        val importedDays = importedIds.flatMap { repo.days(it) }.map { it.day }.toHashSet()
        val sourceByDay = daily.associate { d ->
            d.day to if (d.day in importedDays) "import" else "noop (APPROXIMATE)"
        }

        val sleeps = repo.sleepSessionsMerged(deviceId, 0L, hi)
        // Workouts: imported WHOOP ∪ on-device detected (which carries the "-noop" device id), each
        // side read across its union ids (#458). Apple Health / Health Connect workouts are
        // intentionally omitted, matching the cycles/sleep cut. Dedup by (startTs, sport), imported
        // first so it wins — the same session can exist under both sides (e.g. a reimported export +
        // BLE re-detection), which double-counted it in the CSV and inflated totals on reimport.
        // (PR #97 review, tigercraft4. Swift parity.)
        val seenWorkouts = HashSet<String>()
        val workouts = (repo.workoutsUnion(deviceId, 0L, hi) + repo.detectedWorkoutsUnion(deviceId, 0L, hi))
            .filter { seenWorkouts.add("${it.startTs}|${it.sport}") }
        // Journal lives under the imported ids. Native in-app journal logging (a separate feature on
        // its own device id) isn't read here, keeping the exporter self-contained; the imported
        // journal is the WHOOP-sourced history the round-trip targets. Dedup by the row's natural key
        // (day, question), active-first.
        val seenJournal = HashSet<String>()
        val journal = importedIds.flatMap { repo.journal(it, "0000-01-01", "9999-12-31") }
            .filter { seenJournal.add("${it.day}|${it.question}") }

        // Cycles columns recovered from the imported metricSeries: per (day, key) the FIRST union id
        // that has a value wins (active strap first), mirroring the read-side precedence.
        val seriesByDay = HashMap<String, MutableMap<String, Double>>()
        for (key in listOf("sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min")) {
            for (id in importedIds) {
                for (p in repo.metricSeries(id, key, "0000-01-01", "9999-12-31")) {
                    val row = seriesByDay.getOrPut(p.day) { HashMap() }
                    if (key !in row) row[key] = p.value
                }
            }
        }
        // Sidecar: every metricSeries row under every NOOP source id, full fidelity (rows carry their
        // own deviceId, so union duplicates stay distinguishable on re-import).
        val sidecarRows = buildList {
            for (id in importedIds + computedIds) {
                for (key in repo.metricKeys(id)) {
                    addAll(repo.metricSeries(id, key, "0000-01-01", "9999-12-31"))
                }
            }
        }

        // Classify a workout for the parser-ignored Source column. The on-device detected workouts
        // carry the "-noop" device id; manual logging uses source "manual"; everything else is an
        // imported WHOOP row.
        fun workoutSource(w: WorkoutRow): String = when {
            w.deviceId.endsWith("-noop") -> "noop (APPROXIMATE)"
            w.source == "manual" -> "manual"
            else -> "import"
        }

        val zip = zipBytes(
            linkedMapOf(
                "physiological_cycles.csv" to cyclesCsv(daily, seriesByDay, sourceByDay).toByteArray(),
                "sleeps.csv" to sleepsCsv(
                    sleeps,
                    cycleStart = { com.noop.analytics.AnalyticsEngine.dayString(it.endTs, tzOffsetSec) + " 00:00:00" },
                ) { s ->
                    if (s.deviceId.endsWith("-noop")) "noop (APPROXIMATE)" else "import"
                }.toByteArray(),
                "workouts.csv" to workoutsCsv(workouts, ::workoutSource).toByteArray(),
                "journal_entries.csv" to journalCsv(journal).toByteArray(),
                "noop_metric_series.json" to metricSeriesJson(sidecarRows).toByteArray(),
            ),
        )
        context.contentResolver.openOutputStream(uri)?.use { it.write(zip); it.flush() }
            ?: throw IOException("Could not open the chosen file for writing.")
        return "Exported ${daily.size} days, ${sleeps.size} sleeps, ${workouts.size} workouts, " +
            "${journal.size} journal entries."
    }

    /**
     * The absolute skin temperature for the `Skin temp (celsius)` column: [DailyMetric.skinTempC] when the row
     * has it, otherwise [DailyMetric.skinTempDevC] only when it is itself an absolute (the shape older WHOOP
     * imports stored). A true deviation is never written as a temperature. Twin of the Swift
     * `WhoopCsvExporter.exportedSkinTempCelsius`.
     */
    internal fun exportedSkinTempCelsius(d: DailyMetric): Double? =
        d.skinTempC ?: d.skinTempDevC?.takeIf { VitalBands.isAbsoluteSkinTemp(it) }
}
