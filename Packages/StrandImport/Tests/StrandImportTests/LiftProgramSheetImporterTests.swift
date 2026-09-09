import XCTest
import WhoopStore
@testable import StrandImport

/// Building a Lift Log program from a spreadsheet filled in on a computer.
///
/// Both fixtures carry the SAME content in the two accepted formats, so one set of expectations
/// covers the `.xlsx` reader and the CSV path and neither can drift from the other.
final class LiftProgramSheetImporterTests: XCTestCase {

    private func parse(_ fixture: String) throws -> LiftProgramImportResult {
        try LiftProgramSheetImporter.parse(data: Fixtures.data(fixture))
    }

    // MARK: - The two formats agree

    func testXlsxAndCsvProduceTheSameProgramsFromTheSameContent() throws {
        let x = try parse("lift_program_filled.xlsx")
        let c = try parse("lift_program_filled.csv")
        XCTAssertEqual(x.programs, c.programs,
                       "one parser, two containers — the container must not change the result")
    }

    // MARK: - Grouping

    func testRowsAreGroupedIntoProgramsInSheetOrder() throws {
        let r = try parse("lift_program_filled.xlsx")
        XCTAssertEqual(r.programs.map(\.name), ["Lower A", "Upper A"])
        XCTAssertEqual(r.programs[0].lines.map(\.exercise),
                       ["Leg Press midfoot", "Lying Leg Curl", "Leg Extension"])
        XCTAssertEqual(r.programs[1].lines.map(\.exercise),
                       ["Incline dumbbell press", "Cable fly", "Lat pulldown"],
                       "a blank row in the middle separates nothing — it is just an empty row")
    }

    func testTheProgramNoteIsTakenFromWhicheverRowCarriesIt() throws {
        let r = try parse("lift_program_filled.xlsx")
        XCTAssertEqual(r.programs[0].note, "Belt from set 3")
        XCTAssertNil(r.programs[1].note)
    }

    // MARK: - Targets

    func testTargetsAreReadIncludingEuropeanDecimalsAndUnitSuffixes() throws {
        let r = try parse("lift_program_filled.xlsx")
        let press = r.programs[0].lines[0]
        XCTAssertEqual(press.targetSets, 3)
        XCTAssertEqual(press.targetReps, 10)
        XCTAssertEqual(press.targetWeightKg, 50)
        XCTAssertEqual(press.restSec, 90)
        XCTAssertEqual(press.note, "Slow eccentric")

        // "40,5 kg" — a comma decimal and a unit, which is what a European spreadsheet writes.
        XCTAssertEqual(r.programs[0].lines[2].targetWeightKg, 40.5)
    }

    func testABlankTargetStaysNilRatherThanBecomingZero() throws {
        let r = try parse("lift_program_filled.xlsx")
        let fly = r.programs[1].lines[1]
        XCTAssertNil(fly.targetWeightKg, "a blank cell means not planned; 0 would be a planned zero")
        XCTAssertNil(fly.restSec)
        XCTAssertNil(fly.note)
    }

    // MARK: - Muscles

    func testMusclesResolveAndSecondariesSplitOnCommas() throws {
        let r = try parse("lift_program_filled.xlsx")
        let incline = r.programs[1].lines[0]
        XCTAssertEqual(incline.primaryMuscle, .chest)
        XCTAssertEqual(incline.secondaryMuscles, [.frontDelts, .triceps])
    }

    /// An unrecognised muscle warns and leaves the line unclassified — it never guesses, and it never
    /// throws away the row. The vocabulary is a stored-data contract; deciding that "Shoulders" means
    /// front delts would put sets in a bucket the user did not choose.
    func testAnUnknownMuscleWarnsButKeepsTheExercise() throws {
        let r = try parse("lift_program_filled.xlsx")
        let fly = r.programs[1].lines[1]
        XCTAssertEqual(fly.exercise, "Cable fly")
        XCTAssertNil(fly.primaryMuscle)
        XCTAssertTrue(r.warnings.contains { $0.contains("Shoulders") && $0.contains("Cable fly") },
                      "the warning must name the value AND the exercise: \(r.warnings)")
    }

