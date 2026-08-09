package com.noop.ingest

import android.content.Context
import android.net.Uri
import android.util.Xml
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import java.io.BufferedInputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Apple Health export importer — Kotlin port of the macOS source of truth at
 * `Packages/StrandImport/Sources/StrandImport/AppleHealthImporter.swift`,
 * `AppleHealthAggregator.swift`, and `ImportModels.swift`.
 *
 * Reproduces FAITHFULLY:
 *  - the relevant `HKQuantityTypeIdentifier` / `HKCategoryTypeIdentifier` set and prefix stripping,
 *  - the `<Correlation>`-nested `<Record>` skip + `type|start|end|source|value` dedupe,
 *  - `OxygenSaturation` 0..1 fraction -> percent,
 *  - the `SleepAnalysis` category-value -> stage mapping,
 *  - per-day reduction rules (means for HR/HRV/SpO2/resp/walking/resting/avgHr, max for maxHr,
 *    sums for steps/active/basal, latest-by-end for VO2Max / BodyMass),
 *  - sample bucketing on the LOCAL day of `start`, sleep bucketing on the LOCAL day of `end`
 *    (the wake day), with `asleep = core + deep + rem + asleepUnspecified`.
 *
 * Streams with `Xml.newPullParser()` over the raw `InputStream` — never a DOM, never the whole
 * (multi-hundred-MB / multi-GB) file in memory. Aggregation is bucketed per day; per-day
 * accumulators hold running sums/counts (not raw sample arrays) so peak memory stays bounded by
 * the number of distinct days, not the number of records.
 *
 * Maps the macOS `AppleDailyAggregate` onto the Android Room schema (package `com.noop.data`):
 *  - AppleDaily(deviceId="apple-health"): steps, activeKcal, basalKcal, vo2max, avgHr, maxHr,
 *    walkingHr, weightKg
 *  - DailyMetric(deviceId="apple-health"): restingHr, avgHrv, totalSleepMin, deepMin, remMin,
 *    lightMin (= sleep core), spo2Pct, respRateBpm
 *  - WorkoutRow(source="apple-health"): one per `<Workout>` element
 *  - MetricSeriesRow(deviceId="apple-health"): the flattened (day, key, value) metric points
 *
 * Body-composition extras the macOS aggregator also computes (bodyFatPct, leanMassKg, bmi) have
 * no column in the Android schema and are intentionally dropped (only `weightKg` survives, in
 * AppleDaily). See `risks` in the task summary.
 */
object AppleHealthImporter {

    const val SOURCE_LABEL = "Apple Health"
    const val DEFAULT_DEVICE_ID = "apple-health"

    /**
     * Factory for the streaming pull-parser. Defaults to the Android framework's
     * `Xml.newPullParser()`. JVM unit tests (where `android.util.Xml` is a throwing stub) swap in a
     * kXML2 parser via `XmlPullParserFactory` so the sanitizer + tolerant-parse logic can be
     * exercised off-device. Production code never touches this.
     */
    @Volatile
    internal var newPullParser: () -> XmlPullParser = { Xml.newPullParser() }

    /** Health types Strand cares about (HK prefix already stripped). Mirrors `relevantTypes`. */
    private val RELEVANT_TYPES: Set<String> = setOf(
        "HeartRate",
        "RestingHeartRate",
        "HeartRateVariabilitySDNN",
        "WalkingHeartRateAverage",
        "OxygenSaturation",
        "BodyTemperature",
        "AppleSleepingWristTemperature",
        "RespiratoryRate",
        "ActiveEnergyBurned",
        "BasalEnergyBurned",
        "VO2Max",
        "StepCount",
        "SleepAnalysis",
        // Body composition
        "BodyMass",
        "BodyFatPercentage",
        "LeanBodyMass",
        "BodyMassIndex",
    )

    // ------------------------------------------------------------------------
    // Public entry point
    // ------------------------------------------------------------------------

