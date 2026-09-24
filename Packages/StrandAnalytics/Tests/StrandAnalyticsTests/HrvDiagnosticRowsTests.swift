import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// #2425: the `hrv diag` line must describe the night the #1118 gate judged. It used to pool every session
/// of the day over first-to-last beat, gaps included, and on a refused night printed a verdict that was not
/// an over-count. Asserted as an AGREEMENT with the gate's own helper, not against a fixed label.
/// Byte-parity twin of Kotlin `HrvDiagnosticRowsTest`: same fixtures, same expected values.
final class HrvDiagnosticRowsTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"
    private var dayStart: Int { AnalyticsEngine.dayStartUtcSeconds(day) }
    private var nightStart: Int { dayStart - 4 * 3600 }
    private var nightEnd: Int { nightStart + 600 * 60 }
    private var napStart: Int { dayStart + 13 * 3600 }
    private var napEnd: Int { napStart + 40 * 60 }

    private func verdict(_ rows: [RRInterval]) -> HRVAnalyzer.RrCoverageVerdict {
        let ts = rows.map(\.ts), ms = rows.map { Double($0.rrMs) }
        return HRVAnalyzer.classifyCoverage(coverage: HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms),
                                            collapsed: HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: ms))
    }

    /// Night: two beats every second (refused). Nap: one per second (clean).
    private func dayResult() -> (AnalyticsEngine.DayResult, [RRInterval]) {
        let night = (nightStart..<nightEnd).flatMap { [RRInterval(ts: $0, rrMs: 880), RRInterval(ts: $0, rrMs: 960)] }
        let nap = (napStart..<napEnd).map { RRInterval(ts: $0, rrMs: ($0 - napStart) % 2 == 0 ? 970 : 1_030) }
        let hr = stride(from: nightStart, to: napEnd, by: 30).map { HRSample(ts: $0, bpm: 55) }
        let sessions = [
            SleepSession(start: nightStart, end: nightEnd, efficiency: 0.9,
                         stages: [StageSegment(start: nightStart, end: nightEnd, stage: "light")],
                         restingHR: nil, avgHRV: nil),
            SleepSession(start: napStart, end: napEnd, efficiency: 0.9,
                         stages: [StageSegment(start: napStart, end: napEnd, stage: "light")],
                         restingHR: nil, avgHRV: nil),
        ]
        let rr = night + nap
        return (AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, profile: profile, providedSleep: sessions), rr)
    }

    func testTheDayResultCarriesTheMainNightGroupScoringUsed() {
        let (res, _) = dayResult()
        XCTAssertEqual(res.mainNightBlocks.map(\.start), [nightStart])
        XCTAssertEqual(res.mainNightBlocks.map(\.end), [nightEnd])
    }

    func testTheDiagnosticVerdictAgreesWithTheGateOnARefusedNight() {
        let (res, rr) = dayResult()
        let fallback = res.cachedSleep.map { SleepStageTotals.NightBlock(start: $0.startTs, end: $0.endTs) }
        let rows = AnalyticsEngine.hrvDiagnosticRows(rr, mainNight: res.mainNightBlocks, fallback: fallback)
        XCTAssertEqual(rows.count, 2 * 600 * 60, "the night's beats only, the nap is not pooled in")
        XCTAssertTrue(SleepStager.sessionHrvOverCounted(start: nightStart, end: nightEnd, rr: rr),
                      "precondition: the gate refuses this night")
        XCTAssertFalse(HRVAnalyzer.successiveDiffIsTrustworthy(verdict(rows)),
                       "the line must call it an over-count, as the gate did")
        // The old selection, every session pooled over the 7-hour gap: 1.08, `plausible`. Pinned so the
        // test shows what it replaced, and fails if the fixture stops reproducing the disagreement.
        let pooled = AnalyticsEngine.hrvDiagnosticRows(rr, mainNight: [], fallback: fallback)
        XCTAssertEqual(verdict(pooled), .plausible)
    }

    func testADayWithNoMainNightKeepsThePooledHalfOpenSet() {
        let rr = [RRInterval(ts: 100, rrMs: 1_000), RRInterval(ts: 150, rrMs: 1_000), RRInterval(ts: 200, rrMs: 1_000)]
        let rows = AnalyticsEngine.hrvDiagnosticRows(
            rr, mainNight: [], fallback: [SleepStageTotals.NightBlock(start: 100, end: 200)])
        XCTAssertEqual(rows.map(\.ts), [100, 150], "fallback keeps the old half-open [start, end) window")
        let main = AnalyticsEngine.hrvDiagnosticRows(
            rr, mainNight: [SleepStageTotals.NightBlock(start: 100, end: 200)], fallback: [])
        XCTAssertEqual(main.map(\.ts), [100, 150, 200], "main night uses the gate's inclusive [start, end]")
    }
}
