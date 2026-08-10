package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.analytics.LabMarkerCategory
import com.noop.analytics.MarkerCatalog
import com.noop.data.ImportSummary
import com.noop.data.LabMarkerRow
import com.noop.data.WhoopRepository
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Lab Book markers CSV import (source "lab-csv") — Kotlin twin of
 * Packages/StrandImport/Sources/StrandImport/LabMarkerCsvImport.swift. Keep the two
 * byte-identical (the LabBookProjection twin pattern): same column resolution, same
 * marker aliases, same value/date grammar, same bounds.
 *
 * The Phase-2 bulk import for the Health Records "Lab Book" pillar (spec
 * 2026-06-19-v5-health-records-design.md §"Phasing"): a generic markers CSV with
 * (date, marker, value, unit) rows, exactly the shape the in-app import card promises.
 *
 * Marker names map onto [MarkerCatalog] by key, display name and a small alias table
 * (systolic/SBP → bp_systolic, A1c → hba1c, …); anything unrecognised imports as a
 * CUSTOM marker under the same `custom_<slug>` key the manual editor mints, so a CSV
 * custom marker and a hand-added one fold onto one history. A combined blood-pressure
 * cell ("120/80") splits into the bp_systolic/bp_diastolic pair so diastolic is never
 * silently dropped.
 *
 * NON-CLINICAL: units are stored VERBATIM — this importer never converts mg/dL to
 * mmol/L or judges a value. Malformed rows are skipped and counted, never fatal, and
 * never guessed. Import-DoS bounds: a byte cap on the file and a row cap on the parse.
 *
 * Parsing is pure ([parse]) so it is JVM unit-testable (LabMarkerCsvImportTest).
 */
object LabMarkerCsvImport {

    /** Provenance/source id stored on every imported reading. Identical to the Swift lane. */
    const val SOURCE_ID = "lab-csv"

    /** Byte cap — a markers CSV is a few KB in real life; 32 MB is already absurd. */
    const val MAX_BYTES = 32L shl 20

    /** Row cap — a lifetime of lab results is a few hundred rows; 50 000 bounds a
     *  hostile file without ever touching a real one. */
    const val MAX_ROWS = 50_000

    /** The strap device id Lab Book rows live under (matches LabBookScreen). */
    private const val LAB_STRAP_DEVICE_ID = "my-whoop"

    private const val SOURCE_LABEL = "Lab Book CSV"

    /** One parsed reading: a numeric value for a marker on a literal yyyy-MM-dd day. */
    data class LabMarkerCsvRow(
        val markerKey: String,
        val category: LabMarkerCategory,
        val day: String,
        val value: Double,
        /** Unit VERBATIM from the file; catalog canonical when the file has no unit
         *  column for a known marker; empty for a unit-less custom marker. */
        val unit: String,
        val isCustomMarker: Boolean,
        /** Optional free-text note carried VERBATIM from the source (e.g. a vendor's own
         *  status column, source-attributed). null for the generic (date,marker,value,unit)
         *  importer, which never annotates. Maps to LabMarker.note. */
        val note: String? = null,
    )

    /** Result of parsing a markers CSV. Mirrors the Swift LabMarkerCsvResult. */
    data class LabMarkerCsvResult(
        /** Deduped per (markerKey, day) — the LAST row in the file wins — sorted by (day, markerKey). */
        val rows: List<LabMarkerCsvRow>,
        /** Data rows dropped: bad date, missing marker, non-numeric value. Reported, never fatal. */
        val skippedRows: Int,
        /** Distinct custom_<slug> keys created for unrecognised marker names, sorted. */
        val customMarkerKeys: List<String>,
        val earliestDay: String?,
        val latestDay: String?,
        /** True when the row cap stopped the parse early. */
        val truncated: Boolean,
        /** True when the file was rejected outright for exceeding the byte cap. */
        val fileTooLarge: Boolean,
        /** Rows a vendor export marked as NOT MEASURED (e.g. WHOOP's "--" / "No Data
         *  Available"). Counted SEPARATELY from [skippedRows] so a clean import of a normal
         *  export doesn't look broken. Always 0 for the generic importer. */
        val notMeasured: Int = 0,
    ) {
        val importedReadings: Int get() = rows.size
        val distinctMarkers: Int get() = rows.map { it.markerKey }.toHashSet().size
    }