    /**
     * Import an Apple Health export from a SAF [uri]. The uri may point at:
     *  - an `export.zip` (Apple nests the XML under `apple_health_export/export.xml`), or
     *  - a raw `export.xml`.
     *
     * The content is read via `context.contentResolver.openInputStream(uri)` and stream-parsed.
     * Aggregated rows are upserted into [repo] under [deviceId] (DailyMetric / AppleDaily /
     * MetricSeriesRow) and "apple-health" as `source` (WorkoutRow). Returns an [ImportSummary]
     * keyed by table name; on any failure returns [ImportSummary.failure].
     */
    suspend fun importExport(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = DEFAULT_DEVICE_ID,
    ): ImportSummary {
        val agg = Aggregator()
        try {
            context.contentResolver.openInputStream(uri)?.use { raw ->
                val buffered = BufferedInputStream(raw, 1 shl 16)
                if (isZip(buffered)) {
                    parseZip(buffered, agg)
                } else {
                    parseXml(buffered, agg)
                }
            } ?: return ImportSummary.failure(SOURCE_LABEL, "Could not open the selected file.")
        } catch (e: MissingExportXml) {
            return ImportSummary.failure(SOURCE_LABEL, "No export.xml found inside the archive.")
        } catch (e: Exception) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "Could not read the Apple Health export: ${e.message ?: e.javaClass.simpleName}",
            )
        }

        return persist(agg, repo, deviceId)
    }

    // ------------------------------------------------------------------------
    // Zip handling — locate export.xml anywhere in the archive and stream it.
    // ------------------------------------------------------------------------

    private class MissingExportXml : Exception()

    /** Peek the first 4 bytes for the local-file-header magic `PK`. */
    private fun isZip(input: BufferedInputStream): Boolean {
        input.mark(4)
        val sig = ByteArray(4)
        val n = input.read(sig, 0, 4)
        input.reset()
        if (n < 4) return false
        return sig[0] == 'P'.code.toByte() &&
            sig[1] == 'K'.code.toByte() &&
            sig[2].toInt() == 0x03 &&
            sig[3].toInt() == 0x04
    }

    /**
     * Stream the zip with [ZipInputStream], find the first entry whose basename is `export.xml`
     * (case-insensitive — Apple nests it under `apple_health_export/`), and stream-parse it WITHOUT
     * inflating to disk or RAM first. The entry stream is parsed directly off the inflating stream;
     * a guarded wrapper prevents the pull-parser from closing the underlying zip stream.
     */
    private fun parseZip(input: InputStream, agg: Aggregator) {
        val zip = ZipInputStream(input)
        var entry = zip.nextEntry
        while (entry != null) {
            if (!entry.isDirectory && baseName(entry.name).equals("export.xml", ignoreCase = true)) {
                parseXml(NonClosingInputStream(zip), agg)
                return
            }
            zip.closeEntry()
            entry = zip.nextEntry
        }
        throw MissingExportXml()
    }

    private fun baseName(path: String): String {
        val p = path.replace('\\', '/')
        val idx = p.lastIndexOf('/')
        return if (idx >= 0) p.substring(idx + 1) else p
    }

    /** Prevents the XML pull-parser from closing the shared underlying stream (the zip). */
    private class NonClosingInputStream(private val delegate: InputStream) : InputStream() {
        override fun read(): Int = delegate.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = delegate.read(b, off, len)
        override fun available(): Int = delegate.available()
        override fun close() { /* no-op: keep the zip stream open */ }
    }

    // ------------------------------------------------------------------------
    // Streaming XML parse (Xml.newPullParser / XmlPullParser).
    // ------------------------------------------------------------------------

    /**
     * Pull-parse the export, tracking `<Correlation>` nesting so `<Record>`s inside a correlation
     * are skipped (they also appear top-level). Dispatches each top-level `<Record>` and every
     * `<Workout>` straight into the [Aggregator], which buckets by day immediately — no per-record
     * objects are retained.
     */
    private fun parseXml(input: InputStream, agg: Aggregator) {
        // SANITIZER: wrap the (possibly decade-old, possibly mojibake) byte stream so XML-1.0-illegal
        // control bytes and broken UTF-8 are scrubbed in fixed-size chunks BEFORE the pull-parser sees
        // them. Without this a single bad byte mid-file aborts the whole multi-year import. The
        // sanitizer is itself a streaming FilterInputStream, so memory stays bounded. Its scrubbed-run
        // count is folded into the import summary so a partial import is never silently presented as
        // complete. Mirrors `SanitizingInputStream` in the macOS source of truth.
        val sanitized = SanitizingInputStream(input)

        val parser: XmlPullParser = newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(sanitized, null) // null encoding => parser reads the XML declaration

        var correlationDepth = 0
        try {
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> when (parser.name) {
                        "Correlation" -> correlationDepth += 1
                        "Record" -> if (correlationDepth == 0) handleRecord(parser, agg)
                        "Workout" -> handleWorkout(parser, agg)
                        else -> { /* ignore */ }
                    }
                    XmlPullParser.END_TAG -> if (parser.name == "Correlation" && correlationDepth > 0) {
                        correlationDepth -= 1
                    }
                }
                event = parser.next()
            }
        } catch (e: Exception) {
            // TOLERANT PARSE: a hard, structural XML error can still slip past the byte sanitizer
            // (e.g. a truncated/garbled tag, not just a bad byte). The pull-parser may signal this as
            // either an XmlPullParserException or an IOException (truncated stream) — both mean "the
            // parser cannot continue". If we already parsed at least one record, KEEP the partial
            // result rather than discarding a whole 15-year import over the tail; count the dropped
            // tail as one skipped span and surface it. If nothing was parsed yet, rethrow so a
            // completely broken file still fails loudly (the caller turns it into a failure summary).
            if (e is XmlPullParserException || e is java.io.IOException) {
                if (agg.hasAnyRecord()) {
                    agg.noteSkippedSpan()
                } else {
                    throw e
                }
            } else {
                throw e // programming errors etc. propagate unchanged
            }
        }

        // Fold in however many illegal-byte runs the sanitizer scrubbed (one per contiguous run).
        agg.addSkippedSpans(sanitized.scrubbedRunCount)
    }

    private fun attr(parser: XmlPullParser, name: String): String? = parser.getAttributeValue(null, name)

    // MARK: Record handling — mirrors HealthXMLDelegate.handleRecord + Aggregator rules.

    private fun handleRecord(parser: XmlPullParser, agg: Aggregator) {
        val rawType = attr(parser, "type") ?: return
        val type = stripPrefix(rawType)
        if (type !in RELEVANT_TYPES) return

        val startStr = attr(parser, "startDate") ?: return
        val endStr = attr(parser, "endDate") ?: return
        val start = HealthDate.parse(startStr) ?: return
        val end = HealthDate.parse(endStr) ?: return

        val source = attr(parser, "sourceName")
        val unit = attr(parser, "unit")
        val rawValue = attr(parser, "value")

        if (type == "SleepAnalysis") {
            val stage = SleepStage.from(rawValue ?: "")
            // Faithful to the macOS importer: sleep-stage intervals are appended UNCONDITIONALLY
            // (the dedupe set there only protects the generic *sample* sink, not `sleepIntervals`).
            // Top-level records are already de-correlated, so duplicates are not expected in
            // practice, but we match the Swift behaviour exactly rather than dedupe here.
            agg.addSleep(stage, start, end, end.offsetMin)
            return
        }

        val raw = rawValue?.toDoubleOrNull()
        var numeric = raw
        if (type == "OxygenSaturation" && numeric != null) {
            numeric = numeric * 100.0
        }

        val valueForKey = rawValue ?: numeric?.toString() ?: ""
        val key = dedupeKey(type, start.epoch, end.epoch, source, valueForKey)
        if (!agg.markSeen(key)) return

        if (numeric == null) return
        agg.addSample(type, numeric, unit, start, end, start.offsetMin, source)
    }

    // MARK: Workout handling — mirrors HealthXMLDelegate.handleWorkout.

    private fun handleWorkout(parser: XmlPullParser, agg: Aggregator) {
        val startStr = attr(parser, "startDate") ?: return
        val endStr = attr(parser, "endDate") ?: return
        val start = HealthDate.parse(startStr) ?: return
        val end = HealthDate.parse(endStr) ?: return

        val rawActivity = attr(parser, "workoutActivityType") ?: "Unknown"
        val activity = stripPrefix(rawActivity)

        var durationS: Double? = null
        val dStr = attr(parser, "duration")
        if (dStr != null) {
            val d = dStr.toDoubleOrNull()
            if (d != null) {
                durationS = when ((attr(parser, "durationUnit") ?: "min").lowercase()) {
                    "min" -> d * 60.0
                    "sec", "s" -> d
                    "hr", "h" -> d * 3600.0
                    else -> d * 60.0
                }
            }
        }

        // Per-workout totals: iOS <=15 put them on the <Workout> element as `totalDistance` /
        // `totalEnergyBurned` attributes; iOS 16+ moved them into nested <WorkoutStatistics> children
        // (energy/distance now `type`+`sum`, heart rate `average`/`maximum`). Read the legacy attributes
        // first, then let the children FILL any still absent — a modern export carries no legacy
        // attributes so nothing a legacy value set is clobbered. Mirrors HealthXMLDelegate.handleWorkout.
        var distanceM: Double? = attr(parser, "totalDistance")?.toDoubleOrNull()
            ?.let { distanceMeters(it, attr(parser, "totalDistanceUnit")) }
        var energyKcal: Double? = attr(parser, "totalEnergyBurned")?.toDoubleOrNull()
        var avgHr: Double? = null
        var maxHr: Double? = null

        // Walk this workout's own sub-tree. A self-closing <WorkoutStatistics/> yields START_TAG then
        // END_TAG, so relative-depth tracking (1 inside the open <Workout>, back to 0 at </Workout>)
        // consumes each child exactly once and skips MetadataEntry / WorkoutEvent / WorkoutRoute.
        var depth = 1
        while (depth > 0) {
            val ev = parser.next()
            if (ev == XmlPullParser.END_DOCUMENT) break
            if (ev == XmlPullParser.START_TAG) {
                if (parser.name == "WorkoutStatistics") {
                    when (val statType = stripPrefix(attr(parser, "type") ?: "")) {
                        "ActiveEnergyBurned" ->
                            if (energyKcal == null) energyKcal = attr(parser, "sum")?.toDoubleOrNull()
                        "HeartRate" -> {
                            if (avgHr == null) avgHr = attr(parser, "average")?.toDoubleOrNull()
                            if (maxHr == null) maxHr = attr(parser, "maximum")?.toDoubleOrNull()
                        }
                        else -> if (statType.startsWith("Distance") && distanceM == null) {
                            distanceM = attr(parser, "sum")?.toDoubleOrNull()
                                ?.let { distanceMeters(it, attr(parser, "unit")) }
                        }
                    }
                }
                depth += 1
            } else if (ev == XmlPullParser.END_TAG) {
                depth -= 1
            }
        }

        agg.addWorkout(activity, durationS, distanceM, energyKcal, avgHr, maxHr, start, end)
    }

    /** Convert a distance value in `km` / `mi` / `m` to metres (defaulting to km, Apple's usual unit). */
    private fun distanceMeters(value: Double, unit: String?): Double = when ((unit ?: "km").lowercase()) {
        "km" -> value * 1000.0
        "mi" -> value * 1609.344
        "m" -> value
        else -> value * 1000.0
    }

    // ------------------------------------------------------------------------
    // Persistence — map aggregates onto the Room schema and upsert.
    // ------------------------------------------------------------------------

    private suspend fun persist(
        agg: Aggregator,
        repo: WhoopRepository,
        deviceId: String,
    ): ImportSummary {
        val days = agg.finishDays() // sorted ascending by day; union of sample + sleep days

        if (days.isEmpty()) {
            return ImportSummary(
                source = SOURCE_LABEL,
                counts = emptyMap(),
                message = "No supported Apple Health data found in the export.",
            )
        }

        repo.upsertDevice(deviceId, name = SOURCE_LABEL)

        val appleDailyRows = ArrayList<AppleDaily>(days.size)
        val dailyMetricRows = ArrayList<DailyMetric>(days.size)
        val metricSeriesRows = ArrayList<MetricSeriesRow>(days.size * 8)

        for (d in days) {
            appleDailyRows += AppleDaily(
                deviceId = deviceId,
                day = d.day,
                steps = d.steps?.let { Math.round(it).toInt() },
                activeKcal = d.activeKcal,
                basalKcal = d.basalKcal,
                vo2max = d.vo2max,
                avgHr = d.avgHr?.let { Math.round(it).toInt() },
                maxHr = d.maxHr?.let { Math.round(it).toInt() },
                walkingHr = d.walkingHr?.let { Math.round(it).toInt() },
                weightKg = d.weightKg,
            )

            // DailyMetric carries the cardio/respiratory/sleep aggregates Apple Health provides.
            // Other DailyMetric columns (efficiency, recovery, strain, disturbances, exerciseCount,
            // skinTempDevC) are not derivable from an Apple Health export and stay null.
            val hasDailyMetric = d.restingHr != null || d.hrvSDNN != null || d.spo2Pct != null ||
                d.respRate != null || d.asleepMin != null || d.deepMin != null || d.remMin != null ||
                d.coreMin != null || d.steps != null
            if (hasDailyMetric) {
                dailyMetricRows += DailyMetric(
                    deviceId = deviceId,
                    day = d.day,
                    totalSleepMin = d.asleepMin,
                    deepMin = d.deepMin,
                    remMin = d.remMin,
                    lightMin = d.coreMin, // Apple "core" sleep is the light-sleep stage
                    restingHr = d.restingHr?.let { Math.round(it).toInt() },
                    avgHrv = d.hrvSDNN,
                    spo2Pct = d.spo2Pct,
                    respRateBpm = d.respRate,
                    // #89: Apple Health steps must land in DailyMetric.steps too — FusionDayAdapter reads the
                    // daily step total via WhoopRepository.dailyColumn("steps") = d.steps, so leaving it null
                    // (the pre-fix state) meant imported Apple steps never surfaced. `d.steps` is a Double.
                    steps = d.steps?.let { Math.round(it).toInt() },
                )
            }

            // Flattened metric points — mirrors AppleHealthAggregator.metricPoints key set.
            fun add(key: String, value: Double?) {
                if (value != null) metricSeriesRows += MetricSeriesRow(deviceId, d.day, key, value)
            }
            add("resting_hr", d.restingHr)
            add("hrv", d.hrvSDNN)
            add("spo2", d.spo2Pct)
            add("resp_rate", d.respRate)
            add("avg_hr", d.avgHr)
            add("max_hr", d.maxHr)
            add("walking_hr", d.walkingHr)
            add("steps", d.steps)
            add("active_kcal", d.activeKcal)
            add("basal_kcal", d.basalKcal)
            add("vo2max", d.vo2max)
            add("weight", d.weightKg)
            add("body_fat", d.bodyFatPct)
            add("lean_mass", d.leanMassKg)
            add("bmi", d.bmi)
            add("asleep_min", d.asleepMin)
            add("deep_min", d.deepMin)
            add("rem_min", d.remMin)
            add("core_min", d.coreMin)
            add("awake_min", d.awakeMin)
            add("in_bed_min", d.inBedMin)
        }

        val workoutRows = agg.finishWorkouts(deviceId)

        // Upsert (Room OnConflictStrategy on each repo method handles idempotent re-import).
        repo.upsertAppleDaily(appleDailyRows)
        if (dailyMetricRows.isNotEmpty()) repo.upsertDailyMetrics(dailyMetricRows)
        if (metricSeriesRows.isNotEmpty()) repo.upsertMetricSeries(metricSeriesRows)
        if (workoutRows.isNotEmpty()) repo.upsertWorkouts(workoutRows)

        val skipped = agg.skippedSpanCount()

        val counts = LinkedHashMap<String, Int>()
        counts["appleDaily"] = appleDailyRows.size
        if (dailyMetricRows.isNotEmpty()) counts["dailyMetric"] = dailyMetricRows.size
        if (metricSeriesRows.isNotEmpty()) counts["metricSeries"] = metricSeriesRows.size
        if (workoutRows.isNotEmpty()) counts["workout"] = workoutRows.size
        // Surface dropped spans honestly so a partial (tolerant) import never looks complete.
        if (skipped > 0) counts["skippedSpans"] = skipped

        val firstDay = days.first().day
        val lastDay = days.last().day
        val message = buildString {
            append("Imported ")
            append(appleDailyRows.size)
            append(" day")
            if (appleDailyRows.size != 1) append("s")
            if (workoutRows.isNotEmpty()) {
                append(", ")
                append(workoutRows.size)
                append(" workout")
                if (workoutRows.size != 1) append("s")
            }
            append(" from Apple Health.")
            if (skipped > 0) {
                append(" Skipped ")
                append(skipped)
                append(" damaged span")
                if (skipped != 1) append("s")
                append(".")
            }
        }

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = message,
        )
    }

    // ------------------------------------------------------------------------
    // Test seam — JVM-runnable parse of a raw stream (no Context/Uri/Room needed).
    // ------------------------------------------------------------------------

    /** Observable result of a JVM-side parse, for unit tests of the sanitizer / tolerant parse. */
    internal class ParseProbe(
        /** Finalized per-day aggregates, ascending by day. */
        val days: List<DailyAggView>,
        val workoutCount: Int,
        /** Finalized workout rows (exposes energy/distance/HR for the WorkoutStatistics tests). */
        val workouts: List<WorkoutRow>,
        /** Dropped XML spans (sanitizer-scrubbed runs + hard-error-truncated tail). */
        val skippedSpans: Int,
    )

    /** A read-only view of a finalized day, exposing the fields the tests assert on. */
    internal class DailyAggView(val day: String, val avgHr: Double?, val maxHr: Double?, val steps: Double?)

    /**
     * Run the SAME sanitizer + tolerant pull-parse + per-day aggregation that production uses, over a
     * raw [input] stream, and return an observable probe. This is the JVM entry point for tests: it
     * avoids `Context`/`Uri`/Room while exercising the real `parseXml` choke point (sanitizer and
     * tolerant-parse layers included). Production import goes through `importExport`, never this.
     */
    internal fun parseStreamForTest(input: InputStream): ParseProbe {
        val agg = Aggregator()
        parseXml(input, agg)
        val days = agg.finishDays().map { DailyAggView(it.day, it.avgHr, it.maxHr, it.steps) }
        val workouts = agg.finishWorkouts(DEFAULT_DEVICE_ID)
        return ParseProbe(
            days = days,
            workoutCount = workouts.size,
            workouts = workouts,
            skippedSpans = agg.skippedSpanCount(),
        )
    }

    // ------------------------------------------------------------------------
    // Helpers — prefix stripping, dedupe key, sleep-stage mapping.
    // ------------------------------------------------------------------------

    /**
     * Strip the HealthKit identifier prefix. `HKQuantityTypeIdentifierHeartRate` -> `HeartRate`,
     * `HKCategoryTypeIdentifierSleepAnalysis` -> `SleepAnalysis`,
     * `HKWorkoutActivityTypeRunning` -> `Running`. Mirrors `AppleHealthImporter.stripPrefix`.
     */
    private val PREFIXES = arrayOf(
        "HKQuantityTypeIdentifier",
        "HKCategoryTypeIdentifier",
        "HKDataTypeIdentifier",
        "HKWorkoutActivityType",
    )

    private fun stripPrefix(raw: String): String {
        for (p in PREFIXES) if (raw.startsWith(p)) return raw.substring(p.length)
        return raw
    }

    /** Dedupe key per spec: `type|start|end|source|value` (epoch seconds as Double, like Swift). */
    private fun dedupeKey(type: String, start: Double, end: Double, source: String?, value: String): String =
        "$type|$start|$end|${source ?: ""}|$value"
}

