import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Swift twin of `SleepFragmentedNightTest`.
///
/// #1937: a night whose sleep runs are ALL under `minSleepMin` produced no session at all, however much
/// sleep they added up to. The capture that found it: `sleepRuns=5 droppedMinSleep=5 kept=0
/// detectedSpanMin=298 survivingSpanMin=0 sparse=false` — five hours of detected sleep, five runs
/// averaging 59.6 minutes, every one a minute short, and the night vanished. The rescue that exists for
/// exactly this was gated on the night being SPARSE, and the night was dense.
final class SleepFragmentedNightTests: XCTestCase {

    private let minSleepS = 60 * 60

    private func mins(_ m: Int...) -> [Int] { m.map { $0 * 60 } }

    /// The reported shape: 298 minutes of detected sleep across five runs, none of them clearing the
    /// floor. Note this night CANNOT be written in whole minutes: five runs each at most 59 min sum to
    /// 295. Runs are second-granular, and 298/5 = 59.6 min, so each one falls 24 seconds short.
    func testTheReportedFiveFragmentNightQualifies() {
        let runs = [Int](repeating: 3576, count: 5)            // 59.6 min each
        XCTAssertEqual(runs.reduce(0, +) / 60, 298)            // the reported detectedSpanMin
        XCTAssertTrue(runs.allSatisfy { $0 < minSleepS })      // and every one is dropped by the floor
        XCTAssertTrue(SleepStager.isFragmentedToNothing(runs, minSleepS: minSleepS))
    }

