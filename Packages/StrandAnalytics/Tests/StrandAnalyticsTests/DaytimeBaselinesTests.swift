import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Coverage for the CALLER-side daytime-baseline fold (DaytimeBaselines.swift) that feeds
/// `DaytimeStress.analyze(mode: .baselineRelative(hr:rmssd:))`: the per-day aggregate definition, the
/// trailing-history fold, the graceful-degradation `scoringMode` gate, and the fold→score round trip.
final class DaytimeBaselinesTests: XCTestCase {

    // MARK: - Fixtures (multi-day: day `d` is offset by d·86 400 s; local hour-of-day is preserved)

    /// One local day of HR: every hour in `hours` filled with `n` 1 Hz samples at a per-hour bpm.
    /// `bpms` maps to `hours` in order. tz offset 0, so local hour-of-day == wall-clock hour.
    private func dayHR(_ dayIndex: Int, hours: [Int], bpms: [Int],
                       n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        let dayBase = dayIndex * 86_400
        var out: [HRSample] = []
        for (h, bpm) in zip(hours, bpms) {
            let base = dayBase + h * 3_600
            out += (0..<n).map { HRSample(ts: base + $0, bpm: bpm) }
        }
        return out
    }

    /// One local day flat at a single bpm across waking hours 8…17 (ten scored hours).
    private func flatDayHR(_ dayIndex: Int, bpm: Int) -> [HRSample] {
        dayHR(dayIndex, hours: Array(8...17), bpms: Array(repeating: bpm, count: 10))
    }

    /// R-R for one local hour with a controllable beat-to-beat jitter (drives RMSSD).
    private func hourRR(_ dayIndex: Int, hour: Int, rrMs: Int, jitter: Int, n: Int = 120) -> [RRInterval] {
        let base = dayIndex * 86_400 + hour * 3_600
        return (0..<n).map { RRInterval(ts: base + $0 * 30, rrMs: rrMs + ($0 % 2 == 0 ? jitter : -jitter)) }
    }

    private func flatDayRR(_ dayIndex: Int, rrMs: Int, jitter: Int) -> [RRInterval] {
        (8...17).flatMap { hourRR(dayIndex, hour: $0, rrMs: rrMs, jitter: jitter) }
    }

    // MARK: - Per-day aggregate

