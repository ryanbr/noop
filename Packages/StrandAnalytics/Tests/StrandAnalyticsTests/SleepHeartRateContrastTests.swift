import Foundation
import XCTest
@testable import StrandAnalytics

final class SleepHeartRateContrastTests: XCTestCase {
    private func filled(_ value: Double, _ count: Int) -> [Double?] { Array(repeating: value, count: count) }

    func testLowerSleepHRProducesPositiveReduction() {
        let result = SleepHeartRateContrast.evaluate(wakeHR: filled(70, 40), primarySleepHR: filled(56, 40))
        let r = try! XCTUnwrap(result)
        XCTAssertEqual(r.wakeMeanBpm, 70, accuracy: 1e-12)
        XCTAssertEqual(r.sleepMeanBpm, 56, accuracy: 1e-12)
        XCTAssertEqual(r.sleepMinusWakeBpm, -14, accuracy: 1e-12)
        XCTAssertEqual(r.sleepReductionPercent, 20, accuracy: 1e-12)   // 100*(70-56)/70
        XCTAssertEqual(r.wakeCoverage, 1, accuracy: 1e-12)
        XCTAssertEqual(r.sleepCoverage, 1, accuracy: 1e-12)
    }

    func testHigherSleepHRProducesNegativeReductionWithoutClassification() {
        let result = SleepHeartRateContrast.evaluate(wakeHR: filled(60, 40), primarySleepHR: filled(66, 40))
        let r = try! XCTUnwrap(result)
        XCTAssertEqual(r.sleepMinusWakeBpm, 6, accuracy: 1e-12)
        XCTAssertEqual(r.sleepReductionPercent, -10, accuracy: 1e-12)  // 100*(60-66)/60
    }

    func testMinimumValidSampleGateAppliesIndependentlyToBothWindows() {
        // Wake has 30 valid, sleep only 29 -> nil (gate per-window).
        let wake = filled(65, 30)
        var sleep = filled(55, 29); sleep.append(nil)
        XCTAssertNil(SleepHeartRateContrast.evaluate(wakeHR: wake, primarySleepHR: sleep))
        // Both at 30 -> passes.
        XCTAssertNotNil(SleepHeartRateContrast.evaluate(wakeHR: filled(65, 30), primarySleepHR: filled(55, 30)))
    }

    func testMissingAndInvalidEpochsAreExcludedAndReduceCoverage() {
        // 40 slots: 30 valid @60, 5 nil, 5 out-of-range (10 bpm) -> 30 valid, coverage 0.75.
        let nils: [Double?] = Array(repeating: nil, count: 5)
        let lows: [Double?] = Array(repeating: 10.0, count: 5)
        let wake: [Double?] = filled(60, 30) + nils + lows
        let sleep = filled(50, 40)
        let r = try! XCTUnwrap(SleepHeartRateContrast.evaluate(wakeHR: wake, primarySleepHR: sleep))
        XCTAssertEqual(r.wakeValidSamples, 30)
        XCTAssertEqual(r.wakeTotalSamples, 40)
        XCTAssertEqual(r.wakeCoverage, 0.75, accuracy: 1e-12)
        XCTAssertEqual(r.wakeMeanBpm, 60, accuracy: 1e-12)   // out-of-range 10s never entered the mean
    }

    func testUnequalWindowLengthsAreAllowedAndCoverageIsPerWindow() {
        let r = try! XCTUnwrap(SleepHeartRateContrast.evaluate(wakeHR: filled(70, 60),
                                                               primarySleepHR: filled(58, 30)))
        XCTAssertEqual(r.wakeTotalSamples, 60)
        XCTAssertEqual(r.sleepTotalSamples, 30)
        XCTAssertEqual(r.wakeCoverage, 1, accuracy: 1e-12)
        XCTAssertEqual(r.sleepCoverage, 1, accuracy: 1e-12)
    }

    func testValidityRangeEdgesAreIncluded() {
        // 30 and 220 are inclusive; 29.9 and 220.1 are excluded.
        let lows: [Double?] = Array(repeating: 30.0, count: 15)
        let highs: [Double?] = Array(repeating: 220.0, count: 15)
        let edges: [Double?] = [29.9, 220.1]
        let wake: [Double?] = lows + highs + edges
        let r = try! XCTUnwrap(SleepHeartRateContrast.evaluate(wakeHR: wake, primarySleepHR: filled(60, 30)))
        XCTAssertEqual(r.wakeValidSamples, 30)                 // the two out-of-range edges excluded
        XCTAssertEqual(r.wakeMeanBpm, 125, accuracy: 1e-12)    // (30*15 + 220*15)/30
    }

    func testEmptyAndInvalidConfigurationFailClosed() {
        XCTAssertNil(SleepHeartRateContrast.evaluate(wakeHR: [], primarySleepHR: filled(60, 30)))
        XCTAssertNil(SleepHeartRateContrast.evaluate(wakeHR: filled(60, 30), primarySleepHR: []))
        XCTAssertNil(SleepHeartRateContrast.evaluate(wakeHR: filled(60, 30), primarySleepHR: filled(60, 30),
                                                     minimumValidSamples: 0))
        XCTAssertNil(SleepHeartRateContrast.evaluate(wakeHR: filled(.nan, 40), primarySleepHR: filled(60, 40)))
    }
}
