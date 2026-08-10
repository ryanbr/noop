import Foundation

// MARK: - Lab Book markers CSV import (source "lab-csv")
//
// LabMarkerCsvImport.swift — the Phase-2 bulk import for the Health Records "Lab Book"
// pillar (spec 2026-06-19-v5-health-records-design.md §"Phasing"): a generic markers CSV
// with (date, marker, value, unit) rows, exactly the shape the in-app import card
// promises. Header names are matched tolerantly (Date/Day/Taken, Marker/Test/Name,
// Value/Result, Unit/Units) through the shared `CSVTable`, so spreadsheet exports and
// hand-made files both read.
//
// Marker names map onto the built-in `MarkerCatalog` by key, by display name, and
// through a small alias table (systolic/SBP → bp_systolic, A1c → hba1c, …); anything
// unrecognised imports as a CUSTOM marker under the same `custom_<slug>` key the manual
// editor mints, so a CSV custom marker and a hand-added one fold onto one history. A
// combined blood-pressure cell ("120/80") splits into the bp_systolic/bp_diastolic pair
// (spec §"Blood pressure modelling") so diastolic is never silently dropped.
//
// NON-CLINICAL (spec §"Non-clinical / legal framing"): units are stored VERBATIM — this
// importer never converts mg/dL to mmol/L or judges a value. Malformed rows are skipped
// and counted, never fatal, and never guessed (mirrors NutritionCsvImporter's ethos).
// Import-DoS bounds: a byte cap on the file and a row cap on the parse, like the other
// file importers (ActivityFileImporter.maxBytes / WearableExportImporter.maxRows).
//
// Pure and deterministic — no DB, no I/O, no timezone use (dates are handled as literal
// "yyyy-MM-dd" day strings). The app layer maps rows 1:1 onto `LabMarkerRow` (the same
// split NutritionCsvImport keeps between parse and store).

/// One parsed reading: a numeric value for a marker on a literal `yyyy-MM-dd` day.
public struct LabMarkerCsvRow: Sendable, Equatable {
    /// Catalog key (`"ldl"`, `"bp_systolic"`, …) or a `custom_<slug>` key.
    public var markerKey: String
    /// The catalog's category for known markers; `.other` for customs.
    public var category: LabMarkerCategory
    /// Literal day from the file, canonicalised to `yyyy-MM-dd`.
    public var day: String
    /// The numeric reading, exactly as written (no unit conversion, ever).
    public var value: Double
    /// Unit string VERBATIM from the file; the catalog's canonical unit when the file
    /// has no unit column for a known marker; empty for a unit-less custom marker.
    public var unit: String
    /// True when the marker name didn't match the catalog and imported as a custom marker.
    public var isCustomMarker: Bool
    /// Optional free-text note carried VERBATIM from the source (e.g. a vendor's own status
    /// column, source-attributed). nil for the generic (date,marker,value,unit) importer, which
    /// never annotates. Maps to `LabMarker.note`.
    public var note: String?

    public init(markerKey: String, category: LabMarkerCategory, day: String,
                value: Double, unit: String, isCustomMarker: Bool, note: String? = nil) {
        self.markerKey = markerKey
        self.category = category
        self.day = day
        self.value = value
        self.unit = unit
        self.isCustomMarker = isCustomMarker
        self.note = note
    }
}

/// Result of parsing a markers CSV: the readings (deduped per marker+day, last row
/// wins — matching the store's latest-per-day projection), plus skip/bound reporting.
public struct LabMarkerCsvResult: Sendable, Equatable {
    /// Parsed readings, sorted by (day, markerKey). One per (markerKey, day): when a
    /// file repeats a marker on the same day, the LAST row wins (the same rule as
    /// `LabBookProjection` latest-per-day and the nutrition importer's duplicate days).
    public var rows: [LabMarkerCsvRow]
    /// Data rows dropped: unparseable/missing date, missing marker name, or a value
    /// that isn't a number. Reported, never fatal.
    public var skippedRows: Int
    /// Distinct `custom_<slug>` keys created for unrecognised marker names, sorted.
    public var customMarkerKeys: [String]
    public var earliestDay: String?
    public var latestDay: String?
    /// True when the row cap stopped the parse early (the tail was not read).
    public var truncated: Bool
    /// True when the file was rejected outright for exceeding the byte cap.
    public var fileTooLarge: Bool
    /// Rows a vendor export marked as NOT MEASURED (e.g. WHOOP's "--" / "No Data Available").
    /// Counted SEPARATELY from `skippedRows` so a clean import of a normal export doesn't look
    /// broken. Always 0 for the generic importer.
    public var notMeasured: Int

