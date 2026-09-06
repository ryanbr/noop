import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HeartRateRecoveryTests: XCTestCase {
    private let end = 10_000

    private func denseEligible(endHR: Int = 170) -> [HRSample] {
        // Five minutes of continuous Zone-3+ effort, ending at the requested cessation HR.
        (end - 300...end).map { HRSample(ts: $0, bpm: $0 >= end - 30 ? endHR : 145) }
    }

    private func window(minutes: Int, values: [Int]) -> [HRSample] {
        let target = end + minutes * 60
        return values.enumerated().map { i, bpm in HRSample(ts: target - values.count / 2 + i, bpm: bpm) }
    }

    private func result(for eligibilitySamples: [HRSample]) -> HeartRateRecovery.Result? {
        HeartRateRecovery.calculate(
            samples: eligibilitySamples + window(minutes: 1, values: [140, 140, 140]),
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        )
    }

    func testCalculatesOneTwoAndFiveMinuteDropsFromRobustReadings() {
        let samples = denseEligible()
            + window(minutes: 1, values: [146, 146, 220, 146, 146]) // optical spike cannot own the reading
            + window(minutes: 2, values: [132, 132, 132])
            + window(minutes: 5, values: [112, 112, 112])

        let result = HeartRateRecovery.calculate(samples: samples.shuffled(), workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200)
        XCTAssertEqual(result, .init(endHR: 170, after1Minute: 24, after2Minutes: 38, after5Minutes: 58))
    }

    func testRequiresSustainedHighIntensityRatherThanOnePeak() {
        var samples = (end - 300...end).map { HRSample(ts: $0, bpm: 120) }
        samples.append(HRSample(ts: end, bpm: 190))
        samples += window(minutes: 1, values: [140, 140, 140])
        XCTAssertNil(HeartRateRecovery.calculate(samples: samples, workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200))
    }

    func testRejectsDisconnectedHighIntensityFragments() {
        // Plenty of nominally-high points, but each is separated by more than the continuity cap.
        let sparse = stride(from: end - 300, through: end, by: 15).map { HRSample(ts: $0, bpm: 170) }
        let samples = sparse + window(minutes: 1, values: [140, 140, 140])
        XCTAssertNil(HeartRateRecovery.calculate(samples: samples, workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200))
    }

    func testRejectsThreeSeparatedFortySecondHighIntensityRuns() {
        let samples = [
            HRSample(ts: end - 140, bpm: 170), HRSample(ts: end - 130, bpm: 170),
            HRSample(ts: end - 120, bpm: 170), HRSample(ts: end - 110, bpm: 170),
            HRSample(ts: end - 100, bpm: 120),
            HRSample(ts: end - 90, bpm: 170), HRSample(ts: end - 80, bpm: 170),
            HRSample(ts: end - 70, bpm: 170), HRSample(ts: end - 60, bpm: 170),
            HRSample(ts: end - 50, bpm: 120),
            HRSample(ts: end - 40, bpm: 170), HRSample(ts: end - 30, bpm: 170),
            HRSample(ts: end - 20, bpm: 170), HRSample(ts: end - 10, bpm: 170),
            HRSample(ts: end, bpm: 120),
        ]

        XCTAssertNil(result(for: samples))
    }

    func testGapExactlyAtCapUsesLeftSampleAndExactMinimumIsAccepted() {
        let samples = stride(from: end - 120, through: end - 10, by: 10)
            .map { HRSample(ts: $0, bpm: 170) }
            + [HRSample(ts: end, bpm: 120)]

        XCTAssertEqual(result(for: samples), .init(endHR: 170, after1Minute: 30,
                                                  after2Minutes: nil, after5Minutes: nil))
    }

    func testGapOverCapResetsTheQualifyingRun() {
        let beforeGap = stride(from: end - 180, through: end - 110, by: 10)
            .map { HRSample(ts: $0, bpm: 170) }
        let afterGap = stride(from: end - 99, through: end - 9, by: 10)
            .map { HRSample(ts: $0, bpm: 170) }
            + [HRSample(ts: end, bpm: 170)]

        XCTAssertNil(result(for: beforeGap + afterGap))
    }

    func testBelowThresholdIntervalResetsTheQualifyingRun() {
        let samples = stride(from: end - 130, through: end, by: 10).map { ts in
            HRSample(ts: ts, bpm: ts == end - 60 ? 120 : 170)
        }

        XCTAssertNil(result(for: samples))
    }

    func testDuplicateTimestampDoesNotBreakAnOtherwiseContinuousRun() {
        let samples = stride(from: end - 120, through: end, by: 10)
            .map { HRSample(ts: $0, bpm: 170) }
            + [HRSample(ts: end - 60, bpm: 120)]

        XCTAssertEqual(result(for: samples), .init(endHR: 170, after1Minute: 30,
                                                  after2Minutes: nil, after5Minutes: nil))
    }

    func testDoesNotCreditPreWorkoutHeartRateTowardEligibility() {
        let samples = denseEligible() + window(minutes: 1, values: [140, 140, 140])
        // Only the final minute belongs to this workout. The preceding high HR must not make it eligible.
        XCTAssertNil(HeartRateRecovery.calculate(samples: samples, workoutStart: end - 60,
                                                 workoutEnd: end, maxHR: 200))
    }

    func testReturnsOnlyMeasurementsWithRealCoverage() {
        let samples = denseEligible()
            + window(minutes: 1, values: [150, 150, 150])
            + window(minutes: 5, values: [110, 110]) // fewer than the coverage gate
        let result = HeartRateRecovery.calculate(samples: samples, workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200)
        XCTAssertEqual(result, .init(endHR: 170, after1Minute: 20, after2Minutes: nil, after5Minutes: nil))
    }

    func testNoPostWorkoutCoverageReturnsNil() {
        XCTAssertNil(HeartRateRecovery.calculate(samples: denseEligible(), workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200))
    }

    func testAHeartRateRiseRemainsSignedInsteadOfBeingClamped() {
        let samples = denseEligible(endHR: 160) + window(minutes: 1, values: [165, 165, 165])
        let result = HeartRateRecovery.calculate(samples: samples, workoutStart: end - 300,
                                                 workoutEnd: end, maxHR: 200)
        XCTAssertEqual(result?.after1Minute, -5)
    }
}
