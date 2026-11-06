import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// "Hours vs needed" divides by the same need the sleep-debt ledger, the debt tile and the Rest score use
/// (`SleepModel.debtNeedMin`, the engine's `personalizedNeedHours`), not by the wearer's own mean sleep.
/// The mean drifts down with a chronic deficit, so before this a steady 6.5h sleeper read 87% of need on
/// one tile while the ledger beside it counted every night 1.5h short. Twin: `SleepImportedFiguresTest`
/// `hoursVsNeededUsesTheNormativeNeedWithoutAnImport`.
final class SleepNeedOneSourceTests: XCTestCase {

    private func nightsFixture(asleepMin: Double, count: Int) -> [DailyMetric] {
        // Dated back from today's logical day so the tile's staleness-bounded `latest` reads the newest.
        let cal = Calendar.current
        let anchor = Date()
        return (0..<count).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: anchor) ?? anchor
            return DailyMetric(day: BodyVitalSigns.logicalDayKey(date), totalSleepMin: asleepMin, efficiency: 0.9,
                               deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                               avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        }
    }

    func testAShortSleeperIsMeasuredAgainstTheNormativeNeed() {
        let days = nightsFixture(asleepMin: 390, count: 10)       // a steady 6.5h
        let need = SleepModel.debtNeedMin(days: days)
        XCTAssertEqual(need, 480, accuracy: 1e-9, "Below the adult floor, the need is the 8h target.")
        let latest = SleepModel.hoursVsNeededSeries(days: days, importedSleep: [:]).latest
        XCTAssertEqual(latest ?? -1, 390.0 / 480.0 * 100.0, accuracy: 1e-9)
        XCTAssertNotEqual(latest ?? -1, 390.0 / 450.0 * 100.0, accuracy: 1e-6,
                          "The old 7.5h-floored mean read 86.7%: a second need on the same screen.")
    }

    func testALongSleeperIsMeasuredAgainstTheirOwnLongerNeed() {
        let days = nightsFixture(asleepMin: 540, count: 10)       // a steady 9h: the need adjusts UP
        XCTAssertEqual(SleepModel.debtNeedMin(days: days), 540, accuracy: 1e-9)
        XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: days, importedSleep: [:]).latest ?? -1, 100, accuracy: 1e-9)
    }

    func testAnImportedNeedStillWinsForItsDay() {
        let days = nightsFixture(asleepMin: 400, count: 1)
        let imported = [days[0].day: ImportedSleepFigures(performancePct: nil, consistencyPct: nil, needMin: 500, debtMin: nil)]
        XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: days, importedSleep: imported).latest ?? -1,
                       400.0 / 500.0 * 100.0, accuracy: 1e-9)
    }
}
