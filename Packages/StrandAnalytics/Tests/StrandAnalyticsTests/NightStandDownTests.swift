import XCTest
@testable import StrandAnalytics

/// `NightStandDown` — the learned night band an Oura ring's daytime-HR hold stands down for when the
/// all-day HR toggle is on. Pure; the live source's `shouldSuspendLiveHR` composes it with the screen rule.
final class NightStandDownTests: XCTestCase {

    private func sec(_ h: Int, _ m: Int = 0) -> Int { h * 3_600 + m * 60 }

    /// Midsleep 02:30 on an 8 h night: bedtime 22:30, wake 06:30 → band 21:30 → 07:30 across midnight.
    func testBandIsBedtimeMinusLeadToWakePlusTail() {
        let band = NightStandDown.band(habitualMidsleepSec: sec(2, 30), typicalSleepHours: 8)
        XCTAssertEqual(band, NightStandDown.Band(startSec: sec(21, 30), endSec: sec(7, 30)))
        XCTAssertEqual(NightStandDown.describe(band!), "21:30–07:30")
    }

    func testContainsIsCircularAcrossMidnight() {
        let band = NightStandDown.Band(startSec: sec(21, 30), endSec: sec(7, 30))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: sec(21, 30)))    // start inclusive
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: sec(23, 59)))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: 0))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: sec(7, 29)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: sec(7, 30)))   // end exclusive
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: sec(12)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: sec(21, 29)))
        // A second-of-day past the day wraps instead of falling out.
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: 86_400 + sec(1)))
    }

    /// A shift worker sleeping 09:00 → 16:00 (midsleep 12:30, 7 h): band 08:00 → 17:00, no midnight crossing.
    func testDaytimeSleeperBandDoesNotCrossMidnight() {
        let band = NightStandDown.band(habitualMidsleepSec: sec(12, 30), typicalSleepHours: 7)!
        XCTAssertEqual(band, NightStandDown.Band(startSec: sec(8), endSec: sec(17)))
        XCTAssertTrue(NightStandDown.contains(band, secOfDay: sec(12)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: sec(2)))
        XCTAssertFalse(NightStandDown.contains(band, secOfDay: sec(22)))
    }

    /// Cold start (no learned schedule) is nil — the caller keeps the screen rule rather than a made-up clock.
    func testColdStartIsNil() {
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: nil, typicalSleepHours: 8))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: sec(2), typicalSleepHours: nil))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: sec(2), typicalSleepHours: 0))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: -1, typicalSleepHours: 8))
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: 86_400, typicalSleepHours: 8))
    }

    /// A padded night that would swallow the whole day is unlearned, not "never hold the ring".
    func testWholeDayNightIsNil() {
        XCTAssertNil(NightStandDown.band(habitualMidsleepSec: sec(2), typicalSleepHours: 22.5))
        XCTAssertNotNil(NightStandDown.band(habitualMidsleepSec: sec(2), typicalSleepHours: 21.9))
    }

    /// Same bedtime derivation as the battery night-guard: midsleep − half the night, circular.
    func testBedtimeMatchesTheBatteryNightGuardDerivation() {
        // 00:30 midsleep, 7.5 h → bedtime 20:45 → band opens 19:45; wake 04:15 → band closes 05:15.
        let band = NightStandDown.band(habitualMidsleepSec: sec(0, 30), typicalSleepHours: 7.5)!
        XCTAssertEqual(band.startSec, sec(19, 45))
        XCTAssertEqual(band.endSec, sec(5, 15))
    }
}
