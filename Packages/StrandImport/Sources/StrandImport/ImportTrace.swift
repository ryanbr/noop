import Foundation

// ImportTrace.swift - pure line formatters + the live-readout parser for the Import & Data Ingest
// test mode (Test Centre domain `.dataImport`, wire id "import").
//
// These own the line SHAPE; the app-target import handlers (WhoopImporter / AppleHealthImport /
// XiaomiImporter / WearableImporter, driven from AppModel) own the live emit and gate every call behind
// TestCentre.active(.dataImport), routing each line through LiveState.append(log:domain:.dataImport).
// When the mode is off, none of these is ever called, so the import path pays nothing.
//
// What an import run reports (the registered captures for this mode):
//   parserVersion  - which importer + version produced the rows.
//   fileMeta       - the input's detected kind, extension and size BUCKET (never the path/name).
//   perStageRows   - per category: rows the parser produced (in) vs rows the store actually wrote (out).
//   rejectCounts   - rows the parser dropped (a tolerant skip) + spans a tolerant XML import scrubbed.
//   dayDeltas      - distinct local days mapped vs distinct days the store actually persisted, the tell
//                    for the "didn't save" / day-owner-collision cluster (#601 / #749 / #754).
//   firstFailingRow / failingFileSample - a REDACTED, length-capped peek at a row/sample that would not
//                    parse, so a malformed export is diagnosable without ever shipping the raw values.
//
// HARD privacy rule: firstFailingRow + failingFileSample are user data. They are masked + capped HERE,
// before the line is handed to the redacting sink (which masks MAC/serial/UUID but NOT arbitrary CSV
// health values), and the export re-scrubs every line again. No clock, no I/O, no raw PII. A fixture
// pins the exact lines. No em-dashes. The Kotlin twin is ImportTrace (ImportTrace.kt), byte-aligned.

public enum ImportTrace {

    /// Bump when a line shape changes so a shared report's parser version is unambiguous. Stamped into
    /// the parserVersion line alongside the per-importer source label, so a maintainer reading a bundle
    /// knows exactly which emitter wrote it. The Kotlin twin carries the SAME value.
    public static let traceVersion = 1

    // MARK: - parserVersion + fileMeta

    /// The parser-identity line: which importer ran, its trace version, and the detected source kind.
    /// `importerVersion` is the per-importer schema/version the app passes (e.g. the WHOOP CSV mapping
    /// revision); it stays a small integer so the line carries no free text from the file.
    public static func parserVersionLine(sourceKind: DataSourceKind, importerVersion: Int) -> String {
        "import parser=\(sourceKind.rawValue) v=\(importerVersion) traceV=\(traceVersion)"
    }

    /// The file-meta line: the detected kind, the lowercased extension, and the size BUCKET (never the
    /// byte-exact size, never the name or path). The bucket is enough to tell a tiny single-CSV apart
    /// from a multi-year multi-GB export without fingerprinting the exact file.
    public static func fileMetaLine(sourceKind: DataSourceKind, ext: String, sizeBytes: Int) -> String {
        "import file kind=\(sourceKind.rawValue) ext=\(safeExt(ext)) size=\(sizeBucket(sizeBytes))"
    }

    // MARK: - perStageRows + rejectCounts

    /// One per-stage line for a category: rows the parser produced (`rowsIn`) and rows the store actually
    /// wrote (`rowsOut`, the summed SQLite changes from the upsert). When `rowsOut < rowsIn` the gap is the
    /// "mapped but not saved" signal (a row with no usable day key, or a day-owner collision); when they
    /// match the stage round-tripped cleanly. `category` is a stable key ("cycles" / "sleeps" / "days" / ...),
    /// never free text from the file.
    public static func stageLine(category: String, rowsIn: Int, rowsOut: Int) -> String {
        let note = rowsOut < rowsIn ? " (\(rowsIn - rowsOut) not written)" : " (all written)"
        return "import stage=\(category) rowsIn=\(rowsIn) rowsOut=\(rowsOut)\(note)"
    }

