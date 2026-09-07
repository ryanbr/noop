import XCTest
@testable import StrandAnalytics

/// Swift twin of `SleepHeroLogicTest`. The Kotlin side has had these since the logic was written; the
/// Swift side had none, because the function lived private inside the view — which is why the defect
/// below went uncaught on this platform until a report arrived.
final class SleepNightLabelTests: XCTestCase {

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A wake at `hour` on the given day, as an epoch second.
    private func wake(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 7) -> Int {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hour
        return Int(utc.date(from: c)!.timeIntervalSince1970)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hour
        return utc.date(from: c)!
    }

    /// The bug. Measured from the newest RECORDED night, offset 0 was always zero, so the hero read
    /// "Last night" over a night days old — beside the correct date, contradicting it.
    func testAStaleNewestNightIsNotCalledLastNight() {
        let n = SleepNightLabel.nightsAgo(
            wakeTimestamps: [wake(2026, 9, 5)] as [Int?], offset: 0,
            today: day(2026, 9, 7), calendar: utc)
        XCTAssertEqual(n, 2)
    }

    func testTheNightThatEndedThisMorningIsStillLastNight() {
        let n = SleepNightLabel.nightsAgo(
            wakeTimestamps: [wake(2026, 9, 7)] as [Int?], offset: 0,
            today: day(2026, 9, 7), calendar: utc)
        XCTAssertEqual(n, 0)
    }

    /// Calendar distance, not carousel index: a night with no data is skipped by the carousel, so
    /// labelling by index would make the nights either side of it read as consecutive.
    func testCountsCalendarNightsNotCarouselIndex() {
        let nights: [Int?] = [wake(2026, 8, 13), wake(2026, 8, 10)]
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 0,
                                                 today: day(2026, 8, 13), calendar: utc), 0)
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 1,
                                                 today: day(2026, 8, 13), calendar: utc), 3)
    }

    /// Only TODAY is rolled; the shown night keeps its calendar wake-date, because that is what the
    /// carousel groups by. Rolling both sides collapsed two distinct entries onto one label.
    func testTwoNightsEitherSideOfTheRollKeepDistinctLabels() {
        let nights: [Int?] = [wake(2026, 9, 7, 2), wake(2026, 9, 6, 7)]
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 0,
                                                 today: day(2026, 9, 7), calendar: utc), 0)
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 1,
                                                 today: day(2026, 9, 7), calendar: utc), 1)
    }

    /// The pre-roll window, which lands on the NEGATIVE branch and gets the right answer from what
    /// reads like an error fallback. Wake at 02:00, check at 03:00: the night's calendar date is the
    /// 7th while the logical day is still the 6th, so the distance is -1 and offset 0 is genuinely
    /// "Last night". Pinned so a later tightening of that branch cannot break it silently.
    func testANightWokenBeforeTheRollStillReadsLastNight() {
        let n = SleepNightLabel.nightsAgo(
            wakeTimestamps: [wake(2026, 9, 7, 2)] as [Int?], offset: 0,
            today: day(2026, 9, 6, 23), calendar: utc)
        XCTAssertEqual(n, 0)
    }

    func testOutOfRangeFallsBackToTheIndex() {
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: [] as [Int?], offset: 5,
                                                 today: day(2026, 9, 7), calendar: utc), 5)
    }

    /// A carousel entry with no session falls back to the offset, exactly as the Kotlin twin does.
    /// Mapping it to 0 would put the night in 1970 and print roughly twenty thousand nights ago.
    ///
    /// The dates are chosen so the fallback is DISTINGUISHABLE: at offset 1 the answer is 1 only
    /// because the guard fired, since the real night sits fourteen nights back and an unguarded 1970
    /// would be five figures. A nil at offset 0 against a same-day today would have returned 0 either
    /// way and proved nothing.
    func testAnEntryWithNoSessionFallsBackToTheIndex() {
        let nights: [Int?] = [wake(2026, 9, 6), nil]
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 0,
                                                 today: day(2026, 9, 20), calendar: utc), 14)
        XCTAssertEqual(SleepNightLabel.nightsAgo(wakeTimestamps: nights, offset: 1,
                                                 today: day(2026, 9, 20), calendar: utc), 1)
    }
}
