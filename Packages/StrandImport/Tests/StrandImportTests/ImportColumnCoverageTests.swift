import XCTest
import WhoopStore   // DailyMetric — the type importColumnCoverage takes
@testable import StrandImport

/// Pins the import column-coverage line. Kotlin twin: `ImportColumnCoverageTest`. The two must emit
/// byte-identical strings, so the expectations are written out in full.
final class ImportColumnCoverageTests: XCTestCase {

    func testCallsOutTheAbsentColumn() {
        XCTAssertEqual(
            ImportTrace.columnCoverageLine(stage: "cycles", rows: 58, counts: [
                ("recovery", 58), ("rhr", 58), ("hrv", 58), ("skin_temp", 58),
                ("spo2", 0), ("strain", 58),
            ]),
            "import columns stage=cycles rows=58 recovery=58 rhr=58 hrv=58 skin_temp=58 spo2=0 strain=58"
            + " — ABSENT: spo2"
        )
    }

    func testHealthyImportHasNoAbsentClause() {
        XCTAssertEqual(
            ImportTrace.columnCoverageLine(stage: "cycles", rows: 2, counts: [("recovery", 2), ("spo2", 2)]),
            "import columns stage=cycles rows=2 recovery=2 spo2=2"
        )
    }

    func testEveryAbsentColumnIsListedInParserOrder() {
        XCTAssertEqual(
            ImportTrace.columnCoverageLine(stage: "cycles", rows: 9, counts: [
                ("spo2", 0), ("recovery", 9), ("skin_temp", 0),
            ]),
            "import columns stage=cycles rows=9 spo2=0 recovery=9 skin_temp=0 — ABSENT: spo2, skin_temp"
        )
    }

    func testAPartiallyPopulatedColumnIsNotAbsent() {
        // 1-of-58 is a real signal (a sparse column), and materially different from "never present".
        let line = ImportTrace.columnCoverageLine(stage: "cycles", rows: 58, counts: [("spo2", 1)])
        XCTAssertEqual(line, "import columns stage=cycles rows=58 spo2=1")
        XCTAssertFalse(line.contains("ABSENT"))
    }

    func testTheLabelOrderIsTheCrossPlatformContract() {
        // The order is part of the emitted string. If this changes, the Kotlin twin must change with it,
        // in the same position — the two lines would otherwise silently stop matching.
        XCTAssertEqual(importColumnLabels, ["recovery", "rhr", "hrv", "skin_temp", "spo2", "strain", "resp"])
    }

    func testCoverageEmitsTheLabelsInContractOrder() {
        XCTAssertEqual(importColumnCoverage([]).map(\.0), importColumnLabels)
    }

    func testAnEmptyCountsListDoesNotTrailASpace() {
        // Unreachable through the app today, but the formatter is public and a trailing space would
        // survive into anything that later parses these logs.
        XCTAssertEqual(
            ImportTrace.columnCoverageLine(stage: "cycles", rows: 0, counts: []),
            "import columns stage=cycles rows=0"
        )
    }
}
