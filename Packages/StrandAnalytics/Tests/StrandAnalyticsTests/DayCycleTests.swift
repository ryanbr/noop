import XCTest
@testable import StrandAnalytics

final class DayCycleTests: XCTestCase {
    func testDefaultsAndCalendarMode() {
        XCTAssertEqual(DayCycleMode.persisted(nil), .sleepOnset)
        XCTAssertEqual(DayCycleMode.persisted("midnight"), .midnight)
        let window = DayCycleResolver.activeWindow(mode: .midnight, latestSleep: nil, now: 86_500,
                                                   offsetSec: 0)
        XCTAssertEqual(window.startInclusive, 86_400)
        XCTAssertEqual(window.source, .calendar)
    }

    func testSleepOnsetCycleStaysOpenAcrossMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 20 * 3_600, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        let fallback = DayCycleResolver.fallbackMidnight(after: sleep.startInclusive, offsetSec: 0)
        XCTAssertEqual(fallback, 2 * 86_400)
        let active = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                   now: fallback, offsetSec: 0)
        XCTAssertEqual(active.source, .detectedSleep)
        XCTAssertEqual(active.startInclusive, sleep.startInclusive)
    }

    /// Both branches of the 18-hour fallback rule, which neither platform pinned.
    ///
    /// `fallbackMidnight` returns the first midnight at least `minSyntheticMidnightAgeSeconds` after onset.
    /// Because the candidate is `floor(minimum / day) * day`, it is at or BELOW `minimum` always — so the
    /// direct branch is reachable only on exact equality, when onset sits precisely 18 h before a midnight.
    /// Every existing case here and on Kotlin used an onset that rolls, so a `>=` quietly weakened to `>`
    /// would have moved that boundary a full day and nothing would have failed.
    func testFallbackTakesTheMidnightExactlyEighteenHoursAfterOnset() {
        // 06:00 + 18 h lands exactly on the next midnight: taken directly, not rolled past.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 6 * 3_600, offsetSec: 0), 86_400)
    }

    /// The rolling branch at a different onset from the case above, so the two are not the same test twice.
    func testFallbackRollsWhenTheNextMidnightIsTooSoon() {
        // 23:00 + 18 h overshoots the next midnight, so the one after it wins.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 23 * 3_600, offsetSec: 0), 2 * 86_400)
    }

    /// The boundary is LOCAL midnight, not UTC midnight — and until now nothing said so. Every
    /// day-cycle case on both platforms passed a zero offset, so the whole offset arithmetic, which is
    /// the part that decides which local day a boundary lands on, was unpinned. This repo has already
    /// had days re-bucket on travel once, so it is worth a case rather than an argument.
    ///
    /// 06:00 local at UTC-5 is 11:00 UTC. Plus 18 h is 05:00 UTC the next day, which IS local midnight
    /// there, so the direct branch takes it: 104_400 = 29 h UTC = 00:00 local. A resolver that floored
    /// to UTC midnight would answer 86_400 and be a day out for a third of the planet.
    func testFallbackLandsOnLocalMidnightNotUTC() {
        let offsetSec = -5 * 3_600
        let onsetLocal0600 = 6 * 3_600 - offsetSec
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: onsetLocal0600, offsetSec: offsetSec),
                       104_400)
    }

    func testAbsoluteCapStillUsesSyntheticMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 0, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        XCTAssertEqual(DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                     now: 40 * 3_600, offsetSec: 0).source,
                       .syntheticMidnight)
    }

    func testCoverageSegmentsPreferPriorityWithoutCrossingDeviceCounters() {
        let window = PhysiologicalSteps.CycleWindow(sleepId: "night", onset: 100, endExclusive: 500)
        let segments = PhysiologicalSteps.ownerSegmentsFromCoverage(window, coverage: [
            .init(owner: "secondary", onset: 100, endExclusive: 350, priority: 1),
            .init(owner: "active", onset: 200, endExclusive: 500, priority: 0),
        ], fallbackOwner: "secondary")
        XCTAssertEqual(segments, [
            .init(owner: "secondary", onset: 100, endExclusive: 200),
            .init(owner: "active", onset: 200, endExclusive: 500),
        ])
    }
}
