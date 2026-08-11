import XCTest
@testable import Strand

/// Pins the "HR tracked but no sleep" diagnostic (#1244). When a day clears the >=200-HR gate yet the
/// stager detects NO in-bed session, the summary line only says `totalSleepMin=nil` with no clue why —
/// every other night trace (`rhr`/`rrsample`/`hrv diag`) emits only once a session exists. The engine now
/// ships one counts-only reason line naming the raw inputs the stager was handed, so the next capture
/// separates the causes (no motion vs coverage gap vs window). `sleepDetectNoNightLogLine` is the pure
/// formatter the loop calls; tested directly (no store). Mirrors the Android `sleepDetectNoNightLogLine`
/// so the two platforms log a byte-identical line.
@MainActor
final class IntelligenceSleepDetectNoNightTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testNoMotionNight_theLeadingHypothesis() {
        // The #1244 shape: plenty of HR, but grav=0 (no motion offloaded) so the in-bed detector can't
        // gate the night → nothing stages. `window=54h` is the past-day span (30 h back → next midnight).
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-11", hrCount: 41230, rrCount: 0, respCount: 880,
            gravCount: 0, stepCount: 12, providedCount: 0, windowHours: 54)
        XCTAssertEqual(line,
            "sleep-detect day=2026-08-11 NO-NIGHT hr=41230 rr=0 resp=880 "
            + "grav=0 steps=12 provided=0 window=54h")
    }

    func testTodayWindowIs48h() {
        // Today's read caps at dayStart+18h (vs a past day's next-midnight), so the whole span is 48 h.
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-12", hrCount: 5000, rrCount: 900, respCount: 300,
            gravCount: 4, stepCount: 0, providedCount: 0, windowHours: 48)
        XCTAssertTrue(line.contains("window=48h"), line)
    }

    func testLineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-11", hrCount: 1, rrCount: 1, respCount: 1,
            gravCount: 1, stepCount: 1, providedCount: 1, windowHours: 54)
        XCTAssertFalse(line.contains("—"))
    }
}
