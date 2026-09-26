import XCTest
@testable import StrandAnalytics

/// `NightStandDown` — the learned night band an Oura ring's daytime-HR hold stands down for when the
/// all-day HR toggle is on. Pure; the live source's `shouldSuspendLiveHR` composes it with the screen rule.
final class NightStandDownTests: XCTestCase {

    private func clock(_ h: Int, _ m: Int = 0) -> Int { h * 3_600 + m * 60 }

    /// Midsleep 02:30 on an 8 h night: bedtime 22:30, wake 06:30 → band 21:30 → 07:30 across midnight.
    func testBandIsBedtimeMinusLeadToWakePlusTail() {
        let band = NightStandDown.band(habitualMidsleepSec: clock(2, 30), typicalSleepHours: 8)
        XCTAssertEqual(band, NightStandDown.Band(startSec: clock(21, 30), endSec: clock(7, 30)))
        XCTAssertEqual(NightStandDown.describe(band!), "21:30–07:30")
    }

    /// The RESUMED line stamps the local time it fired at, so a resume inside its own band is readable.
    func testDescribeSecOfDayWrapsIntoTheDay() {
        XCTAssertEqual(NightStandDown.describeSecOfDay(clock(8, 3)), "08:03")
        XCTAssertEqual(NightStandDown.describeSecOfDay(0), "00:00")
        XCTAssertEqual(NightStandDown.describeSecOfDay(-60), "23:59")
        XCTAssertEqual(NightStandDown.describeSecOfDay(86_400 + clock(1)), "01:00")
    }

    func testContainsIsCircularAcrossMidnight() {
        let band = NightStandDown.Band(startSec: clock(21, 30), endSec: clock(7, 30))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: clock(21, 30)))    // start inclusive
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: clock(23, 59)))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: 0))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: clock(7, 29)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: clock(7, 30)))   // end exclusive
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: clock(12)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: clock(21, 29)))
        // A second-of-day past the day wraps instead of falling out.
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: 86_400 + clock(1)))
    }

    /// A shift worker sleeping 09:00 → 16:00 (midsleep 12:30, 7 h): band 08:00 → 17:00, no midnight crossing.
    func testDaytimeSleeperBandDoesNotCrossMidnight() {
        let band = NightStandDown.band(habitualMidsleepSec: clock(12, 30), typicalSleepHours: 7)!
        XCTAssertEqual(band, NightStandDown.Band(startSec: clock(8), endSec: clock(17)))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: clock(12)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: clock(2)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: clock(22)))
    }

    /// Cold start (no learned schedule) is nil — the caller keeps the screen rule rather than a made-up clock.
    func testColdStartIsNil() {
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: nil, typicalSleepHours: 8))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: clock(2), typicalSleepHours: nil))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: clock(2), typicalSleepHours: 0))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: -1, typicalSleepHours: 8))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: 86_400, typicalSleepHours: 8))
    }

    /// A padded night that would swallow the whole day is unlearned, not "never hold the ring".
    func testWholeDayNightIsNil() {
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: clock(2), typicalSleepHours: 22.5))
        XCTAssertNotNil(NightStandDown.band(habitualMidsleepSec: clock(2), typicalSleepHours: 21.9))
    }

    /// Same bedtime derivation as the battery night-guard: midsleep − half the night, circular.
    func testBedtimeMatchesTheBatteryNightGuardDerivation() {
        // 00:30 midsleep, 7.5 h → bedtime 20:45 → band opens 19:45; wake 04:15 → band closes 05:15.
        let band = NightStandDown.band(habitualMidsleepSec: clock(0, 30), typicalSleepHours: 7.5)!
        XCTAssertEqual(band.startSec, clock(19, 45))
        XCTAssertEqual(band.endSec, clock(5, 15))
    }
}
