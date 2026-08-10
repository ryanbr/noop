import Foundation

// MARK: - WHOOP biomarker CSV export parser (source "whoop-biomarkers")
//
// WhoopBiomarkerExportParser.swift — Kotlin twin of
// android/app/src/main/java/com/noop/ingest/WhoopBiomarkerExportParser.kt. Keep the two
// byte-identical.
//
// WHOOP's own biomarker export ("Biomarker Name","Value","Status","Recorded On Date") matches
// none of the generic `LabMarkerCsvImport` column aliases cleanly and differs in four further
// ways, so importing your own WHOOP labs otherwise means rewriting the file by hand (issue #1220).
// This is a VENDOR-GATED parser (like the Fitbit/Garmin/Oura export parsers): its looser rules —
// a US M/D/YY date, a unit packed inside the value cell — only ever run for a file that carries
// the WHOOP signature, so the generic path's "never guess" discipline is untouched.
//
// It reuses `LabMarkerCsvImport`'s tested core (marker→key resolution, the number grammar, the
// calendar-date validator) and produces the SAME `LabMarkerCsvResult` the generic importer does,
// so the store/app path is unchanged. Five deltas, all WHOOP-only:
//   1. Header aliases: "Biomarker Name" → marker, "Recorded On Date" → date.
//   2. Split a packed "value unit" cell ("70 cells/uL" → 70 + "cells/uL"), unit stored verbatim.
//   3. Accept a US M/D/YY (2-digit-year) date — contained to this vendor, never the generic path.
//   4. Tolerate thousands separators (already handled by the shared number grammar).
//   5. "--" / "No Data Available" rows are NOT MEASURED, counted separately, not "skipped".
//
// NON-CLINICAL: WHOOP's own "Status" column (Optimal / Sufficient / Out of Range) is carried
// VERBATIM into `LabMarkerCsvRow.note` with a "WHOOP:" prefix — the user's own provider's word,
// source-attributed, never NOOP asserting anything. Units are stored verbatim, never converted.
//
// Pure and deterministic — no DB, no I/O.

public enum WhoopBiomarkerExportParser {

    /// Provenance/source id stored on every imported reading. Distinct from the generic "lab-csv".
    public static let sourceId = "whoop-biomarkers"

    /// WHOOP export header keys (post-`HeaderNorm.normalize`; the foreign-alias map is wearable-only,
    /// so these biomarker headers pass through unaliased on both platforms).
    private static let nameCol = "biomarker_name"
    private static let valueCol = "value"
    private static let statusCol = "status"
    private static let dateCol = "recorded_on_date"

    /// True when `table` is a WHOOP biomarker export (its four-column signature). Only then do the
    /// vendor-specific rules below apply; any other file falls to the generic `LabMarkerCsvImport`.
    static func matches(_ table: CSVTable) -> Bool {
        let h = Set(table.normalizedHeaders)
        return h.contains(nameCol) && h.contains(valueCol) && h.contains(statusCol) && h.contains(dateCol)
    }

    public static func matches(text: String) -> Bool { matches(CSVTable(text: text)) }

    /// Signature check on raw bytes, using the SAME decode as `parse(data:)` (BOM-tolerant, latin-1
    /// fallback) so detection and parsing never disagree on an odd encoding. The app layer, which
    /// can't see the internal `CSVTable`, routes on this before calling `parse(data:)`.
    public static func matches(data: Data) -> Bool {
        data.count <= LabMarkerCsvImport.maxBytes && matches(CSVTable(data: data))
    }

    /// Parse raw CSV bytes. Files over the shared byte cap are rejected outright.
    public static func parse(data: Data) -> LabMarkerCsvResult {
        guard data.count <= LabMarkerCsvImport.maxBytes else {
            return LabMarkerCsvResult(rows: [], skippedRows: 0, customMarkerKeys: [],
                                      earliestDay: nil, latestDay: nil, truncated: false,
                                      fileTooLarge: true, notMeasured: 0)
        }
        return parseTable(CSVTable(data: data), maxRows: LabMarkerCsvImport.maxRows)
    }

    /// Parse CSV text.
    public static func parse(text: String) -> LabMarkerCsvResult {
        parseTable(CSVTable(text: text), maxRows: LabMarkerCsvImport.maxRows)
    }

    // MARK: - Core (row cap injectable for tests)