/**
 * Canonical sleep stages Strand recognises from Apple Health `HKCategoryValueSleepAnalysis*`
 * values. Mirrors `SleepStage` + `SleepStage.from(rawValue:)` in `ImportModels.swift`.
 */
private enum class SleepStage {
    IN_BED, ASLEEP_UNSPECIFIED, ASLEEP_CORE, ASLEEP_DEEP, ASLEEP_REM, AWAKE, UNKNOWN;

    companion object {
        fun from(raw: String): SleepStage = when (raw) {
            "HKCategoryValueSleepAnalysisInBed", "InBed", "0" -> IN_BED
            "HKCategoryValueSleepAnalysisAsleep",
            "HKCategoryValueSleepAnalysisAsleepUnspecified", "Asleep", "1" -> ASLEEP_UNSPECIFIED
            "HKCategoryValueSleepAnalysisAsleepCore", "AsleepCore", "3" -> ASLEEP_CORE
            "HKCategoryValueSleepAnalysisAsleepDeep", "AsleepDeep", "4" -> ASLEEP_DEEP
            "HKCategoryValueSleepAnalysisAsleepREM", "AsleepREM", "5" -> ASLEEP_REM
            "HKCategoryValueSleepAnalysisAwake", "Awake", "2" -> AWAKE
            else -> UNKNOWN
        }
    }
}

