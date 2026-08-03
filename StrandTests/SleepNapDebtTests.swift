import XCTest
import WhoopStore
@testable import Strand

/// Nap debt-credit wiring: the Sleep tab must credit only actual asleep minutes from blocks outside
/// the canonical main-night group. The scalar debt arithmetic is pinned in StrandAnalytics tests;
/// these app-target tests pin the session classification/decoding seam. Android mirrors both cases.
final class SleepNapDebtTests: XCTestCase {

    private let midnight = 1_749_513_600

    private func session(start: Int, durationMin: Int, stages: String) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: start + durationMin * 60,
                           efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: stages)
    }

    func testAfternoonNapContributesItsAsleepMinutes() {
        let nightStart = midnight - 60 * 60
        let napStart = midnight + 14 * 60 * 60
        let night = session(
            start: nightStart, durationMin: 416,
            stages: #"{"awake":24,"light":214,"deep":82,"rem":96}"#) // 392 asleep
        let nap = session(
            start: napStart, durationMin: 50,
            stages: #"{"awake":2,"light":30,"deep":10,"rem":8}"#) // 48 asleep

        XCTAssertEqual(SleepView.napSleepMinutes([night, nap]), 48, accuracy: 1e-9)
    }

    func testBridgedMainNightFragmentsAreNotDoubleCreditedAsNaps() {
        let firstStart = midnight - 60 * 60                 // 23:00
        let secondStart = midnight + 90 * 60                // 01:30, 30-minute gap
        let napStart = midnight + 14 * 60 * 60
        let first = session(
            start: firstStart, durationMin: 120,
            stages: #"{"awake":10,"light":70,"deep":25,"rem":15}"#)
        let second = session(
            start: secondStart, durationMin: 210,
            stages: #"{"awake":15,"light":120,"deep":40,"rem":35}"#)
        let nap = session(
            start: napStart, durationMin: 50,
            stages: #"{"awake":2,"light":30,"deep":10,"rem":8}"#)

        XCTAssertEqual(SleepView.napSleepMinutes([first, second, nap]), 48, accuracy: 1e-9)
    }
}