    func testAWarningNamesTheSheetsOwnRowNumber() throws {
        let r = try parse("lift_program_filled.xlsx")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("Row 6:") },
                      "Cable fly is the 5th data row, which is row 6 in the sheet: \(r.warnings)")
    }

    func testMuscleNamesAreCaseAndSpacingInsensitiveAndAcceptStoredTokens() {
        for spelling in ["Front delts", "front delts", "FRONT-DELTS", "frontdelts", "frontDelts"] {
            XCTAssertEqual(LiftMuscle(sheetName: spelling), .frontDelts, "failed on \(spelling)")
        }
        XCTAssertNil(LiftMuscle(sheetName: "shoulders"), "no guessing beyond spelling")
        XCTAssertNil(LiftMuscle(sheetName: "   "))
    }

    func testEveryMuscleInTheVocabularyIsReachableByItsEnglishName() {
        // The shipped template's dropdown offers these; if a case were added to LiftMuscle without a
        // name here, it would be offered and then rejected on import.
        for m in LiftMuscle.allCases {
            XCTAssertEqual(LiftMuscle(sheetName: m.rawValue), m)
        }
    }

    // MARK: - The shipped template itself

    /// The empty template in `docs/` is the file users actually download. Parsing it must not throw
    /// on its headers, and it must contain no programs — an unfilled template imports nothing.
    func testTheShippedTemplateHasTheHeadersTheImporterExpects() throws {
        let data = try templateData()

        // The header row is what the importer matches on, so it is what must not drift. (`rows`
        // is empty for an unfilled template by design — every data row is blank.)
        let grid = try XlsxSheet.grid(from: data)
        let headers = grid.first.map { $0.map { HeaderNorm.normalize($0) } } ?? []
        for expected in ["program", "program_note", "exercise", "primary_muscle",
                         "secondary_muscles", "sets", "reps", "weight_kg", "rest_sec", "note"] {
            XCTAssertTrue(headers.contains(expected),
                          "the shipped template lost the \"\(expected)\" column: \(headers)")
        }

        // And an UNFILLED template is empty, not a program of blank exercises.
        XCTAssertThrowsError(try LiftProgramSheetImporter.parse(data: data)) { error in
            XCTAssertEqual(error as? LiftProgramSheetImporter.ImportError, .empty)
        }
    }

    /// `xl/worksheets/sheet1.xml` is a stable id, not a position. This fixture puts the instructions
    /// sheet FIRST in tab order with the program data still in sheet1.xml — reading by filename would
    /// import the instructions page as a program, or find no exercise column and refuse the file.
    func testTheFirstTabIsFoundThroughTheWorkbookNotTheFilename() throws {
        let r = try parse("lift_program_tabs_reordered.xlsx")
        XCTAssertEqual(r.programs.count, 1, "the instructions tab is first; the data must still be found")
        XCTAssertEqual(r.programs[0].lines.map(\.exercise), ["Back squat"])
        XCTAssertEqual(r.programs[0].lines[0].targetWeightKg, 100)
    }

    /// The template must not permit the one edit that breaks the import. In OOXML these
    /// `sheetProtection` flags answer "is this PREVENTED" and default to true, so an attribute set to
    /// "0" ALLOWS the thing it names — an earlier template shipped `insertColumns="0"`, permitting
    /// exactly the change that shifts reps into the weight column.
    func testTheShippedTemplateLocksColumnEditsAndAllowsRowEdits() throws {
        let xml = try templateSheetXml()
        XCTAssertTrue(xml.contains("sheet=\"1\""), "the sheet must actually be protected")
        XCTAssertFalse(xml.contains("insertColumns=\"0\""), "inserting columns must stay prevented")
        XCTAssertFalse(xml.contains("deleteColumns=\"0\""), "deleting columns must stay prevented")
        XCTAssertTrue(xml.contains("insertRows=\"0\""), "a long routine needs more rows")
        XCTAssertTrue(xml.contains("selectUnlockedCells=\"0\""), "the data cells must be typable")
    }

    // MARK: - Refusals

    func testAFileWithNoExerciseColumnIsRefusedWithThatReason() {
        let csv = "Program,Sets,Reps\nLower A,3,10\n"
        XCTAssertThrowsError(try LiftProgramSheetImporter.parse(data: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? LiftProgramSheetImporter.ImportError, .missingColumns(["exercise"]))
        }
    }

    func testNonsenseIsRefusedRatherThanImportedAsOneStrangeProgram() {
        XCTAssertThrowsError(try LiftProgramSheetImporter.parse(data: Data([0x00, 0x01, 0x02])))
    }

    /// Only the exercise is required; a sheet with nothing else still makes a usable program that can
    /// be finished in the app.
    func testAnExerciseOnlySheetImports() throws {
        let csv = "Exercise\nBack squat\nBench press\n"
        let r = try LiftProgramSheetImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.programs.count, 1)
        XCTAssertEqual(r.programs[0].lines.map(\.exercise), ["Back squat", "Bench press"])
        XCTAssertNil(r.programs[0].lines[0].targetSets)
    }

    /// Excel in most of Europe writes CSV with semicolons. `CSVTable` sniffs the delimiter, and this
    /// pins that the lift path benefits from it.
    func testASemicolonDelimitedCsvIsRead() throws {
        let csv = "Program;Exercise;Primary muscle;Sets;Reps\nLower A;Back squat;Quads;5;5\n"
        let r = try LiftProgramSheetImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.programs[0].lines[0].exercise, "Back squat")
        XCTAssertEqual(r.programs[0].lines[0].primaryMuscle, .quads)
        XCTAssertEqual(r.programs[0].lines[0].targetSets, 5)
    }

    // MARK: - Bounds
    //
    // This feature is a convenience. It must never be the reason the app is slow, runs out of
    // memory, or writes a database nobody wants — so every input it accepts is bounded, and the
    // bounds are pinned here.

    func testAnAbsurdlyLargeFileIsRefusedBeforeAnyParsing() {
        let big = Data(count: LiftProgramSheetImporter.maxFileBytes + 1)
        XCTAssertThrowsError(try LiftProgramSheetImporter.parse(data: big)) { error in
            XCTAssertEqual(error as? LiftProgramSheetImporter.ImportError, .tooLarge)
        }
    }

    func testTooManyProgramsAreTruncatedAndSaidSo() throws {
        var csv = "Program,Exercise\n"
        for i in 0..<(LiftProgramSheetImporter.maxPrograms + 10) {
            csv += "Program \(i),Exercise \(i)\n"
        }
        let r = try LiftProgramSheetImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.programs.count, LiftProgramSheetImporter.maxPrograms)
        XCTAssertTrue(r.warnings.contains { $0.contains("larger than a program can be") },
                      "a truncated import must say it was truncated: \(r.warnings)")
    }

    func testTooManyLinesInOneProgramAreTruncated() throws {
        var csv = "Program,Exercise\n"
        for i in 0..<(LiftProgramSheetImporter.maxLinesPerProgram + 10) {
            csv += "One,Exercise \(i)\n"
        }
        let r = try LiftProgramSheetImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(r.programs.count, 1)
        XCTAssertEqual(r.programs[0].lines.count, LiftProgramSheetImporter.maxLinesPerProgram)
    }

    /// A sheet full of bad muscle names must not produce thousands of warnings — the preview would
    /// be unscrollable and the user no better informed.
    func testWarningsAreCapped() throws {
        // Deliberately under `maxLinesPerProgram`, so this isolates the WARNING cap rather than
        // tripping the line cap and testing two things at once.
        let rows = LiftProgramSheetImporter.maxLinesPerProgram - 10
        var csv = "Exercise,Primary muscle\n"
        for i in 0..<rows { csv += "Exercise \(i),Nonsense\n" }
        let r = try LiftProgramSheetImporter.parse(data: Data(csv.utf8))
        XCTAssertGreaterThan(rows, LiftProgramSheetImporter.maxWarnings, "the fixture must exceed the cap")
        XCTAssertEqual(r.warnings.count, LiftProgramSheetImporter.maxWarnings)
        XCTAssertEqual(r.programs[0].lines.count, rows, "every line still imports; only warnings are capped")
    }

    // MARK: - Reaching the shipped template

    /// `docs/lift-log-program-template.xlsx` — the file users actually download, read from the repo
    /// rather than copied into the test bundle, so a stale copy cannot pass while the real one drifts.
    private func templateData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/lift-log-program-template.xlsx")
        return try Data(contentsOf: url)
    }

    private func templateSheetXml() throws -> String {
        let data = try templateData()
        guard let part = XlsxSheet.rawPart(data, path: "xl/worksheets/sheet1.xml"),
              let xml = String(data: part, encoding: .utf8) else {
            XCTFail("the template has no first worksheet part")
            return ""
        }
        return xml
    }
}

