import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

final class SleepRecalculationWindowTests: XCTestCase {
    private let now = 1_800_000_000

    func testCalendarWakeDaysIncludeBothDSTLengthsAndNeighborContext() throws {
        for (day, hours) in [("2026-03-08", 23), ("2026-11-01", 25), ("2021-06-15", 24)] {
            let window = try XCTUnwrap(SleepRecalculationWindow.make(
                day: day, timeZone: TimeZone(identifier: "America/Chicago")!, now: now))
            XCTAssertEqual(window.end - window.start, hours * 3600)
            XCTAssertEqual(window.readStart, window.start - StreamReadCap.lookbackSeconds)
            XCTAssertFalse(window.contains(window.start - 1))
            XCTAssertTrue(window.contains(window.start))
            XCTAssertTrue(window.contains(window.end - 1))
            XCTAssertFalse(window.contains(window.end))
        }
    }

    func testRejectsInvalidAndUnfinishedDatesWithoutRollingThem() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        for day in ["2026-02-30", "2026-13-01", "2026-1-01", "not-a-day"] {
            XCTAssertNil(SleepRecalculationWindow.make(day: day, timeZone: zone, now: now))
        }
        let window = try XCTUnwrap(SleepRecalculationWindow.make(day: "2021-06-15", timeZone: zone, now: now))
        XCTAssertNil(SleepRecalculationWindow.make(day: window.day, timeZone: zone, now: window.end - 1))
        XCTAssertNotNil(SleepRecalculationWindow.make(day: window.day, timeZone: zone, now: window.end))
    }

    func testSelectedOldMissingNightRunsRealDetectorFromInputs() throws {
        let window = try XCTUnwrap(SleepRecalculationWindow.make(
            day: "2021-06-15", timeZone: TimeZone(secondsFromGMT: 0)!, now: now))
        let end = window.start + 6 * 3600
        let start = end - 7 * 3600
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 50) }
        let gravity = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let rr = stride(from: start, to: end, by: 2).map {
            RRInterval(ts: $0, rrMs: (($0 - start) / 2).isMultiple(of: 2) ? 1195 : 1205)
        }
        let missing = AnalyticsEngine.analyzeDay(day: window.day, profile: UserProfile(), sleepDayWindow: window)
        XCTAssertTrue(missing.cachedSleep.isEmpty)
        let recovered = AnalyticsEngine.analyzeDay(day: window.day, hr: hr, rr: rr, gravity: gravity, profile: UserProfile(),
                                                    sleepDayWindow: window)
        XCTAssertEqual(recovered.cachedSleep.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(recovered.daily.totalSleepMin), 300)
        XCTAssertTrue(recovered.cachedSleep.allSatisfy { window.contains($0.endTs) })
    }

    func testRealDayTotalsUseAbsoluteCalendarBoundsOnDSTDays() throws {
        for day in ["2026-03-08", "2026-11-01"] {
            let window = try XCTUnwrap(SleepRecalculationWindow.make(
                day: day, timeZone: TimeZone(identifier: "America/Chicago")!, now: now))
            let hr = stride(from: window.start - 7200, to: window.end + 7200, by: 30)
                .map { HRSample(ts: $0, bpm: 100 + ($0 / 30) % 30) }
            let full = AnalyticsEngine.analyzeDay(day: day, dayHr: hr, profile: UserProfile(),
                tzOffsetSeconds: window.offsetSeconds, sleepDayWindow: window)
            let clipped = AnalyticsEngine.analyzeDay(day: day, dayHr: hr.filter { window.contains($0.ts) }, profile: UserProfile(),
                tzOffsetSeconds: window.offsetSeconds, sleepDayWindow: window)
            XCTAssertEqual(full.daily.activeKcalEst, clipped.daily.activeKcalEst)
            XCTAssertNotNil(full.daily.activeKcalEst)
        }
    }
    func testSavedManualWindowWinsEvenWhenDetectedOnsetUsesAnotherKey() throws {
        let window = try XCTUnwrap(SleepRecalculationWindow.make(day: "2021-06-15", timeZone: TimeZone(secondsFromGMT: 0)!, now: now))
        let start = window.start - 3600
        let end = window.start + 6 * 3600
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 50) }
        let grav = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let bed = window.start + 3600
        let wake = bed + 7200
        let manual = CachedSleepSession(startTs: start - 30, endTs: wake, efficiency: 1,
            restingHr: 50, avgHrv: 10, stagesJSON: "[{\"start\":\(bed),\"end\":\(wake),\"stage\":\"deep\"}]",
            userEdited: true, startTsAdjusted: bed)
        let result = AnalyticsEngine.analyzeDay(day: window.day, hr: hr, gravity: grav, profile: UserProfile(),
            sleepDayWindow: window, preservedSleep: [manual])
        XCTAssertEqual(result.daily.totalSleepMin, 120)
        XCTAssertEqual(result.cachedSleep.count, 1)
        XCTAssertEqual(result.cachedSleep.first?.startTs, bed)
        XCTAssertEqual(result.cachedSleep.first?.endTs, wake)
    }

}