/**
 * A parsed Apple Health timestamp: the UTC instant in epoch SECONDS plus the original UTC offset
 * (minutes). Apple exports `yyyy-MM-dd HH:mm:ss Z` (space before a colon-less offset). We parse the
 * fields directly rather than via SimpleDateFormat to avoid per-record allocation across tens of
 * millions of records, and compute the epoch with a pure-arithmetic civil-day algorithm.
 */
private class HealthDate(val epoch: Double, val offsetMin: Int) {

    companion object {
        /**
         * Parse `yyyy-MM-dd HH:mm:ss ±HHMM` / `±HH:MM` / `Z`. Also tolerates an ISO-8601 `T`
         * separator. Returns null on anything unparseable (matching the Swift importer's silent skip).
         */
        fun parse(raw: String): HealthDate? {
            val s = raw.trim()
            if (s.length < 19) return null

            // Date: yyyy-MM-dd
            val year = intAt(s, 0, 4) ?: return null
            if (s[4] != '-') return null
            val month = intAt(s, 5, 2) ?: return null
            if (s[7] != '-') return null
            val day = intAt(s, 8, 2) ?: return null

            val sep = s[10]
            if (sep != ' ' && sep != 'T' && sep != 't') return null

            // Time: HH:mm:ss
            val hour = intAt(s, 11, 2) ?: return null
            if (s[13] != ':') return null
            val minute = intAt(s, 14, 2) ?: return null
            if (s[16] != ':') return null
            val second = intAt(s, 17, 2) ?: return null

            val offsetMin = offsetMinutes(s)

            // Days since Unix epoch (1970-01-01) for this civil Y-M-D, then add the time-of-day, then
            // subtract the offset to get the true UTC instant. (epoch_local - offset = epoch_utc)
            val days = daysFromCivil(year, month, day)
            val localSecs = days * 86400.0 + hour * 3600.0 + minute * 60.0 + second
            val utcSecs = localSecs - offsetMin * 60.0
            return HealthDate(utcSecs, offsetMin)
        }

        private fun intAt(s: String, start: Int, len: Int): Int? {
            if (start + len > s.length) return null
            var acc = 0
            for (i in start until start + len) {
                val c = s[i]
                if (c < '0' || c > '9') return null
                acc = acc * 10 + (c - '0')
            }
            return acc
        }

        /**
         * Days from 1970-01-01 to the given proleptic-Gregorian civil date (may be negative).
         * Howard Hinnant's `days_from_civil` algorithm — exact, no DST, no allocation.
         */
        private fun daysFromCivil(y0: Int, m: Int, d: Int): Long {
            val y = if (m <= 2) y0 - 1 else y0
            val era = (if (y >= 0) y else y - 399) / 400
            val yoe = (y - era * 400).toLong()                       // [0, 399]
            val doy = ((153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1).toLong() // [0, 365]
            val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy          // [0, 146096]
            return era.toLong() * 146097L + doe - 719468L
        }

        /**
         * Extract the trailing UTC offset (`+0100`, `-0500`, `+01:00`, `Z`) in minutes. Mirrors
         * `HealthDateParser.offsetMinutes`.
         */
        fun offsetMinutes(raw: String): Int {
            val trimmed = raw.trim()
            if (trimmed.endsWith("Z") || trimmed.endsWith("z")) return 0
            // The offset is the last token; look within the last ~6 chars for a sign.
            val tail = trimmed.takeLast(6)
            var signIdx = -1
            for (i in tail.indices) if (tail[i] == '+' || tail[i] == '-') { signIdx = i; break }
            if (signIdx < 0) return 0
            val offStr = tail.substring(signIdx)
            val sign = if (offStr.startsWith("-")) -1 else 1
            val digits = StringBuilder()
            for (c in offStr.drop(1)) if (c.isDigit()) digits.append(c)
            if (digits.length < 2) return 0
            val ds = digits.toString()
            val hours: Int
            val minutes: Int
            if (ds.length >= 4) {
                hours = ds.substring(0, 2).toIntOrNull() ?: 0
                minutes = ds.substring(2, 4).toIntOrNull() ?: 0
            } else {
                hours = ds.substring(0, 2).toIntOrNull() ?: 0
                minutes = 0
            }
            return sign * (hours * 60 + minutes)
        }
    }
}

/**
 * Bounded, streaming per-day aggregator. Holds running statistics (sums + counts for means,
 * running max, latest-by-end value) per distinct day — NOT raw sample lists — so memory scales
 * with the number of days, not the number of records.
 *
 * Reproduces the reduction rules from `AppleHealthAggregator`:
 *  - mean: restingHr, hrvSDNN, spo2, respRate, walkingHr, avgHr
 *  - max: maxHr
 *  - sum: steps, activeEnergy, basalEnergy
 *  - latest by sample `end`: vo2max, bodyMass(weightKg), bodyFat, leanMass, bmi
 *  - sample day = local day of `start`; sleep day = local day of `end` (wake day)
 *  - asleep = core + deep + rem + asleepUnspecified
 */
private class Aggregator {

