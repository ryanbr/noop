package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.ZipInputStream
import kotlin.math.roundToInt

/**
 * Imports a WHOOP CSV export (the four-CSV bundle, zipped or loose) into the local Room store.
 *
 * This is the Android port of the macOS source of truth
 * `Packages/StrandImport/Sources/StrandImport/WhoopExportImporter.swift`
 * (with `CSVParsing.swift` ported in [CsvParser.kt]). The CSV column mapping is reproduced
 * faithfully: same columns -> same fields, same header normalization + aliases, same
 * timezone-aware date parsing, same "(cal)" == kcal unit handling, same row-skip rules.
 *
 * Differences are only in the SINK: the Swift importer returns normalized model arrays;
 * here we map those same rows onto the verified Room entities (com.noop.data) and upsert
 * through [WhoopRepository]. All WHOOP rows are written under deviceId "my-whoop".
 *
 * Recognised filenames (case-insensitive, matched anywhere in a zip tree, exactly as Swift):
 *   physiological_cycles.csv  -> DailyMetric  (master daily summary)
 *   sleeps.csv                -> SleepSession + folds sleep fields into DailyMetric
 *   workouts.csv              -> WorkoutRow(source = "my-whoop")
 *   journal_entries.csv       -> JournalEntry
 *
 * The whole pipeline is tolerant: missing files / columns / blank cells degrade gracefully.
 */
object WhoopCsvImporter {

    private const val WHOOP_DEVICE = "my-whoop"
    private const val SOURCE_LABEL = "WHOOP"

    private const val CYCLES_NAME = "physiological_cycles.csv"
    private const val SLEEPS_NAME = "sleeps.csv"
    private const val WORKOUTS_NAME = "workouts.csv"
    private const val JOURNAL_NAME = "journal_entries.csv"

    /** Per-CSV uncompressed ceiling (zip-bomb guard). Mirrors Swift maxEntryBytes = 256 MB. */
    private const val MAX_ENTRY_BYTES = 256L shl 20

    /** Aggregate RAM ceiling across ALL retained CSVs from one import. The per-entry cap bounds a single
     *  file but NOT the sum of the retained set — this backstops a crafted export from accumulating
     *  unbounded ByteArray in the map before parsing. A real WHOOP bundle is a few MB, so 1 GB never trips
     *  in practice. Mirrors the Swift WhoopExportImporter.maxTotalBytes (#70). */
    internal const val MAX_TOTAL_BYTES = 1L shl 30

    /**
     * Charge/Effort/Rest redesign (2026-06-12): WHOOP "Day Strain" is on WHOOP's 0–21 scale, but
     * NOOP's "Effort" score lives on 0–100 (StrainScorer.maxStrain = 100). Rescale an imported Day
     * Strain by 100/21 when writing the `strain` metric so imported history sits on the same axis as
     * live-computed Effort. Keep byte-identical to Swift
     * (WhoopExportImporter.dayStrainToEffortScale).
     */
    private const val DAY_STRAIN_TO_EFFORT_SCALE = 100.0 / 21.0

    /**
     * WHOOP CSVs carry "Sleep efficiency %" on a 0–100 scale, but NOOP's `efficiency` columns store
     * the 0–1 fraction the native pipeline writes (AnalyticsEngine: actual-sleep ÷ in-bed). Divide at
     * the WRITE boundary — the verbatim parsed value stays untouched, same shape as the Day Strain
     * rescale above. Keep byte-identical to Swift (WhoopExportImporter.fractionFromImportedEfficiencyPct).
     */
    private fun efficiencyFractionFromPct(pct: Double?): Double? = pct?.let { it / 100.0 }