    func testDayHRAggregateIsTheTenthPercentileOfWakingHourMeanHRs() {
        // Ten waking hours (08…17) with a spread of constant per-hour HRs; each hour's MEAN HR is just
        // its bpm. P10 of [60,62,64,66,68,70,72,74,76,78] via the shared linear-interp quantile is
        // 60 + 0.9·(62−60) = 61.8 — the calm floor, well below the day's median.
        let bpms = [60, 62, 64, 66, 68, 70, 72, 74, 76, 78]
        let hr = dayHR(0, hours: Array(8...17), bpms: bpms)
        let agg = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0)
        XCTAssertNotNil(agg.hr)
        XCTAssertEqual(agg.hr!, 61.8, accuracy: 1e-6)
        XCTAssertNil(agg.rmssd, "no R-R → no daytime RMSSD aggregate")
    }

    func testDayHRAggregateAppliesTheSameMinSamplesGateAsTheScorer() {
        // An under-gate sparse hour at a very low bpm must NOT drag the P10 floor down — the scorer would
        // never score it, so the aggregate must not reference it either.
        let dense = dayHR(0, hours: Array(8...17), bpms: [60, 62, 64, 66, 68, 70, 72, 74, 76, 78])
        let sparse = dayHR(0, hours: [7], bpms: [40], n: DaytimeStress.minHourHRSamples - 1)
        let withSparse = DaytimeStress.dayDaytimeAggregate(hr: dense + sparse, rr: [], tzOffsetSeconds: 0)
        let denseOnly = DaytimeStress.dayDaytimeAggregate(hr: dense, rr: [], tzOffsetSeconds: 0)
        XCTAssertEqual(withSparse.hr!, denseOnly.hr!, accuracy: 1e-9,
            "a below-gate hour leaked into the daytime-HR floor")
    }

    func testDayHRAggregateExcludesNonWakingHours() {
        // A very low 03:00 hour (outside 06:00–22:00) must not become the calm floor.
        let waking = dayHR(0, hours: Array(8...17), bpms: [60, 62, 64, 66, 68, 70, 72, 74, 76, 78])
        let night = dayHR(0, hours: [3], bpms: [45])
        let withNight = DaytimeStress.dayDaytimeAggregate(hr: waking + night, rr: [], tzOffsetSeconds: 0)
        XCTAssertEqual(withNight.hr!, 61.8, accuracy: 1e-6,
            "a non-waking hour leaked into the daytime-HR floor")
    }

    func testDayRMSSDAggregateIsPresentWithRRAndTracksVariability() {
        // A relaxed day (high jitter → high RMSSD) vs a suppressed day (low jitter → low RMSSD): both
        // produce a non-nil median RMSSD aggregate, and the relaxed day's is clearly higher.
        let hr = flatDayHR(0, bpm: 65)
        let relaxed = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: flatDayRR(0, rrMs: 900, jitter: 45),
                                                        tzOffsetSeconds: 0)
        let suppressed = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: flatDayRR(0, rrMs: 900, jitter: 5),
                                                           tzOffsetSeconds: 0)
        XCTAssertNotNil(relaxed.rmssd)
        XCTAssertNotNil(suppressed.rmssd)
        XCTAssertGreaterThan(relaxed.rmssd!, suppressed.rmssd!,
            "the higher-variability day should carry a higher median daytime RMSSD")
    }

    // MARK: - Fold trailing history

    func testFoldConvergesHRBaselineToThePersonalDaytimeFloor() {
        // Twelve identical days whose P10 daytime HR is exactly 65 → the EWMA center converges to 65 and
        // the baseline is usable (12 ≥ minNightsSeed). No R-R anywhere → RMSSD baseline is nil.
        let days = (0..<12).map { DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65), rr: [],
                                                                  tzOffsetSeconds: 0) }
        let b = DaytimeStress.foldDaytimeBaselines(days: days)
        XCTAssertEqual(b.hr.baseline, 65.0, accuracy: 1e-6)
        XCTAssertTrue(b.hr.usable)
        XCTAssertNil(b.rmssd, "no daytime R-R history → HR-only baseline")
    }

    func testFoldReturnsRMSSDBaselineOnlyWhenEnoughDaytimeRRDays() {
        // Two days of R-R is below minNightsSeed → RMSSD baseline withheld (nil → HR-only). Eight days
        // clears the seed → a usable RMSSD baseline is returned.
        let twoDays = (0..<2).map {
            DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65),
                                            rr: flatDayRR($0, rrMs: 900, jitter: 40), tzOffsetSeconds: 0)
        }
        XCTAssertNil(DaytimeStress.foldDaytimeBaselines(days: twoDays).rmssd,
            "an untrustworthy 2-day RMSSD baseline must be withheld")

        let eightDays = (0..<8).map {
            DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65),
                                            rr: flatDayRR($0, rrMs: 900, jitter: 40), tzOffsetSeconds: 0)
        }
        let rmssd = DaytimeStress.foldDaytimeBaselines(days: eightDays).rmssd
        XCTAssertNotNil(rmssd, "eight days of daytime R-R should yield a usable RMSSD baseline")
        XCTAssertTrue(rmssd!.usable)
    }

    // MARK: - scoringMode graceful degradation

    func testScoringModeFallsBackToDayRelativeOnColdStartAndSparseHistory() {
        // No history → day-relative (cold start unchanged).
        guard case .dayRelative = DaytimeStress.scoringMode(history: []) else {
            return XCTFail("empty history must fall back to .dayRelative")
        }
        // Three days is below minNightsSeed → still day-relative.
        let threeDays = (0..<3).map { DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65), rr: [],
                                                                      tzOffsetSeconds: 0) }
        guard case .dayRelative = DaytimeStress.scoringMode(history: threeDays) else {
            return XCTFail("sub-seed history must fall back to .dayRelative")
        }
    }

    func testScoringModeUsesBaselineRelativeOnceHistoryIsUsable() {
        // Six days of real daytime HR clears the seed → the Oura-style baseline-relative mode, carrying
        // the folded HR baseline (~65) and a nil RMSSD baseline (no R-R history here).
        let days = (0..<6).map { DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65), rr: [],
                                                                 tzOffsetSeconds: 0) }
        guard case let .baselineRelative(hr, rmssd) = DaytimeStress.scoringMode(history: days) else {
            return XCTFail("usable history must select .baselineRelative")
        }
        XCTAssertEqual(hr.baseline, 65.0, accuracy: 1e-6)
        XCTAssertNil(rmssd)
    }

    // MARK: - Fold → score round trip (the whole point)

    func testFoldedBaselineScoresElevationAgainstThePersonalFloorNotTheDaysOwnHours() {
        // Personal floor folded from history = 65 bpm. TODAY is elevated ALL day (every waking hour 80 =
        // 65 + the validated 15 bpm margin). A DAY-relative read would anchor on the day's OWN hours and
        // miss an all-day-high day; the baseline-relative read scores it against the personal 65 floor,
        // so every hour lands at/above the HIGH band and the day logs high-stress minutes.
        let history = (0..<20).map { DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65), rr: [],
                                                                     tzOffsetSeconds: 0) }
        let mode = DaytimeStress.scoringMode(history: history)
        guard case .baselineRelative = mode else { return XCTFail("expected baseline-relative") }

        let today = flatDayHR(0, bpm: 80)
        let r = DaytimeStress.analyze(hr: today, rr: [], tzOffsetSeconds: 0, mode: mode)
        XCTAssertFalse(r.scored.isEmpty)
        XCTAssertTrue(r.hrOnlyFallback, "no RMSSD baseline → HR-only, honestly flagged")
        XCTAssertGreaterThan(r.highStressMinutes, 0, "an all-day-elevated day must log high-stress time")
        for p in r.scored {
            XCTAssertGreaterThanOrEqual(p.level!, DaytimeStress.highBandFloor - 0.05,
                "80 bpm is the personal floor + the validated 15 bpm margin → the HIGH band")
        }
    }

    func testFoldedBaselineCalmDayAtThePersonalFloorReadsNeutralNotHigh() {
        // TODAY sits exactly at the personal 65 floor all day → each hour reads ~1.5 (neutral), never
        // high. Guards the calm end of the scale end-to-end through the fold.
        let history = (0..<20).map { DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65), rr: [],
                                                                     tzOffsetSeconds: 0) }
        let mode = DaytimeStress.scoringMode(history: history)
        let r = DaytimeStress.analyze(hr: flatDayHR(0, bpm: 65), rr: [], tzOffsetSeconds: 0, mode: mode)
        XCTAssertEqual(r.highStressMinutes, 0)
        for p in r.scored { XCTAssertEqual(p.level!, 1.5, accuracy: 0.05) }
    }

    func testMedianRMSSDBaselineKeepsANormalHourNeutralNoStacking() {
        // The anti-stacking guarantee behind anchoring the RMSSD aggregate at the MEDIAN (not a calm
        // ceiling): with BOTH a HR baseline (65) and an RMSSD baseline folded from history, a TODAY that
        // sits at the HR floor AND at its typical daytime HRV must stay out of the HIGH band. A ceiling
        // anchor would make this ordinary hour read ~1–2σ "below baseline" and stack a false stress term.
        let history = (0..<20).map {
            DaytimeStress.DaytimeDayStreams(hr: flatDayHR($0, bpm: 65),
                                            rr: flatDayRR($0, rrMs: 900, jitter: 40), tzOffsetSeconds: 0)
        }
        let mode = DaytimeStress.scoringMode(history: history)
        guard case let .baselineRelative(_, rmssd) = mode else {
            return XCTFail("expected baseline-relative with an RMSSD baseline")
        }
        XCTAssertNotNil(rmssd, "20 days of daytime R-R should yield a usable RMSSD baseline")

        // Today: HR at the floor, HRV at the SAME typical variability as history.
        let today = flatDayHR(0, bpm: 65)
        let todayRR = flatDayRR(0, rrMs: 900, jitter: 40)
        let r = DaytimeStress.analyze(hr: today, rr: todayRR, tzOffsetSeconds: 0, mode: mode)
        XCTAssertFalse(r.hrOnlyFallback, "an RMSSD baseline was supplied")
        XCTAssertEqual(r.highStressMinutes, 0, "a typical HR+HRV day must not read as high stress")
        for p in r.scored {
            XCTAssertLessThan(p.level!, DaytimeStress.highBandFloor,
                "a normal hour with an RMSSD baseline must not stack into the HIGH band")
        }
    }
}
