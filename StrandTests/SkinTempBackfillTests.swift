import XCTest
import StrandAnalytics
import WhoopProtocol

/// #1853: tests for the PURE half of the skin-temp absolute backfill — the session-attribution rule
/// (rule 1), the anchor rule (rule 3), and the pagination rule (rule 2). The I/O walker that reads
/// from / writes to `WhoopStore` is covered separately.
final class SkinTempBackfillTests: XCTestCase {

    // MARK: Rule 1 — attribute sessions by END

    /// A session whose END falls in the day is matched; one whose END falls in the previous day is not.
    /// The night window is 54 h wide and contains the previous night, so filtering by end is the only
    /// thing that keeps two nights from being averaged into one temperature.
    func testSessionsForDay_matchesByEndNotStart() {
        // dayStart = 2026-08-25 00:00 UTC = 1_789_632_000
        let dayStart = 1_789_632_000
        let prevNightEnd = dayStart - 3_600           // 23:00 the PREVIOUS day → NOT matched
        let thisNightEnd = dayStart + 7 * 3_600       // 07:00 this day → matched
        let nextNightEnd = dayStart + 86_400 + 3_600  // 01:00 NEXT day → NOT matched
        let sessions = [
            SleepSession(start: dayStart - 8 * 3_600, end: prevNightEnd, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
            SleepSession(start: dayStart - 1 * 3_600, end: thisNightEnd, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
            SleepSession(start: dayStart + 20 * 3_600, end: nextNightEnd, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        let matched = SkinTempBackfill.sessionsForDay(sessions, dayStart: dayStart)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.end, thisNightEnd)
    }

    /// A session ending exactly at midnight (dayStart) is matched (>= dayStart).
    func testSessionsForDay_inclusiveAtDayStart() {
        let dayStart = 1_789_632_000
        let sessions = [
            SleepSession(start: dayStart - 8 * 3_600, end: dayStart, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        XCTAssertEqual(SkinTempBackfill.sessionsForDay(sessions, dayStart: dayStart).count, 1)
    }

    /// A session ending exactly at next midnight (dayStart + 86400) is NOT matched (< dayEnd).
    func testSessionsForDay_exclusiveAtDayEnd() {
        let dayStart = 1_789_632_000
        let sessions = [
            SleepSession(start: dayStart + 12 * 3_600, end: dayStart + 86_400, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        XCTAssertEqual(SkinTempBackfill.sessionsForDay(sessions, dayStart: dayStart).count, 0)
    }

    /// Empty sessions → empty match (the night declines with "no sleep session ends on this day").
    func testSessionsForDay_emptySessionsReturnsEmpty() {
        XCTAssertEqual(SkinTempBackfill.sessionsForDay([], dayStart: 0).count, 0)
    }

    // MARK: Rule 3 — the WHOOP 4.0 anchor comes from the current window

    /// A WHOOP 4.0 with a per-device anchor from the current window uses it.
    func testResolveAnchor_whoop4WithAnchorReturnsIt() {
        let anchor = SkinTempBackfill.resolveAnchor(family: .whoop4, windowAnchorRaw: 1290.0)
        XCTAssertEqual(anchor, 1290.0)
    }

    /// A WHOOP 4.0 with NO per-device anchor returns nil → the night DECLINES. The global 826 is NOT
    /// a fallback here — a re-learned anchor puts backfilled nights on a different offset from the
    /// stored ones and the chart plots two scales as one line.
    func testResolveAnchor_whoop4WithoutAnchorDeclines() {
        let anchor = SkinTempBackfill.resolveAnchor(family: .whoop4, windowAnchorRaw: nil)
        XCTAssertNil(anchor, "rule 3: no anchor ⇒ decline, never the global default")
    }

    /// A WHOOP 5/MG always returns nil anchor (centidegree path, no anchor) — and does NOT decline on
    /// anchor grounds (the decline check in `computeNight` is `family == .whoop4 && anchor == nil`).
    func testResolveAnchor_whoop5ReturnsNilButDoesNotDecline() {
        let anchor = SkinTempBackfill.resolveAnchor(family: .whoop5, windowAnchorRaw: nil)
        XCTAssertNil(anchor)
        // The computeNight test below confirms a 5/MG night proceeds without an anchor.
    }

    // MARK: computeNight — the full per-night plan

    /// A 5/MG night with enough worn samples fills. The centidegree path needs no anchor.
    func testComputeNight_whoop5WithEnoughSamplesFills() {
        let dayStart = 1_789_632_000
        let candidate = SkinTempBackfill.NightCandidate(
            day: "2026-08-25", from: dayStart - 30 * 3_600, to: dayStart + 24 * 3_600, owner: "my-whoop")
        // A session ending in this day.
        let sessions = [
            SleepSession(start: dayStart - 1 * 3_600, end: dayStart + 7 * 3_600, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        // 400 worn skin-temp samples (3057 raw = 30.57 °C on 5/MG) at 1 Hz, with matching HR.
        let skinTemp = (0..<400).map { i in
            SkinTempSample(ts: dayStart - 1 * 3_600 + i, raw: 3057)
        }
        let hr = (0..<400).map { i in HRSample(ts: dayStart - 1 * 3_600 + i, bpm: 60) }
        let result = SkinTempBackfill.computeNight(
            candidate: candidate, sessions: sessions, hr: hr, skinTemp: skinTemp,
            family: .whoop5, windowAnchorRaw: nil, dayStart: dayStart)
        XCTAssertNotNil(result.skinTempC)
        XCTAssertEqual(result.skinTempC!, 30.57, accuracy: 0.01)
        XCTAssertNil(result.declineReason)
    }

    /// A WHOOP 4.0 night with no per-device anchor DECLINES (rule 3). Even with enough samples the
    /// night is not filled — the global 826 is NOT a fallback.
    func testComputeNight_whoop4WithoutAnchorDeclines() {
        let dayStart = 1_789_632_000
        let candidate = SkinTempBackfill.NightCandidate(
            day: "2026-08-25", from: dayStart - 30 * 3_600, to: dayStart + 24 * 3_600, owner: "my-whoop")
        let sessions = [
            SleepSession(start: dayStart - 1 * 3_600, end: dayStart + 7 * 3_600, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        // Enough samples to fill IF the anchor were allowed — but rule 3 declines before the funnel.
        let skinTemp = (0..<400).map { i in
            SkinTempSample(ts: dayStart - 1 * 3_600 + i, raw: 826)
        }
        let hr = (0..<400).map { i in HRSample(ts: dayStart - 1 * 3_600 + i, bpm: 60) }
        let result = SkinTempBackfill.computeNight(
            candidate: candidate, sessions: sessions, hr: hr, skinTemp: skinTemp,
            family: .whoop4, windowAnchorRaw: nil, dayStart: dayStart)
        XCTAssertNil(result.skinTempC, "rule 3: no anchor ⇒ decline, never the global default")
        XCTAssertNotNil(result.declineReason)
        XCTAssertTrue(result.declineReason!.contains("anchor"), "decline reason names the anchor")
    }

    /// A night with no sessions ending on the day declines.
    func testComputeNight_noSessionsDeclines() {
        let dayStart = 1_789_632_000
        let candidate = SkinTempBackfill.NightCandidate(
            day: "2026-08-25", from: dayStart - 30 * 3_600, to: dayStart + 24 * 3_600, owner: "my-whoop")
        let result = SkinTempBackfill.computeNight(
            candidate: candidate, sessions: [], hr: [], skinTemp: [],
            family: .whoop5, windowAnchorRaw: nil, dayStart: dayStart)
        XCTAssertNil(result.skinTempC)
        XCTAssertEqual(result.declineReason, "no sleep session ends on this day")
    }

    /// A night with too few worn samples (< minSkinTempSamples = 300) declines.
    func testComputeNight_tooFewSamplesDeclines() {
        let dayStart = 1_789_632_000
        let candidate = SkinTempBackfill.NightCandidate(
            day: "2026-08-25", from: dayStart - 30 * 3_600, to: dayStart + 24 * 3_600, owner: "my-whoop")
        let sessions = [
            SleepSession(start: dayStart - 1 * 3_600, end: dayStart + 7 * 3_600, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        // Only 100 samples — below the 300 floor.
        let skinTemp = (0..<100).map { i in
            SkinTempSample(ts: dayStart - 1 * 3_600 + i, raw: 3057)
        }
        let hr = (0..<100).map { i in HRSample(ts: dayStart - 1 * 3_600 + i, bpm: 60) }
        let result = SkinTempBackfill.computeNight(
            candidate: candidate, sessions: sessions, hr: hr, skinTemp: skinTemp,
            family: .whoop5, windowAnchorRaw: nil, dayStart: dayStart)
        XCTAssertNil(result.skinTempC)
        XCTAssertNotNil(result.declineReason)
        XCTAssertTrue(result.declineReason!.contains("worn samples"), "decline reason names the sample floor")
    }

    /// A night whose sessions END in the PREVIOUS day is not matched (rule 1), even if the session
    /// span overlaps this day's window. This is the exact bug rule 1 prevents: two nights averaged
    /// into one temperature.
    func testComputeNight_previousNightSessionNotMatched() {
        let dayStart = 1_789_632_000
        let candidate = SkinTempBackfill.NightCandidate(
            day: "2026-08-25", from: dayStart - 30 * 3_600, to: dayStart + 24 * 3_600, owner: "my-whoop")
        // A session that ends in the PREVIOUS day (23:00 on Aug 24) but whose span overlaps this day's
        // 54 h window. Without rule 1 this would be matched and the night would fill.
        let sessions = [
            SleepSession(start: dayStart - 9 * 3_600, end: dayStart - 1 * 3_600, efficiency: 0.9,
                         stages: [], restingHR: nil, avgHRV: nil, hrOnly: false),
        ]
        let skinTemp = (0..<400).map { i in
            SkinTempSample(ts: dayStart - 9 * 3_600 + i, raw: 3057)
        }
        let hr = (0..<400).map { i in HRSample(ts: dayStart - 9 * 3_600 + i, bpm: 60) }
        let result = SkinTempBackfill.computeNight(
            candidate: candidate, sessions: sessions, hr: hr, skinTemp: skinTemp,
            family: .whoop5, windowAnchorRaw: nil, dayStart: dayStart)
        XCTAssertNil(result.skinTempC, "rule 1: a session ending in the previous day is not this day's")
        XCTAssertEqual(result.declineReason, "no sleep session ends on this day")
    }

    // MARK: Rule 2 — page the candidates

    /// Page 0 returns the first `pageSize` candidates, oldest-first.
    func testPage_firstPageReturnsOldestN() {
        let candidates = (0..<120).map { i in
            SkinTempBackfill.NightCandidate(day: "2026-08-\(String(format: "%02d", i + 1))",
                                             from: 0, to: 0, owner: "my-whoop")
        }
        let page0 = SkinTempBackfill.page(candidates, page: 0, pageSize: 50)
        XCTAssertEqual(page0.count, 50)
        XCTAssertEqual(page0.first?.day, "2026-08-01")
        XCTAssertEqual(page0.last?.day, "2026-08-50")
    }

    /// Page 2 returns the next chunk; page 3 is empty (only 120 candidates, 50 per page → 3 pages).
    func testPage_thirdPageEmpty() {
        let candidates = (0..<120).map { i in
            SkinTempBackfill.NightCandidate(day: "2026-08-\(String(format: "%02d", i + 1))",
                                             from: 0, to: 0, owner: "my-whoop")
        }
        let page2 = SkinTempBackfill.page(candidates, page: 2, pageSize: 50)
        XCTAssertEqual(page2.count, 20)
        let page3 = SkinTempBackfill.page(candidates, page: 3, pageSize: 50)
        XCTAssertTrue(page3.isEmpty, "page 3 is empty — the walker stops here")
    }

    /// An empty candidate list returns an empty page on every page.
    func testPage_emptyCandidatesReturnsEmpty() {
        XCTAssertTrue(SkinTempBackfill.page([], page: 0).isEmpty)
    }

    /// A partial last page returns exactly the remainder.
    func testPage_partialLastPage() {
        let candidates = (0..<75).map { i in
            SkinTempBackfill.NightCandidate(day: "2026-08-\(String(format: "%02d", i + 1))",
                                             from: 0, to: 0, owner: "my-whoop")
        }
        let page1 = SkinTempBackfill.page(candidates, page: 1, pageSize: 50)
        XCTAssertEqual(page1.count, 25)
    }
}