    /// The reject-counts line: rows the parser dropped as unusable (`droppedRows`, a tolerant skip, e.g. a
    /// CSV row with no parseable timestamp) and the number of tolerant-import spans the XML sanitizer
    /// scrubbed (`skippedSpans`, Apple Health only; 0 elsewhere). So a partial import never silently looks
    /// complete.
    /// Which metric columns an imported table actually carried, and which were empty in every row.
    ///
    /// The import trace already reports rows in, rows rejected and days mapped, but not whether a given
    /// COLUMN arrived. That is the question behind a whole class of "why is this card empty" reports: the
    /// file imported cleanly, the rows landed, and one metric is still blank because the export never
    /// contained it — or contained it under a header the aliases do not match. Both look identical from
    /// outside, and neither is distinguishable from a store-write failure without this line.
    ///
    /// `counts` is (column, rows-with-a-usable-value) in the parser's own order, so the line reads in the
    /// order a maintainer would look for them. A column at zero is called out explicitly in an ABSENT
    /// clause rather than left for the reader to spot among a dozen numbers; the clause is omitted when
    /// every column arrived, so the healthy case is quiet but still present.
    ///
    /// Known at parse time, so it carries none of the store-write ambiguity that keeps `rowsOut` honest
    /// but unverified on Android — this line means the same thing on both platforms.
    public static func columnCoverageLine(stage: String, rows: Int, counts: [(String, Int)]) -> String {
        // Built from the non-empty parts rather than interpolated positionally: an empty `counts` would
        // otherwise leave a trailing space, and a malformed line is worse than a useless one for anything
        // that later greps these logs. No caller can pass empty today; the formatter is shared and public,
        // so it should not depend on that staying true.
        let head = "import columns stage=\(stage) rows=\(rows)"
        let body = counts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let absent = counts.filter { $0.1 == 0 }.map(\.0)
        let tail = absent.isEmpty ? "" : " — ABSENT: \(absent.joined(separator: ", "))"
        return body.isEmpty ? head : "\(head) \(body)\(tail)"
    }

    public static func rejectLine(droppedRows: Int, skippedSpans: Int) -> String {
        "import rejects droppedRows=\(droppedRows) skippedSpans=\(skippedSpans)"
    }

    // MARK: - dayDeltas

    /// The day-delta line: distinct local days the import MAPPED vs distinct days the store reports it
    /// actually PERSISTED. A gap is the day-owner-collision / "didn't save" tell (#601 / #749 / #754): the
    /// rows parsed and mapped, but a day already owned by another source, or a duplicated day key, meant
    /// fewer days landed than expected. `category` names the stage the days belong to.
    public static func dayDeltaLine(category: String, daysMapped: Int, daysPersisted: Int) -> String {
        let note = daysPersisted < daysMapped ? " (\(daysMapped - daysPersisted) days not persisted)" : " (all days persisted)"
        return "import dayDelta stage=\(category) daysMapped=\(daysMapped) daysPersisted=\(daysPersisted)\(note)"
    }

    // MARK: - firstFailingRow + failingFileSample (redacted, capped)

    /// The first-failing-row line: a REDACTED, length-capped rendering of the first row the parser could
    /// not use, so a malformed export is diagnosable. `headerKeys` are the normalized column names (already
    /// safe - they are schema, not data); `rawCells` are the row's cell values, which ARE user data and are
    /// masked here cell-by-cell (digits -> #, letters -> x, structure preserved) before the line is built.
    /// `rowIndex` is the 1-based data-row position. Returns nil when there is no failing row to report.
    public static func firstFailingRowLine(category: String,
                                           rowIndex: Int,
                                           headerKeys: [String],
                                           rawCells: [String]) -> String? {
        guard !rawCells.isEmpty else { return nil }
        let masked = rawCells.prefix(maxSampleCells).map { redactCell($0) }
        let cols = headerKeys.prefix(maxSampleCells).joined(separator: ",")
        let shape = cols.isEmpty ? "" : " cols=[\(capped(cols))]"
        return "import firstFailingRow stage=\(category) row=\(rowIndex)\(shape) "
            + "masked=[\(capped(masked.joined(separator: ",")))]"
    }

    /// The failing-file-sample lines: a REDACTED, capped peek at the start of the input that failed to
    /// parse at all (e.g. a header NOOP did not recognise, a wrong-format file). `rawSample` is raw bytes
    /// decoded to text upstream; it is masked here (every value-like run is replaced, only structural
    /// punctuation + recognised header tokens survive) and hard-capped to `maxSampleChars`, so no raw
    /// health value or identifier can ride along. Returns [] when there is nothing to sample.
    public static func failingFileSampleLines(sourceKind: DataSourceKind, rawSample: String) -> [String] {
        let masked = redactSample(rawSample)
        guard !masked.isEmpty else { return [] }
        return ["import failingFileSample kind=\(sourceKind.rawValue) bytes=\(sizeBucket(rawSample.utf8.count)) "
            + "sample=[\(masked)]"]
    }

