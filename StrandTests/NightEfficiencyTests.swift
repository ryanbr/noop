import XCTest
import WhoopStore
@testable import Strand

final class NightEfficiencyTests: XCTestCase {
    func testSelectedNightUsesItsOwnDayAndSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let wake = Int(formatter.date(from: "2026-06-01 07:00")!.timeIntervalSince1970)
        func night(_ efficiency: Double?) -> Night {
            Night(session: CachedSleepSession(startTs: wake - 8 * 3600, endTs: wake,
                                              efficiency: efficiency, restingHr: nil, avgHrv: nil,
                                              stagesJSON: nil, userEdited: false, startTsAdjusted: nil),
                  stages: Stages(awake: 100, light: 200, deep: 100, rem: 100))
        }
        func day(_ key: String, _ efficiency: Double?) -> DailyMetric {
            DailyMetric(day: key, totalSleepMin: 400, efficiency: efficiency,
                        deepMin: 100, remMin: 100, lightMin: 200, disturbances: nil,
                        restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                        exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        }
        let days = [day("2026-06-01", 0.92), day("2026-06-02", 0.99)]
        XCTAssertEqual(night(0.87).efficiencyPct(days: days), 87)
        XCTAssertEqual(night(nil).efficiencyPct(days: days), 92)
        XCTAssertEqual(night(nil).efficiencyPct(days: [days[1]]), 80)
    }

    func testResolverOracle() {
        let cases: [(Double?, Double?, Double, Double, Double?)] = [
            (0.87, 0.92, 400, 500, 87),
            (87, 92, 400, 500, 87),
            (nil, 0.92, 400, 500, 92),
            (nil, 92, 400, 500, 92),
            (nil, nil, 400, 500, 80),
            (nil, nil, 600, 500, 100),
            (nil, nil, 0, 0, nil),
            (nil, nil, 10, -1, nil),
            (1, 92, 0, 0, 100),
            (1.01, nil, 0, 0, 1.01),
            (0, 92, 400, 500, 0),
        ]
        for (session, day, asleep, bed, expected) in cases {
            XCTAssertEqual(nightEfficiencyPct(sessionEfficiency: session, dayEfficiency: day,
                                              asleep: asleep, timeInBed: bed), expected)
        }
    }
}
