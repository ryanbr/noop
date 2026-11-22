import XCTest
@testable import Strand
import WhoopStore

/// The header the Apple on-device model reads first. TODAY must be today's row, never simply the
/// newest stored one, and the two weeks must be calendar windows, not row counts.
@MainActor
final class AICoachAppleHeaderTests: XCTestCase {

    private func engine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-aicoach-apple-header"))
    }

    private func day(_ key: String, charge: Double) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: 50, avgHrv: 60, recovery: charge, strain: 10, exerciseCount: nil)
    }

    /// Midday, so the 04:00 logical-day rollover cannot move the day.
    private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!

    func testTodayIsTodaysRowNotTheNewestStoredOne() {
        let header = engine().appleHeader(days: [day("2026-03-09", charge: 61)], now: noon)
        let first = header.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(first.contains("2026-03-10"), first)
        XCTAssertTrue(first.contains("no data for today yet"), first)
        XCTAssertFalse(first.contains("charge 61"), first)
    }

    func testTodaysRowIsQuoted() {
        let header = engine().appleHeader(days: [day("2026-03-09", charge: 61),
                                                 day("2026-03-10", charge: 72)], now: noon)
        let first = header.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(first.contains("2026-03-10"), first)
        XCTAssertTrue(first.contains("charge 72"), first)
    }

    /// Gaps in both weeks, and an old row that "the 14 newest rows" would have pulled in.
    func testWeeksAreCalendarWindows() {
        let days = [day("2026-02-01", charge: 10),
                    day("2026-02-25", charge: 70), day("2026-03-03", charge: 70),
                    day("2026-03-04", charge: 50), day("2026-03-10", charge: 50)]
        let lines = engine().appleHeader(days: days, now: noon).components(separatedBy: "\n")
        let thisWeek = lines.first { $0.hasPrefix("THE WEEK (") } ?? ""
        let before = lines.first { $0.hasPrefix("THE WEEK BEFORE") } ?? ""
        XCTAssertTrue(thisWeek.contains("charge 50"), thisWeek)
        XCTAssertTrue(before.contains("charge 70"), before)
    }
}
