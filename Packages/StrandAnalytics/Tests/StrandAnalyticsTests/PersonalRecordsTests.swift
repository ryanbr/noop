import XCTest
@testable import StrandAnalytics

/// Mirrors com.noop.analytics.PersonalRecordsTest - same fixtures, same expected outputs.
final class PersonalRecordsTests: XCTestCase {

    private let today = "2026-10-20"

    private func key(_ epoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch) * 86_400)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// `n` consecutive days ending at `end`, HRV from `hrv` by index.
    private func daysRun(_ n: Int, end: String, hrv: (Int) -> Double?) -> [PersonalRecords.Day] {
        let endEpoch = Baselines.isoEpochDay(end)!
        return (0..<n).map { i in PersonalRecords.Day(day: key(endEpoch - (n - 1) + i), hrvMs: hrv(i)) }
    }

    private func record(_ days: [PersonalRecords.Day], _ metric: PersonalRecordMetric,
                        today: String? = nil) -> PersonalRecords.Record? {
        PersonalRecords.records(days, today: today ?? self.today).first { $0.metric == metric }
    }

    func testEmptyHistoryHasNoRecords() {
        XCTAssertEqual(PersonalRecords.records([], today: today), [])
    }

    func testHighestHrvWinsAndKeepsPreviousBest() {
        let r = record(daysRun(5, end: "2026-10-01") { [40.0, 55, 50, 70, 60][$0] }, .hrv)!
        XCTAssertEqual(r.value, 70)
        XCTAssertEqual(r.day, "2026-09-30")
        XCTAssertEqual(r.previousBest, 55)
        XCTAssertEqual(r.samples, 5)
        XCTAssertFalse(r.isNew)
    }

    func testRestingHrLowerIsBetter() {
        let days = [
            PersonalRecords.Day(day: "2026-10-01", restingHr: 52),
            PersonalRecords.Day(day: "2026-10-02", restingHr: 47),
            PersonalRecords.Day(day: "2026-10-03", restingHr: 49),
        ]
        let r = record(days, .restingHr)!
        XCTAssertEqual(r.value, 47)
        XCTAssertEqual(r.day, "2026-10-02")
        XCTAssertEqual(r.previousBest, 52)
    }

    func testTieKeepsEarliestDay() {
        let r = record(daysRun(3, end: "2026-10-01") { _ in 60 }, .hrv)!
        XCTAssertEqual(r.day, "2026-09-29")
        XCTAssertNil(r.previousBest)
    }

    func testImplausibleValuesAreIgnored() {
        let days = [
            PersonalRecords.Day(day: "2026-10-01", hrvMs: 400, restingHr: 10, sleepMin: 12),
            PersonalRecords.Day(day: "2026-10-02", hrvMs: 65, restingHr: 50, sleepMin: 480),
        ]
        XCTAssertEqual(record(days, .hrv)?.value, 65)
        XCTAssertEqual(record(days, .sleep)?.value, 480)
        XCTAssertEqual(record(days, .restingHr)?.value, 50)
        XCTAssertEqual(record(days, .hrv)?.samples, 1)
    }

    func testEfficiencyPercentReadsAsFraction() {
        let days = [PersonalRecords.Day(day: "2026-10-01", efficiency: 91),
                    PersonalRecords.Day(day: "2026-10-02", efficiency: 0.88)]
        XCTAssertEqual(record(days, .efficiency)!.value, 0.91, accuracy: 1e-12)
    }

    func testUnorderedInputAndBadKeys() {
        let days = [
            PersonalRecords.Day(day: "2026-10-03", hrvMs: 50),
            PersonalRecords.Day(day: "not-a-day", hrvMs: 99),
            PersonalRecords.Day(day: "2026-10-01", hrvMs: 50),
            PersonalRecords.Day(day: "2026-10-02", hrvMs: 45),
        ]
        let r = record(days, .hrv)!
        XCTAssertEqual(r.day, "2026-10-01")
        XCTAssertEqual(r.samples, 3)
    }

    func testNewRecordNeedsRecentDayAndEnoughHistory() {
        let r = record(daysRun(20, end: today) { $0 == 19 ? 90 : 50 + Double($0) }, .hrv)!
        XCTAssertEqual(r.day, today)
        XCTAssertTrue(r.isNew)
        XCTAssertEqual(r.previousBest, 68)
    }

    func testRecordInFirstWeeksIsNotNew() {
        let r = record(daysRun(10, end: today) { 50 + Double($0) }, .hrv)!
        XCTAssertEqual(r.day, today)
        XCTAssertFalse(r.isNew)
    }

    func testNewWindowIsSevenDaysInclusive() {
        XCTAssertTrue(record(daysRun(20, end: "2026-10-14") { $0 == 19 ? 90 : 50 }, .hrv)!.isNew)
        XCTAssertFalse(record(daysRun(20, end: "2026-10-13") { $0 == 19 ? 90 : 50 }, .hrv)!.isNew)
    }

    func testFutureDayIsNeverNew() {
        XCTAssertFalse(record(daysRun(20, end: "2026-10-22") { $0 == 19 ? 90 : 50 }, .hrv)!.isNew)
    }

    func testUnparseableTodayMarksNothingNew() {
        XCTAssertFalse(record(daysRun(20, end: today) { $0 == 19 ? 90 : 50 }, .hrv, today: "bad")!.isNew)
    }

    func testMetricsWithoutValuesAreOmittedAndOrderIsStable() {
        let days = [PersonalRecords.Day(day: "2026-10-01", hrvMs: 61, strain: 14.2, steps: 12_000)]
        XCTAssertEqual(PersonalRecords.records(days, today: today).map(\.metric), [.hrv, .strain, .steps])
    }
}
