package com.noop.ingest

import com.noop.analytics.LabMarkerCategory
import com.noop.analytics.MarkerCatalog
import com.noop.ingest.LabMarkerCsvImport.LabMarkerCsvResult
import com.noop.ingest.LabMarkerCsvImport.LabMarkerCsvRow

/**
 * WHOOP biomarker CSV export parser (source "whoop-biomarkers") — Kotlin twin of
 * Packages/StrandImport/Sources/StrandImport/WhoopBiomarkerExportParser.swift. Keep the two
 * byte-identical.
 *
 * WHOOP's own biomarker export ("Biomarker Name","Value","Status","Recorded On Date") matches
 * none of the generic [LabMarkerCsvImport] column aliases cleanly and differs in four further
 * ways, so importing your own WHOOP labs otherwise means rewriting the file by hand (issue #1220).
 * This is a VENDOR-GATED parser (like the Fitbit/Garmin/Oura export parsers): its looser rules —
 * a US M/D/YY date, a unit packed inside the value cell — only ever run for a file that carries
 * the WHOOP signature, so the generic path's "never guess" discipline is untouched.
 *
 * It reuses [LabMarkerCsvImport]'s tested core (marker→key resolution, the number grammar, the
 * calendar-date validator) and produces the SAME [LabMarkerCsvResult] the generic importer does,
 * so the store/app path is unchanged. Five deltas, all WHOOP-only:
 *   1. Header aliases: "Biomarker Name" → marker, "Recorded On Date" → date.
 *   2. Split a packed "value unit" cell ("70 cells/uL" → 70 + "cells/uL"), unit stored verbatim.
 *   3. Accept a US M/D/YY (2-digit-year) date — contained to this vendor, never the generic path.
 *   4. Tolerate thousands separators (already handled by the shared number grammar).
 *   5. "--" / "No Data Available" rows are NOT MEASURED, counted separately, not "skipped".
 *
 * NON-CLINICAL: WHOOP's own "Status" column (Optimal / Sufficient / Out of Range) is carried
 * VERBATIM into [LabMarkerCsvRow.note] with a "WHOOP:" prefix — the user's own provider's word,
 * source-attributed, never NOOP asserting anything. Units are stored verbatim, never converted.
 *
 * Pure parsing (JVM unit-testable, WhoopBiomarkerExportParserTest).
 */
object WhoopBiomarkerExportParser {

    /** Provenance/source id stored on every imported reading. Distinct from the generic "lab-csv". */
    const val SOURCE_ID = "whoop-biomarkers"

    /** WHOOP export header keys (post-[HeaderNorm.normalize]; the foreign-alias map is wearable-only,
     *  so these biomarker headers pass through unaliased on both platforms). */
    private const val NAME_COL = "biomarker_name"
    private const val VALUE_COL = "value"
    private const val STATUS_COL = "status"
    private const val DATE_COL = "recorded_on_date"

    /** True when [table] is a WHOOP biomarker export (its four-column signature). Only then do the
     *  vendor-specific rules below apply; any other file falls to the generic [LabMarkerCsvImport]. */
    internal fun matches(table: CsvTable): Boolean {
        val h = table.normalizedHeaders.toHashSet()
        return NAME_COL in h && VALUE_COL in h && STATUS_COL in h && DATE_COL in h
    }

    fun matches(text: String): Boolean = matches(CsvTable.fromText(text))

    /** Parse raw CSV bytes. Files over the shared byte cap are rejected outright. */
    fun parse(data: ByteArray): LabMarkerCsvResult {
        if (data.size > LabMarkerCsvImport.MAX_BYTES) {
            return LabMarkerCsvResult(
                rows = emptyList(), skippedRows = 0, customMarkerKeys = emptyList(),
                earliestDay = null, latestDay = null, truncated = false, fileTooLarge = true,
                notMeasured = 0,
            )
        }
        return parse(CsvTable.fromData(data), LabMarkerCsvImport.MAX_ROWS)
    }

    /** Parse CSV text. */
    fun parse(text: String): LabMarkerCsvResult = parse(CsvTable.fromText(text), LabMarkerCsvImport.MAX_ROWS)

