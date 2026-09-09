import Foundation
import ZIPFoundation

// A deliberately small `.xlsx` reader: enough to read a filled-in template, and nothing else.
//
// An .xlsx is a ZIP of XML. Reading one properly — styles, number formats, dates, formulas, multiple
// sheets, streaming — is a library's worth of work. This reads the FIRST worksheet as text, which is
// all a program sheet needs, and is honest about that: no formula evaluation (a cell's last cached
// value is used, which is what Excel wrote), no date coercion, no styling.
//
// Only ZIPFoundation and Foundation's own XMLParser are used, both already in the package. Nothing
// new enters the dependency graph for this.
enum XlsxSheet {

    /// Header-keyed rows, in the same shape `CSVTable` produces, so both formats feed one parser.
    static func rows(from data: Data) throws -> [[String: String]] {
        let grid = try grid(from: data)
        guard let headerRow = grid.first else { return [] }

        let keys = headerRow.map { HeaderNorm.normalize($0) }
        var out: [[String: String]] = []
        for cells in grid.dropFirst() {
            // Blank rows are ordinary in a spreadsheet — a user leaves space at the bottom.
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            var dict: [String: String] = [:]
            for (i, key) in keys.enumerated() where !key.isEmpty {
                let v = i < cells.count ? cells[i] : ""
                if dict[key] == nil || dict[key]!.isEmpty { dict[key] = v }
            }
            out.append(dict)
        }
        return out
    }

    /// The first worksheet as a rectangular grid of strings.
    static func grid(from data: Data) throws -> [[String]] {
        guard let archive = try? Archive(data: data, accessMode: .read) else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        // Shared strings are optional: a sheet written with inline strings has no such part.
        let shared = (try? entryData(archive, "xl/sharedStrings.xml")).map(SharedStrings.parse) ?? []

        guard let sheetData = try? firstWorksheet(archive) else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        return SheetParser.parse(sheetData, shared: shared)
    }

    /// The first worksheet part. Templates this reads are single-sheet, and `sheet1.xml` is what
    /// every writer emits for one; the scan is the fallback for a file that numbered it differently.
    private static func firstWorksheet(_ archive: Archive) throws -> Data {
        if let d = try? entryData(archive, "xl/worksheets/sheet1.xml") { return d }
        let names = archive.map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
        guard let first = names.first, let d = try? entryData(archive, first) else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        return d
    }

    private static func entryData(_ archive: Archive, _ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        var out = Data()
        _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { out.append($0) }
        return out
    }

    /// `xl/sharedStrings.xml` — the string pool most cells point into.
    private final class SharedStrings: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var current: String?
        private var collecting = false

        static func parse(_ data: Data) -> [String] {
            let d = SharedStrings()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            // A rich-text run splits one logical string across several <t> elements; they concatenate.
            if name == "t" { collecting = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { current = (current ?? "") + string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == "t" { collecting = false }
            if name == "si" {
                strings.append(current ?? "")
                current = nil
            }
        }
    }

    /// A worksheet part: rows of cells, placed by their `r` reference so gaps stay gaps.
    private final class SheetParser: NSObject, XMLParserDelegate {
        private var shared: [String] = []
        private var grid: [[String]] = []
        private var row: [String] = []
        private var cellRef = ""
        private var cellType = ""
        private var text: String?
        private var collecting = false

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let d = SheetParser()
            d.shared = shared
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.grid
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                row = []
            case "c":
                cellRef = attributes["r"] ?? ""
                cellType = attributes["t"] ?? ""
                text = nil
            case "v", "t":
                collecting = true
                text = text ?? ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { text = (text ?? "") + string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch name {
            case "v", "t":
                collecting = false
            case "c":
                // t="s" means the value is an index into the shared-string pool; anything else is
                // the literal text (inline strings arrive already resolved through <t>).
                var value = text ?? ""
                if cellType == "s", let i = Int(value), i >= 0, i < shared.count {
                    value = shared[i]
                }
                let column = SheetParser.columnIndex(cellRef)
                if column >= 0 {
                    while row.count <= column { row.append("") }
                    row[column] = value
                } else {
                    row.append(value)
                }
                text = nil
            case "row":
                grid.append(row)
                row = []
            default:
                break
            }
        }

        /// "C7" -> 2. Zero-based, so a skipped column stays an empty cell rather than shifting every
        /// value after it one place left — which would silently move reps into the weight column.
        static func columnIndex(_ ref: String) -> Int {
            var n = 0
            var any = false
            for ch in ref.uppercased() {
                guard let ascii = ch.asciiValue else { break }
                if ascii >= 65, ascii <= 90 {
                    n = n * 26 + Int(ascii - 64)
                    any = true
                } else {
                    break
                }
            }
            return any ? n - 1 : -1
        }
    }
}