    /// THE safety property. A night where any single run already clears the floor keeps at least one
    /// session today, so the predicate must decline and leave the sparse rule to decide exactly as
    /// before. Without this the change could alter a night that currently scores.
    func testANightWithOneQualifyingRunIsNeverTouched() {
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(90, 20, 15), minSleepS: minSleepS))
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(60, 20, 15), minSleepS: minSleepS))
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(20, 15, 90), minSleepS: minSleepS))
    }

    /// A handful of brief stirs is not a night. The SUM has to clear the floor too.
    func testBriefStirsDoNotBecomeANight() {
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(5, 8, 12), minSleepS: minSleepS))
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(30, 29), minSleepS: minSleepS))
        XCTAssertTrue(SleepStager.isFragmentedToNothing(mins(30, 30), minSleepS: minSleepS))
    }

    /// One fragment is not a fragmented night; there is nothing to bridge it to.
    func testASingleShortRunIsNotAFragmentedNight() {
        XCTAssertFalse(SleepStager.isFragmentedToNothing(mins(59), minSleepS: minSleepS))
        XCTAssertFalse(SleepStager.isFragmentedToNothing([], minSleepS: minSleepS))
    }

    /// The predicate only ever opens the bridge; the bridge's own rules still decide. Stated here
    /// because the predicate's name suggests more authority than it has.
    func testThePredicateEnablesAnAttemptRatherThanGrantingIt() {
        XCTAssertTrue(SleepStager.isFragmentedToNothing(mins(40, 40), minSleepS: minSleepS))
        let far = SleepStager.bridgeSparseSleepTraced(
            [SleepStager.Period(stage: "sleep", start: 0, end: 40 * 60),
             SleepStager.Period(stage: "sleep", start: 40 * 60 + 10 * 3600,
                                end: 40 * 60 + 10 * 3600 + 40 * 60)],
            sparse: true, hr: [], baseline: nil)
        XCTAssertEqual(far.0.filter { $0.stage == "sleep" }.count, 2,
                       "a gap of hours must not be bridged")
    }

    // MARK: - end-to-end: the reported night through detectSleep

    private let refMidnight = 1_749_513_600            // 2025-06-10 00:00:00 UTC
    private func at(_ min: Int) -> Int { refMidnight + min * 60 }

    /// Still gravity at 1/min: continuous, so the night reads DENSE, which is the point of #1937.
    private func stillG(_ fromMin: Int, _ toMin: Int) -> [GravitySample] {
        stride(from: at(fromMin), to: at(toMin), by: 60).map { GravitySample(ts: $0, x: 0, y: 0, z: 1.0) }
    }

    /// Moving gravity at 1/min: orientation swings every sample, so this reads as an active run.
    private func movingG(_ fromMin: Int, _ toMin: Int) -> [GravitySample] {
        stride(from: at(fromMin), to: at(toMin), by: 60).enumerated().map { i, t in
            i % 2 == 0 ? GravitySample(ts: t, x: 1.0, y: 0, z: 0)
                       : GravitySample(ts: t, x: 0, y: 1.0, z: 0)
        }
    }

    private func hr1Hz(_ fromMin: Int, _ toMin: Int, _ bpm: Int) -> [HRSample] {
        (at(fromMin) ..< at(toMin)).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// The reported night end to end: five sleep runs of 59 minutes, each separated by a 20-minute
    /// stir, gravity continuous throughout so the night is DENSE. Every run is under the 60-minute
    /// floor, so before this change the night scored nothing at all.
    ///
    /// Five runs means the bridge has to chain FOUR consecutive absorptions, which is the part the pure
    /// predicate tests cannot reach.
    ///
    /// The stir length is load-bearing at BOTH ends and a first attempt at 3 minutes made this test pass
    /// for the wrong reason. `mergePeriods` absorbs any run under `mergeMin` (15) and rejoins the
    /// same-stage neighbours, so short stirs never fragmented the night: it arrived as ONE 306-minute
    /// run that always scored, and the rescue under test never ran. The stir must therefore be at least
    /// mergeMin to survive the merge, and at most sparseBridgeActiveMaxInBandMin (60, since HR stays in
    /// the sleep band) for the bridge to absorb it.
    private func fragmentedDenseNight() -> ([HRSample], [GravitySample]) {
        var g: [GravitySample] = []
        var t = 0
        for i in 0 ..< 5 {
            g += stillG(t, t + 59)
            t += 59
            if i < 4 { g += movingG(t, t + 20); t += 20 }
        }
        return (hr1Hz(0, t, 50), g)
    }

    func testTheFragmentedDenseNightIsRescuedEndToEnd() {
        let (hr, grav) = fragmentedDenseNight()
        XCTAssertFalse(SleepStager.isGravitySparse(grav, hr: hr),
                       "the fixture must be DENSE, or the old sparse gate would already rescue it")

        var lines: [String] = []
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav, traceSink: { lines.append($0) })

        XCTAssertFalse(sessions.isEmpty,
                       "a night of five 59-minute runs must now produce a session, got none.\n"
                        + lines.joined(separator: "\n"))
        let spanMin = sessions.reduce(0) { $0 + ($1.end - $1.start) / 60 }
        XCTAssertGreaterThanOrEqual(spanMin, 240, "expected most of the 295 sleeping minutes, got \(spanMin)")
        // Anti-vacuity: the session must exist BECAUSE the rescue fired. Without this the test passes
        // when the fixture is not actually fragmented, which is exactly what a 3-minute stir did.
        XCTAssertTrue(lines.contains { $0.contains("gate=sparseBridge ") && $0.contains("fragmentedToNothing=true") },
                      "the session must come from the #1937 rescue, not an unfragmented fixture.\n"
                        + lines.joined(separator: "\n"))
    }

    /// The trace must name BOTH gates, so a dense rescue cannot contradict the summary line beside it.
    ///
    /// The contiguous substring pins key ORDER and spacing, not just presence. Nothing in the tree
    /// compares the two languages' trace output automatically, so a format change on one side would
    /// otherwise diverge in silence; the Kotlin twin asserts this identical fragment.
    func testTheTraceNamesBothGates() {
        let (hr, grav) = fragmentedDenseNight()
        var lines: [String] = []
        _ = SleepStager.detectSleep(hr: hr, gravity: grav, traceSink: { lines.append($0) })
        let bridge = lines.first { $0.contains("gate=sparseBridge ") }
        XCTAssertNotNil(bridge, "expected a sparseBridge line, got:\n" + lines.joined(separator: "\n"))
        XCTAssertTrue(bridge!.contains("sparse=false fragmentedToNothing=true gapMin="),
                      "unexpected sparseBridge detail format: \(bridge!)")
    }
}