    public init(rows: [LabMarkerCsvRow], skippedRows: Int, customMarkerKeys: [String],
                earliestDay: String?, latestDay: String?, truncated: Bool, fileTooLarge: Bool,
                notMeasured: Int = 0) {
        self.rows = rows
        self.skippedRows = skippedRows
        self.customMarkerKeys = customMarkerKeys
        self.earliestDay = earliestDay
        self.latestDay = latestDay
        self.truncated = truncated
        self.fileTooLarge = fileTooLarge
        self.notMeasured = notMeasured
    }

    /// Number of readings imported.
    public var importedReadings: Int { rows.count }
    /// Number of distinct markers the readings cover.
    public var distinctMarkers: Int { Set(rows.map(\.markerKey)).count }
}

public enum LabMarkerCsvImport {

    /// Provenance/source id stored on every imported reading (`LabMarker.source`).
    public static let sourceId = "lab-csv"

    /// Byte cap — a markers CSV is a few KB in real life; 32 MB is already absurd.
    public static let maxBytes = 32 << 20
    /// Row cap — a lifetime of lab results is a few hundred rows; 50 000 bounds a
    /// hostile file without ever touching a real one.
    public static let maxRows = 50_000

    /// Parse raw CSV bytes (UTF-8, BOM-tolerant, latin-1 fallback — same as `CSVTable`).
    /// Files over `maxBytes` are rejected outright (`fileTooLarge`).
    public static func parse(data: Data) -> LabMarkerCsvResult {
        guard data.count <= maxBytes else {
            return LabMarkerCsvResult(rows: [], skippedRows: 0, customMarkerKeys: [],
                                      earliestDay: nil, latestDay: nil,
                                      truncated: false, fileTooLarge: true)
        }
        return parseTable(CSVTable(data: data), maxRows: maxRows)
    }

    /// Parse CSV text.
    public static func parse(text: String) -> LabMarkerCsvResult {
        parseTable(CSVTable(text: text), maxRows: maxRows)
    }

    // MARK: - Core (row cap injectable for tests)