    private val DAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    /**
     * Public entry point the UI calls.
     *
     * Accepts either a `.zip` containing the WHOOP CSVs, or a single `.csv` (routed by
     * its filename, falling back to header sniffing when the name is unrecognised).
     * Reads the SAF [uri] via the content resolver. Upserts everything via [repo] under
     * [deviceId] (defaults to "my-whoop"), then returns an [ImportSummary] keyed by table.
     */
    suspend fun importZip(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = WHOOP_DEVICE,
    ): ImportSummary {
        val (csvData, truncated) = try {
            loadCsvData(context, uri)
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read export: ${e.message ?: "unknown error"}")
        }

        if (csvData.isEmpty()) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No WHOOP CSVs found (expected physiological_cycles.csv, sleeps.csv, workouts.csv or journal_entries.csv)."
            )
        }

        val cycles = csvData[CYCLES_NAME]?.let { parseCycles(CsvTable.fromData(it), deviceId) } ?: emptyList()
        val cycleSeries = csvData[CYCLES_NAME]?.let { parseCycleSeries(CsvTable.fromData(it), deviceId) } ?: emptyList()
        val sleepParse = csvData[SLEEPS_NAME]?.let { parseSleeps(CsvTable.fromData(it), deviceId) }
        val sleepSessions = sleepParse?.sessions ?: emptyList()
        val sleepDaily = sleepParse?.daily ?: emptyList()
        val workouts = csvData[WORKOUTS_NAME]?.let { parseWorkouts(CsvTable.fromData(it), deviceId) } ?: emptyList()
        // #136: journal rows key only by cycle_start; map that to the cycle's wake day so entries land on
        // the same day as their recovery/sleep outcome (else they read one day early and never correlate).
        val journalWake = csvData[CYCLES_NAME]?.let { journalWakeDayMap(CsvTable.fromData(it)) } ?: emptyMap()
        val journal = csvData[JOURNAL_NAME]?.let { parseJournal(CsvTable.fromData(it), deviceId, journalWake) } ?: emptyList()

        // Merge cycle-derived and sleep-derived daily rows on (deviceId, day): cycle fields
        // (recovery / strain / RHR / HRV / SpO2 / skin-temp / resp) win where present, sleep
        // fields fill the architecture columns. One DailyMetric per day, matching the PK.
        val daily = mergeDaily(cycles, sleepDaily)

        if (daily.isEmpty() && sleepSessions.isEmpty() && workouts.isEmpty() && journal.isEmpty()) {
            return ImportSummary.failure(SOURCE_LABEL, "Export contained no usable WHOOP rows.")
        }

        repo.upsertDevice(deviceId, name = "WHOOP")
        if (daily.isNotEmpty()) repo.upsertDailyMetrics(daily)
        if (sleepSessions.isNotEmpty()) repo.upsertSleepSessions(sleepSessions)
        if (workouts.isNotEmpty()) repo.upsertWorkouts(workouts)
        if (journal.isNotEmpty()) {
            // #136: the wake-day fix moves an entry's day, so a naive re-import would leave the pre-fix
            // onset-keyed rows behind as duplicates. Atomically clear + re-write EXACTLY the day span we
            // import ([min, max] of its days), so journal outside the imported range (e.g. from an earlier,
            // wider export) is never touched, and a crash mid-import can't drop the range. Same
            // "re-import replaces this period" semantics daily/sleep already have.
            val jDays = journal.map { it.day }
            repo.replaceJournalRange(deviceId, jDays.min(), jDays.max(), journal)
        }
        if (cycleSeries.isNotEmpty()) repo.upsertMetricSeries(cycleSeries)

        val counts = LinkedHashMap<String, Int>()
        if (daily.isNotEmpty()) counts["dailyMetric"] = daily.size
        if (sleepSessions.isNotEmpty()) counts["sleepSession"] = sleepSessions.size
        if (workouts.isNotEmpty()) counts["workout"] = workouts.size
        if (journal.isNotEmpty()) counts["journal"] = journal.size
        if (cycleSeries.isNotEmpty()) counts["metricSeries"] = cycleSeries.size

        // Date span across everything we wrote.
        val days = ArrayList<String>()
        days.addAll(daily.map { it.day })
        days.addAll(journal.map { it.day })
        days.addAll(sleepSessions.map { epochSecondsToDay(it.startTs) })
        days.addAll(workouts.map { epochSecondsToDay(it.startTs) })
        val firstDay = days.minOrNull()
        val lastDay = days.maxOrNull()

        val total = counts.values.sum()
        val message = buildString {
            append("Imported ")
            append(total)
            append(" WHOOP rows")
            if (firstDay != null && lastDay != null) append(" ($firstDay → $lastDay)")
            append(".")
            // #70: never silently truncate. If the aggregate RAM budget tripped, the retained CSV set was
            // partial — say so plainly instead of reporting a clean import over incomplete data.
            if (truncated) append(" (partial — export exceeded the ${MAX_TOTAL_BYTES shr 30} GB import memory budget)")
        }

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = message,
            columnCoverage = importColumnCoverage(cycles),
            columnCoverageRows = cycles.size,
        )
    }

    // MARK: - Locate + load CSVs

    /**
     * Return `[lowercasedFilename -> rawBytes]` for every recognised WHOOP CSV in the input.
     * Accepts a `.zip` (iterated with [ZipInputStream], routed by base filename) or a single
     * `.csv`. Mirrors Swift `loadCSVData` filename routing.
     */
    private fun loadCsvData(
        context: Context,
        uri: Uri,
        maxTotalBytes: Long = MAX_TOTAL_BYTES,
    ): Pair<Map<String, ByteArray>, Boolean> {
        val wanted = setOf(CYCLES_NAME, SLEEPS_NAME, WORKOUTS_NAME, JOURNAL_NAME)
        val result = LinkedHashMap<String, ByteArray>()
        var total = 0L
        var truncated = false

        // First attempt: treat as a zip. WHOOP exports are zips; this also covers a .zip Uri
        // whose displayName we cannot read. If the stream is not a valid zip, ZipInputStream
        // yields no entries and we fall through to single-CSV handling.
        val firstBytes: ByteArray = context.contentResolver.openInputStream(uri)?.use { it.readAllCapped(MAX_ENTRY_BYTES) }
            ?: throw IllegalStateException("Could not open input stream for $uri")

        if (looksLikeZip(firstBytes)) {
            firstBytes.inputStream().use { raw ->
                ZipInputStream(raw).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        if (!entry.isDirectory) {
                            val base = baseName(entry.name).lowercase()
                            // Only inspect CSVs (skip the export's GPX/ECG/other files).
                            if (base.endsWith(".csv")) {
                                val declared = entry.size // -1 when unknown
                                if (declared <= MAX_ENTRY_BYTES) {
                                    val bytes = zis.readEntryCapped(MAX_ENTRY_BYTES)
                                    if (bytes != null && bytes.isNotEmpty()) {
                                        // Route by English name, then a localized filename alias
                                        // (e.g. German Schlaf.csv), then by header content. This is
                                        // what lets non-English WHOOP exports import (issue #3).
                                        val canonical = when {
                                            base in wanted -> base
                                            else -> localizedAlias(base) ?: sniffCsvKind(bytes)
                                        }
                                        if (canonical != null && !result.containsKey(canonical)) {
                                            if (total + bytes.size > maxTotalBytes) { truncated = true; break }
                                            result[canonical] = bytes
                                            total += bytes.size
                                        }
                                    }
                                }
                            }
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                    }
                }
            }
            if (result.isNotEmpty()) return result to truncated
        }

        // Not a (useful) zip — treat the input as a single CSV. Route by display name; if the
        // name is unknown, sniff the header row to identify which WHOOP CSV it is.
        val name = displayName(context, uri)?.lowercase()
        val routed = when {
            name != null && baseName(name) in wanted -> baseName(name)
            name != null && localizedAlias(baseName(name)) != null -> localizedAlias(baseName(name))
            else -> sniffCsvKind(firstBytes)
        }
        if (routed != null) {
            result[routed] = firstBytes
        }
        return result to false   // single-CSV path holds one file — the budget can't trip here
    }

    /** Whether the leading bytes are a local-file-header zip signature ("PK"). */
    private fun looksLikeZip(bytes: ByteArray): Boolean =
        bytes.size >= 4 &&
            bytes[0] == 0x50.toByte() && bytes[1] == 0x4B.toByte() &&
            bytes[2] == 0x03.toByte() && bytes[3] == 0x04.toByte()

    /** Identify a loose CSV by its header columns when the filename is unhelpful. */
    private fun sniffCsvKind(bytes: ByteArray): String? {
        val table = CsvTable.fromData(bytes)
        val h = table.normalizedHeaders.toHashSet()
        return when {
            "activity_name" in h || "workout_start_time" in h -> WORKOUTS_NAME
            "question_text" in h || "answered_yes_no" in h || "question" in h -> JOURNAL_NAME
            "nap" in h && ("sleep_onset" in h || "wake_onset" in h) -> SLEEPS_NAME
            "cycle_start_time" in h || "recovery_score_pct" in h || "day_strain" in h -> CYCLES_NAME
            "sleep_onset" in h || "asleep_duration_min" in h -> SLEEPS_NAME
            else -> null
        }
    }

    /**
     * Map a known localized WHOOP export filename to its canonical English name. WHOOP localizes
     * the CSV filenames in non-English exports (issue #3), so a German export ships Schlaf.csv,
     * Trainings.csv, physiologische_zyklen.csv and logbuch_eintraege.csv. Header-content sniffing
     * still covers any language whose column headers stay English.
     */
    private fun localizedAlias(base: String): String? = when (base) {
        // German (app.whoop.com → Daten exportieren)
        "physiologische_zyklen.csv" -> CYCLES_NAME
        "schlaf.csv" -> SLEEPS_NAME
        "trainings.csv" -> WORKOUTS_NAME
        "logbuch_eintraege.csv" -> JOURNAL_NAME
        // Spanish (issue #76): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        // Folded + unfolded variants — the filename is lowercased but not diacritic-folded.
        "sueño.csv", "sueno.csv" -> SLEEPS_NAME
        "entrenamientos.csv" -> WORKOUTS_NAME
        // French (issue #79): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        "sommeil.csv" -> SLEEPS_NAME
        "entrainements.csv", "entraînements.csv" -> WORKOUTS_NAME
        // Brazilian Portuguese (issue #692): unlike es/fr, WHOOP localizes ALL FOUR filenames here,
        // cycles included. Names from a real pt-BR export. Folded + unfolded variants because the
        // filename is lowercased but not diacritic-folded; header sniffing is the backstop if it mojibakes.
        "ciclos_fisiológicos.csv", "ciclos_fisiologicos.csv" -> CYCLES_NAME
        "sonos.csv" -> SLEEPS_NAME
        "treinos.csv" -> WORKOUTS_NAME
        "entradas_diário.csv", "entradas_diario.csv" -> JOURNAL_NAME
        else -> null
    }

    private fun baseName(path: String): String {
        val cleaned = path.replace('\\', '/')
        val slash = cleaned.lastIndexOf('/')
        return if (slash >= 0) cleaned.substring(slash + 1) else cleaned
    }

    private fun displayName(context: Context, uri: Uri): String? {
        // Try the OpenableColumns display name; fall back to the last path segment.
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    val n = c.getString(idx)
                    if (!n.isNullOrEmpty()) return n
                }
            }
        } catch (_: Exception) {
            // ignore — fall through
        }
        return uri.lastPathSegment
    }

    // MARK: - physiological_cycles.csv -> DailyMetric

    internal fun parseCycles(table: CsvTable, deviceId: String): List<DailyMetric> {
        val out = ArrayList<DailyMetric>(table.rows.size)
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val cycleEnd = WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)

            // Skip rows with no usable timestamp at all.
            if (cycleStart == null && cycleEnd == null && wakeOnset == null) continue
            // WHOOP cycles are onset-to-onset: cycle_start_time == the sleep onset (the EVENING). Key
            // the day off the WAKE (wake_onset), then cycle_end (the next onset, same wake-day), then
            // the start. Matches parseSleeps + mergeSleep + macOS; keying off the start put scores a day
            // early and blanked Today for import-only users (import day-shift, v8.2.1).
            val day = epochSecondsToDay(wakeOnset ?: cycleEnd ?: cycleStart!!, tz)

            // Same aliases / unit handling as Swift parseCycles.
            val recovery = row.double("recovery_score_pct")
            val restingHr = row.double("resting_heart_rate_bpm", "resting_heart_rate")
            val avgHrv = row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms")
            val skinTemp = row.double("skin_temp_celsius", "skin_temp_f")
            val spo2 = row.double("blood_oxygen_pct", "blood_oxygen_pct_pct")
            val strain = row.double("day_strain")
            val resp = row.double("respiratory_rate_rpm", "respiratory_rate")

            val asleepMin = row.double("asleep_duration_min")
            val lightMin = row.double("light_sleep_duration_min")
            val deepMin = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            val remMin = row.double("rem_duration_min")
            val awakeMin = row.double("awake_duration_min")
            val efficiency = row.double("sleep_efficiency_pct")

            out.add(
                DailyMetric(
                    deviceId = deviceId,
                    day = day,
                    totalSleepMin = asleepMin,
                    efficiency = efficiencyFractionFromPct(efficiency),
                    deepMin = deepMin,
                    remMin = remMin,
                    lightMin = lightMin,
                    // "awake_duration_min" -> disturbances slot (Whoop's disturbance count is
                    // not a separate cycles column; awake minutes are the nearest faithful proxy).
                    disturbances = awakeMin?.roundToInt(),
                    restingHr = restingHr?.roundToInt(),
                    avgHrv = avgHrv,
                    recovery = recovery,
                    // Rescale WHOOP's 0–21 Day Strain onto NOOP's 0–100 Effort axis (see
                    // DAY_STRAIN_TO_EFFORT_SCALE). nil passes through.
                    strain = strain?.let { it * DAY_STRAIN_TO_EFFORT_SCALE },
                    exerciseCount = null, // not present in physiological_cycles.csv
                    spo2Pct = spo2,
                    skinTempDevC = skinTemp,
                    respRateBpm = resp,
                )
            )
        }
        return out
    }

    /**
     * physiological_cycles.csv -> long-format metricSeries rows for the export-verbatim sleep
     * figures the wide DailyMetric has no columns for. Keys mirror the macOS WhoopImporter
     * (Strand/Data/WhoopImporter.swift): sleep_performance / sleep_consistency are 0–100 %,
     * sleep_need_min / sleep_debt_min are minutes. Internal + pure so it is JVM unit-testable
     * (WhoopCycleSeriesTest).
     */
    internal fun parseCycleSeries(table: CsvTable, deviceId: String): List<MetricSeriesRow> {
        val out = ArrayList<MetricSeriesRow>()
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val cycleEnd = WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)
            if (cycleStart == null && cycleEnd == null && wakeOnset == null) continue   // same skip rule as parseCycles
            // Wake-day keying — see parseCycles (WHOOP cycle_start is the evening onset, v8.2.1).
            val day = epochSecondsToDay(wakeOnset ?: cycleEnd ?: cycleStart!!, tz)
            fun add(key: String, v: Double?) { if (v != null) out.add(MetricSeriesRow(deviceId, day, key, v)) }
            add("sleep_performance", row.double("sleep_performance_pct"))
            add("sleep_consistency", row.double("sleep_consistency_pct"))
            add("sleep_need_min", row.double("sleep_need_min"))
            add("sleep_debt_min", row.double("sleep_debt_min"))
        }
        return out
    }

    // MARK: - sleeps.csv -> SleepSession (+ DailyMetric sleep fields)

    internal class SleepParse(
        val sessions: List<SleepSession>,
        val daily: List<DailyMetric>,
    )

    internal fun parseSleeps(table: CsvTable, deviceId: String): SleepParse {
        val sessions = ArrayList<SleepSession>(table.rows.size)
        val daily = ArrayList<DailyMetric>()
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val sleepOnset = WhoopTime.parseEpochSeconds(row.cell("sleep_onset"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)

            // Swift skip rule: cycleStart == nil && sleepOnset == nil && wakeOnset == nil.
            if (cycleStart == null && sleepOnset == null && wakeOnset == null) continue

            val isNap = row.bool("nap") ?: false

            val efficiency = row.double("sleep_efficiency_pct")
            val resp = row.double("respiratory_rate_rpm", "respiratory_rate")
            val asleepMin = row.double("asleep_duration_min")
            val lightMin = row.double("light_sleep_duration_min")
            val deepMin = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            val remMin = row.double("rem_duration_min")
            val awakeMin = row.double("awake_duration_min")

            // SleepSession PK is (deviceId, startTs). Prefer the actual sleep onset, then cycle
            // start. endTs prefers wake_onset; if absent derive from in-bed/asleep minutes.
            val startTs = sleepOnset ?: cycleStart
            if (startTs != null) {
                val inBedMin = row.double("in_bed_duration_min")
                val derivedEnd = startTs + ((inBedMin ?: asleepMin ?: 0.0) * 60.0).toLong()
                val endTs = wakeOnset ?: derivedEnd
                sessions.add(
                    SleepSession(
                        deviceId = deviceId,
                        startTs = startTs,
                        endTs = if (endTs >= startTs) endTs else startTs,
                        efficiency = efficiencyFractionFromPct(efficiency),
                        restingHr = null, // resting HR is a cycles/recovery field, not in sleeps.csv
                        avgHrv = null,    // HRV likewise is a recovery field, not in sleeps.csv
                        stagesJSON = stagesJson(lightMin, deepMin, remMin, awakeMin),
                    )
                )
            }

            // Fold the MAIN sleep (not naps) into a DailyMetric keyed on the sleep's WAKE day, so the
            // sleep-architecture columns are populated even when physiological_cycles.csv is absent.
            // Key off wake_onset: sleep_onset (== cycle_start_time in a WHOOP export) is the PREVIOUS
            // evening, and mergeDaily groups by day-string. parseCycles now keys its cycle rows off the
            // wake too (v8.2.1), so the two align on the same wake-day and merge into one row; keying
            // either off the onset landed the night a day early and split it across two rows. Every
            // convention (sleep-session mergeSleep, the AppleHealth importer, macOS) uses the local
            // wake-day; align with it. Naps stay excluded above.
            if (!isNap) {
                val dayTs = wakeOnset ?: cycleStart ?: sleepOnset
                if (dayTs != null) {
                    daily.add(
                        DailyMetric(
                            deviceId = deviceId,
                            day = epochSecondsToDay(dayTs, tz),
                            totalSleepMin = asleepMin,
                            efficiency = efficiencyFractionFromPct(efficiency),
                            deepMin = deepMin,
                            remMin = remMin,
                            lightMin = lightMin,
                            disturbances = awakeMin?.roundToInt(),
                            restingHr = null,
                            avgHrv = null,
                            recovery = null,
                            strain = null,
                            exerciseCount = null,
                            spo2Pct = null,
                            skinTempDevC = null,
                            respRateBpm = resp,
                        )
                    )
                }
            }
        }
        return SleepParse(sessions, daily)
    }

    // MARK: - workouts.csv -> WorkoutRow

    private fun parseWorkouts(table: CsvTable, deviceId: String): List<WorkoutRow> {
        val out = ArrayList<WorkoutRow>(table.rows.size)
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val workoutStart = WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), tz)
            val workoutEnd = WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), tz)

            // Swift skip rule: workoutStart == nil && workoutEnd == nil && cycleStart == nil.
            if (workoutStart == null && workoutEnd == null && cycleStart == null) continue

            val startTs = workoutStart ?: cycleStart ?: workoutEnd!!
            val sport = row.cell("activity_name") ?: "Workout" // PK component; never blank.

            // Workout strain is also WHOOP's 0–21 scale → rescale onto NOOP's 0–100 Effort axis so
            // imported workouts match detected/manual ones (StrainScorer now scores 0–100).
            val strain = row.double("activity_strain")?.let { it * DAY_STRAIN_TO_EFFORT_SCALE }
            val energyKcal = row.double("energy_burned_cal") // CSV "(cal)" == kcal
            val avgHr = row.double("average_hr_bpm", "average_heart_rate_bpm")
            val maxHr = row.double("max_hr_bpm", "max_heart_rate_bpm")

            val z1 = row.double("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct")
            val z2 = row.double("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct")
            val z3 = row.double("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct")
            val z4 = row.double("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct")
            val z5 = row.double("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct")

            val distance = row.double("distance_meters", "distance_meter")

            // durationS: prefer explicit end-start, else null.
            val durationS: Double? = if (workoutEnd != null && workoutStart != null && workoutEnd >= workoutStart) {
                (workoutEnd - workoutStart).toDouble()
            } else null

            // endTs for the row: workoutEnd, else start + duration, else start.
            val endTs = workoutEnd ?: (startTs + (durationS ?: 0.0).toLong())

            out.add(
                WorkoutRow(
                    deviceId = deviceId,
                    startTs = startTs,
                    endTs = if (endTs >= startTs) endTs else startTs,
                    sport = sport,
                    source = WHOOP_DEVICE, // required by the task: source = "my-whoop"
                    durationS = durationS,
                    energyKcal = energyKcal,
                    avgHr = avgHr?.roundToInt(),
                    maxHr = maxHr?.roundToInt(),
                    strain = strain,
                    distanceM = distance,
                    zonesJSON = zonesJson(z1, z2, z3, z4, z5),
                    notes = null,
                )
            )
        }
        return out
    }

    // MARK: - journal_entries.csv -> JournalEntry

    /** #136: map each cycle's onset (cycle_start_time epoch) to its WAKE day, so journal entries — which
     *  the export keys only by cycle_start — store on the same wake day as the cycle's recovery/sleep
     *  outcome (and the native journal), not the onset evening. Same day rule as parseCycles. */
    internal fun journalWakeDayMap(cycles: CsvTable): Map<Long, String> {
        val out = HashMap<Long, String>()
        for (row in cycles.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val start = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz) ?: continue
            val wake = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)
                ?: WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
                ?: continue
            out[start] = epochSecondsToDay(wake, tz)
        }
        return out
    }

    internal fun parseJournal(
        table: CsvTable,
        deviceId: String,
        wakeDayByStart: Map<Long, String> = emptyMap(),
    ): List<JournalEntry> {
        val out = ArrayList<JournalEntry>(table.rows.size)
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val question = row.cell("question_text", "question")
            // #631: the REAL WHOOP export header is "Answered yes" (-> answered_yes), not the
            // "Answered yes/no" NOOP's own exporter writes (-> answered_yes_no). Every real WHOOP
            // journal import silently zeroed out to "without" because neither of the old keys ever
            // matched, regardless of the account's actual answers.
            val answer = row.cell("answered_yes", "answered_yes_no", "answer", "answer_text")
            val notes = row.cell("notes")

            // Swift: a journal row is only meaningful if it has a question/answer/notes.
            if (question == null && answer == null && notes == null) continue
            // Our JournalEntry PK is (deviceId, day, question); a question is required to store.
            if (question == null) continue

            // #136: journal_entries.csv carries only cycle_start (the onset evening), no wake time. Key the
            // entry to the cycle's WAKE day — the same day parseCycles/parseSleeps and the native journal
            // use — via wakeDayByStart, so it lines up with the recovery/sleep outcome Insights correlates
            // it against. Without this every imported entry sat one day early and never matched its outcome,
            // so all historic days collapsed into "Without". Fall back to the onset day only when the cycle
            // row isn't in the export.
            val day = cycleStart?.let { wakeDayByStart[it] ?: epochSecondsToDay(it, tz) }
                ?: epochSecondsToDay(System.currentTimeMillis() / 1000)

            val answeredYes = parseYesNo(answer)

            out.add(
                JournalEntry(
                    deviceId = deviceId,
                    day = day,
                    question = question,
                    answeredYes = answeredYes,
                    notes = notes,
                )
            )
        }
        return out
    }

    // MARK: - Merge helpers

    /**
     * Merge cycle-derived and sleep-derived daily rows on (deviceId, day). Cycle fields take
     * precedence (they carry recovery/strain/RHR/HRV/SpO2/skin-temp); sleep rows fill any sleep
     * architecture columns the cycle row left null. One row per (deviceId, day) to honour the PK.
     */
    internal fun mergeDaily(cycles: List<DailyMetric>, sleepDaily: List<DailyMetric>): List<DailyMetric> {
        if (sleepDaily.isEmpty()) return dedupeByDay(cycles, preferFirst = true)
        if (cycles.isEmpty()) return dedupeByDay(sleepDaily, preferFirst = true)

        val byDay = LinkedHashMap<String, DailyMetric>()
        // Seed with sleep rows first (lower precedence), then overlay cycle rows.
        for (s in sleepDaily) {
            val key = s.day
            byDay[key] = byDay[key]?.let { mergeRow(it, s) } ?: s
        }
        for (c in cycles) {
            val key = c.day
            val existing = byDay[key]
            byDay[key] = if (existing == null) c else mergeRow(existing, c)
        }
        return byDay.values.toList()
    }

    /** Collapse rows that share a day, keeping the first non-null field per column. */
    private fun dedupeByDay(rows: List<DailyMetric>, preferFirst: Boolean): List<DailyMetric> {
        val byDay = LinkedHashMap<String, DailyMetric>()
        for (r in rows) {
            val existing = byDay[r.day]
            byDay[r.day] = if (existing == null) r else if (preferFirst) mergeRow(existing, r) else mergeRow(r, existing)
        }
        return byDay.values.toList()
    }

    /** [base] wins for every non-null field; [fill] supplies values only where [base] is null. */
    private fun mergeRow(base: DailyMetric, fill: DailyMetric): DailyMetric = DailyMetric(
        deviceId = base.deviceId,
        day = base.day,
        totalSleepMin = base.totalSleepMin ?: fill.totalSleepMin,
        efficiency = base.efficiency ?: fill.efficiency,
        deepMin = base.deepMin ?: fill.deepMin,
        remMin = base.remMin ?: fill.remMin,
        lightMin = base.lightMin ?: fill.lightMin,
        disturbances = base.disturbances ?: fill.disturbances,
        restingHr = base.restingHr ?: fill.restingHr,
        avgHrv = base.avgHrv ?: fill.avgHrv,
        avgSdnn = base.avgSdnn ?: fill.avgSdnn,
        recovery = base.recovery ?: fill.recovery,
        strain = base.strain ?: fill.strain,
        exerciseCount = base.exerciseCount ?: fill.exerciseCount,
        spo2Pct = base.spo2Pct ?: fill.spo2Pct,
        skinTempDevC = base.skinTempDevC ?: fill.skinTempDevC,
        respRateBpm = base.respRateBpm ?: fill.respRateBpm,
    )

    // MARK: - JSON encoders (match DemoSeeder shapes)

    /** Stage-segments array `[{stage, min}]` (minutes), null if no stage data present. */
    private fun stagesJson(lightMin: Double?, deepMin: Double?, remMin: Double?, awakeMin: Double?): String? {
        if (lightMin == null && deepMin == null && remMin == null && awakeMin == null) return null
        val arr = JSONArray()
        fun seg(stage: String, min: Double?) {
            if (min != null) arr.put(JSONObject().put("stage", stage).put("min", min))
        }
        seg("light", lightMin)
        seg("deep", deepMin)
        seg("rem", remMin)
        seg("awake", awakeMin)
        return if (arr.length() == 0) null else arr.toString()
    }

    /** HR-zone-percentage object `{zone1..zone5}`, null if no zone data present. */
    private fun zonesJson(z1: Double?, z2: Double?, z3: Double?, z4: Double?, z5: Double?): String? {
        if (z1 == null && z2 == null && z3 == null && z4 == null && z5 == null) return null
        val obj = JSONObject()
        if (z1 != null) obj.put("zone1", z1)
        if (z2 != null) obj.put("zone2", z2)
        if (z3 != null) obj.put("zone3", z3)
        if (z4 != null) obj.put("zone4", z4)
        if (z5 != null) obj.put("zone5", z5)
        return if (obj.length() == 0) null else obj.toString()
    }

    private fun parseYesNo(raw: String?): Boolean {
        val t = raw?.trim()?.lowercase() ?: return false
        return t == "true" || t == "yes" || t == "1" || t == "y"
    }

    // MARK: - Day-string derivation

    /**
     * Convert wall-clock unix SECONDS to a "YYYY-MM-DD" day string at the given UTC offset
     * (minutes). The offset re-applies the source local-day boundary so a cycle that starts
     * at 23:30 local does not roll to the next UTC day.
     */
    private fun epochSecondsToDay(epochSeconds: Long, offsetMinutes: Int = 0): String {
        val offset = try {
            ZoneOffset.ofTotalSeconds(offsetMinutes * 60)
        } catch (_: Exception) {
            ZoneOffset.UTC
        }
        return Instant.ofEpochSecond(epochSeconds).atOffset(offset).toLocalDate().format(DAY_FMT)
    }
}

// MARK: - Stream helpers

/** Read a whole stream, throwing if it exceeds [cap] bytes (memory guard). */
private fun InputStream.readAllCapped(cap: Long): ByteArray {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        total += n
        if (total > cap) throw IllegalStateException("Input exceeds $cap bytes")
        buffer.write(chunk, 0, n)
    }
    return buffer.toByteArray()
}

/** Read the current zip entry, capping at [cap] bytes; returns null if it overflows. */
private fun ZipInputStream.readEntryCapped(cap: Long): ByteArray? {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        total += n
        if (total > cap) return null
        buffer.write(chunk, 0, n)
    }
    return buffer.toByteArray()
}
