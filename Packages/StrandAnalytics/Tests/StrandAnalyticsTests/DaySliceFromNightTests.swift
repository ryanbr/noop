import XCTest
@testable import StrandAnalytics

/// Locks `AnalyticsEngine.daySliceFromNight` (#997): for a PAST day the calendar-day streams
/// (dayHr/daySteps/dayGravity) are a non-truncated subset of the night window analyzeRecent already read,
/// so re-reading them from the store is redundant — the slice must equal an in-range filter of the night
/// list (which, for a complete night, equals the direct read: same inclusive bounds, same ts-ASC order).
/// And the shortcut must DECLINE (nil → the caller reads directly) in the unsafe cases: TODAY's calendar
/// day runs past the 18 h night cap, and a night read at the stream limit may be truncated inside the day
/// span. If any of that drifts, samples get attributed to the wrong day / dropped, so this is the safety
/// net for the read-skip. Mirrors the Android `AnalyticsEngineDaySliceTest` (same bounds fixture).
final class DaySliceFromNightTests: XCTestCase {

    private struct S: Equatable { let ts: Int }

    // A past day's night window: [dayStart − 30 h, nextMidnight]; the calendar day
    // [dayStart, dayStart + 86400 − 1] sits strictly inside it. Mirrors the real IntelligenceEngine bounds.
    private let dayStart = 1_700_000_000
    private var nightLo: Int { dayStart - 30 * 3_600 }
    private var nightHi: Int { dayStart + 86_400 }        // = nextMidnight (a past day's `to`)
    private var dayLo: Int { dayStart }
    private var dayHi: Int { dayStart + 86_400 - 1 }
    private var night: [S] { stride(from: nightLo, through: nightHi, by: 60).map { S(ts: $0) } }

    func testPastDayReturnsTheInRangeFilterOfTheNightList() throws {
        let slice = try XCTUnwrap(AnalyticsEngine.daySliceFromNight(
            night, nightLo: nightLo, nightHi: nightHi, dayLo: dayLo, dayHi: dayHi, ts: { $0.ts }))
        // Byte-identical to filtering the night list (which, for a complete night, equals the direct read).
        XCTAssertEqual(slice, night.filter { $0.ts >= dayLo && $0.ts <= dayHi })
        // Nothing outside the day leaks in; order is preserved (ascending, as the store returned it).
        XCTAssertTrue(slice.allSatisfy { $0.ts >= dayLo && $0.ts <= dayHi })
        XCTAssertEqual(slice, slice.sorted { $0.ts < $1.ts })
    }

    func testTodayDayEndPastTheNightCapDeclines() {
        // TODAY: the night window caps at dayStart + 18 h, so the calendar day (to +24 h) reaches past it.
        let todayNightHi = dayStart + 18 * 3_600
        XCTAssertNil(AnalyticsEngine.daySliceFromNight(
            night, nightLo: nightLo, nightHi: todayNightHi, dayLo: dayLo, dayHi: dayHi, ts: { $0.ts }))
    }

    func testDstShiftedDayBeforeTheNightWindowDeclines() {
        // The self-protecting guard the other way: a shifted dayLo that falls before the night window
        // (e.g. a DST-moved local midnight) must decline to the direct read, never slice a partial window.
        XCTAssertNil(AnalyticsEngine.daySliceFromNight(
            night, nightLo: nightLo, nightHi: nightHi, dayLo: nightLo - 1, dayHi: dayHi, ts: { $0.ts }))
    }

    func testTruncatedNightReadDeclines() {
        // A night read that returned exactly `limit` rows may be truncated inside the day span (ORDER BY
        // ts ASC LIMIT drops the LATE rows — exactly where the day sits). Locked at an injected small
        // limit AND at the real 200_000 default the IntelligenceEngine call sites rely on.
        let small = (0..<10).map { S(ts: $0) }
        XCTAssertNil(AnalyticsEngine.daySliceFromNight(
            small, nightLo: 0, nightHi: 10, dayLo: 0, dayHi: 5, limit: 10, ts: { $0.ts }))
        let atDefaultLimit = (0..<200_000).map { S(ts: $0) }
        XCTAssertNil(AnalyticsEngine.daySliceFromNight(
            atDefaultLimit, nightLo: 0, nightHi: 200_000, dayLo: 0, dayHi: 100, ts: { $0.ts }))
    }

    func testBoundsAreInclusiveOnBothEnds() {
        // The store range is inclusive [dayLo, dayHi] (`ts >= from AND ts <= to`); the filter must keep
        // the boundary samples and drop their immediate neighbours.
        let edge = [S(ts: dayLo - 1), S(ts: dayLo), S(ts: dayHi), S(ts: dayHi + 1)]
        let slice = AnalyticsEngine.daySliceFromNight(
            edge, nightLo: nightLo, nightHi: nightHi, dayLo: dayLo, dayHi: dayHi, ts: { $0.ts })
        XCTAssertEqual(slice, [S(ts: dayLo), S(ts: dayHi)])
    }
}
