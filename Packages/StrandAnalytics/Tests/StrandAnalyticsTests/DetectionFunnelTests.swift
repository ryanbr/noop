import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// #1545: why a day produced no workout, counted at each gate the detector actually applies.
///
/// The `effort bout` line explains a bout that EXISTS, so it is silent on the harder report — a strap log
/// with 37 days and zero detected workouts, where every gate looks equally plausible from outside. These
/// tests pin that the funnel separates the causes rather than just confirming the zero.
///
/// Byte-parity twin of Kotlin `DetectionFunnelTest`.
final class DetectionFunnelTests: XCTestCase {

    private func hrs(_ n: Int, _ bpm: Int, from: Int = 0) -> [HRSample] {
        (from ..< from + n).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// Motion that genuinely varies — a constant vector has zero intensity and detects nothing.
    private func moving(_ n: Int) -> [GravitySample] {
        (0 ..< n).map { GravitySample(ts: $0, x: $0 % 2 == 0 ? 0.9 : 0.5, y: 0.1, z: 0.1) }
    }

    /// Motion that is present but perfectly still — samples exist, intensity never clears the gate.
    private func still(_ n: Int) -> [GravitySample] {
        (0 ..< n).map { GravitySample(ts: $0, x: 0.9, y: 0.1, z: 0.1) }
    }

    private func funnelOf(_ hr: [HRSample], _ grav: [GravitySample],
                          restingHR: Double? = 60, maxHR: Double? = 190) throws
        -> WorkoutDetector.DetectionFunnel {
        var f: WorkoutDetector.DetectionFunnel?
        _ = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: restingHR, maxHR: maxHR,
                                   age: 30, funnel: { f = $0 })
        return try XCTUnwrap(f, "the funnel must be reported on every exit")
    }

    /// The reporter's case: a day that yields nothing, and the funnel says WHICH gate ate it.
    ///
    /// Here the body is still — motion rows exist in quantity, none clear the intensity threshold. That is
    /// the WHOOP 4.0 coarse-motion suspicion (#345/#28) and it must be distinguishable from a quiet heart.
    func testAStillDayNamesMotionAsTheGateThatAteIt() throws {
        let f = try funnelOf(hrs(3600, 150), still(3600))
        XCTAssertEqual(f.kept, 0)
        XCTAssertGreaterThan(f.motionSamples, 0, "motion rows were present: \(f)")
        XCTAssertEqual(f.motionPassed, 0, "no sample cleared the motion gate")
        XCTAssertEqual(f.active, 0)
        // HR was never even consulted, so the HR counters must stay clean rather than implicating it.
        XCTAssertEqual(f.hrMissing, 0)
        XCTAssertEqual(f.hrTooLow, 0)
    }

    /// The opposite cause, which a bout count of zero reports identically: plenty of motion, but the heart
    /// never cleared resting + 15. Blaming the sensor here would send someone chasing the wrong fault.
    func testAMovingButUnexertedDayNamesHRAsTheGateThatAteIt() throws {
        let f = try funnelOf(hrs(3600, 62), moving(3600))       // floor = 60 + 15 = 75
        XCTAssertEqual(f.kept, 0)
        XCTAssertGreaterThan(f.motionPassed, 0, "motion cleared its gate: \(f)")
        XCTAssertGreaterThan(f.hrTooLow, 0, "HR is what rejected them: \(f)")
        XCTAssertEqual(f.hrMissing, 0, "not a sensor gap")
        XCTAssertEqual(f.active, 0)
    }

    /// A sensor dropout is a third cause again: motion is there, HR simply is not.
    func testAMissingHrStreamIsNotConfusedWithALowHeartRate() throws {
        let f = try funnelOf(hrs(60, 150), moving(3600))        // HR only for the first minute
        XCTAssertGreaterThan(f.hrMissing, 0, "HR gaps must be counted as gaps: \(f)")
        XCTAssertEqual(f.hrTooLow, 0, "nothing was rejected for being too low")
    }

    /// Real work, but under the five-minute bar — the funnel must say "short", not blame a sensor.
    func testAShortEffortIsNamedAsShort() throws {
        // Two minutes of qualifying work inside an otherwise resting hour.
        let hr = hrs(600, 60) + hrs(120, 150, from: 600) + hrs(2880, 60, from: 720)
        let f = try funnelOf(hr, moving(3600))
        XCTAssertEqual(f.kept, 0)
        XCTAssertGreaterThan(f.runs, 0, "a run was formed: \(f)")
        XCTAssertGreaterThan(f.droppedShort, 0, "and rejected for duration: \(f)")
    }

    /// The happy path still reports, and reports a survivor — the funnel is not a failure-only line.
    func testARealWorkoutIsCountedAsKept() throws {
        let hr = hrs(600, 60) + hrs(2400, 150, from: 600) + hrs(600, 60, from: 3000)
        let f = try funnelOf(hr, moving(3600))
        XCTAssertGreaterThan(f.kept, 0, "expected a detected bout: \(f)")
        XCTAssertGreaterThan(f.active, 0)
        XCTAssertEqual(f.hrSamples, 3600)
    }

    /// The thresholds the day was judged against are reported, not left for the reader to guess.
    func testItReportsTheBarTheDayHadToClear() throws {
        let f = try funnelOf(hrs(3600, 62), moving(3600))
        XCTAssertEqual(f.restingHR ?? -1, 60.0, accuracy: 1e-9)
        XCTAssertEqual(f.hrFloor ?? -1, 75.0, accuracy: 1e-9)   // resting + hrMarginBPM (15)
    }

    /// An empty day still reports — the early return must not skip the funnel.
    func testADayWithNoDataStillReports() throws {
        let f = try funnelOf([], [])
        XCTAssertEqual(f.hrSamples, 0)
        XCTAssertEqual(f.motionSamples, 0)
        XCTAssertEqual(f.kept, 0)
    }

    /// The exact bytes. Compared between two users' logs and across platforms, so the shape is contract.
    func testTheLineIsExactlyThis() {
        var f = WorkoutDetector.DetectionFunnel()
        f.hrSamples = 34137; f.motionSamples = 34136
        f.restingHR = 59; f.hrFloor = 74
        f.motionPassed = 1203; f.hrMissing = 12; f.hrTooLow = 1103; f.active = 88
        f.runs = 6; f.bridged = 4
        f.droppedShort = 4; f.droppedNoHR = 0; f.droppedLowIntensity = 0; f.kept = 0
        XCTAssertEqual(
            WorkoutDetector.detectionFunnelLine(day: "2026-08-24", funnel: f),
            "effort detect day=2026-08-24 hr=34137 motion=34136 restHR=59 floor=74 "
                + "motionOK=1203 hrMissing=12 hrTooLow=1103 active=88 runs=6 bridged=4 "
                + "short=4 noHR=0 lowIntensity=0 kept=0")
    }
}