    /**
     * Public entry point the Lab Book screen calls. Reads the SAF [uri] via the content
     * resolver (byte-capped), parses, upserts the readings through [repo] under
     * [deviceId] (the projection to metricSeries rides the existing upsert) and returns
     * an [ImportSummary]. `takenAt` is local noon of the row's literal day so a
     * re-import of the same file updates in place (natural key
     * deviceId+markerKey+takenAt+source) instead of duplicating.
     */
    suspend fun importCsv(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = LAB_STRAP_DEVICE_ID,
    ): ImportSummary {
        val bytes: ByteArray = try {
            context.contentResolver.openInputStream(uri)?.use { it.readCapped(MAX_BYTES) }
                ?: throw IllegalStateException("Could not open input stream for $uri")
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read CSV: ${e.message ?: "unknown error"}")
        }

        // Route a WHOOP biomarker export to its vendor parser (packed units, US 2-digit dates, a Status
        // column carried into note); any other file takes the generic (date,marker,value,unit) path.
        // Detection is on the header signature, so a normal markers CSV is never treated as a WHOOP export.
        val result: LabMarkerCsvResult
        val sourceId: String
        if (bytes.size > MAX_BYTES) {
            result = LabMarkerCsvResult(
                rows = emptyList(), skippedRows = 0, customMarkerKeys = emptyList(),
                earliestDay = null, latestDay = null, truncated = false, fileTooLarge = true,
            )
            sourceId = SOURCE_ID
        } else {
            val table = CsvTable.fromData(bytes)
            if (WhoopBiomarkerExportParser.matches(table)) {
                result = WhoopBiomarkerExportParser.parse(table, MAX_ROWS)
                sourceId = WhoopBiomarkerExportParser.SOURCE_ID
            } else {
                result = parse(table, MAX_ROWS)
                sourceId = SOURCE_ID
            }
        }
        if (result.fileTooLarge) {
            return ImportSummary.failure(SOURCE_LABEL, "That file is too large for a markers CSV import.")
        }
        if (result.rows.isEmpty()) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No usable rows found. Check the file has date, marker and value columns.",
            )
        }

        val markerRows = result.rows.map { r ->
            val epoch = labNoonEpoch(r.day)
            LabMarkerRow(
                id = "${r.markerKey}-$epoch-${UUID.randomUUID().toString().take(8)}",
                deviceId = deviceId,
                markerKey = r.markerKey,
                category = r.category.raw,
                day = r.day,
                takenAt = epoch,
                value = r.value,
                valueText = null,
                unit = r.unit,
                source = sourceId,
                note = r.note,
                referenceText = null,
            )
        }
        repo.upsertLabMarkers(markerRows)

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = linkedMapOf("labMarker" to markerRows.size),
            firstDay = result.earliestDay,
            lastDay = result.latestDay,
            message = buildString {
                append("Imported ${result.importedReadings} reading")
                if (result.importedReadings != 1) append("s")
                append(" across ${result.distinctMarkers} marker")
                if (result.distinctMarkers != 1) append("s")
                if (result.earliestDay != null && result.latestDay != null &&
                    result.earliestDay != result.latestDay
                ) {
                    append(" (${result.earliestDay} → ${result.latestDay})")
                }
                append(".")
                if (result.skippedRows > 0) {
                    append(" ${result.skippedRows} row")
                    if (result.skippedRows != 1) append("s")
                    append(" skipped.")
                }
                // A vendor export's not-measured markers ("--" / "No Data Available") are absent by
                // design, not malformed — report them apart so a clean import doesn't look broken.
                if (result.notMeasured > 0) {
                    append(" ${result.notMeasured} not measured.")
                }
            },
        )
    }

    // MARK: - Pure parsing (JVM unit-testable)

    /** Parse raw CSV bytes. Files over [MAX_BYTES] are rejected outright. */
    fun parse(data: ByteArray): LabMarkerCsvResult {
        if (data.size > MAX_BYTES) {
            return LabMarkerCsvResult(
                rows = emptyList(), skippedRows = 0, customMarkerKeys = emptyList(),
                earliestDay = null, latestDay = null, truncated = false, fileTooLarge = true,
            )
        }
        return parse(CsvTable.fromData(data), MAX_ROWS)
    }

    /** Parse CSV text. */
    fun parse(text: String): LabMarkerCsvResult = parse(CsvTable.fromText(text), MAX_ROWS)

    /** Core parse; the row cap is injectable for tests. Mirrors Swift parseTable. */
    internal fun parse(table: CsvTable, maxRows: Int): LabMarkerCsvResult {
        val headers = table.normalizedHeaders

        val dateCol = resolve(
            headers,
            exact = listOf(
                "date", "day", "taken", "taken_at", "test_date",
                "date_taken", "collected", "collection_date",
            ),
            contains = listOf("date"),
        )
        val markerCol = resolve(
            headers,
            exact = listOf(
                "marker", "marker_name", "name", "test", "test_name",
                "analyte", "biomarker", "measurement",
            ),
            contains = listOf("marker", "test", "analyte"),
            excluding = listOf("date", "value", "result", "unit"),
        )
        val valueCol = resolve(
            headers,
            exact = listOf("value", "result", "reading", "amount"),
            contains = listOf("value", "result"),
            excluding = listOf("unit", "text", "date"),
        )
        val unitCol = resolve(headers, exact = listOf("unit", "units", "uom"), contains = listOf("unit"))

        val byCell = LinkedHashMap<String, LabMarkerCsvRow>()   // (markerKey  day) → last row wins
        var skipped = 0
        var truncated = false
        val customKeys = sortedSetOf<String>()

        fun store(row: LabMarkerCsvRow) {
            byCell[row.markerKey + "\u0001" + row.day] = row
        }

        for ((index, row) in table.rows.withIndex()) {
            if (index >= maxRows) {
                // Bounded, honestly: the unread tail counts as skipped.
                skipped += table.rows.size - maxRows
                truncated = true
                break
            }
            val rawDay = dateCol?.let { row.cell(it) }
            val day = rawDay?.let { canonicalDay(it) }
            val rawName = markerCol?.let { row.cell(it) }
            if (valueCol == null || day == null || rawName == null) {
                skipped += 1
                continue
            }

            val rawValue = row.cell(valueCol) ?: ""
            val rawUnit = unitCol?.let { row.cell(it) }

            // Blood pressure: a combined "120/80" cell (under any bp-family name) becomes
            // the systolic/diastolic PAIR — a one-row-one-marker mapping would silently
            // drop diastolic (spec §"Blood pressure modelling").
            val resolved = resolveMarker(rawName)
            val pair = if (resolved.isBloodPressureFamily) bloodPressurePair(rawValue) else null
            if (pair != null) {
                val unit = rawUnit ?: "mmHg"
                store(
                    LabMarkerCsvRow(
                        BP_SYSTOLIC_KEY, LabMarkerCategory.BLOOD_PRESSURE, day,
                        pair.first, unit, isCustomMarker = false,
                    ),
                )
                store(
                    LabMarkerCsvRow(
                        BP_DIASTOLIC_KEY, LabMarkerCategory.BLOOD_PRESSURE, day,
                        pair.second, unit, isCustomMarker = false,
                    ),
                )
                continue
            }

            // The combined-BP name with a non-pair value has no single marker to land on.
            val key = resolved.key
            if (key == null) { skipped += 1; continue }
            val value = parseValue(rawValue)
            if (value == null) { skipped += 1; continue }

            val def = MarkerCatalog.definition(key)
            val category: LabMarkerCategory
            val unit: String
            if (def != null) {
                category = def.category
                // Unit VERBATIM when the file has one; the catalog's canonical unit is
                // only a label fallback, never a conversion.
                unit = rawUnit ?: def.canonicalUnit
            } else {
                category = LabMarkerCategory.OTHER
                unit = rawUnit ?: ""
                customKeys.add(key)
            }
            store(LabMarkerCsvRow(key, category, day, value, unit, isCustomMarker = def == null))
        }

        val rows = byCell.values.sortedWith(compareBy({ it.day }, { it.markerKey }))
        val days = rows.map { it.day }
        return LabMarkerCsvResult(
            rows = rows,
            skippedRows = skipped,
            customMarkerKeys = customKeys.toList(),
            earliestDay = days.minOrNull(),
            latestDay = days.maxOrNull(),
            truncated = truncated,
            fileTooLarge = false,
        )
    }

    // MARK: - Column resolution (NutritionCsvImporter idiom, Swift parity)

    private fun resolve(
        headers: List<String>,
        exact: List<String>,
        contains: List<String>,
        excluding: List<String> = emptyList(),
    ): String? {
        val set = headers.toHashSet()
        exact.firstOrNull { it in set }?.let { return it }
        for (h in headers) {
            if (excluding.any { it in h }) continue
            if (contains.any { it in h }) return h
        }
        return null
    }

    // MARK: - Marker name → catalog key

    /** The two keys of the blood-pressure pair (values match LabBookProjection). */
    internal const val BP_SYSTOLIC_KEY = "bp_systolic"
    internal const val BP_DIASTOLIC_KEY = "bp_diastolic"

    /** Sentinel for a COMBINED blood-pressure name ("blood pressure", "BP") whose value
     *  cell carries the "120/80" pair. */
    private const val BP_COMBINED = "bp_combined"

    internal data class ResolvedMarker(
        /** The catalog / custom key, or null for the combined-BP sentinel. */
        val key: String?,
        /** True for any bp-family name (combined, systolic or diastolic) — those may
         *  legitimately carry a "120/80" pair value. */
        val isBloodPressureFamily: Boolean,
    )

    /**
     * Resolve a raw marker-name cell to a stable key: catalog key, catalog display name,
     * alias, or (fallback) a `custom_<slug>` key identical to the one the manual editor
     * mints — so CSV customs and hand-added customs fold onto one history.
     */
    internal fun resolveMarker(rawName: String): ResolvedMarker {
        val norm = matchNorm(rawName)
        if (norm.isEmpty()) return ResolvedMarker(key = null, isBloodPressureFamily = false)
        val mapped = aliasTable[norm]
        if (mapped != null) {
            if (mapped == BP_COMBINED) return ResolvedMarker(key = null, isBloodPressureFamily = true)
            return ResolvedMarker(
                key = mapped,
                isBloodPressureFamily = mapped == BP_SYSTOLIC_KEY || mapped == BP_DIASTOLIC_KEY,
            )
        }
        val key = customKey(rawName)
        if (key.isEmpty()) return ResolvedMarker(key = null, isBloodPressureFamily = false)
        return ResolvedMarker(key = key, isBloodPressureFamily = false)
    }

    /** Catalog keys + normalized display names + hand-picked common aliases → key.
     *  Built once. Alias keys are in [matchNorm] form. Byte-identical to Swift. */
    private val aliasTable: Map<String, String> by lazy {
        val t = HashMap<String, String>()
        for (def in MarkerCatalog.builtIn) {
            t[matchNorm(def.key)] = def.key
            t[matchNorm(def.displayName)] = def.key
        }
        // Common report/spreadsheet spellings. NON-DIAGNOSTIC name folding only.
        val extras = mapOf(
            "cholesterol" to "total_cholesterol",
            "cholesterol_total" to "total_cholesterol",
            "ldl_c" to "ldl", "ldl_cholesterol" to "ldl",
            "hdl_c" to "hdl", "hdl_cholesterol" to "hdl",
            "triglyceride" to "triglycerides",
            "glucose" to "fasting_glucose", "blood_glucose" to "fasting_glucose",
            "glucose_fasting" to "fasting_glucose",
            "a1c" to "hba1c", "hb_a1c" to "hba1c",
            "vit_d" to "vitamin_d", "vitamin_d3" to "vitamin_d", "25_oh_vitamin_d" to "vitamin_d",
            "b12" to "vitamin_b12", "vit_b12" to "vitamin_b12",
            "folic_acid" to "folate",
            "serum_iron" to "iron",
            "tsat" to "transferrin_saturation",
            "hemoglobin" to "haemoglobin", "hb" to "haemoglobin",
            "c_reactive_protein" to "crp", "hs_crp" to "crp",
            "ft4" to "free_t4", "t4_free" to "free_t4",
            "sgpt" to "alt", "sgot" to "ast", "gamma_gt" to "ggt",
            "systolic" to "bp_systolic", "sbp" to "bp_systolic",
            "systolic_blood_pressure" to "bp_systolic", "blood_pressure_systolic" to "bp_systolic",
            "diastolic" to "bp_diastolic", "dbp" to "bp_diastolic",
            "diastolic_blood_pressure" to "bp_diastolic", "blood_pressure_diastolic" to "bp_diastolic",
            "blood_pressure" to BP_COMBINED, "bp" to BP_COMBINED,
            "pulse" to "resting_pulse", "resting_heart_rate" to "resting_pulse",
            "body_weight" to "weight", "bodyweight" to "weight",
            "body_fat_pct" to "body_fat", "body_fat_percentage" to "body_fat",
            "waist_circumference" to "waist",
        )
        t.putAll(extras)
        t
    }

    /**
     * Full-collapse normal form for alias matching: lowercase, diacritic-folded, every
     * non-alphanumeric RUN → one `_`, trimmed. (Deliberately NOT [HeaderNorm.normalize],
     * whose WHOOP-header alias map must never fire here.)
     */
    internal fun matchNorm(s: String): String {
        val folded = java.text.Normalizer.normalize(s.lowercase().trim(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
        val out = StringBuilder(folded.length)
        var lastWasUnderscore = false
        for (ch in folded) {
            val isAsciiAlnum = (ch in 'a'..'z') || (ch in '0'..'9')
            if (isAsciiAlnum) {
                out.append(ch)
                lastWasUnderscore = false
            } else if (!lastWasUnderscore) {
                out.append('_')
                lastWasUnderscore = true
            }
        }
        return out.toString().trim('_')
    }

    /**
     * The `custom_<slug>` key for an unrecognised marker name. MUST stay byte-identical
     * to the manual editor's MarkerUnits.slug (ui/MarkerEditorScreen.kt) so a CSV custom
     * marker folds onto a hand-added one. Returns "" for a name with no usable characters.
     */
    internal fun customKey(name: String): String {
        val lowered = name.trim().lowercase()
        val mapped = lowered.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        val collapsed = mapped.replace("__", "_").trim('_')
        return if (collapsed.isEmpty()) "" else "custom_$collapsed"
    }

    // MARK: - Value parsing (decimal commas welcome, nothing guessed)

    private val DECIMAL_COMMA = Regex("^[+-]?[0-9]+,[0-9]+$")
    private val THOUSANDS = Regex("^[+-]?[0-9]{1,3}(,[0-9]{3})+(\\.[0-9]+)?$")

    /**
     * Parse a value cell as a number. Handles plain decimals, a European decimal comma
     * ("5,2"), a thousands-grouped integer ("1,234"), and a trailing unit accidentally
     * left in the cell ("5.2 mmol/L"). Anything else — text results, empty cells, a
     * slash pair outside the BP path — is null, so the row is SKIPPED and counted,
     * never guessed. Byte-identical to the Swift grammar.
     */
    internal fun parseValue(raw: String): Double? {
        val t = raw.trim()
        if (t.isEmpty()) return null
        numberToken(t)?.let { return it }

        // "5.2 mmol/L" / "62 ms": a leading number token, then whitespace + unit text.
        // A "/" IMMEDIATELY after the number (a 120/80 pair, a date) is never a unit.
        var i = 0
        while (i < t.length && t[i] in "0123456789+-.,") i += 1
        if (i == 0 || i >= t.length || t[i] != ' ') return null
        return numberToken(t.substring(0, i))
    }

    /** A finite-only Double parse: NaN / +Inf / -Inf (from "NaN"/"Infinity"/"1e999") are REJECTED so a
     *  hostile or typo'd cell skips-and-counts instead of storing a non-finite "reading" that reaches the
     *  chart math (the importer's "nothing guessed" contract). Also rejects the Java-only "5f"/"5d" and
     *  hex-float tokens java Double.parseDouble accepts but Swift Double() does not, so both platforms
     *  import the same file byte-identically. */
    private fun finiteDouble(s: String): Double? {
        // toDoubleOrNull tolerates a trailing f/F/d/D suffix (a Java float/double literal) that Swift's
        // Double() rejects; drop those so both platforms accept the SAME tokens. (Hex floats like 0x1p3
        // parse on both, so they are left alone.)
        if (s.any { it == 'f' || it == 'F' || it == 'd' || it == 'D' }) return null
        val d = s.toDoubleOrNull() ?: return null
        return if (d.isFinite()) d else null
    }

    /** One bare numeric token with the comma rules — must be exactly a number.
     *  `internal` so the WHOOP biomarker parser can split a packed "value unit" cell. */
    internal fun numberToken(t: String): Double? {
        finiteDouble(t)?.let { return it }
        // One decimal comma ("5,2"; but 3 digits after a single comma reads as a
        // thousands group, anything else as a decimal comma).
        if (DECIMAL_COMMA.matches(t)) {
            val intPart = t.substringBefore(',')
            val afterComma = t.substringAfter(',').length
            // A bare-zero (or leading-zero) integer part can only be a DECIMAL comma: "0,500" is 0.5, never
            // a 500 thousands group (a real thousands number never starts with a lone 0). So the 3-digit
            // thousands rule must NOT fire for those - it used to store "0,500" as 500 (1000x). Mirrors Swift.
            val intIsZeroLed = intPart.startsWith("0") || intPart.startsWith("+0") || intPart.startsWith("-0")
            return if (afterComma == 3 && !intIsZeroLed) {
                finiteDouble(t.replace(",", ""))
            } else {
                finiteDouble(t.replace(",", "."))
            }
        }
        // Multi-group thousands ("1,234,567" or "1,234.5").
        if (THOUSANDS.matches(t)) return finiteDouble(t.replace(",", ""))
        return null
    }

    private val BP_HALF = Regex("^[0-9]+([.,][0-9]+)?$")

    /** A combined blood-pressure pair "120/80" (decimal comma or dot tolerated in each
     *  half) as (systolic, diastolic). null for anything else. */
    internal fun bloodPressurePair(raw: String): Pair<Double, Double>? {
        val parts = raw.trim().split("/")
        if (parts.size != 2) return null
        val sysText = parts[0].trim()
        val diaText = parts[1].trim()
        if (!BP_HALF.matches(sysText) || !BP_HALF.matches(diaText)) return null
        val sys = sysText.replace(",", ".").toDoubleOrNull() ?: return null
        val dia = diaText.replace(",", ".").toDoubleOrNull() ?: return null
        return sys to dia
    }

    // MARK: - Date parsing (pure, timezone-free — the day is a literal)

    private val ISO_PREFIX = Regex("""^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?!\d)""")
    private val DMY_OR_MDY = Regex("""^(\d{1,2})[./-](\d{1,2})[./-](\d{4})(?!\d)""")

    /**
     * Canonicalise a date cell to "yyyy-MM-dd". Accepted (a trailing time after the
     * date is tolerated and ignored):
     *   • ISO-first: "2026-06-15", "2026/6/1", "2026-06-15 08:30".
     *   • Day/month-first with a 4-digit year: "15/01/2026" (day-first when the first
     *     number can only be a day), otherwise month-first ("01/15/2026" — the US
     *     spreadsheet default, same rule as NutritionCsvImporter.parseDay).
     * Anything else is null, so the row is skipped and counted.
     */
    internal fun canonicalDay(raw: String): String? {
        val t = raw.trim()
        if (t.isEmpty()) return null

        ISO_PREFIX.find(t)?.let { m ->
            val (y, mo, d) = m.destructured
            return validDay(y.toInt(), mo.toInt(), d.toInt())
        }
        DMY_OR_MDY.find(t)?.let { m ->
            val a = m.groupValues[1].toInt()
            val b = m.groupValues[2].toInt()
            val y = m.groupValues[3].toInt()
            // a > 12 can only be a day; otherwise default to US month-first.
            val (month, dayOfMonth) = if (a > 12) b to a else a to b
            return validDay(y, month, dayOfMonth)
        }
        return null
    }

    /** "yyyy-MM-dd" when the components form a real calendar date, else null.
     *  Pure math (leap-aware) — byte-identical to the Swift twin. `internal` so the WHOOP
     *  biomarker parser can build a date from an M/D/YY (2-digit-year) cell. */
    internal fun validDay(year: Int, month: Int, day: Int): String? {
        if (month !in 1..12 || day < 1 || day > daysInMonth(year, month)) return null
        return "%04d-%02d-%02d".format(Locale.US, year, month, day)
    }

    private fun daysInMonth(y: Int, m: Int): Int = when (m) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) 29 else 28
        else -> 0
    }

    // MARK: - takenAt derivation (wrapper only, not part of the pure parse)

    /** Epoch seconds of UTC noon on a "yyyy-MM-dd" day — a deterministic, LOCATION-INDEPENDENT takenAt
     *  for imported rows, so re-importing the same file (even after travelling to another zone) upserts
     *  in place instead of minting a duplicate. Pinned to UTC on BOTH platforms so the natural key
     *  (deviceId, markerKey, takenAt, source) never shifts with the device zone. History dates render
     *  from the stored `day` string, not this takenAt. */
    private fun labNoonEpoch(day: String): Long {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val base = try { fmt.parse(day)?.time ?: 0L } catch (_: Exception) { 0L }
        return base / 1000L + 12L * 3600L
    }
}

// MARK: - Stream helper (file-private; the other importers' twins are not visible here)

