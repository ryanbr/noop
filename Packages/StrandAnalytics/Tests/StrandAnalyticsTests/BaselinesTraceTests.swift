import XCTest
@testable import StrandAnalytics

/// The per-night baseline-fold trace. Twin of the Kotlin `BaselinesTraceTest` — the SAME fixtures and
/// the SAME expected strings, because a diagnostic whose two platforms word things differently cannot
/// be compared across a pair of reports.
///
/// The contract that matters most is the first test: the traced state must BE the real fold's, so the
/// trace can never describe a baseline the scorer isn't using.
final class BaselinesTraceTests: XCTestCase {

    private let hrv = Baselines.metricCfg["hrv"]!

    /// The whole point: tracing must not change, or re-derive, the state.
    func testTracedStateIsTheRealFoldsState() {
        var traced: BaselineState? = nil
        var real: BaselineState? = nil
        let nights: [Double?] = [60.0, 70.0, nil, 999.0, 55.0, 62.0, 58.0, 61.0, 150.0, 59.0]
        for v in nights {
            traced = Baselines.updateTrace(traced, value: v, cfg: hrv, metric: "hrv").state
            real = Baselines.update(real, value: v, cfg: hrv)
            XCTAssertEqual(real!.baseline, traced!.baseline, "baseline diverged")
            XCTAssertEqual(real!.spread, traced!.spread, "spread diverged")
            XCTAssertEqual(real!.nValid, traced!.nValid, "nValid diverged")
            XCTAssertEqual(real!.status, traced!.status, "status diverged")
        }
    }

    func testSeedNamesThatOneNightFixesTheCentre() {
        XCTAssertEqual(
            Baselines.updateTrace(nil, value: 60.0, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=seed value=60.0 spread starts at floor=5.0 "
            + "(this ONE night fixes the centre) -> mean=60.0 spread=5.0 nValid=1 status=calibrating")
    }

    /// A first night with no usable value seeds the MIDPOINT and leaves nValid at 0 — not a skip.
    func testSeedEmptyIsDistinctFromASkip() {
        XCTAssertEqual(
            Baselines.updateTrace(nil, value: nil, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=seed-empty no usable first value (bounds=5.0..250.0) "
            + "seeded at midpoint, nValid stays 0 -> mean=127.5 spread=5.0 nValid=0 status=calibrating")
    }

    func testMissingNightIsSkipAndHold() {
        let s = Baselines.updateTrace(nil, value: 60.0, cfg: hrv, metric: "hrv").state
        XCTAssertEqual(
            Baselines.updateTrace(s, value: nil, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=missing skip-and-hold nightsSinceUpdate=1 "
            + "-> mean=60.0 spread=5.0 nValid=1 status=calibrating")
    }

    func testImplausibleNightNamesTheBounds() {
        let s = Baselines.updateTrace(nil, value: 60.0, cfg: hrv, metric: "hrv").state
        XCTAssertEqual(
            Baselines.updateTrace(s, value: 999.0, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=implausible value=999.0 bounds=5.0..250.0 skip-and-hold "
            + "nightsSinceUpdate=1 -> mean=60.0 spread=5.0 nValid=1 status=calibrating")
    }

    /// While young the fold uses the fast half-life and the inflated Winsor band; the line says so.
    func testFoldedYoungReportsTheEarlyAdaptation() {
        let s = Baselines.updateTrace(nil, value: 60.0, cfg: hrv, metric: "hrv").state
        XCTAssertEqual(
            Baselines.updateTrace(s, value: 70.0, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=folded value=70.0 young=yes effSpread=12.5 halfLifeB=3.0 "
            + "winsor=22.5..97.5 clamped=no spread 5.0->5.1 atFloor=no "
            + "-> mean=62.06 spread=5.1 nValid=2 status=calibrating")
    }

    /// A hard outlier is "seen, NOT folded" — the case that otherwise leaves no trace at all.
    func testRejectedNightIsNamedWithItsThreshold() {
        let settled = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 10), cfg: hrv, metric: "hrv").state
        XCTAssertEqual(
            Baselines.updateTrace(settled, value: 150.0, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=rejected value=150.0 dev=90.0 > k=5.0*spread=5.0 (seen, NOT folded) "
            + "-> mean=60.0 spread=5.0 nValid=10 status=provisional")
    }

    func testFoldedSettledUsesTheNormalHalfLifeAndBand() {
        let settled = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 10), cfg: hrv, metric: "hrv").state
        XCTAssertEqual(
            Baselines.updateTrace(settled, value: 66.0, cfg: hrv, metric: "hrv").lines[0],
            "baseline hrv night=folded value=66.0 young=no effSpread=5.0 halfLifeB=14.0 "
            + "winsor=45.0..75.0 clamped=no spread 5.0->5.02 atFloor=no "
            + "-> mean=60.29 spread=5.02 nValid=11 status=provisional")
    }

    /// The reason this file exists: a flat history leaves the spread ON its floor for as long as you
    /// care to fold, and `atFloor=yes` is the only way a log ever says so. Every other diagnostic shows
    /// a settled-looking spread=5.0 with nothing to distinguish it from a converged one.
    func testAFlatHistoryReportsSpreadPinnedOnTheFloor() {
        let out = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 12), cfg: hrv, metric: "hrv")
        XCTAssertEqual(out.state.spread, 5.0)
        let folded = out.lines.filter { $0.contains("night=folded") }
        XCTAssertFalse(folded.isEmpty, "expected folded nights")
        XCTAssertTrue(folded.allSatisfy { $0.contains("atFloor=yes") },
                      "a flat history must report atFloor=yes")
    }