    static func parseTable(_ table: CSVTable, maxRows: Int) -> LabMarkerCsvResult {
        var byCell: [String: LabMarkerCsvRow] = [:]   // (markerKey \u{1} day) → last row wins
        var skipped = 0
        var notMeasured = 0
        var truncated = false
        var customKeys: Set<String> = []

        func store(_ row: LabMarkerCsvRow) {
            byCell[row.markerKey + "\u{1}" + row.day] = row
        }

        for (index, row) in table.rows.enumerated() {
            if index >= maxRows {
                skipped += table.rows.count - maxRows
                truncated = true
                break
            }
            let rawValue = row.cell(valueCol) ?? ""
            let rawDate = row.cell(dateCol) ?? ""
            let rawName = row.cell(nameCol)
            let rawStatus = row.cell(statusCol)

            // WHOOP marks an unmeasured marker with "--" (value AND date) or "No Data Available" (status).
            // That is legitimately absent, not malformed — count it apart so a clean export doesn't report
            // dozens of "skipped" rows and look broken.
            if isNoData(rawValue) || isNoData(rawDate) { notMeasured += 1; continue }

            guard let rawName else { skipped += 1; continue }
            guard let day = whoopDay(rawDate) else { skipped += 1; continue }
            guard let split = splitValueUnit(rawValue) else { skipped += 1; continue }
            let (value, packedUnit) = split

            // Reuse the generic marker→key resolution. A bp-combined sentinel (key == nil) has no single
            // marker to land on in a one-value-per-row export, so skip it (WHOOP does not emit paired BP here).
            let resolved = LabMarkerCsvImport.resolveMarker(rawName)
            guard let key = resolved.key else { skipped += 1; continue }

            let category: LabMarkerCategory
            let unit: String
            if let def = MarkerCatalog.definition(for: key) {
                category = def.category
                unit = packedUnit.isEmpty ? def.canonicalUnit : packedUnit
            } else {
                category = .other
                unit = packedUnit
                customKeys.insert(key)
            }

            let note: String? = {
                guard let s = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !s.isEmpty, !isNoData(s) else { return nil }
                return "WHOOP: " + s
            }()
            store(LabMarkerCsvRow(markerKey: key, category: category, day: day, value: value,
                                  unit: unit, isCustomMarker: MarkerCatalog.definition(for: key) == nil,
                                  note: note))
        }

        let rows = byCell.values.sorted {
            $0.day == $1.day ? $0.markerKey < $1.markerKey : $0.day < $1.day
        }
        let days = rows.map(\.day)
        return LabMarkerCsvResult(rows: rows, skippedRows: skipped, customMarkerKeys: customKeys.sorted(),
                                  earliestDay: days.min(), latestDay: days.max(),
                                  truncated: truncated, fileTooLarge: false, notMeasured: notMeasured)
    }

    // MARK: - WHOOP-specific cell handling

    /// WHOOP's not-measured sentinels: a literal "--" or "No Data Available" (any case/spacing).
    /// Matched via `LabMarkerCsvImport.matchNorm` so "no data available" folds regardless of casing.
    static func isNoData(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "--" { return true }
        return LabMarkerCsvImport.matchNorm(t) == "no_data_available"
    }

    /// Split a packed WHOOP value cell into (number, verbatim unit): "70 cells/uL" → 70 + "cells/uL",
    /// "3,490 cells/uL" → 3490 + "cells/uL", "33 U/L" → 33 + "U/L", a bare "70" → 70 + "". nil when the
    /// leading token is not a number (skip-and-count). Reuses the shared number grammar for the value.
    static func splitValueUnit(_ raw: String) -> (Double, String)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = LabMarkerCsvImport.numberToken(t) { return (d, "") }   // whole cell is a number, no unit
        let scalars = Array(t)
        var i = 0
        while i < scalars.count, "0123456789+-.,".contains(scalars[i]) { i += 1 }
        guard i > 0, i < scalars.count, scalars[i] == " " else { return nil }
        guard let value = LabMarkerCsvImport.numberToken(String(scalars[0..<i])) else { return nil }
        let unit = String(scalars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        return (value, unit)
    }

    /// Canonicalise a WHOOP date to "yyyy-MM-dd". WHOOP writes a US month-first date, usually with a
    /// 2-digit year ("7/2/26" → 2026-07-02). ISO and 4-digit-year forms delegate to the shared
    /// `LabMarkerCsvImport.canonicalDay`; the 2-digit-year form is handled here (vendor-gated, so the
    /// generic path never guesses a 2-digit US year). Month-first is KNOWN for WHOOP, so an invalid
    /// month (a value the generic ambiguity-resolver would swap) is simply rejected.
    static func whoopDay(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = LabMarkerCsvImport.canonicalDay(t) { return iso }
        guard let m = firstMatch(t, pattern: "^([0-9]{1,2})[./-]([0-9]{1,2})[./-]([0-9]{2})(?![0-9])")
        else { return nil }
        let year = 2000 + m[2]
        return LabMarkerCsvImport.validDay(year: year, month: m[0], day: m[1])
    }

    /// First regex match's integer capture groups, or nil (a local copy of the generic importer's
    /// private helper — the two are trivially identical).
    private static func firstMatch(_ s: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        var out: [Int] = []
        for i in 1..<match.numberOfRanges {
            guard let r = Range(match.range(at: i), in: s), let v = Int(s[r]) else { return nil }
            out.append(v)
        }
        return out
    }
}