    /** Running mean: sum + count. */
    private class Mean {
        var sum = 0.0
        var n = 0
        fun add(v: Double) { sum += v; n += 1 }
        fun value(): Double? = if (n == 0) null else sum / n
    }

    /** Latest-by-end value. */
    private class Latest {
        var value: Double? = null
        var at = Double.NEGATIVE_INFINITY // sample end epoch
        fun consider(v: Double, end: Double) {
            if (value == null || at <= end) { value = v; at = end }
        }
    }

    private class DayAcc {
        val resting = Mean()
        val hrv = Mean()
        val spo2 = Mean()
        val resp = Mean()
        val walking = Mean()
        val hr = Mean()
        var maxHr = Double.NEGATIVE_INFINITY
        var hasHr = false
        // #589: per-SOURCE step sums — iPhone + Watch both count the same walk, so summing across
        // sources double-counts (~2x). Take the MAX source per day at read-out (mirrors Apple Health).
        val stepsBySource = mutableMapOf<String, Double>()
        var active = 0.0; var hasActive = false
        var basal = 0.0; var hasBasal = false
        val vo2 = Latest()
        val weight = Latest()
        val bodyFat = Latest()
        val lean = Latest()
        val bmi = Latest()
        // Sleep minutes per stage (keyed by wake day).
        var deep = 0.0
        var rem = 0.0
        var core = 0.0
        var unspecified = 0.0
        var awake = 0.0
        var inBed = 0.0
        var hasSleep = false
    }

