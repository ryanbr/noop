import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepAwareStepCounterTests: XCTestCase {
    private func sample(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }
    private func sleep(stages: [StageSegment] = []) -> SleepSession {
        SleepSession(start: 0, end: 100, efficiency: 1, stages: stages, restingHR: nil, avgHRV: nil)
    }

    func testIsolatedBedMotionIsRejected() {
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow([
            sample(0, 0), sample(1, 1), sample(20, 2)
        ], sleepSessions: [sleep()]))
    }

    func testCoherentNightWalkCounts() {
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow([
            sample(0, 0), sample(1, 2), sample(2, 4), sample(3, 6), sample(4, 8), sample(5, 10)
        ], sleepSessions: [sleep()]), 10)
    }

    func testExplicitWakeGapCountsImmediately() {
        let wake = StageSegment(start: 10, end: 20, stage: "wake")
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow([
            sample(9, 0), sample(10, 2)
        ], sleepSessions: [sleep(stages: [wake])]), 2)
    }

    func testDiagnosticRejectionReasonsAreSeparated() {
        let count = SleepAwareStepCounter.count([
            sample(0, 100, 0), sample(1, 102, 1), sample(2, 110, 1),
            sample(4, 117, 2), sample(5, 120, 0)
        ], sleepSessions: [])
        XCTAssertEqual(count.totalTicks, 9)
        XCTAssertEqual(count.rejectedActivityClassTicks, 3)
        XCTAssertEqual(count.rejectedImplausibleTicks, 8)
    }
}
