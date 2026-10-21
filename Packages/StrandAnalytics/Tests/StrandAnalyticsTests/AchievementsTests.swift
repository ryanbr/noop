import XCTest
@testable import StrandAnalytics

/// Mirrored by android AchievementsTest.kt - same fixtures, same expected outputs.
final class AchievementsTests: XCTestCase {

    private func key(_ epoch: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epoch) * 86_400)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func testStreakAndThresholdMilestones() {
        let start = Baselines.isoEpochDay("2026-09-01")!
        // 8 scored days in a row, a gap, then one more.
        var days = (0..<8).map { Achievements.Day(day: key(start + $0), recovery: 50) }
        days.append(Achievements.Day(day: key(start + 10), recovery: 95, strain: 18.2, sleepMin: 481, steps: 10_000))
        days.append(Achievements.Day(day: key(start + 11), strain: 30, sleepMin: 2_000))   // implausible, no score
        let a = Dictionary(uniqueKeysWithValues: Achievements.evaluate(days.shuffled(), today: key(start + 12))
            .map { ($0.id, $0) })
        XCTAssertEqual(a[.firstScore]?.unlockedDay, "2026-09-01")
        XCTAssertEqual(a[.streak7]?.unlockedDay, "2026-09-07")
        XCTAssertNil(a[.streak30]?.unlockedDay)
        XCTAssertNil(a[.scored100]?.unlockedDay)
        XCTAssertEqual(a[.charge90]?.unlockedDay, "2026-09-11")
        XCTAssertEqual(a[.sleep8h]?.unlockedDay, "2026-09-11")
        XCTAssertEqual(a[.effort18]?.unlockedDay, "2026-09-11")
        XCTAssertEqual(a[.steps10k]?.unlockedDay, "2026-09-11")
        XCTAssertTrue(a[.charge90]!.isNew)
        XCTAssertFalse(a[.firstScore]!.isNew)
        XCTAssertEqual(Achievements.evaluate([], today: "x").count, AchievementId.allCases.count)
    }

    func testDuplicateDayCountsOnceInStreak() {
        let start = Baselines.isoEpochDay("2026-01-01")!
        var days = (0..<6).map { Achievements.Day(day: key(start + $0), recovery: 40) }
        days.append(Achievements.Day(day: key(start + 5), recovery: 41))
        let a = Achievements.evaluate(days, today: key(start + 5))
        XCTAssertNil(a.first { $0.id == .streak7 }?.unlockedDay)
    }
}
