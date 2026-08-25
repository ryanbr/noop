package com.noop.analytics

// ImportTrace.kt - Kotlin twin of ImportTrace.swift. Pure line formatters + the live-readout parser for
// the Import & Data Ingest test mode (TestDomain.IMPORT, wire id "import"), byte-aligned with the Swift
// line shapes so a shared report reads identically on either platform.
//
// What an import run reports: parserVersion (importer + version), fileMeta (kind + ext + size BUCKET, never
// a path/name), perStageRows (rows parsed/mapped in vs rows the store reported out), rejectCounts (rows the
// parser/map dropped + tolerant XML spans scrubbed), dayDeltas (distinct days mapped vs persisted), and a
// REDACTED, length-capped firstFailingRow / failingFileSample.
//
// HARD privacy rule (matches Swift): firstFailingRow + failingFileSample are user data; they are masked
// (digits -> #, letters -> x, structure kept) + capped HERE, before the line reaches the redacting log
// sink, and the export re-scrubs every line again. No clock, no IO, no raw PII. No em-dashes.

object ImportTrace {

    /** Bump when a line shape changes. Stamped into the parser line. SAME value as the Swift twin. */
    const val TRACE_VERSION = 1

    // parserVersion + fileMeta

    /** The parser-identity line: which importer ran (wire [kind], e.g. "whoopExport"), its per-importer
     *  schema version, and the trace version. Mirrors the Swift formatter. */
    fun parserVersionLine(kind: String, importerVersion: Int): String =
        "import parser=$kind v=$importerVersion traceV=$TRACE_VERSION"

    /** The file-meta line: the detected kind, the lowercased+sanitized extension, and the size BUCKET
     *  (never the byte-exact size, never the name or path). Mirrors the Swift formatter. */
    fun fileMetaLine(kind: String, ext: String, sizeBytes: Long): String =
        "import file kind=$kind ext=${safeExt(ext)} size=${sizeBucket(sizeBytes)}"

    // perStageRows + rejectCounts + dayDeltas

    /** One per-stage line: rows handed to the store ([rowsIn]) vs rows it reported writing ([rowsOut]); a
     *  gap is the "mapped but not saved" / day-owner-collision signal. Mirrors the Swift formatter. */
    fun stageLine(category: String, rowsIn: Int, rowsOut: Int): String {
        val note = if (rowsOut < rowsIn) " (${rowsIn - rowsOut} not written)" else " (all written)"
        return "import stage=$category rowsIn=$rowsIn rowsOut=$rowsOut$note"
    }

    /**
     * Which metric columns an imported table actually carried, and which were empty in every row.
     *
     * The import trace already reports rows in, rows rejected and days mapped, but not whether a given
     * COLUMN arrived. That is the question behind a whole class of "why is this card empty" reports: the
     * file imported cleanly, the rows landed, and one metric is still blank because the export never
     * contained it — or contained it under a header the aliases do not match. Both look identical from
     * outside, and neither is distinguishable from a store-write failure without this line.
     *
     * [counts] is (column, rows-with-a-usable-value) in the parser's own order, so the line reads in the
     * order a maintainer would look for them. A column at zero is called out explicitly in an ABSENT
     * clause rather than left for the reader to spot among a dozen numbers; the clause is omitted when
     * every column arrived, so the healthy case is quiet but still present.
     *
     * Known at parse time, so it carries none of the store-write ambiguity that keeps rowsOut honest but
     * unverified on Android — this line means the same thing on both platforms. Swift twin:
     * `ImportTrace.columnCoverageLine`.
     */
    fun columnCoverageLine(stage: String, rows: Int, counts: List<Pair<String, Int>>): String {
        // Built from the non-empty parts rather than interpolated positionally: an empty [counts] would
        // otherwise leave a trailing space, and a malformed line is worse than a useless one for anything
        // that later greps these logs. No caller can pass empty today; the formatter is shared, so it
        // should not depend on that staying true.
        val head = "import columns stage=$stage rows=$rows"
        val body = counts.joinToString(" ") { "${it.first}=${it.second}" }
        val absent = counts.filter { it.second == 0 }.map { it.first }
        val tail = if (absent.isEmpty()) "" else " — ABSENT: ${absent.joinToString(", ")}"
        return if (body.isEmpty()) head else "$head $body$tail"
    }

    /** The reject-counts line: rows dropped as unusable + tolerant XML spans scrubbed. Mirrors Swift. */
    fun rejectLine(droppedRows: Int, skippedSpans: Int): String =
        "import rejects droppedRows=$droppedRows skippedSpans=$skippedSpans"

