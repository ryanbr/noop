import XCTest
@testable import StrandAnalytics

/// Recalibration must discard earlier history before it can affect the production baseline state.
final class BaselineEpochTests: XCTestCase {
    private let epoch: Double = 1_784_419_200 // 2026-07-19 00:00:00 UTC
    private let days = ["2026-07-16", "2026-07-17", "2026-07-18",
                        "2026-07-19", "2026-07-20", "2026-07-21"]
    private let values: [Double?] = [40, 41, 42, 43, 44, 45]
    private let cfg = Baselines.metricCfg["hrv"]!

    func testNonPositiveEpochPreservesTheEntireFoldState() {
        let expected = Baselines.foldHistory(values, cfg: cfg)
        for anchor in [0.0, -1.0] {
            XCTAssertEqual(Baselines.foldHistory(values, dayKeys: days, cfg: cfg,
                                                 baselineEpoch: anchor), expected)
        }
    }

    func testMidnightEpochKeepsTheEpochDayAndReseedsFromItsValue() {
        let actual = Baselines.foldHistory(values, dayKeys: days, cfg: cfg, baselineEpoch: epoch)
        XCTAssertEqual(actual, Baselines.foldHistory(Array(values.suffix(3)), cfg: cfg))
        XCTAssertEqual(actual.nValid, 3)
    }

    func testEpochAfterMidnightDropsThatDaysNightToo() {
        let actual = Baselines.foldHistory(values, dayKeys: days, cfg: cfg, baselineEpoch: epoch + 1)
        XCTAssertEqual(actual, Baselines.foldHistory(Array(values.suffix(2)), cfg: cfg))
        XCTAssertEqual(actual.nValid, 2, "night membership uses UTC day start, not its date label alone")
    }

    func testDroppedMissingAndOutlyingValuesCannotAgeOrAnchorTheNewBaseline() {
        let kept: [Double?] = [43, 44, 45]
        let history: [Double?] = [nil, 250, 1] + kept
        let actual = Baselines.foldHistory(history, dayKeys: days, cfg: cfg, baselineEpoch: epoch)
        XCTAssertEqual(actual, Baselines.foldHistory(kept, cfg: cfg),
                       "discarded nights must never reach update, including skip-and-hold bookkeeping")
    }

    func testEpochAfterAllHistoryReturnsAnEmptyCalibratingBaseline() {
        let actual = Baselines.foldHistory(values, dayKeys: days, cfg: cfg,
                                           baselineEpoch: epoch + 3 * 86400)
        XCTAssertEqual(actual, Baselines.foldHistory([], cfg: cfg))
        XCTAssertEqual(actual.nValid, 0)
        XCTAssertFalse(actual.usable)
    }

    func testThreeSurvivingNightsStayUnusableUntilTheFourthNightArrives() {
        // #731: fifteen good nights, with recalibration retaining only July 20–22.
        let allDays = (8...22).map { String(format: "2026-07-%02d", $0) }
        let history: [Double?] = Array(repeating: 45, count: allDays.count)
        let anchor = epoch + 86400
        let three = Baselines.foldHistory(history, dayKeys: allDays, cfg: cfg, baselineEpoch: anchor)
        XCTAssertEqual(three, Baselines.foldHistory(Array(history.suffix(3)), cfg: cfg))
        XCTAssertEqual(three.nValid, 3)
        XCTAssertFalse(three.usable, "three is below minNightsSeed")
        let four = Baselines.foldHistory(history + [45], dayKeys: allDays + ["2026-07-23"],
                                          cfg: cfg, baselineEpoch: anchor)
        XCTAssertEqual(four.nValid, 4)
        XCTAssertTrue(four.usable)
    }
}