    /// One line per night, in order, so a history reads as a trajectory.
    func testFoldHistoryTraceEmitsOneLinePerNight() {
        let out = Baselines.foldHistoryTrace([60.0, nil, 62.0, 999.0, 58.0], cfg: hrv, metric: "hrv")
        XCTAssertEqual(out.lines.count, 5)
        XCTAssertTrue(out.lines[0].contains("night=seed"))
        XCTAssertTrue(out.lines[1].contains("night=missing"))
        XCTAssertTrue(out.lines[2].contains("night=folded"))
        XCTAssertTrue(out.lines[3].contains("night=implausible"))
    }

    func testEmptyHistoryIsSafe() {
        let out = Baselines.foldHistoryTrace([], cfg: hrv, metric: "hrv")
        XCTAssertEqual(out.lines, ["baseline hrv history=empty"])
        XCTAssertEqual(out.state.nValid, 0)
    }

    /// Project convention: no em-dashes leak into a log line.
    func testNoEmDashesInAnyLine() {
        let out = Baselines.foldHistoryTrace([60.0, nil, 999.0, 70.0, 150.0], cfg: hrv, metric: "hrv")
        XCTAssertFalse(out.lines.isEmpty)
        XCTAssertFalse(out.lines.contains { $0.contains("\u{2014}") })
    }

    /// The tail cap bounds the log without changing the state: the whole history is still folded.
    func testTailCapsTheLinesButNotTheFold() {
        let hist: [Double?] = (0..<30).map { 60.0 + Double($0) }
        let full = Baselines.foldHistoryTrace(hist, cfg: hrv, metric: "hrv")
        let capped = Baselines.foldHistoryTrace(hist, cfg: hrv, metric: "hrv", tail: 5)
        XCTAssertEqual(full.state.baseline, capped.state.baseline, "state must not depend on the cap")
        XCTAssertEqual(full.state.nValid, capped.state.nValid)
        XCTAssertEqual(capped.lines.count, 6)   // 1 omission notice + 5 nights
        XCTAssertEqual(capped.lines[0], "baseline hrv (earlier 25 night(s) omitted)")
        XCTAssertEqual(Array(full.lines.suffix(5)), Array(capped.lines.dropFirst()))
    }

