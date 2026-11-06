import XCTest
import WhoopStore
@testable import Strand

/// The wind-down nudge is timed from the sleep need the Sleep tab states (`SleepModel.debtNeedMin`), not
/// from a fixed 8 h nothing ever set. Pins the rounding rule (byte-identical with the Kotlin
/// `WindDownStore.needMinutes`), that the need is adopted only when it moves, that the nudge time follows
/// it, and that the Alarms copy adds need and lead up correctly.
@MainActor
final class WindDownSleepNeedTests: XCTestCase {

    private let needKey = "windDown.sleepNeedMinutes"
    private let enabledKey = "windDown.enabled"
    private let leadKey = "windDown.leadMinutes"
    private let wakeKey = "windDown.wakeMinutes"
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        // Keep the wearer's own settings out of the way and restore them afterwards; the nudge stays OFF
        // so no test schedules a real notification.
        for key in [needKey, enabledKey, leadKey, wakeKey] {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [needKey, enabledKey, leadKey, wakeKey] {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    /// The same inputs and expected minutes as the Kotlin `WindDownSleepNeedTest` (oracle output of this
    /// function compiled standalone): half away from zero, clamped to 5–11 h, non-finite → 8 h.
    func testNeedRoundsAndClampsLikeTheKotlinTwin() {
        let inputs: [Double] = [-1e300, -5, 0, 299.4, 299.5, 300, 300.5, 479.49, 479.5, 480, 480.4999, 480.5, 495.75,
                                504.4999999, 504.5, 517.25, 539.99, 559.5, 570, 659.4, 659.5, 660, 660.4, 700, 1e300,
                                .nan, .infinity, -.infinity]
        let expected = [300, 300, 300, 300, 300, 300, 301, 479, 480, 480, 480, 481, 496, 504, 505, 517, 540, 560, 570,
                        659, 660, 660, 660, 660, 660, 480, 480, 480]
        XCTAssertEqual(inputs.map { WindDownNudge.needMinutes(fromNormativeNeedMin: $0) }, expected)
    }

    func testNeedIsAdoptedOnlyWhenItMoves() {
        XCTAssertEqual(WindDownNudge.sleepNeedMinutes, 480, "Nothing adopted yet: the cold-start 8 h.")
        XCTAssertTrue(WindDownNudge.adoptSleepNeed(normativeNeedMin: 517.25))
        XCTAssertEqual(WindDownNudge.sleepNeedMinutes, 517)
        XCTAssertFalse(WindDownNudge.adoptSleepNeed(normativeNeedMin: 517.4), "Same rounded need: no write.")
        XCTAssertTrue(WindDownNudge.adoptSleepNeed(normativeNeedMin: 480))
        XCTAssertEqual(WindDownNudge.sleepNeedMinutes, 480)
    }

    /// The need the nudge uses is the Sleep tab's, from the same rows: 10 nights whose upper quartile is
    /// 8h 40m give the Sleep tab's 520-minute need, and the reminder for a 07:00 wake moves to 21:50.
    func testNudgeFollowsTheSleepTabNeed() {
        let totals: [Double] = [420, 450, 470, 480, 500, 510, 520, 520, 530, 540]
        let rows = totals.enumerated().map { index, minutes in
            DailyMetric(day: String(format: "2026-10-%02d", index + 1), totalSleepMin: minutes, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil)
        }
        let sleepTabNeed = SleepModel.debtNeedMin(days: rows)
        XCTAssertEqual(sleepTabNeed, 520, accuracy: 1e-6)
        WindDownNudge.adoptSleepNeed(normativeNeedMin: sleepTabNeed)
        XCTAssertEqual(WindDownNudge.sleepNeedMinutes, 520)
        UserDefaults.standard.set(7 * 60, forKey: wakeKey)
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(), 21 * 60 + 50, "07:00 − 8h 40m − 30m lead")
        WindDownNudge.adoptSleepNeed(normativeNeedMin: 480)
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(), 22 * 60 + 30, "the old fixed 8 h: 07:00 − 8h − 30m")
    }

    /// The copy states need + lead as hours and minutes; it used to print the need's whole hours beside
    /// the lead, which read "8h 30m" for an 8h 40m need.
    func testAlarmsCopyAddsNeedAndLead() {
        WindDownNudge.adoptSleepNeed(normativeNeedMin: 520)
        XCTAssertEqual(WindDownNudge.offsetHoursMinutes.hours, 9)
        XCTAssertEqual(WindDownNudge.offsetHoursMinutes.minutes, 10)
        WindDownNudge.adoptSleepNeed(normativeNeedMin: 480)
        XCTAssertEqual(WindDownNudge.offsetHoursMinutes.hours, 8)
        XCTAssertEqual(WindDownNudge.offsetHoursMinutes.minutes, 30)
    }
}