    static func parseTable(_ table: CSVTable, maxRows: Int) -> LabMarkerCsvResult {
        let headers = table.normalizedHeaders

        // Which normalized column feeds each field. Exact matches first, then a
        // substring fallback (same resolve idiom as NutritionCsvImporter).
        let dateCol = resolve(headers,
                              exact: ["date", "day", "taken", "taken_at", "test_date",
                                      "date_taken", "collected", "collection_date"],
                              contains: ["date"])
        let markerCol = resolve(headers,
                                exact: ["marker", "marker_name", "name", "test", "test_name",
                                        "analyte", "biomarker", "measurement"],
                                contains: ["marker", "test", "analyte"],
                                excluding: ["date", "value", "result", "unit"])
        let valueCol = resolve(headers,
                               exact: ["value", "result", "reading", "amount"],
                               contains: ["value", "result"],
                               excluding: ["unit", "text", "date"])
        let unitCol = resolve(headers,
                              exact: ["unit", "units", "uom"],
                              contains: ["unit"])

        var byCell: [String: LabMarkerCsvRow] = [:]   // (markerKey \u{1} day) → last row wins
        var skipped = 0
        var truncated = false
        var customKeys: Set<String> = []

        for (index, row) in table.rows.enumerated() {
            if index >= maxRows {
                // Bounded, honestly: the unread tail counts as skipped.
                skipped += table.rows.count - maxRows
                truncated = true
                break
            }
            guard let dateCol, let markerCol, let valueCol,
                  let rawDay = row.cell(dateCol),
                  let day = canonicalDay(rawDay),
                  let rawName = row.cell(markerCol)
            else { skipped += 1; continue }

            let rawValue = row.cell(valueCol) ?? ""
            let rawUnit = unitCol.flatMap { row.cell($0) }

            // Blood pressure: a combined "120/80" cell (under any bp-family name) becomes
            // the systolic/diastolic PAIR — a one-row-one-marker mapping would silently
            // drop diastolic (spec §"Blood pressure modelling").
            let resolved = resolveMarker(rawName)
            if resolved.isBloodPressureFamily, let pair = bloodPressurePair(rawValue) {
                let unit = rawUnit ?? "mmHg"
                store(&byCell, LabMarkerCsvRow(markerKey: bpSystolicKey, category: .bloodPressure,
                                               day: day, value: pair.systolic, unit: unit,
                                               isCustomMarker: false))
                store(&byCell, LabMarkerCsvRow(markerKey: bpDiastolicKey, category: .bloodPressure,
                                               day: day, value: pair.diastolic, unit: unit,
                                               isCustomMarker: false))
                continue
            }

            // The combined-BP name with a non-pair value has no single marker to land on.
            guard let key = resolved.key else { skipped += 1; continue }
            guard let value = parseValue(rawValue) else { skipped += 1; continue }

            let category: LabMarkerCategory
            let unit: String
            if let def = MarkerCatalog.definition(for: key) {
                category = def.category
                // Unit VERBATIM when the file has one; the catalog's canonical unit is
                // only a label fallback, never a conversion.
                unit = rawUnit ?? def.canonicalUnit
            } else {
                category = .other
                unit = rawUnit ?? ""
                customKeys.insert(key)
            }
            store(&byCell, LabMarkerCsvRow(markerKey: key, category: category, day: day,
                                           value: value, unit: unit,
                                           isCustomMarker: MarkerCatalog.definition(for: key) == nil))
        }

        let rows = byCell.values.sorted {
            $0.day == $1.day ? $0.markerKey < $1.markerKey : $0.day < $1.day
        }
        let days = rows.map(\.day)
        return LabMarkerCsvResult(
            rows: rows,
            skippedRows: skipped,
            customMarkerKeys: customKeys.sorted(),
            earliestDay: days.min(),
            latestDay: days.max(),
            truncated: truncated,
            fileTooLarge: false
        )
    }

    /// Same (markerKey, day) cell → the LAST row in the file wins.
    private static func store(_ byCell: inout [String: LabMarkerCsvRow], _ row: LabMarkerCsvRow) {
        byCell[row.markerKey + "\u{1}" + row.day] = row
    }

    // MARK: - Column resolution (NutritionCsvImporter idiom)

    private static func resolve(
        _ headers: [String],
        exact: [String],
        contains: [String],
        excluding: [String] = []
    ) -> String? {
        for e in exact where headers.contains(e) { return e }
        for h in headers {
            if excluding.contains(where: { h.contains($0) }) { continue }
            if contains.contains(where: { h.contains($0) }) { return h }
        }
        return nil
    }

    // MARK: - Marker name → catalog key

    /// The two keys of the blood-pressure pair (values match `LabBookProjection`).
    static let bpSystolicKey = "bp_systolic"
    static let bpDiastolicKey = "bp_diastolic"
    /// Sentinel for a COMBINED blood-pressure name ("blood pressure", "BP") whose value
    /// cell carries the "120/80" pair.
    private static let bpCombined = "\u{1}bp_combined"

    struct ResolvedMarker {
        /// The catalog / custom key, or nil for the combined-BP sentinel.
        let key: String?
        /// True for any bp-family name (combined, systolic or diastolic) — those may
        /// legitimately carry a "120/80" pair value.
        let isBloodPressureFamily: Bool
    }

    /// Resolve a raw marker-name cell to a stable key: catalog key, catalog display
    /// name, alias, or (fallback) a `custom_<slug>` key identical to the one the manual
    /// editor mints — so CSV customs and hand-added customs fold onto one history.
    static func resolveMarker(_ rawName: String) -> ResolvedMarker {
        let norm = matchNorm(rawName)
        if norm.isEmpty { return ResolvedMarker(key: nil, isBloodPressureFamily: false) }
        if let mapped = aliasTable[norm] {
            if mapped == bpCombined { return ResolvedMarker(key: nil, isBloodPressureFamily: true) }
            return ResolvedMarker(key: mapped,
                                  isBloodPressureFamily: mapped == bpSystolicKey || mapped == bpDiastolicKey)
        }
        let key = customKey(rawName)
        guard !key.isEmpty else { return ResolvedMarker(key: nil, isBloodPressureFamily: false) }
        return ResolvedMarker(key: key, isBloodPressureFamily: false)
    }