    /** Honest per-stage line for the Android seam, where Room's @Upsert reports no store-write count (it is
     *  fire-and-forget at this layer, unlike the Swift store which returns the summed SQLite changes). It
     *  emits the rows handed to the store ([rowsIn]) but marks rowsOut UNVERIFIED rather than claiming
     *  "(all written)" - so the line never asserts a save it cannot confirm. The "rowsOut=?" marker keeps
     *  the line honest for the #601/#749/#754 "didn't save" cluster: an unverified write is shown as
     *  unverified, not as success. No Swift twin (Swift always has the real count). */
    fun stageLineUnverified(category: String, rowsIn: Int): String =
        "import stage=$category rowsIn=$rowsIn rowsOut=? (store-write not verified on Android)"

    /** Honest day-delta line for the Android seam: the distinct days MAPPED, with daysPersisted marked
     *  UNVERIFIED rather than claiming "(all days persisted)", because Room does not report the persisted
     *  count at this layer. Mirror of [stageLineUnverified] for the day-owner-collision tell. */
    fun dayDeltaLineUnverified(category: String, daysMapped: Int): String =
        "import dayDelta stage=$category daysMapped=$daysMapped daysPersisted=? (store-write not verified on Android)"

    /** The day-delta line: distinct local days MAPPED vs days the store PERSISTED; a gap is the
     *  day-owner-collision / "didn't save" tell. Mirrors the Swift formatter. */
    fun dayDeltaLine(category: String, daysMapped: Int, daysPersisted: Int): String {
        val note = if (daysPersisted < daysMapped) " (${daysMapped - daysPersisted} days not persisted)"
        else " (all days persisted)"
        return "import dayDelta stage=$category daysMapped=$daysMapped daysPersisted=$daysPersisted$note"
    }

    // firstFailingRow + failingFileSample (redacted, capped)

    /** The first-failing-row line: a REDACTED, length-capped rendering of the first row the parser could
     *  not use. The [headerKeys] are schema (kept); the [rawCells] are user data and are masked cell-by-cell
     *  before the line is built. null when there is no failing row. Mirrors the Swift formatter. */
    fun firstFailingRowLine(category: String, rowIndex: Int,
                            headerKeys: List<String>, rawCells: List<String>): String? {
        if (rawCells.isEmpty()) return null
        val masked = rawCells.take(MAX_SAMPLE_CELLS).joinToString(",") { redactCell(it) }
        val cols = headerKeys.take(MAX_SAMPLE_CELLS).joinToString(",")
        val shape = if (cols.isEmpty()) "" else " cols=[${capped(cols)}]"
        return "import firstFailingRow stage=$category row=$rowIndex$shape masked=[${capped(masked)}]"
    }

    /** The failing-file-sample lines: a REDACTED, capped peek at the start of a file that failed to parse
     *  at all. [rawSample] is masked + hard-capped here. emptyList() when there is nothing to sample.
     *  Mirrors the Swift formatter. */
    fun failingFileSampleLines(kind: String, rawSample: String): List<String> {
        val masked = redactSample(rawSample)
        if (masked.isEmpty()) return emptyList()
        return listOf(
            "import failingFileSample kind=$kind bytes=${sizeBucket(rawSample.toByteArray(Charsets.UTF_8).size.toLong())} " +
                "sample=[$masked]",
        )
    }

    // Redaction + caps (the privacy floor) - byte-identical to the Swift helpers.

    const val MAX_SAMPLE_CELLS = 12
    const val MAX_SAMPLE_CHARS = 200

    /** Mask one cell's value: any Unicode NUMBER -> "#", any letter -> "x", everything else passes through,
     *  so the SHAPE survives but no real datum does. Byte-identical to the Swift redactCell: Swift uses
     *  Character.isNumber (the whole Unicode Number group - decimal Nd, letter-number Nl, other-number No),
     *  so the test below matches all three rather than Kotlin's isDigit() (decimal Nd only) - otherwise a
     *  superscript or fraction in a cell would mask differently across platforms and the masked output for
     *  the SAME row would not be identical. */
    fun redactCell(s: String): String {
        val sb = StringBuilder(s.length)
        for (ch in s) {
            when {
                isUnicodeNumber(ch) -> sb.append('#')
                ch.isLetter() -> sb.append('x')
                else -> sb.append(ch)
            }
        }
        return sb.toString()
    }

    /** True for the whole Unicode Number group (Nd, Nl, No), matching Swift's Character.isNumber - NOT just
     *  decimal digits (Kotlin's Char.isDigit), so masked output is byte-identical to the Swift twin. */
    private fun isUnicodeNumber(ch: Char): Boolean = when (Character.getType(ch)) {
        Character.DECIMAL_DIGIT_NUMBER.toInt(),
        Character.LETTER_NUMBER.toInt(),
        Character.OTHER_NUMBER.toInt() -> true
        else -> false
    }

    /** Mask a free-form file sample the SAME way as a cell, after collapsing newlines, then hard-cap it.
     *  Mirrors the Swift redactSample. */
    fun redactSample(s: String): String {
        val oneLine = s.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
        return capped(redactCell(oneLine))
    }