    private val byDay = HashMap<String, DayAcc>()
    // Dedupe over sample keys, stored as the key's 64-bit HASH not the full String (#183). A large Apple
    // Health export has tens of millions of unique samples; retaining a ~50-100 B String each was ~1-2 GB
    // of RAM, enough to hang the import under memory pressure. 8 B/entry is ~10x smaller. See [hash64].
    private val seen = HashSet<Long>()
    private val workouts = ArrayList<PendingWorkout>()

    /** True once any relevant, date-valid record / workout / sleep row was dispatched. Drives the
     * tolerant-parse decision (keep partial vs. fail). Mirrors `HealthXMLDelegate.hasAnyRecord`. */
    private var sawAnyRecord = false
    /** Count of XML spans dropped during a tolerant import (sanitizer-scrubbed illegal-byte runs +
     * a hard-error-truncated tail). Surfaced in the summary so a partial import is never hidden. */
    private var skippedSpans = 0

    private class PendingWorkout(
        val sport: String,
        val startTs: Long,
        val endTs: Long,
        val durationS: Double?,
        val distanceM: Double?,
        val energyKcal: Double?,
        val avgHr: Double?,
        val maxHr: Double?,
    )

    /** Returns true if [key] was not seen before (i.e. this row should be processed). Dedupes on the
     *  key's 64-bit hash, not the full String, to bound memory on a huge export (#183). */
    fun markSeen(key: String): Boolean = seen.add(hash64(key))

    /** 64-bit FNV-1a over [s]'s UTF-16 code units. Kotlin's `String.hashCode` is only 32-bit — that's
     *  ~46k collisions over 20M keys, silently dropping tens of thousands of real samples; a 64-bit hash
     *  keeps that ~1e-5. A rare collision just drops a look-alike duplicate — the effect dedup intends. */
    private fun hash64(s: String): Long {
        var h = 0xcbf29ce484222325uL.toLong()   // FNV-1a 64-bit offset basis
        for (i in s.indices) {
            h = (h xor s[i].code.toLong()) * 0x100000001b3L   // xor code unit, × FNV prime (wraps, intended)
        }
        return h
    }

    fun hasAnyRecord(): Boolean = sawAnyRecord

    /** Account for one dropped span (a hard parse error that truncated the tail). */
    fun noteSkippedSpan() { skippedSpans += 1 }

    /** Add the number of illegal-byte runs the sanitizer scrubbed. */
    fun addSkippedSpans(n: Int) { skippedSpans += n }

    fun skippedSpanCount(): Int = skippedSpans

    private fun acc(day: String): DayAcc = byDay.getOrPut(day) { DayAcc() }

    private fun localDay(epochSecs: Double, offsetMin: Int): String {
        val shifted = epochSecs + offsetMin * 60.0
        val days = Math.floorDiv(shifted.toLong(), 86400L)
        return civilFromDays(days)
    }

    fun addSample(type: String, value: Double, unit: String?, start: HealthDate, end: HealthDate, offsetMin: Int, sourceName: String? = null) {
        sawAnyRecord = true
        val day = localDay(start.epoch, offsetMin)
        val a = acc(day)
        when (type) {
            "RestingHeartRate" -> a.resting.add(value)
            "HeartRateVariabilitySDNN" -> a.hrv.add(value)
            "OxygenSaturation" -> {
                // Importer already scaled by 100; defend against raw 0..1 fractions too.
                val pct = if (value > 0 && value <= 1.0) value * 100.0 else value
                a.spo2.add(pct)
            }
            "RespiratoryRate" -> a.resp.add(value)
            "WalkingHeartRateAverage" -> a.walking.add(value)
            "HeartRate" -> {
                a.hr.add(value)
                if (!a.hasHr || value > a.maxHr) { a.maxHr = value; a.hasHr = true }
            }
            "StepCount" -> { a.stepsBySource[sourceName ?: ""] = (a.stepsBySource[sourceName ?: ""] ?: 0.0) + value }
            "ActiveEnergyBurned" -> { a.active += value; a.hasActive = true }
            "BasalEnergyBurned" -> { a.basal += value; a.hasBasal = true }
            "VO2Max" -> a.vo2.consider(value, end.epoch)
            "BodyMass" -> a.weight.consider(if (unitLooksLikePounds(unit)) value * 0.453592 else value, end.epoch)
            "BodyFatPercentage" -> {
                val pct = if (value > 0 && value <= 1.0) value * 100.0 else value
                a.bodyFat.consider(pct, end.epoch)
            }
            "LeanBodyMass" -> a.lean.consider(if (unitLooksLikePounds(unit)) value * 0.453592 else value, end.epoch)
            "BodyMassIndex" -> a.bmi.consider(value, end.epoch)
            // BodyTemperature / AppleSleepingWristTemperature pass the relevant-type filter but
            // have no daily aggregate slot in the macOS aggregator either — intentionally dropped.
            else -> { /* ignore */ }
        }
    }

    fun addSleep(stage: SleepStage, start: HealthDate, end: HealthDate, offsetMin: Int) {
        sawAnyRecord = true
        val minutes = Math.max(0.0, (end.epoch - start.epoch)) / 60.0
        val day = localDay(end.epoch, offsetMin) // wake day = local day of end
        val a = acc(day)
        when (stage) {
            SleepStage.ASLEEP_DEEP -> a.deep += minutes
            SleepStage.ASLEEP_REM -> a.rem += minutes
            SleepStage.ASLEEP_CORE -> a.core += minutes
            SleepStage.ASLEEP_UNSPECIFIED -> a.unspecified += minutes
            SleepStage.AWAKE -> a.awake += minutes
            SleepStage.IN_BED -> a.inBed += minutes
            SleepStage.UNKNOWN -> { /* ignore */ }
        }
        a.hasSleep = true
    }

    fun addWorkout(sport: String, durationS: Double?, distanceM: Double?, energyKcal: Double?, avgHr: Double?, maxHr: Double?, start: HealthDate, end: HealthDate) {
        sawAnyRecord = true
        workouts += PendingWorkout(
            sport = sport,
            startTs = Math.round(start.epoch),
            endTs = Math.round(end.epoch),
            durationS = durationS,
            distanceM = distanceM,
            energyKcal = energyKcal,
            avgHr = avgHr,
            maxHr = maxHr,
        )
    }

