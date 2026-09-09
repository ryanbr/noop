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

    /// One worksheet, reduced to what the caller needs to recognise and read it.
    ///
    /// Headers are kept SEPARATE from rows so an empty sheet is still identifiable. A downloaded
    /// template that nobody has filled in has the right columns and no data, and that has to be
    /// reported as "no exercises yet" rather than "wrong file" — the user is holding the right file.
    struct Sheet {
        var headerKeys: Set<String>
        var rows: [[String: String]]
    }

    /// Every worksheet, in workbook (tab) order.
    ///
    /// Every sheet rather than the first, because the caller is looking for a particular KIND of
    /// sheet and only it can recognise one. A user who reorders tabs, keeps the instructions page in
    /// front, or pastes the data into their own workbook still gets an import; picking by position
    /// would refuse all three.
    static func sheets(from data: Data) throws -> [Sheet] {
        try grids(from: data).map(headerKeyed)
    }

    /// One grid's header row applied to the rows beneath it.
    private static func headerKeyed(_ grid: [[String]]) -> Sheet {
        guard let headerRow = grid.first else { return Sheet(headerKeys: [], rows: []) }
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
        return Sheet(headerKeys: Set(keys.filter { !$0.isEmpty }), rows: out)
    }

    /// The FIRST worksheet as a rectangular grid — kept for callers that only want to look at the
    /// leading sheet's headers.
    static func grid(from data: Data) throws -> [[String]] {
        guard let first = try grids(from: data).first else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        return first
    }

    /// Every worksheet as a grid of strings, in workbook (tab) order.
    static func grids(from data: Data) throws -> [[[String]]] {
        guard let archive = try? Archive(data: data, accessMode: .read) else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        // Shared strings are optional: a sheet written with inline strings has no such part.
        var shared: [String] = []
        if let pool = try? entryData(archive, "xl/sharedStrings.xml") {
            shared = SharedStrings.parse(pool)
        }
        let parts = worksheetPaths(archive)
        guard !parts.isEmpty else { throw LiftProgramSheetImporter.ImportError.unreadable }
        return parts.compactMap { path in
            (try? entryData(archive, path)).map { SheetParser.parse($0, shared: shared) }
        }
    }

    /// Worksheet part paths in TAB order, resolved through the workbook.
    ///
    /// `xl/worksheets/sheet1.xml` is a stable id, not a position: a user who drags the instructions
    /// tab in front of the data tab, or a writer that numbers parts differently, leaves `sheet1.xml`
    /// sitting behind another sheet. So take `<sheet>` order from `xl/workbook.xml` — that IS tab
    /// order — and map each `r:id` through `xl/_rels/workbook.xml.rels`.
    ///
    /// Falls back to every worksheet part sorted by name, for a file whose workbook part is missing
    /// or unreadable. Order matters less there than not losing the data entirely.
    private static func worksheetPaths(_ archive: Archive) -> [String] {
        if let workbook = try? entryData(archive, "xl/workbook.xml"),
           let rels = try? entryData(archive, "xl/_rels/workbook.xml.rels") {
            let ids = WorkbookOrder.sheetRelationshipIds(workbook)
            let targets = WorkbookOrder.targets(in: rels)
            let paths = ids.compactMap { targets[$0] }.map { target -> String in
                // Targets are written relative to the workbook part, which lives in `xl/`.
                target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
            if !paths.isEmpty { return paths }
        }
        return archive.map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
    }

    /// One part's raw bytes, by path. Internal, for tests that need to assert on the XML itself —
    /// the shipped template's sheet protection is not visible through the parsed grid.
    static func rawPart(_ data: Data, path: String) -> Data? {
        guard let archive = try? Archive(data: data, accessMode: .read) else { return nil }
        return try? entryData(archive, path)
    }

    /// Ceiling on ONE decompressed part.
    ///
    /// Measured on the expanded stream, not the archive, because that is the only bound that means
    /// anything: an .xlsx is a ZIP, and a zip bomb is by definition tiny compressed and enormous
    /// expanded, so a limit on the file's own size is trivially defeated. `DataBackup` guards its
    /// restore the same way and for the same reason (#1807). 64 MB is orders of magnitude above any
    /// real worksheet and still bounded.
    static let maxPartBytes = 64 * 1024 * 1024

    private static func entryData(_ archive: Archive, _ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw LiftProgramSheetImporter.ImportError.unreadable
        }
        var out = Data()
        out.reserveCapacity(min(Int(entry.uncompressedSize), 1 << 20))
        _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { chunk in
            guard out.count + chunk.count <= maxPartBytes else {
                throw LiftProgramSheetImporter.ImportError.tooLarge
            }
            out.append(chunk)
        }
        return out
    }

    /// Reads just enough of `workbook.xml` and its rels to put the worksheets in tab order.
    final class WorkbookOrder: NSObject, XMLParserDelegate {
        private var ids: [String] = []
        private var targets: [String: String] = [:]
        private var collectingRels = false

        /// `r:id` of every `<sheet>`, in document order — which is tab order.
        static func sheetRelationshipIds(_ data: Data) -> [String] {
            let d = WorkbookOrder()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.ids
        }

        /// Relationship id -> target path.
        static func targets(in rels: Data) -> [String: String] {
            let d = WorkbookOrder()
            d.collectingRels = true
            let p = XMLParser(data: rels)
            p.delegate = d
            p.parse()
            return d.targets
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if collectingRels {
                if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                    targets[id] = target
                }
                return
            }
            // The r:id attribute arrives qualified or not depending on the writer.
            if name == "sheet", let rid = attributes["r:id"] ?? attributes["id"] {
                ids.append(rid)
            }
        }
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
