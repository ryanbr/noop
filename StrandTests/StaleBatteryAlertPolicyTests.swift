import XCTest
@testable import Strand

/// A strap that drains while disconnected still gets a warning (#2556).
///
/// The live crossings in `BatteryAlertPolicy` can only judge a percentage the app received, and both run off
/// the connection, so a strap that goes flat out of range crosses 15 and 12 unseen. On an unbonded 5/MG,
/// where a link can average under two minutes, that is the ordinary case rather than an exotic one.
///
/// Same cases and same expected values as the Kotlin `StaleBatteryAlertPolicyTest`, both taken from one
/// oracle rather than from reading either implementation back.
final class StaleBatteryAlertPolicyTests: XCTestCase {

    private let now = 1_790_000_000
    private func hours(_ h: Int) -> Int { h * 3600 }

    private func ev(soc: Int? = 11,
                    ts: Int? = 1_790_000_000 - 6 * 3600,
                    charging: Bool? = false,
                    connected: Bool = false,
                    alerted: Int? = nil) -> BatteryNotifier.StaleBatteryAlertPolicy.Decision {
        BatteryNotifier.StaleBatteryAlertPolicy.evaluate(
            lastSocPct: soc, lastTsSec: ts, lastCharging: charging,
            nowSec: now, connected: connected, alertedForTs: alerted)
    }

    /// The live crossings own the connected case. Two readouts of one fact must not disagree.
    func testAConnectedStrapIsNeverTheStalePathsBusiness() {
        XCTAssertFalse(ev(connected: true).fire)
    }

    func testSixHoursOutOfContactAtElevenPercentWarnsAndReportsTheAge() {
        let d = ev()
        XCTAssertTrue(d.fire)
        XCTAssertEqual(d.ageSeconds, hours(6))
    }

    /// Recent silence is normal: a strap goes out of range constantly and that is not news.
    func testOneHourOutOfContactIsNotStaleEnough() {
        XCTAssertFalse(ev(ts: now - hours(1)).fire)
    }

    /// The boundary belongs to firing, so a strap exactly at the window is not left in limbo.
    func testExactlyAtTheStaleWindowFires() {
        let d = ev(ts: now - BatteryNotifier.StaleBatteryAlertPolicy.staleAfterSeconds)
        XCTAssertTrue(d.fire)
        XCTAssertEqual(d.ageSeconds, BatteryNotifier.StaleBatteryAlertPolicy.staleAfterSeconds)
    }

    func testAHealthyLastReadingSaysNothingHoweverLongAgo() {
        XCTAssertFalse(ev(soc: 16).fire)
    }

    /// Same threshold as the live low alert, inclusive, so the two cannot disagree about what "low" is.
    func testExactlyAtTheLowThresholdCountsAsLow() {
        XCTAssertTrue(ev(soc: BatteryNotifier.BatteryAlertPolicy.lowThreshold).fire)
    }

    func testAStrapLastSeenOnTheChargerIsNotInTrouble() {
        XCTAssertFalse(ev(charging: true).fire)
    }

    /// Only a CONFIRMED charging reading suppresses, matching the live policy. Unknown still warns.
    func testUnknownChargingStateStillWarns() {
        XCTAssertTrue(ev(charging: nil).fire)
    }

    func testTheSameReadingDoesNotRenotifyOnEveryAppOpen() {
        XCTAssertFalse(ev(alerted: now - hours(6)).fire)
    }

    /// Keyed on the reading's timestamp, not a boolean: a NEWER low reading is a new fact.
    func testANewerLowReadingFiresEvenThoughAnOlderOneAlreadyDid() {
        XCTAssertTrue(ev(alerted: now - hours(9)).fire)
    }

    func testNoBankedReadingMeansNothingToSay() {
        XCTAssertFalse(ev(soc: nil, ts: nil, charging: nil).fire)
    }

    /// The age label is what the wearer actually reads, and it is shared phrasing with the Kotlin twin, so
    /// both ends of the pair pin the same boundary. Hours below two days, days above.
    func testTheAgeLabelReadsInHoursBelowTwoDaysAndInDaysAbove() {
        let l = BatteryNotifier.StaleBatteryAlertPolicy.ageLabel
        XCTAssertEqual(l(hours(2)), "2h")
        XCTAssertEqual(l(hours(6)), "6h")
        XCTAssertEqual(l(hours(47)), "47h")
        XCTAssertEqual(l(hours(48)), "2d")
        XCTAssertEqual(l(hours(80)), "3d")
    }

    /// Truncation, not rounding: 6h59m is still "6h", so the label never overstates the silence.
    func testAPartialHourRoundsDown() {
        XCTAssertEqual(BatteryNotifier.StaleBatteryAlertPolicy.ageLabel(hours(6) + 3599), "6h")
    }

    /// A reading from the future is a clock problem, not a flat strap.
    func testAFutureReadingNeverWarns() {
        XCTAssertFalse(ev(ts: now + hours(1)).fire)
    }
}