    /** Finalize per-day aggregates, sorted ascending by day. */
    fun finishDays(): List<DailyAgg> = byDay.entries
        .map { (day, a) ->
            DailyAgg(
                day = day,
                restingHr = a.resting.value(),
                hrvSDNN = a.hrv.value(),
                spo2Pct = a.spo2.value(),
                respRate = a.resp.value(),
                avgHr = a.hr.value(),
                maxHr = if (a.hasHr) a.maxHr else null,
                walkingHr = a.walking.value(),
                steps = a.stepsBySource.values.maxOrNull(),   // #589 max source, not cross-source sum
                activeKcal = if (a.hasActive) a.active else null,
                basalKcal = if (a.hasBasal) a.basal else null,
                vo2max = a.vo2.value,
                weightKg = a.weight.value,
                bodyFatPct = a.bodyFat.value,
                leanMassKg = a.lean.value,
                bmi = a.bmi.value,
                asleepMin = if (a.hasSleep) a.core + a.deep + a.rem + a.unspecified else null,
                deepMin = if (a.hasSleep) a.deep else null,
                remMin = if (a.hasSleep) a.rem else null,
                coreMin = if (a.hasSleep) a.core else null,
                awakeMin = if (a.hasSleep) a.awake else null,
                inBedMin = if (a.hasSleep) a.inBed else null,
            )
        }
        .sortedBy { it.day }

    /**
     * Finalize workout rows. The Room `workout` table PK is (deviceId, startTs, sport), so any
     * Apple Health workouts colliding on that key collapse via the upsert (matching how the macOS
     * cache keys workouts). `durationS` falls back to (endTs - startTs) when absent.
     */
    fun finishWorkouts(deviceId: String): List<WorkoutRow> = workouts.map { w ->
        WorkoutRow(
            deviceId = deviceId,
            startTs = w.startTs,
            endTs = w.endTs,
            sport = w.sport,
            source = "apple-health",
            durationS = w.durationS ?: (w.endTs - w.startTs).toDouble(),
            energyKcal = w.energyKcal,
            avgHr = w.avgHr?.let { Math.round(it).toInt() },
            maxHr = w.maxHr?.let { Math.round(it).toInt() },
            strain = null,
            distanceM = w.distanceM,
            zonesJSON = null,
            notes = null,
        )
    }

    private fun unitLooksLikePounds(unit: String?): Boolean {
        val u = unit?.lowercase() ?: return false
        return u == "lb" || u == "lbs" || u.contains("pound")
    }

    companion object {
        /** Inverse of HealthDate.daysFromCivil — days since epoch -> `yyyy-MM-dd` (UTC civil). */
        fun civilFromDays(z0: Long): String {
            val z = z0 + 719468L
            val era = (if (z >= 0) z else z - 146096L) / 146097L
            val doe = z - era * 146097L                         // [0, 146096]
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
            val y = yoe + era * 400L
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)   // [0, 365]
            val mp = (5 * doy + 2) / 153                        // [0, 11]
            val d = (doy - (153 * mp + 2) / 5 + 1).toInt()      // [1, 31]
            val m = (if (mp < 10) mp + 3 else mp - 9).toInt()   // [1, 12]
            val year = (if (m <= 2) y + 1 else y).toInt()
            // Locale.ROOT keeps this storage day-key ASCII regardless of the app-language selection (#1004).
            return String.format(java.util.Locale.ROOT, "%04d-%02d-%02d", year, m, d)
        }
    }
}

/** Finalized per-day aggregate mirroring `AppleDailyAggregate`. */
private class DailyAgg(
    val day: String,
    val restingHr: Double?,
    val hrvSDNN: Double?,
    val spo2Pct: Double?,
    val respRate: Double?,
    val avgHr: Double?,
    val maxHr: Double?,
    val walkingHr: Double?,
    val steps: Double?,
    val activeKcal: Double?,
    val basalKcal: Double?,
    val vo2max: Double?,
    val weightKg: Double?,
    val bodyFatPct: Double?,
    val leanMassKg: Double?,
    val bmi: Double?,
    val asleepMin: Double?,
    val deepMin: Double?,
    val remMin: Double?,
    val coreMin: Double?,
    val awakeMin: Double?,
    val inBedMin: Double?,
)

/**
 * A streaming [FilterInputStream] that scrubs every byte XML 1.0 forbids — and every invalid UTF-8
 * sequence — as it streams, in fixed-size chunks, before the bytes reach the pull-parser. Kotlin
 * port of `SanitizingInputStream` in the macOS source of truth
 * (`Packages/StrandImport/Sources/StrandImport/AppleHealthImporter.swift`).
 *
 * WHY: a single malformed byte in a multi-year Apple Health `export.xml` (a stray control char, or
 * mojibake / truncated UTF-8 from a decade-old phone) makes the pull-parser abort with a hard error,
 * discarding everything parsed up to that point. Repairing the byte stream up front lets the parse
 * run to EOF so the import survives.
 *
 * It holds at most one source chunk plus the ≤ 3 trailing bytes of a UTF-8 sequence that straddles a
 * chunk boundary, so memory stays bounded — the file is never inflated to RAM.
 *
 * Rules (UTF-8 only — Apple Health exports declare UTF-8):
 *  - Bytes `< 0x20` that are not TAB (0x09), LF (0x0A) or CR (0x0D) → dropped (XML-1.0 illegal).
 *    0x20..0x7F (incl. DEL 0x7F, which XML 1.0 permits) pass through.
 *  - Any byte sequence that is not valid UTF-8 → replaced with U+FFFD (`EF BF BD`).
 *  - Valid multi-byte sequences pass through byte-for-byte, including ones split across a chunk
 *    boundary (the incomplete tail is carried into the next read).
 *
 * [scrubbedRunCount] counts CONTIGUOUS runs of dropped/replaced bytes (one per run, not per byte) so
 * the import summary can report "N spans skipped" honestly.
 */