    /// Catalog keys + normalized display names + hand-picked common aliases → key.
    /// Built once. Alias keys are in `matchNorm` form.
    private static let aliasTable: [String: String] = {
        var t: [String: String] = [:]
        for def in MarkerCatalog.builtIn {
            t[matchNorm(def.key)] = def.key
            t[matchNorm(def.displayName)] = def.key
        }
        // Common report/spreadsheet spellings. NON-DIAGNOSTIC name folding only.
        let extras: [String: String] = [
            "cholesterol": "total_cholesterol",
            "cholesterol_total": "total_cholesterol",
            "ldl_c": "ldl", "ldl_cholesterol": "ldl",
            "hdl_c": "hdl", "hdl_cholesterol": "hdl",
            "triglyceride": "triglycerides",
            "glucose": "fasting_glucose", "blood_glucose": "fasting_glucose",
            "glucose_fasting": "fasting_glucose",
            "a1c": "hba1c", "hb_a1c": "hba1c",
            "vit_d": "vitamin_d", "vitamin_d3": "vitamin_d", "25_oh_vitamin_d": "vitamin_d",
            "b12": "vitamin_b12", "vit_b12": "vitamin_b12",
            "folic_acid": "folate",
            "serum_iron": "iron",
            "tsat": "transferrin_saturation",
            "hemoglobin": "haemoglobin", "hb": "haemoglobin",
            "c_reactive_protein": "crp", "hs_crp": "crp",
            "ft4": "free_t4", "t4_free": "free_t4",
            "sgpt": "alt", "sgot": "ast", "gamma_gt": "ggt",
            "systolic": "bp_systolic", "sbp": "bp_systolic",
            "systolic_blood_pressure": "bp_systolic", "blood_pressure_systolic": "bp_systolic",
            "diastolic": "bp_diastolic", "dbp": "bp_diastolic",
            "diastolic_blood_pressure": "bp_diastolic", "blood_pressure_diastolic": "bp_diastolic",
            "blood_pressure": bpCombined, "bp": bpCombined,
            "pulse": "resting_pulse", "resting_heart_rate": "resting_pulse",
            "body_weight": "weight", "bodyweight": "weight",
            "body_fat_pct": "body_fat", "body_fat_percentage": "body_fat",
            "waist_circumference": "waist",
        ]
        for (k, v) in extras { t[k] = v }
        return t
    }()

    /// Full-collapse normal form for alias matching: lowercase, diacritic-folded,
    /// every non-alphanumeric RUN → one `_`, trimmed. (Deliberately NOT
    /// `HeaderNorm.normalize`, whose WHOOP-header alias map must never fire here.)
    static func matchNorm(_ s: String) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasUnderscore = false
        for ch in folded {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    /// The `custom_<slug>` key for an unrecognised marker name. MUST stay byte-identical
    /// to the manual editor's `MarkerUnits.slug` (Strand/Screens/MarkerEditorView.swift)
    /// so a CSV custom marker folds onto a hand-added one. Returns "" for a name with no
    /// usable characters.
    static func customKey(_ name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "_"
        }
        let collapsed = String(mapped).replacingOccurrences(of: "__", with: "_")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !trimmed.isEmpty else { return "" }
        return "custom_" + trimmed
    }

    // MARK: - Value parsing (decimal commas welcome, nothing guessed)

    /// Parse a value cell as a number. Handles plain decimals, a European decimal comma
    /// ("5,2"), a thousands-grouped integer ("1,234"), and a trailing unit accidentally
    /// left in the cell ("5.2 mmol/L"). Anything else — text results, empty cells, a
    /// slash pair outside the BP path — is nil, so the row is SKIPPED and counted,
    /// never guessed.
    static func parseValue(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = numberToken(t) { return d }

        // "5.2 mmol/L" / "62 ms": a leading number token, then whitespace + unit text.
        // A "/" IMMEDIATELY after the number (a 120/80 pair, a date) is never a unit.
        let scalars = Array(t)
        var i = 0
        while i < scalars.count, "0123456789+-.,".contains(scalars[i]) { i += 1 }
        guard i > 0, i < scalars.count, scalars[i] == " " else { return nil }
        let token = String(scalars[0..<i])
        return numberToken(token)
    }

