import XCTest
@testable import StrandImport

/// Tests for the WHOOP biomarker export parser (#1220). Synthetic fixture with the same
/// structural quirks as a real export (quoted names with commas, packed value+unit, thousands
/// separators, "--"/"No Data Available" rows, US M/D/YY dates). Mirrors the Android
/// `WhoopBiomarkerExportParserTest` fixture-for-fixture so the twins stay byte-identical.
final class WhoopBiomarkerExportParserTests: XCTestCase {

    // A synthetic export (values invented) mirroring the real header + row shapes from the issue.
    private let fixture = """
    "Biomarker Name",Value,Status,"Recorded On Date"
    "1,5-Anhydroglucitol (1,5-AG)",--,"No Data Available",--
    Ferritin,"1,050 ng/mL",Optimal,7/2/26
    "Vitamin D","72 nmol/L",Sufficient,7/2/26
    LDL,"3.1 mmol/L","Out of Range",1/23/26
    Basophils,"70 cells/uL",Optimal,1/23/26
    """

    // MARK: - Detection

    func testMatchesOnlyTheWhoopSignature() {
        XCTAssertTrue(WhoopBiomarkerExportParser.matches(text: fixture))
        // The generic (date,marker,value,unit) shape must NOT route to the vendor parser.
        XCTAssertFalse(WhoopBiomarkerExportParser.matches(text: "date,marker,value,unit\n2026-05-01,ldl,3.1,mmol/L"))
        // A near-miss missing the Status column is not a WHOOP export.
        XCTAssertFalse(WhoopBiomarkerExportParser.matches(text: "\"Biomarker Name\",Value,\"Recorded On Date\"\nFerritin,80,7/2/26"))
    }

    // MARK: - Happy path

    func testParsesReadingsCountsNotMeasuredSeparately() {
        let result = WhoopBiomarkerExportParser.parse(text: fixture)
        XCTAssertEqual(result.importedReadings, 4)   // ferritin, vitamin_d, ldl, basophils
        XCTAssertEqual(result.notMeasured, 1)        // the "--" / "No Data Available" anhydroglucitol row
        XCTAssertEqual(result.skippedRows, 0)        // nothing malformed
        XCTAssertEqual(result.distinctMarkers, 4)
        XCTAssertEqual(result.earliestDay, "2026-01-23")
        XCTAssertEqual(result.latestDay, "2026-07-02")
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.fileTooLarge)
        XCTAssertEqual(result.customMarkerKeys, ["custom_basophils"])
    }

    func testKeepsPackedUnitAndThousandsSeparator() {
        let rows = WhoopBiomarkerExportParser.parse(text: fixture).rows
        let ferritin = rows.first { $0.markerKey == "ferritin" }!
        XCTAssertEqual(ferritin.value, 1050.0)          // "1,050" thousands separator stripped
        XCTAssertEqual(ferritin.unit, "ng/mL")          // unit split out of the packed cell, verbatim
        XCTAssertEqual(ferritin.category, .bloodPanel)
        XCTAssertFalse(ferritin.isCustomMarker)
        XCTAssertEqual(ferritin.day, "2026-07-02")      // US M/D/YY (2-digit year) → ISO
    }

    func testCarriesStatusVerbatimIntoNoteAttributed() {
        let rows = WhoopBiomarkerExportParser.parse(text: fixture).rows
        XCTAssertEqual(rows.first { $0.markerKey == "ferritin" }?.note, "WHOOP: Optimal")
        XCTAssertEqual(rows.first { $0.markerKey == "vitamin_d" }?.note, "WHOOP: Sufficient")
        // A verdict is carried verbatim + attributed — NOOP never asserts it itself.
        XCTAssertEqual(rows.first { $0.markerKey == "ldl" }?.note, "WHOOP: Out of Range")
    }

    func testUnknownMarkerBecomesCustomWithItsUnit() {
        let baso = WhoopBiomarkerExportParser.parse(text: fixture).rows.first { $0.markerKey == "custom_basophils" }!
        XCTAssertTrue(baso.isCustomMarker)
        XCTAssertEqual(baso.category, .other)
        XCTAssertEqual(baso.value, 70.0)
        XCTAssertEqual(baso.unit, "cells/uL")
        XCTAssertEqual(baso.note, "WHOOP: Optimal")
    }

    // MARK: - Cell-level rules

    func testIsNoDataMatchesBothSentinels() {
        XCTAssertTrue(WhoopBiomarkerExportParser.isNoData("--"))
        XCTAssertTrue(WhoopBiomarkerExportParser.isNoData("No Data Available"))
        XCTAssertTrue(WhoopBiomarkerExportParser.isNoData("  no data available  "))
        XCTAssertFalse(WhoopBiomarkerExportParser.isNoData("Optimal"))
        XCTAssertFalse(WhoopBiomarkerExportParser.isNoData("70 cells/uL"))
    }

    func testSplitValueUnitHandlesPackedAndBare() {
        func eq(_ a: (Double, String)?, _ v: Double, _ u: String, _ line: UInt = #line) {
            XCTAssertEqual(a?.0, v, line: line)
            XCTAssertEqual(a?.1, u, line: line)
        }
        eq(WhoopBiomarkerExportParser.splitValueUnit("70 cells/uL"), 70.0, "cells/uL")
        eq(WhoopBiomarkerExportParser.splitValueUnit("3,490 cells/uL"), 3490.0, "cells/uL")
        eq(WhoopBiomarkerExportParser.splitValueUnit("33 U/L"), 33.0, "U/L")
        eq(WhoopBiomarkerExportParser.splitValueUnit("70"), 70.0, "")
        XCTAssertNil(WhoopBiomarkerExportParser.splitValueUnit("--"))
        XCTAssertNil(WhoopBiomarkerExportParser.splitValueUnit("negative"))
    }

    func testWhoopDayAcceptsTwoDigitUsDates() {
        XCTAssertEqual(WhoopBiomarkerExportParser.whoopDay("7/2/26"), "2026-07-02")
        XCTAssertEqual(WhoopBiomarkerExportParser.whoopDay("1/23/26"), "2026-01-23")
        XCTAssertEqual(WhoopBiomarkerExportParser.whoopDay("12/31/26"), "2026-12-31")
        XCTAssertEqual(WhoopBiomarkerExportParser.whoopDay("2026-06-15"), "2026-06-15")  // ISO still ok
        XCTAssertNil(WhoopBiomarkerExportParser.whoopDay("13/2/26"))   // month 13 is not a valid US date
        XCTAssertNil(WhoopBiomarkerExportParser.whoopDay("--"))
    }
}