internal class SanitizingInputStream(
    source: InputStream,
    private val chunkSize: Int = 1 shl 16,
) : FilterInputStream(source) {

    /** Bytes lifted from the source but not yet sanitized — only an incomplete UTF-8 tail (≤ 3). */
    private var carry = ByteArray(0)
    /** Sanitized bytes ready to hand to the parser but not yet consumed. */
    private var out = ByteArray(0)
    private var outOffset = 0
    private var sourceEof = false

    private var inScrubRun = false
    var scrubbedRunCount = 0
        private set

    override fun read(): Int {
        if (!ensureOutput()) return -1
        val b = out[outOffset].toInt() and 0xFF
        outOffset += 1
        compactIfDrained()
        return b
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (!ensureOutput()) return -1
        val available = out.size - outOffset
        val n = minOf(len, available)
        System.arraycopy(out, outOffset, b, off, n)
        outOffset += n
        compactIfDrained()
        return n
    }

    override fun available(): Int = (out.size - outOffset)

    /** No mark/reset across the sanitizer (the parser does not need it). */
    override fun markSupported(): Boolean = false

    /** Ensure at least one sanitized byte is available; returns false at true EOF. */
    private fun ensureOutput(): Boolean {
        while (outOffset >= out.size) {
            if (sourceEof) {
                // At EOF, a leftover partial UTF-8 sequence is itself invalid → one U+FFFD.
                if (carry.isNotEmpty()) {
                    scrub(holdIncompleteTail = false)
                    if (outOffset < out.size) return true
                }
                return false
            }
            refill()
        }
        return true
    }

    private fun compactIfDrained() {
        if (outOffset >= out.size) {
            out = ByteArray(0)
            outOffset = 0
        }
    }

    /** Read one chunk from the source, append to carry, scrub up to the last complete UTF-8 boundary. */
    private fun refill() {
        val chunk = ByteArray(chunkSize)
        val n = `in`.read(chunk, 0, chunkSize)
        if (n <= 0) {
            sourceEof = true
            return
        }
        carry = if (carry.isEmpty()) chunk.copyOf(n) else carry + chunk.copyOf(n)
        scrub(holdIncompleteTail = true)
    }

    /**
     * Consume [carry], emit sanitized bytes into [out]. When [holdIncompleteTail] is true the trailing
     * bytes of a not-yet-complete (but so-far-valid) UTF-8 sequence are left in [carry] for the next
     * chunk. Mirrors the Swift `scrub(holdIncompleteTail:)`.
     */
    private fun scrub(holdIncompleteTail: Boolean) {
        val bytes = carry
        val count = bytes.size
        val sink = ArrayList<Byte>(count + (out.size - outOffset))
        // Keep any not-yet-consumed sanitized output ahead of the new bytes.
        for (j in outOffset until out.size) sink.add(out[j])

        var i = 0
        while (i < count) {
            val b = bytes[i].toInt() and 0xFF

            // 1) ASCII fast path.
            if (b < 0x80) {
                if (b >= 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
                    sink.add(b.toByte())
                    inScrubRun = false
                } else {
                    // XML-1.0-illegal C0 control char (< 0x20, not TAB/LF/CR) → drop.
                    noteScrub()
                }
                i += 1
                continue
            }

            // 2) Multi-byte UTF-8. Sequence length from the lead byte.
            val seqLen = when {
                b and 0xE0 == 0xC0 -> 2
                b and 0xF0 == 0xE0 -> 3
                b and 0xF8 == 0xF0 -> 4
                else -> 0 // continuation byte as a lead, or 0xF8..0xFF: invalid.
            }

            if (seqLen == 0) {
                emitReplacement(sink)
                i += 1
                continue
            }

            if (i + seqLen > count) {
                if (holdIncompleteTail) {
                    // Might still complete in the next chunk — carry it over.
                    break
                } else {
                    emitReplacement(sink)
                    i += 1
                    continue
                }
            }

            if (isValidUtf8Sequence(bytes, i, seqLen)) {
                for (k in 0 until seqLen) sink.add(bytes[i + k])
                inScrubRun = false
                i += seqLen
            } else {
                // Only the lead byte is consumed; invalid continuation bytes are re-examined.
                emitReplacement(sink)
                i += 1
            }
        }

        // Anything from i onward is the held-back incomplete tail (or nothing).
        carry = if (i >= count) ByteArray(0) else bytes.copyOfRange(i, count)

        out = ByteArray(sink.size)
        for (k in sink.indices) out[k] = sink[k]
        outOffset = 0
    }

    private fun emitReplacement(sink: ArrayList<Byte>) {
        // U+FFFD in UTF-8.
        sink.add(0xEF.toByte()); sink.add(0xBF.toByte()); sink.add(0xBD.toByte())
        noteScrub()
    }

    /** Account for one scrubbed byte, collapsing consecutive bad bytes into a single counted span. */
    private fun noteScrub() {
        if (!inScrubRun) {
            scrubbedRunCount += 1
            inScrubRun = true
        }
    }

    /**
     * Validate a UTF-8 sequence of [length] bytes starting at [start], including overlong / surrogate
     * / out-of-range constraints (RFC 3629), so only encodings a strict XML parser accepts pass
     * through. Mirrors the Swift `isValidUTF8Sequence`.
     */
    private fun isValidUtf8Sequence(bytes: ByteArray, start: Int, length: Int): Boolean {
        val b0 = bytes[start].toInt() and 0xFF
        return when (length) {
            2 -> {
                // Valid 2-byte lead is C2..DF; C0/C1 are overlong encodings of ASCII.
                if (b0 < 0xC2) false else isCont(bytes[start + 1])
            }
            3 -> {
                val b1 = bytes[start + 1].toInt() and 0xFF
                if (!isCont(bytes[start + 2])) {
                    false
                } else when (b0) {
                    0xE0 -> b1 in 0xA0..0xBF       // exclude overlong
                    0xED -> b1 in 0x80..0x9F       // exclude UTF-16 surrogates
                    else -> isCont(bytes[start + 1])
                }
            }
            4 -> {
                val b1 = bytes[start + 1].toInt() and 0xFF
                if (!isCont(bytes[start + 2]) || !isCont(bytes[start + 3])) {
                    false
                } else when (b0) {
                    0xF0 -> b1 in 0x90..0xBF       // exclude overlong
                    0xF4 -> b1 in 0x80..0x8F       // exclude > U+10FFFF
                    in 0xF1..0xF3 -> isCont(bytes[start + 1])
                    else -> false
                }
            }
            else -> false
        }
    }

    private fun isCont(b: Byte): Boolean = (b.toInt() and 0xC0) == 0x80
}
