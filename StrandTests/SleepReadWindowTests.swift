import XCTest
@testable import Strand

/// Pins the sleep READ window's end bound.
///
/// This one bound has now produced the same user-visible bug twice. #500 fixed it for PAST days but left
/// TODAY capped at `dayStart + 18h`, so a day-sleeper (asleep ~12:00, awake ~20:00) — still inside today
/// when they wake — had every wake reported as a flat **18:00** until local midnight, at which point the
/// day became past, the other branch took over, and the same night silently re-scored to the real time.
///
/// It is invisible in a build and invisible in a strap log: the trace shows a perfectly well-formed sleep
/// run that simply ends at 18:00:00. It cost three wrong diagnoses (offload lag, the `minSleepMin` gate,
/// clock drift) before the reproduction — "it fixes itself at 00:01" — identified the branch. Hence tests
/// on the bound itself rather than on the pipeline around it.
final class SleepReadWindowTests: XCTestCase {

    /// 2026-08-14 00:00 and 2026-08-15 00:00 in Athens (UTC+3) — the night from the reported capture.
    private let today = 1_786_690_800          // Fri 14 Aug 00:00 +03
    private var tomorrow: Int { today + 86_400 }

    // MARK: - Today

    /// The regression. The wearer woke at 20:41; the read must reach it.
    func testTodayReadsPastSixPMWhenTheWearerIsStillAwakeLater() {
        let wake = today + 20 * 3_600 + 41 * 60      // 20:41
        let now = wake + 20 * 60                     // they check the app at 21:01
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: today, now: now)
        XCTAssertGreaterThanOrEqual(end, wake,
                                    "read window ends before the wake — it would report a flat 18:00")
        XCTAssertNotEqual(end, today + 18 * 3_600, "the 18:00 cap is back")
    }

    /// Today must never read into the future — the only property the old bound actually secured.
    func testTodayNeverReadsPastNow() {
        let now = today + 9 * 3_600                  // 09:00
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: today, now: now)
        XCTAssertEqual(end, now)
    }

    /// …and never past the day's own end, even if `now` has somehow run on.
    func testTodayIsStillBoundedByTheNextLocalMidnight() {
        let now = today + 30 * 3_600                 // absurd, but the bound must hold
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: today, now: now)
        XCTAssertEqual(end, tomorrow)
    }

    /// Early in the morning the window is still short — nothing here widens it beyond the present.
    func testTodayEarlyMorningIsCappedAtNowNotAtSixPM() {
        let now = today + 2 * 3_600                  // 02:00
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: today, now: now)
        XCTAssertEqual(end, now)
        XCTAssertLessThan(end, today + 18 * 3_600)
    }

    // MARK: - Past days

    /// A past day reads the whole day — this is the half #500 already fixed, pinned so it stays fixed.
    func testAPastDayReadsThroughToTheNextLocalMidnight() {
        let yesterday = today - 86_400
        let now = today + 21 * 3_600
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: yesterday,
                                                       nowLocalMidnight: today, now: now)
        XCTAssertEqual(end, today, "a past day must read to its own next midnight")
    }

    /// A past day's window must NOT be shortened by `now` — that would re-truncate old nights.
    func testAPastDayIsNotClampedByNow() {
        let longAgo = today - 10 * 86_400
        let end = IntelligenceEngine.sleepReadWindowEnd(dayStart: longAgo,
                                                       nowLocalMidnight: today, now: today + 60)
        XCTAssertEqual(end, longAgo + 86_400)
    }

    // MARK: - The rollover itself

    /// The reported symptom, expressed directly: the SAME night must not read differently either side of
    /// local midnight. Before the fix the 00:01 reading reached 20:41 and the 23:59 one stopped at 18:00.
    func testTheSameNightReadsTheSameJustBeforeAndJustAfterMidnight() {
        let wake = today + 20 * 3_600 + 41 * 60

        // 23:59, still "today"
        let before = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: today,
                                                          now: today + 86_340)
        // 00:01, now a past day
        let after = IntelligenceEngine.sleepReadWindowEnd(dayStart: today, nowLocalMidnight: tomorrow,
                                                         now: tomorrow + 60)

        XCTAssertGreaterThanOrEqual(before, wake, "pre-midnight read still truncates the wake")
        XCTAssertGreaterThanOrEqual(after, wake)
        XCTAssertEqual(after, tomorrow)
    }
}