    /** Hard-cap a fragment to MAX_SAMPLE_CHARS, appending "..." when trimmed. Mirrors the Swift capped. */
    fun capped(s: String): String =
        if (s.length <= MAX_SAMPLE_CHARS) s else s.substring(0, MAX_SAMPLE_CHARS) + "..."

    /** A coarse size bucket so the line never carries the byte-exact size. Mirrors the Swift sizeBucket. */
    fun sizeBucket(bytes: Long): String = when {
        bytes < 0 -> "?"
        bytes < 1_024 -> "<1KB"
        bytes < 10_240 -> "1-10KB"
        bytes < 102_400 -> "10-100KB"
        bytes < 1_048_576 -> "100KB-1MB"
        bytes < 10_485_760 -> "1-10MB"
        bytes < 104_857_600 -> "10-100MB"
        bytes < 1_073_741_824 -> "100MB-1GB"
        else -> ">1GB"
    }

    /** Sanitise an extension to a short alphanumeric token. Mirrors the Swift safeExt. */
    fun safeExt(ext: String): String {
        val t = ext.lowercase().filter { it.isLetter() || it.isDigit() }
        return if (t.isEmpty()) "none" else t.take(8)
    }

    /** Map an Android importer's raw Room-table count key (ImportSummary.counts key, e.g. "dailyMetric",
     *  "sleepSession", "workout") to the Swift import-trace CATEGORY vocabulary, so a cross-platform report
     *  keys every per-stage line off the SAME stage= name. The mapping is source-aware because the same Room
     *  table means different Swift categories per importer: WHOOP's dailyMetric IS the cycle-derived daily
     *  (Swift "cycles") and its sleepSession IS Swift "sleeps", whereas Apple Health keeps its own
     *  appleDaily/dailyMetric split. Keys with no Swift twin (journal, metricSeries) and the reject key
     *  (skippedSpans, never a stage) pass through unchanged. Pure; no IO; no em-dashes. */
    fun categoryWire(source: String, rawKey: String): String = when (source) {
        // WHOOP export (WhoopCsvImporter SOURCE_LABEL "WHOOP"): align with WhoopImporter.swift categories.
        "WHOOP" -> when (rawKey) {
            "dailyMetric" -> "cycles"
            "sleepSession" -> "sleeps"
            "workout" -> "workouts"
            else -> rawKey   // journal, metricSeries: no Swift category, keep the raw key
        }
        // Apple Health (AppleHealthImporter SOURCE_LABEL): align with AppleHealthImport.swift categories.
        "Apple Health" -> when (rawKey) {
            "workout" -> "workouts"
            else -> rawKey   // appleDaily, dailyMetric, metricSeries already match Swift / have no twin
        }
        // Any other source: only normalise the singular table name to the Swift plural where it exists.
        else -> when (rawKey) {
            "workout" -> "workouts"
            else -> rawKey
        }
    }

    /** Map an Android importer's human source label (ImportSummary.source) to the Swift DataSourceKind wire
     *  string, so the parser/file lines read identically on both platforms. An unknown label passes through
     *  lowercased + sanitized so a new source never crashes or leaks free text. */
    fun kindWire(source: String): String = when (source) {
        "WHOOP" -> "whoopExport"
        "Apple Health" -> "appleHealth"
        "Xiaomi Smart Band" -> "xiaomiBand"
        "Oura" -> "ouraImport"
        "Fitbit" -> "fitbitImport"
        "Garmin" -> "garminImport"
        else -> source.lowercase().filter { it.isLetterOrDigit() }.ifEmpty { "unknown" }
    }
}

/**
 * Pure values for the Import & Data Ingest live-readout. Kotlin twin of the Swift ImportReadout. Parses
 * the IMPORT-tagged log tail the import emitters write. No state, no IO, no em-dashes. (The Compose readout
 * panel is deferred for ALL modes; this parser exists for parity + the shared report.)
 */
object ImportReadout {

    /** The last import summary for the `lastImportSummary` id: the most recent parser-identity fragment in
     *  the tagged tail, enriched with the latest per-stage and day-delta fragment. null when no import has
     *  been traced yet. Mirrors the Swift parser. */
    fun lastImportSummary(taggedTail: List<String>): String? {
        var parserFrag: String? = null
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("import parser=")
            if (i >= 0) { parserFrag = line.substring(i + "import parser=".length).trim(); break }
        }
        val parser = parserFrag ?: return null

        var stageFrag: String? = null
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("import stage=")
            if (i >= 0) { stageFrag = line.substring(i + "import stage=".length).trim(); break }
        }
        var dayFrag: String? = null
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("import dayDelta ")
            if (i >= 0) { dayFrag = line.substring(i + "import dayDelta ".length).trim(); break }
        }

        val sb = StringBuilder("parser=$parser")
        if (stageFrag != null) sb.append(" · stage=").append(stageFrag)
        if (dayFrag != null) sb.append(" · ").append(dayFrag)
        return sb.toString()
    }
}