    /** Core parse; the row cap is injectable for tests. Mirrors the Swift parseTable. */
    internal fun parse(table: CsvTable, maxRows: Int): LabMarkerCsvResult {
        val byCell = LinkedHashMap<String, LabMarkerCsvRow>()   // (markerKey  day) → last row wins
        var skipped = 0
        var notMeasured = 0
        var truncated = false
        val customKeys = sortedSetOf<String>()

        fun store(row: LabMarkerCsvRow) {
            byCell[row.markerKey + "\u0001" + row.day] = row
        }

        for ((index, row) in table.rows.withIndex()) {
            if (index >= maxRows) {
                skipped += table.rows.size - maxRows
                truncated = true
                break
            }
            val rawValue = row.cell(VALUE_COL) ?: ""
            val rawDate = row.cell(DATE_COL) ?: ""
            val rawName = row.cell(NAME_COL)
            val rawStatus = row.cell(STATUS_COL)

            // WHOOP marks an unmeasured marker with "--" (value AND date) or "No Data Available" (status).
            // That is legitimately absent, not malformed — count it apart so a clean export doesn't report
            // dozens of "skipped" rows and look broken.
            if (isNoData(rawValue) || isNoData(rawDate)) { notMeasured += 1; continue }

            if (rawName == null) { skipped += 1; continue }
            val day = whoopDay(rawDate)
            if (day == null) { skipped += 1; continue }
            val split = splitValueUnit(rawValue)
            if (split == null) { skipped += 1; continue }
            val (value, packedUnit) = split

            // Reuse the generic marker→key resolution. A bp-combined sentinel (key == null) has no single
            // marker to land on in a one-value-per-row export, so skip it (WHOOP does not emit paired BP here).
            val resolved = LabMarkerCsvImport.resolveMarker(rawName)
            val key = resolved.key
            if (key == null) { skipped += 1; continue }

            val def = MarkerCatalog.definition(key)
            val category: LabMarkerCategory
            val unit: String
            if (def != null) {
                category = def.category
                unit = if (packedUnit.isNotEmpty()) packedUnit else def.canonicalUnit
            } else {
                category = LabMarkerCategory.OTHER
                unit = packedUnit
                customKeys.add(key)
            }

            val note = rawStatus?.trim()
                ?.takeIf { it.isNotEmpty() && !isNoData(it) }
                ?.let { "WHOOP: $it" }
            store(LabMarkerCsvRow(key, category, day, value, unit, isCustomMarker = def == null, note = note))
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
            notMeasured = notMeasured,
        )
    }

    // MARK: - WHOOP-specific cell handling

    /** WHOOP's not-measured sentinels: a literal "--" or "No Data Available" (any case/spacing).
     *  Matched via [LabMarkerCsvImport.matchNorm] so "no data available" folds regardless of casing. */
    internal fun isNoData(s: String): Boolean {
        val t = s.trim()
        if (t == "--") return true
        return LabMarkerCsvImport.matchNorm(t) == "no_data_available"
    }

    /** Split a packed WHOOP value cell into (number, verbatim unit): "70 cells/uL" → 70 + "cells/uL",
     *  "3,490 cells/uL" → 3490 + "cells/uL", "33 U/L" → 33 + "U/L", a bare "70" → 70 + "". null when the
     *  leading token is not a number (skip-and-count). Reuses the shared number grammar for the value. */
    internal fun splitValueUnit(raw: String): Pair<Double, String>? {
        val t = raw.trim()
        if (t.isEmpty()) return null
        LabMarkerCsvImport.numberToken(t)?.let { return it to "" }   // whole cell is a number, no unit
        var i = 0
        while (i < t.length && t[i] in "0123456789+-.,") i += 1
        if (i == 0 || i >= t.length || t[i] != ' ') return null
        val value = LabMarkerCsvImport.numberToken(t.substring(0, i)) ?: return null
        val unit = t.substring(i + 1).trim()
        return value to unit
    }

    /** Canonicalise a WHOOP date to "yyyy-MM-dd". WHOOP writes a US month-first date, usually with a
     *  2-digit year ("7/2/26" → 2026-07-02). ISO and 4-digit-year forms delegate to the shared
     *  [LabMarkerCsvImport.canonicalDay]; the 2-digit-year form is handled here (vendor-gated, so the
     *  generic path never guesses a 2-digit US year). Month-first is KNOWN for WHOOP, so an invalid
     *  month (a value the generic ambiguity-resolver would swap) is simply rejected. */
    internal fun whoopDay(raw: String): String? {
        val t = raw.trim()
        LabMarkerCsvImport.canonicalDay(t)?.let { return it }
        val m = MDY2.find(t) ?: return null
        val month = m.groupValues[1].toInt()
        val day = m.groupValues[2].toInt()
        val year = 2000 + m.groupValues[3].toInt()
        return LabMarkerCsvImport.validDay(year, month, day)
    }

    private val MDY2 = Regex("""^(\d{1,2})[./-](\d{1,2})[./-](\d{2})(?!\d)""")
}
