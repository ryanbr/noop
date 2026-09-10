import XCTest
@testable import Strand

/// PR#554 (MumiZed, reimplemented as NoopApp) — per-day wake overrides for the wind-down nudge.
///
/// The nudge derives its fire time from the user's wake time minus sleep need minus lead. Per-day overrides
/// let a single weekday use a DIFFERENT wake time (a weekend lie-in, say) while every un-overridden day
/// falls back to the default. These pin: the override round-trips through the store, an absent override
/// reverts a day to the default, the per-weekday nudge math follows the override, and clamping is honest.
///
/// `WindDownNudge` is @MainActor and backed by UserDefaults.standard, so each test clears its keys first.
@MainActor
final class WindDownPerDayOverrideTests: XCTestCase {

    private let perDayKey = "windDown.perDayWakeMinutes"
    private let wakeKey = "windDown.wakeMinutes"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
        super.tearDown()
    }

    func testNoOverrides_everyDayUsesDefaultWake() {
        WindDownNudge.setWakeMinutes(7 * 60)   // 07:00 default
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
        for weekday in 1...7 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testSetOverride_appliesToThatDayOnly() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)   // Saturday lie-in to 09:00
        XCTAssertTrue(WindDownNudge.hasPerDayOverrides)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 7), 9 * 60)
        // Every other day still uses the default.
        for weekday in 1...6 {
            XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testClearOverride_revertsDayToDefault() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: 8 * 60)   // Sunday 08:00
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 8 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: nil)      // clear it
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 1), 7 * 60)
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    func testPerDayNudgeMinute_followsTheOverride() {
        // Defaults: 8h need + 30m lead. Wake 07:00 default → nudge 22:00. Override Saturday wake 09:00 →
        // nudge 00:00 the previous day's evening? No — 09:00 − 8:30 = 00:30. Just assert it tracks the math.
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)
        let need = WindDownNudge.sleepNeedMinutes, lead = WindDownNudge.leadMinutes
        let expectedSat = (((9 * 60 - need - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 7), expectedSat)
        // A non-overridden day uses the default wake.
        let expectedDefault = (((7 * 60 - need - lead) % 1440) + 1440) % 1440
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 3), expectedDefault)
    }

    func testOverrideMinutesAreClamped() {
        WindDownNudge.setWakeOverride(weekday: 4, minutes: 5_000)   // way past a day
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 24 * 60 - 1)
        WindDownNudge.setWakeOverride(weekday: 4, minutes: -100)
        XCTAssertEqual(WindDownNudge.wakeMinutes(forWeekday: 4), 0)
    }

    func testInvalidWeekday_isIgnored() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 9, minutes: 8 * 60)   // no weekday 9
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    // MARK: - #1863: day shift and weekday pinning

    func testShiftedWeekday_wrapsThroughWeekEnd() {
        // Sunday (1) − 1 → Saturday (7); Monday (2) − 1 → Sunday (1); no shift is identity.
        XCTAssertEqual(WindDownNudge.shiftedWeekday(weekday: 1, by: -1), 7)
        XCTAssertEqual(WindDownNudge.shiftedWeekday(weekday: 2, by: -1), 1)
        XCTAssertEqual(WindDownNudge.shiftedWeekday(weekday: 3, by: -1), 2)
        XCTAssertEqual(WindDownNudge.shiftedWeekday(weekday: 7, by: -1), 6)
        for weekday in 1...7 {
            XCTAssertEqual(WindDownNudge.shiftedWeekday(weekday: weekday, by: 0), weekday)
        }
    }

    func testNudgeDayShift_earlyWake_isPreviousDay() {
        // Tuesday 03:30 wake, default 8h need + 30m lead: raw = 210 − 480 − 30 = −300 → shift −1.
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 3, minutes: 3 * 60 + 30)   // Tuesday 03:30
        XCTAssertEqual(WindDownNudge.nudgeDayShift(forWeekday: 3), -1)
        // The wrapped minute is 19:00 the previous evening.
        XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWeekday: 3), 19 * 60)
    }

    func testNudgeDayShift_normalWake_isPreviousDay() {
        // 07:00 wake, default 8h need + 30m lead: raw = 420 − 480 − 30 = −90 → shift −1.
        WindDownNudge.setWakeMinutes(7 * 60)
        XCTAssertEqual(WindDownNudge.nudgeDayShift(forWeekday: 3), -1)
    }

    func testNudgeDayShift_lateWake_isSameDay() {
        // 09:00 wake, default 8h need + 30m lead: raw = 540 − 480 − 30 = 30 → shift 0.
        WindDownNudge.setWakeMinutes(9 * 60)
        XCTAssertEqual(WindDownNudge.nudgeDayShift(forWeekday: 3), 0)
    }

    func testEarlyWakeNudge_pinnedToPreviousDay() {
        // #1863 scenario: Tuesday (weekday 3) 03:30 wake → nudge at 19:00 on Monday (weekday 2).
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 3, minutes: 3 * 60 + 30)   // Tuesday 03:30
        let shift = WindDownNudge.nudgeDayShift(forWeekday: 3)
        let minute = WindDownNudge.nudgeMinuteOfDay(forWeekday: 3)
        let nudgeWeekday = WindDownNudge.shiftedWeekday(weekday: 3, by: shift)
        XCTAssertEqual(shift, -1)
        XCTAssertEqual(minute, 19 * 60)            // 19:00
        XCTAssertEqual(nudgeWeekday, 2)            // Monday, not Tuesday
    }

    func testEarlyWakeOnSunday_pinnedToSaturday() {
        // Sunday (weekday 1) 03:30 wake → nudge at 19:00 on Saturday (weekday 7).
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: 3 * 60 + 30)   // Sunday 03:30
        let shift = WindDownNudge.nudgeDayShift(forWeekday: 1)
        let nudgeWeekday = WindDownNudge.shiftedWeekday(weekday: 1, by: shift)
        XCTAssertEqual(shift, -1)
        XCTAssertEqual(nudgeWeekday, 7)            // Saturday, wrapping the week end
    }
}
