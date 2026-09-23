import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// A manual workout records one heart-rate sample a second. The live heart rate reaches it once per R-R packet and
/// again whenever the rate moves, and Effort credits a repeated second as another second of effort.
final class WorkoutSampleOncePerSecondTests: XCTestCase {

    func testASecondThatAlreadyHasASampleTakesNoOther() {
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(workout.recordSample(HRSample(ts: 1_000, bpm: 120)))
        XCTAssertFalse(workout.recordSample(HRSample(ts: 1_000, bpm: 121)))
        XCTAssertTrue(workout.recordSample(HRSample(ts: 1_001, bpm: 122)))
        XCTAssertEqual(workout.samples.map(\.ts), [1_000, 1_001])
        XCTAssertEqual(workout.samples.map(\.bpm), [120, 122])
    }

    /// The rate moving is often why a second arrives twice, so the refused reading can be that second's high: it is
    /// not recorded, but it is the workout's peak, live and saved.
    func testARepeatedSecondStillReachesThePeak() {
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(workout.savedPeak)
        _ = workout.recordSample(HRSample(ts: 1_000, bpm: 120))
        workout.peakHr = 120   // what captureWorkoutSample does after an accepted sample
        XCTAssertFalse(workout.recordSample(HRSample(ts: 1_000, bpm: 131)))
        XCTAssertEqual(workout.samples.map(\.bpm), [120])
        XCTAssertEqual(workout.peakHr, 131)
        XCTAssertEqual(workout.savedPeak, 131)
        XCTAssertFalse(workout.recordSample(HRSample(ts: 1_000, bpm: 125)))   // a lower repeat moves nothing
        XCTAssertEqual(workout.peakHr, 131)
    }

    /// Twenty minutes climbing from 100 to 160 bpm, each second arriving twice (the R-R packet, then the rate
    /// moving) as it does during exercise. Recorded through `recordSample`, the workout's Effort is the Effort of
    /// the plain once-a-second stream; the repeats, kept, scored higher.
    func testRepeatedSecondsNoLongerAddEffort() {
        let seconds = 20 * 60
        let clean = (0..<seconds).map { HRSample(ts: 5_000 + $0, bpm: 100 + $0 * 60 / seconds) }
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 5_000))
        var everyArrival: [HRSample] = []
        for sample in clean {
            for _ in 0..<2 {
                _ = workout.recordSample(sample)
                everyArrival.append(sample)
            }
        }
        func effort(_ samples: [HRSample]) -> Double {
            StrainScorer.strain(samples, maxHR: 190, restingHR: 60) ?? 0
        }
        XCTAssertEqual(workout.samples.map(\.ts), clean.map(\.ts))
        XCTAssertEqual(effort(workout.samples), effort(clean))
        XCTAssertGreaterThan(effort(everyArrival), effort(clean))
    }
}
