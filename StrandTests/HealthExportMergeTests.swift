import XCTest
import WhoopStore
@testable import Strand

/// The Apple Health export's row precedence (#2264).
///
/// Why this exists: the write-back unions computed dailies with imported ones and lets imported win. That
/// is correct, but it was written as a wholesale replacement, and `WhoopImporter` cannot populate
/// `avgSdnn` because a CSV carries no raw R-R to derive it from. So a night that had been re-scored with a
/// correct SDNN silently began exporting `avgHrv` instead, which for a strap row is RMSSD, under
/// `heartRateVariabilitySDNN`. That is not a missing value, it is a right value replaced by a wrong one,
/// and only on the days an import happened to cover.
final class HealthExportMergeTests: XCTestCase {

    /// Every field carries a DISTINCT non-nil value on purpose.
    ///
    /// `DailyMetric.init` defaults everything from `spo2Pct` onward to nil, so a field the merge forgets
    /// to pass still compiles and silently blanks. A fixture built from nils cannot catch that: the
    /// assertion passes because nil equals nil. Distinct values turn a dropped field into a failure.
    private func row(day: String = "2026-09-16", avgHrv: Double? = 42, avgSdnn: Double? = nil,
                     restingHr: Int? = 51, recovery: Double? = 70) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.91, deepMin: 90, remMin: 100,
                    lightMin: 230, disturbances: 3, restingHr: restingHr, avgHrv: avgHrv,
                    recovery: recovery, strain: 12.5, exerciseCount: 2, spo2Pct: 96.5,
                    skinTempDevC: -0.4, respRateBpm: 14.2, steps: 8123, activeKcalEst: 512.5,
                    spo2Red: 1234, spo2Ir: 5678, avgSdnn: avgSdnn, skinTempC: 33.2,
                    sleepHrOnly: true)
    }

    /// Assert the merge changed `avgSdnn` and NOTHING else, field by field.
    private func assertOnlySdnnDiffers(_ merged: DailyMetric, from imported: DailyMetric,
                                       expectedSdnn: Double?, file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(merged.avgSdnn, expectedSdnn, "avgSdnn", file: file, line: line)
        XCTAssertEqual(merged.day, imported.day, "day", file: file, line: line)
        XCTAssertEqual(merged.totalSleepMin, imported.totalSleepMin, "totalSleepMin", file: file, line: line)
        XCTAssertEqual(merged.efficiency, imported.efficiency, "efficiency", file: file, line: line)
        XCTAssertEqual(merged.deepMin, imported.deepMin, "deepMin", file: file, line: line)
        XCTAssertEqual(merged.remMin, imported.remMin, "remMin", file: file, line: line)
        XCTAssertEqual(merged.lightMin, imported.lightMin, "lightMin", file: file, line: line)
        XCTAssertEqual(merged.disturbances, imported.disturbances, "disturbances", file: file, line: line)
        XCTAssertEqual(merged.restingHr, imported.restingHr, "restingHr", file: file, line: line)
        XCTAssertEqual(merged.avgHrv, imported.avgHrv, "avgHrv", file: file, line: line)
        XCTAssertEqual(merged.recovery, imported.recovery, "recovery", file: file, line: line)
        XCTAssertEqual(merged.strain, imported.strain, "strain", file: file, line: line)
        XCTAssertEqual(merged.exerciseCount, imported.exerciseCount, "exerciseCount", file: file, line: line)
        XCTAssertEqual(merged.spo2Pct, imported.spo2Pct, "spo2Pct", file: file, line: line)
        XCTAssertEqual(merged.skinTempDevC, imported.skinTempDevC, "skinTempDevC", file: file, line: line)
        XCTAssertEqual(merged.respRateBpm, imported.respRateBpm, "respRateBpm", file: file, line: line)
        XCTAssertEqual(merged.steps, imported.steps, "steps", file: file, line: line)
        XCTAssertEqual(merged.activeKcalEst, imported.activeKcalEst, "activeKcalEst", file: file, line: line)
        XCTAssertEqual(merged.spo2Red, imported.spo2Red, "spo2Red", file: file, line: line)
        XCTAssertEqual(merged.spo2Ir, imported.spo2Ir, "spo2Ir", file: file, line: line)
        XCTAssertEqual(merged.skinTempC, imported.skinTempC, "skinTempC", file: file, line: line)
        XCTAssertEqual(merged.sleepHrOnly, imported.sleepHrOnly, "sleepHrOnly", file: file, line: line)
    }

    func testComputedSdnnSurvivesAnImportThatHasNone() {
        let computed = row(avgHrv: 42, avgSdnn: 61)
        let imported = row(avgHrv: 44)                       // a CSV row: RMSSD, never an SDNN
        let merged = HealthExportMerge.merged(computed: computed, imported: imported)
        XCTAssertEqual(merged.avgSdnn, 61, "the computed SDNN must not be dropped by the import")
        XCTAssertEqual(merged.avgHrv, 44, "every other field still comes from the imported row")
    }

    func testImportedSdnnWinsWhenItHasOne() {
        let merged = HealthExportMerge.merged(computed: row(avgSdnn: 61), imported: row(avgSdnn: 70))
        XCTAssertEqual(merged.avgSdnn, 70, "precedence is unchanged where the importer does supply a value")
    }

    func testNoComputedRowLeavesTheImportedRowUntouched() {
        let imported = row(avgHrv: 44)
        XCTAssertEqual(HealthExportMerge.merged(computed: nil, imported: imported), imported)
    }

    func testNeitherSideHavingSdnnIsStillNil() {
        let merged = HealthExportMerge.merged(computed: row(avgHrv: 42), imported: row(avgHrv: 44))
        XCTAssertNil(merged.avgSdnn, "nothing is invented when neither side has a value")
    }

    func testEveryOtherImportedFieldSurvivesTheCarry() {
        // The carry rebuilds the struct, and ten of its parameters default to nil, so a forgotten one
        // compiles and blanks data silently. Every field is checked, not a sample.
        let imported = row(avgHrv: 44, restingHr: 52, recovery: 71)
        let merged = HealthExportMerge.merged(computed: row(avgSdnn: 61), imported: imported)
        assertOnlySdnnDiffers(merged, from: imported, expectedSdnn: 61)
    }
}
