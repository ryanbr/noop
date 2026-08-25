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

    /// The funnel must ACCOUNT for everything, not merely count some things.
    ///
    /// Two arithmetic invariants hold by construction, because each gate is an exclusive `continue`:
    ///   A. every motion sample that cleared its gate is then either a sensor gap, a too-low heart rate,
    ///      or active — `motionOK == hrMissing + hrTooLow + active`;
    ///   B. every run that survived bridging has exactly one outcome —
    ///      `bridged == short + noHR + lowIntensity + kept`.
    ///
    /// This is the test that earns the funnel its trust. A future gate added to the detector without a
    /// matching counter would silently make some rejections vanish from the line — and a diagnostic that
    /// loses candidates without saying so is exactly the thing this whole feature exists to stop being.
    func testEveryRejectedCandidateIsAccountedFor() throws {
        let cases: [(String, [HRSample], [GravitySample])] = [
            ("still", hrs(3600, 150), still(3600)),
            ("unexerted", hrs(3600, 62), moving(3600)),
            ("hr gap", hrs(60, 150), moving(3600)),
            ("short", hrs(600, 60) + hrs(120, 150, from: 600) + hrs(2880, 60, from: 720), moving(3600)),
            ("real", hrs(600, 60) + hrs(2400, 150, from: 600) + hrs(600, 60, from: 3000), moving(3600)),
        ]
        for (name, hr, grav) in cases {
            let f = try funnelOf(hr, grav)
            XCTAssertEqual(f.motionPassed, f.hrMissing + f.hrTooLow + f.active,
                           "\(name): motionOK must equal hrMissing + hrTooLow + active (\(f))")
            XCTAssertEqual(f.bridged, f.droppedShort + f.droppedNoHR + f.droppedLowIntensity + f.kept,
                           "\(name): bridged runs must equal short + noHR + lowIntensity + kept (\(f))")
        }
    }

    /// The exact bytes. Compared between two users' logs and across platforms, so the shape is contract.
    func testTheLineIsExactlyThis() {
        var f = WorkoutDetector.DetectionFunnel()
        f.hrSamples = 34137; f.motionSamples = 34136
        f.restingHR = 59; f.hrFloor = 74
        f.motionPassed = 1203; f.hrMissing = 12; f.hrTooLow = 1103; f.active = 88
        f.runs = 6; f.bridged = 4
        f.longestRunS = 212; f.meanRunS = 74
        f.droppedShort = 4; f.droppedNoHR = 0; f.droppedLowIntensity = 0; f.kept = 0
        XCTAssertEqual(
            WorkoutDetector.detectionFunnelLine(day: "2026-08-24", funnel: f),
            "effort detect day=2026-08-24 hr=34137 motion=34136 restHR=59 floor=74 "
                + "motionOK=1203 hrMissing=12 hrTooLow=1103 active=88 runs=6 bridged=4 "
                + "longestRunS=212 meanRunS=74 "
                + "short=4 noHR=0 lowIntensity=0 kept=0")
    }

    /// The field case these two fields exist for, with the gate ORDER that makes them necessary.
    ///
    /// `droppedShort` is tested first and short-circuits, so a non-zero `droppedLowIntensity` already
    /// proves some run cleared the duration bar. What it cannot say is by how much — and that is the
    /// whole difference between a five-minute stroll and an hour-long effort wrongly rejected.
    ///
    /// Both fixtures carry the SAME counts, taken from a real 22-day log (79 bridged, 64 short, 15
    /// low-intensity, kept=0). Only `longestRunS` tells them apart.
    func testTheLongestRunSizesWhatSurvivedTheDurationGate() {
        // The bar a run must clear is minDurS MINUS the smoothing window, not a round five minutes —
        // pinned here so the 290 s quoted in the field's doc cannot go stale if either constant is tuned.
        let effectiveBarS = Int(WorkoutDetector.minExerciseMin * 60 - WorkoutDetector.motionSmoothS)
        XCTAssertEqual(effectiveBarS, 290)
        let minDurS = Int(WorkoutDetector.minExerciseMin * 60)

        // A walk: the longest survivor barely clears five minutes, so kept=0 is an honest zero.
        var walk = WorkoutDetector.DetectionFunnel()
        walk.bridged = 79; walk.longestRunS = 312; walk.meanRunS = 41
        walk.droppedShort = 64; walk.droppedLowIntensity = 15; walk.kept = 0
        XCTAssertTrue(WorkoutDetector.detectionFunnelLine(day: "2026-08-24", funnel: walk)
            .contains("longestRunS=312"))
        XCTAssertLessThan(walk.longestRunS, 2 * minDurS, "barely over the bar — a walk")

        // Identical counts, hour-long survivor: that is the reading worth chasing.
        var suspicious = WorkoutDetector.DetectionFunnel()
        suspicious.bridged = 79; suspicious.longestRunS = 3600; suspicious.meanRunS = 41
        suspicious.droppedShort = 64; suspicious.droppedLowIntensity = 15; suspicious.kept = 0
        XCTAssertEqual(walk.droppedShort, suspicious.droppedShort,
                       "the counts alone cannot distinguish the two")
        XCTAssertEqual(walk.droppedLowIntensity, suspicious.droppedLowIntensity)
        XCTAssertGreaterThan(suspicious.longestRunS, 6 * minDurS,
                             "an hour-long run rejected on intensity is what this field exists to surface")
    }
}
