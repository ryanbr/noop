import XCTest
@testable import StrandAnalytics

/// The staleness bound on a carried vital. A carry exists so a missed night doesn't blank a tile — not
/// so a months-old value keeps reading as tonight's measurement. The regression these pin: NOOP showed
/// "Respiratory 15.6" every day for a fortnight, which was the last value of a WHOOP CSV import that
/// ended 2026-07-30, carried forward unbounded by two separate "latest vital" resolvers.
final class VitalCarryStalenessTests: XCTestCase {

    // MARK: cutoffKey

    func testCutoffKeyIsTodayMinusCarryDays() {
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "2026-08-13", carryDays: 7), "2026-08-06")
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "2026-08-13", carryDays: 0), "2026-08-13")
    }

    func testCutoffKeyCrossesMonthAndYearBoundaries() {
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "2026-03-03", carryDays: 7), "2026-02-24")
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "2026-01-03", carryDays: 7), "2025-12-27")
    }

    /// Leap day is a real calendar step, not a 365-day assumption.
    func testCutoffKeyHandlesLeapYear() {
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "2028-03-05", carryDays: 7), "2028-02-27")
    }

    /// Fail CLOSED: an unparseable key admits only today rather than opening the carry wide.
    func testCutoffKeyFailsClosedOnGarbage() {
        XCTAssertEqual(Baselines.cutoffKey(todayKey: "not-a-day", carryDays: 7), "not-a-day")
    }

    // MARK: freshestCarried

    func testCarriesAValueInsideTheWindow() {
        let points = [(day: "2026-08-01", value: 16.0), (day: "2026-08-10", value: 15.6)]
        let got = Baselines.freshestCarried(points, todayKey: "2026-08-13", carryDays: 7)
        XCTAssertEqual(got?.value, 15.6)
        XCTAssertEqual(got?.day, "2026-08-10")
    }

    /// THE REPORTED BUG: the import's last day is 2026-07-30 and "today" is 2026-08-13 — 14 days.
    /// It must not be presented as the latest reading.
    func testDropsTheFourteenDayOldImportThatShowed156() {
        let points = [(day: "2026-07-28", value: 16.0),
                      (day: "2026-07-29", value: 16.2),
                      (day: "2026-07-30", value: 15.6)]
        XCTAssertNil(Baselines.freshestCarried(points, todayKey: "2026-08-13", carryDays: 7))
    }

    /// The window is inclusive at its edge and exclusive one day past it.
    func testWindowEdgeIsInclusive() {
        let atEdge = [(day: "2026-08-06", value: 15.6)]
        XCTAssertEqual(Baselines.freshestCarried(atEdge, todayKey: "2026-08-13", carryDays: 7)?.value, 15.6)

        let oneDayPast = [(day: "2026-08-05", value: 15.6)]
        XCTAssertNil(Baselines.freshestCarried(oneDayPast, todayKey: "2026-08-13", carryDays: 7))
    }

    /// Only the NEWEST point is judged: an old value is not rescued by a fresh one, and a fresh value
    /// is not blocked by old ones sitting behind it in the series.
    func testJudgesOnlyTheNewestPoint() {
        let points = [(day: "2026-07-30", value: 15.6), (day: "2026-08-12", value: 14.1)]
        XCTAssertEqual(Baselines.freshestCarried(points, todayKey: "2026-08-13", carryDays: 7)?.value, 14.1)
    }

    func testTodaysOwnValueAlwaysCarries() {
        let points = [(day: "2026-08-13", value: 14.1)]
        XCTAssertEqual(Baselines.freshestCarried(points, todayKey: "2026-08-13", carryDays: 7)?.value, 14.1)
    }

    func testEmptySeriesCarriesNothing() {
        XCTAssertNil(Baselines.freshestCarried([(day: String, value: Double)](),
                                               todayKey: "2026-08-13", carryDays: 7))
    }

    /// A future-dated row (a bad-clock strap) is newer than the cutoff, so it still resolves — the
    /// future-clock guard is the caller's `$0.day < todayKey` bound, not this one. Pinned so the
    /// division of responsibility is explicit rather than accidental.
    func testFutureDatedRowIsNotFilteredHere() {
        let points = [(day: "2026-09-01", value: 14.1)]
        XCTAssertEqual(Baselines.freshestCarried(points, todayKey: "2026-08-13", carryDays: 7)?.value, 14.1)
    }

    // MARK: the constant itself

    /// The bound must stay well inside `staleDays` — past that the personal baseline judging the value
    /// is itself stale, so presenting the value as "latest" is doubly wrong.
    func testCarryWindowIsShorterThanBaselineStaleness() {
        XCTAssertLessThan(Baselines.vitalCarryDays, Baselines.staleDays)
        XCTAssertEqual(Baselines.vitalCarryDays, 7)
    }
}
