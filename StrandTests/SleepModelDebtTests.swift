import XCTest
import WhoopStore
@testable import Strand

final class SleepModelDebtTests: XCTestCase {
    private func day(_ value: String, sleep: Double?) -> DailyMetric {
        DailyMetric(day: value, totalSleepMin: sleep, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testLocalFallbackLatestAgreesWithLedger() {
        let days = [day("2026-06-01", sleep: 360), day("2026-06-02", sleep: 480)]
        let metric = SleepModel.sleepDebtSeries(
            days: days, importedSleep: [:], napSleepMinByDay: [:])
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latest ?? -1, ledger.magnitudeMin, accuracy: 1e-9)
    }

    func testImportedWhoopDebtRemainsVerbatim() {
        let days = [day("2026-06-01", sleep: 480)]
        let imported = ["2026-06-01": ImportedSleepFigures(
            performancePct: nil, consistencyPct: nil, needMin: nil, debtMin: 17.25)]
        let metric = SleepModel.sleepDebtSeries(
            days: days, importedSleep: imported, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latest ?? -1, 17.25, accuracy: 1e-9)
    }

    /// The tile's latest value is WHOOP's exported figure for its night: the model says so, so the tile can
    /// label it (the debt ledger on the same tab is always NOOP's own, and the two can differ).
    func testImportedLatestIsMarkedAsWhoops() {
        let days = [day("2026-06-01", sleep: 360), day("2026-06-02", sleep: 480)]
        let imported = ["2026-06-02": ImportedSleepFigures(
            performancePct: nil, consistencyPct: nil, needMin: nil, debtMin: 17.25)]
        let metric = SleepModel.sleepDebtSeries(days: days, importedSleep: imported, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latestDay, "2026-06-02")
        XCTAssertTrue(SleepModel.debtLatestIsImported(metric, importedSleep: imported))
        XCTAssertEqual(nightDetailDebtCaption(metric.latest, fromWhoop: true), String(localized: "From WHOOP"))
    }

    /// An older imported night does not label a latest value NOOP computed itself.
    func testLocalLatestIsNotMarkedEvenAfterAnImportedNight() {
        let days = [day("2026-06-01", sleep: 360), day("2026-06-02", sleep: 480)]
        let imported = ["2026-06-01": ImportedSleepFigures(
            performancePct: nil, consistencyPct: nil, needMin: nil, debtMin: 90)]
        let metric = SleepModel.sleepDebtSeries(days: days, importedSleep: imported, napSleepMinByDay: [:])
        XCTAssertEqual(metric.latestDay, "2026-06-02")
        XCTAssertFalse(SleepModel.debtLatestIsImported(metric, importedSleep: imported))
        XCTAssertFalse(SleepModel.debtLatestIsImported(
            SleepModel.sleepDebtSeries(days: [], importedSleep: [:], napSleepMinByDay: [:]), importedSleep: imported))
        XCTAssertEqual(nightDetailDebtCaption(nil, fromWhoop: true), String(localized: "vs need"),
                       "No figure, no source claim")
    }
}
