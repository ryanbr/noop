import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// #804 Fix A: a night the MOTION detector can't stage — an Oura ring sends NO gravity vector, so
/// `detectSleep` returns nothing and the night scored blank — must still score when the caller hands
/// `analyzeDay` the ring's OWN persisted hypnogram via `providedSleep`. And the byte-identical default
/// path (empty `providedSleep`) must be unchanged.
final class AnalyticsEngineProvidedSleepTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    /// Build a night [start, end) of hr (30 s) + rr (2 s, varied so RMSSD is computable) with NO gravity.
    private func nightStreams(start: Int, end: Int) -> (hr: [HRSample], rr: [RRInterval]) {
        let hr = stride(from: start, to: end, by: 30).map { HRSample(ts: $0, bpm: 52 + ($0 / 300) % 4) }
        // rrMs cycles 1080…1120 so successive differences are non-zero → a real (non-nil) RMSSD.
        var i = 0
        let rr = stride(from: start, to: end, by: 2).map { ts -> RRInterval in
            defer { i += 1 }
            return RRInterval(ts: ts, rrMs: 1080 + (i % 6) * 8)
        }
        return (hr, rr)
    }

    /// A contiguous deep/light/rem/wake hypnogram spanning [start, end), the shape #773 persists.
    private func hypnogram(start: Int) -> [StageSegment] {
        var t = start
        func seg(_ mins: Int, _ stage: String) -> StageSegment {
            let s = StageSegment(start: t, end: t + mins * 60, stage: stage); t += mins * 60; return s
        }
        return [
            seg(20, "wake"), seg(100, "light"), seg(60, "deep"), seg(60, "light"),
            seg(60, "rem"), seg(120, "light"), seg(60, "deep"), seg(60, "rem"),
            seg(40, "light"), seg(20, "wake"),
        ]   // 600 min in bed; deep 120, rem 120, light 320, wake 40
    }

    func testProvidedHypnogramScoresANightWithoutGravity() {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3600          // 20:00 the previous evening
        let sleepEnd = sleepStart + 600 * 60          // +10 h → 06:00, ends on `day`
        let s = nightStreams(start: sleepStart, end: sleepEnd)
        let provided = [SleepSession(start: sleepStart, end: sleepEnd, efficiency: 0.75,
                                     stages: hypnogram(start: sleepStart), restingHR: nil, avgHRV: nil)]

        let res = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                             providedSleep: provided)

        XCTAssertNotNil(res.daily.totalSleepMin, "the provided hypnogram must score the night")
        XCTAssertEqual(res.daily.totalSleepMin ?? 0, 560, accuracy: 1)   // light 320 + deep 120 + rem 120
        XCTAssertEqual(res.daily.deepMin ?? 0, 120, accuracy: 1)
        XCTAssertEqual(res.daily.remMin ?? 0, 120, accuracy: 1)
        XCTAssertEqual(res.daily.efficiency ?? 0, 0.75, accuracy: 0.001)
        XCTAssertFalse(res.cachedSleep.isEmpty)
        // HRV & resting HR are re-derived from THIS day's rr/hr over the provided window (the ring row
        // carried neither) — the whole point of #804 (avgHrv was nil despite 36 k rr present).
        XCTAssertNotNil(res.daily.avgHrv, "avgHrv must be derived from rr over the provided sleep window")
        XCTAssertNotNil(res.daily.restingHr)
    }

    func testEmptyProvidedSleepIsByteIdenticalToOmitting() {
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let s = nightStreams(start: dayStart - 4 * 3600, end: dayStart + 6 * 3600)

        let omitted = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile)
        let empty = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                               providedSleep: [])
        XCTAssertEqual(omitted.daily, empty.daily)
        // No gravity + no provided hypnogram = the pre-fix #804 state: the night does not score.
        XCTAssertNil(omitted.daily.totalSleepMin)
        XCTAssertNil(omitted.daily.avgHrv)
    }

    func testProvidedSessionKeepsItsOwnStoredHrvWhenPresent() {
        // A provided session that already carries restingHR/avgHRV is used verbatim (not recomputed).
        let day = "2026-07-27"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3600
        let sleepEnd = sleepStart + 600 * 60
        let s = nightStreams(start: sleepStart, end: sleepEnd)
        let provided = [SleepSession(start: sleepStart, end: sleepEnd, efficiency: 0.8,
                                     stages: hypnogram(start: sleepStart), restingHR: 48, avgHRV: 65)]

        let res = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, profile: profile,
                                             providedSleep: provided)
        XCTAssertEqual(res.daily.restingHr, 48)
        XCTAssertEqual(res.daily.avgHrv ?? 0, 65, accuracy: 0.001)
    }
}