    // MARK: - Redaction + caps (the privacy floor)

    /// Max cells rendered from a failing row, so a wide table can't pad the line.
    static let maxSampleCells = 12
    /// Max characters of a masked fragment kept in a line (cells joined, or the file sample), so a single
    /// pathological row/file can't blow the log line size.
    static let maxSampleChars = 200

    /// Mask one cell's value: keep its SHAPE (lengths, separators) but replace every datum so no real
    /// number or string survives. Digits -> "#", letters -> "x", everything else (",", ":", "-", "+", ".",
    /// whitespace, "/") passes through so a maintainer can still see "this looked like a date" / "this was a
    /// decimal". An empty cell renders as "" (an honest "blank cell"). No raw value ever leaves.
    static func redactCell(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isNumber { out.append("#") }
            else if ch.isLetter { out.append("x") }
            else { out.append(ch) }   // structural punctuation/whitespace is safe + diagnostic
        }
        return out
    }

    /// Mask a free-form file sample the SAME way as a cell (digits -> #, letters -> x, punctuation kept),
    /// then hard-cap it. Applied to a raw header / first bytes of an unrecognised file, so the masked
    /// result reveals the STRUCTURE (delimiters, a header-row shape) without any real token.
    static func redactSample(_ s: String) -> String {
        // Collapse newlines so the sample is one diagnostic line, then mask + cap.
        let oneLine = s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return capped(redactCell(oneLine))
    }

    /// Hard-cap a fragment to `maxSampleChars`, appending a short ellipsis marker when it was trimmed so
    /// the line honestly shows it was capped.
    static func capped(_ s: String) -> String {
        if s.count <= maxSampleChars { return s }
        return String(s.prefix(maxSampleChars)) + "..."
    }

    /// A coarse size bucket for the file/sample size, so the line never carries the byte-exact size (a weak
    /// fingerprint). Powers-of-ten-ish buckets are plenty to tell scale apart.
    static func sizeBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<0:            return "?"
        case 0..<1_024:       return "<1KB"
        case 1_024..<10_240:  return "1-10KB"
        case 10_240..<102_400: return "10-100KB"
        case 102_400..<1_048_576: return "100KB-1MB"
        case 1_048_576..<10_485_760: return "1-10MB"
        case 10_485_760..<104_857_600: return "10-100MB"
        case 104_857_600..<1_073_741_824: return "100MB-1GB"
        default:              return ">1GB"
        }
    }

    /// Sanitise an extension to a short alphanumeric token so a weird picked name can't smuggle text into
    /// the line. Lowercased, letters/digits only, capped to 8 chars; "" when there is no extension.
    static func safeExt(_ ext: String) -> String {
        let t = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return t.isEmpty ? "none" : String(t.prefix(8))
    }
}

/// Pure values for the Import & Data Ingest live-readout panel. Parses the `.dataImport`-tagged log tail
/// the import emitters write, so the panel reflects exactly the last import run without the app layer
/// exposing new published properties (mirrors the Connection / Workouts / Steps readouts). No state, no
/// side effects, no em-dashes. The Kotlin twin is the ImportReadout object in ImportTrace.kt.
public enum ImportReadout {

    /// The last import summary for the `lastImportSummary` id: the most recent parser-identity fragment
    /// in the tagged tail ("parser=<kind> v=<n> traceV=<n>"), enriched with the latest per-stage and
    /// day-delta lines when present, so the panel reads what the run actually did. nil when no import has
    /// been traced yet.
    public static func lastImportSummary(taggedTail: [String]) -> String? {
        // The parser line anchors a run; report it plus the most recent stage / dayDelta fragment so the
        // panel shows source + whether everything landed, the same facts the emitted lines carry.
        var parserFrag: String?
        for line in taggedTail.reversed() {
            if let r = line.range(of: "import parser=") {
                parserFrag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let parser = parserFrag else { return nil }

        var stageFrag: String?
        for line in taggedTail.reversed() {
            if let r = line.range(of: "import stage=") {
                stageFrag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        var dayFrag: String?
        for line in taggedTail.reversed() {
            if let r = line.range(of: "import dayDelta ") {
                dayFrag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        var out = "parser=\(parser)"
        if let stageFrag { out += " · stage=\(stageFrag)" }
        if let dayFrag { out += " · \(dayFrag)" }
        return out
    }
}