    /// A finite-only Double parse: NaN / +Inf / -Inf (from "nan"/"inf"/"1e999" and friends) are
    /// REJECTED so a hostile or typo'd cell falls into the skip-and-counted path instead of landing a
    /// non-finite "reading" in the store and the chart math (the importer's "nothing guessed" contract).
    private static func finiteDouble(_ s: String) -> Double? {
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// Parse one bare numeric token with the comma rules — the token must be exactly
    /// a number, nothing more. `internal` so the WHOOP biomarker parser can split a packed
    /// "value unit" cell with the same grammar.
    static func numberToken(_ t: String) -> Double? {
        if let d = finiteDouble(t) { return d }
        // One decimal comma ("5,2" / "12,345" is ambiguous: 3 digits after a single
        // comma reads as a thousands group, anything else as a decimal comma).
        if matches(t, pattern: "^[+-]?[0-9]+,[0-9]+$") {
            let intPart = t.split(separator: ",")[0]
            let afterComma = t.split(separator: ",")[1].count
            // A bare-zero (or leading-zero) integer part can only be a DECIMAL comma: "0,500" is 0.5,
            // never a 500 thousands group (a real thousands number never starts with a lone 0). So the
            // 3-digit thousands rule must NOT fire for those - it used to store "0,500" as 500 (1000x).
            let intIsZeroLed = intPart.hasPrefix("0") || intPart.hasPrefix("+0") || intPart.hasPrefix("-0")
            if afterComma == 3 && !intIsZeroLed {
                return finiteDouble(t.replacingOccurrences(of: ",", with: ""))
            }
            return finiteDouble(t.replacingOccurrences(of: ",", with: "."))
        }
        // Multi-group thousands ("1,234,567" or "1,234.5").
        if matches(t, pattern: "^[+-]?[0-9]{1,3}(,[0-9]{3})+(\\.[0-9]+)?$") {
            return finiteDouble(t.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    /// A combined blood-pressure pair "120/80" (decimal comma or dot tolerated in each
    /// half). nil for anything else.
    static func bloodPressurePair(_ raw: String) -> (systolic: Double, diastolic: Double)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let sysText = parts[0].trimmingCharacters(in: .whitespaces)
        let diaText = parts[1].trimmingCharacters(in: .whitespaces)
        guard matches(sysText, pattern: "^[0-9]+([.,][0-9]+)?$"),
              matches(diaText, pattern: "^[0-9]+([.,][0-9]+)?$"),
              let sys = Double(sysText.replacingOccurrences(of: ",", with: ".")),
              let dia = Double(diaText.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return (sys, dia)
    }

    private static func matches(_ s: String, pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Date parsing (pure, timezone-free — the day is a literal)

    /// Canonicalise a date cell to `yyyy-MM-dd`. Accepted (a trailing time after a
    /// space or `T` is tolerated and ignored):
    ///   • ISO-first: "2026-06-15", "2026/6/1", "2026-06-15 08:30".
    ///   • Day/month-first with a 4-digit year: "15/01/2026" (day-first when the first
    ///     number can only be a day), otherwise month-first ("01/15/2026" — the US
    ///     spreadsheet default, same rule as the Android nutrition importer).
    /// Anything else is nil, so the row is skipped and counted.
    static func canonicalDay(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        if let m = firstMatch(t, pattern: "^([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})(?![0-9])") {
            return validDay(year: m[0], month: m[1], day: m[2])
        }
        if let m = firstMatch(t, pattern: "^([0-9]{1,2})[./-]([0-9]{1,2})[./-]([0-9]{4})(?![0-9])") {
            let a = m[0], b = m[1], y = m[2]
            // a > 12 can only be a day; otherwise default to US month-first.
            let (month, day) = a > 12 ? (b, a) : (a, b)
            return validDay(year: y, month: month, day: day)
        }
        return nil
    }

    /// First regex match's integer capture groups, or nil.
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

    /// "yyyy-MM-dd" when the components form a real calendar date, else nil.
    /// Pure math (leap-aware), no Foundation calendar — byte-identical to the Kotlin twin.
    /// `internal` so the WHOOP biomarker parser can build a date from an M/D/YY (2-digit-year) cell.
    static func validDay(year: Int, month: Int, day: Int) -> String? {
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year, month) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2: return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
        default: return 0
        }
    }
}