    /// A tail bigger than the history leaves it untouched, with no misleading omission notice.
    func testTailLargerThanHistoryAddsNoNotice() {
        let out = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 3), cfg: hrv, metric: "hrv", tail: 14)
        XCTAssertEqual(out.lines.count, 3)
        XCTAssertFalse(out.lines.contains { $0.contains("omitted") })
    }

    /// The recalibration drop, named. This is #731's failure mode: the tap discards earlier nights and
    /// restarts the count, and no log ever said so.
    func testRecalibrationDropIsNamedAndMatchesTheRealFold() {
        let days = ["2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05"]
        let values: [Double?] = [60.0, 61.0, 62.0, 63.0, 64.0]
        // Epoch at 2026-08-04 UTC start-of-day: the first three nights are dropped.
        let epoch = utcEpoch(year: 2026, month: 8, day: 4)
        let out = Baselines.foldHistoryTrace(values, dayKeys: days, cfg: hrv, metric: "hrv", baselineEpoch: epoch)
        XCTAssertEqual(out.lines[0], "baseline hrv recalibrated=2026-08-04 dropped=3 night(s) before it")
        // and the state is the REAL recalibration-aware fold's, not a re-derivation
        let real = Baselines.foldHistory(values, dayKeys: days, cfg: hrv, baselineEpoch: epoch)
        XCTAssertEqual(real.baseline, out.state.baseline)
        XCTAssertEqual(real.spread, out.state.spread)
        XCTAssertEqual(real.nValid, out.state.nValid)
    }

    /// No epoch set: identical to the plain fold, with no recalibration line invented.
    func testNoRecalibrationEpochBehavesLikeThePlainFold() {
        let days = ["2026-08-01", "2026-08-02", "2026-08-03"]
        let values: [Double?] = [60.0, 61.0, 62.0]
        let out = Baselines.foldHistoryTrace(values, dayKeys: days, cfg: hrv, metric: "hrv", baselineEpoch: 0)
        let plain = Baselines.foldHistoryTrace(values, cfg: hrv, metric: "hrv")
        XCTAssertEqual(plain.lines, out.lines)
        XCTAssertEqual(plain.state.baseline, out.state.baseline)
    }

    /// dayKeys SHORTER than values: the real fold only tests the epoch for indices it has a key for, and
    /// keeps the rest. The trace filters on the same condition, so the states must agree — this is the
    /// case where a filter-then-fold shortcut could silently diverge from a fold-with-skips.
    func testShortDayKeysKeepTheUndatedNightsExactlyLikeTheRealFold() {
        let values: [Double?] = [60.0, 61.0, 62.0, 63.0, 64.0]
        let days = ["2026-08-01", "2026-08-02"]   // only two keys for five nights
        let epoch = utcEpoch(year: 2026, month: 8, day: 2)
        let out = Baselines.foldHistoryTrace(values, dayKeys: days, cfg: hrv, metric: "hrv", baselineEpoch: epoch)
        let real = Baselines.foldHistory(values, dayKeys: days, cfg: hrv, baselineEpoch: epoch)
        XCTAssertEqual(real.baseline, out.state.baseline)
        XCTAssertEqual(real.spread, out.state.spread)
        XCTAssertEqual(real.nValid, out.state.nValid)
        XCTAssertTrue(out.lines[0].contains("dropped=1"))   // only 2026-08-01 precedes the epoch
    }

    /// tail = 0 keeps the notice and nothing else, rather than emitting an empty list.
    func testTailOfZeroKeepsOnlyTheOmissionNotice() {
        let out = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 4), cfg: hrv, metric: "hrv", tail: 0)
        XCTAssertEqual(out.lines, ["baseline hrv (earlier 4 night(s) omitted)"])
        XCTAssertEqual(out.state.nValid, 4)
    }

    /// A negative tail is ignored rather than trimming anything.
    func testNegativeTailIsIgnored() {
        let out = Baselines.foldHistoryTrace(Array(repeating: 60.0, count: 4), cfg: hrv, metric: "hrv", tail: -1)
        XCTAssertEqual(out.lines.count, 4)
        XCTAssertFalse(out.lines.contains { $0.contains("omitted") })
    }

    /// The recalibration line must SURVIVE the tail cap: it is prepended after trimming, not trimmed.
    func testRecalibrationLineSurvivesATightTail() {
        let values: [Double?] = (0..<20).map { 60.0 + Double($0) }
        let days = (0..<20).map { String(format: "2026-08-%02d", $0 + 1) }
        let epoch = utcEpoch(year: 2026, month: 8, day: 5)
        let out = Baselines.foldHistoryTrace(values, dayKeys: days, cfg: hrv, metric: "hrv",
                                             baselineEpoch: epoch, tail: 3)
        XCTAssertTrue(out.lines[0].contains("recalibrated="), "recalibration line must not be trimmed")
        XCTAssertTrue(out.lines[1].contains("omitted"))
        XCTAssertEqual(out.lines.count, 5)   // recalibration + notice + 3 nights
    }

    /// UTC start-of-day epoch, so the fixtures read the same on any machine.
    private func utcEpoch(year: Int, month: Int, day: Int) -> Double {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: comps)!.timeIntervalSince1970
    }
}
