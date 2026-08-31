import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// #1657 twin of `SleepStagerActiveBridgeTest`. The sparse-gravity bridge could only ever join sleep
/// runs already adjacent in its own output, so ANY active run between two sleep runs blocked the merge
/// permanently. A field trace found it merging nothing on 14 of 14 sparse nights for exactly that reason
/// — and since a bathroom trip is definitionally an active run, the rescue built for fragmentation was
/// unavailable in the case that needs it most. The pieces then died at the 60-minute session floor,
/// which is how a 6h40m night scored 150 minutes.
final class SleepStagerActiveBridgeTests: XCTestCase {

    private func sleep(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "sleep", start: start, end: end)
    }
    private func active(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "active", start: start, end: end)
    }
    /// Flat HR well under the band, so the HR gate is never the thing under test.
    private func calmHr(_ from: Int, _ to: Int, bpm: Int = 50) -> [HRSample] {
        stride(from: from, through: to, by: 60).map { HRSample(ts: $0, bpm: bpm) }
    }
    private let baseline = 60.0

    /// THE reported shape: asleep, a short trip, asleep again. Each piece is under the 60-minute session
    /// floor on its own; together they are a night.
    func testAShortActiveInterruptionBetweenTwoSleepRunsIsAbsorbed() {
        let out = SleepStager.bridgeSparseSleep(
            [sleep(0, 3000), active(3000, 3900), sleep(3900, 9000)],
            sparse: true, hr: calmHr(0, 9000), baseline: baseline)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.stage, "sleep")
        XCTAssertEqual(out.first?.start, 0)
        XCTAssertEqual(out.first?.end, 9000)
    }

    /// The guard that keeps this honest. A long active run is a real break in the night, not a stir, and
    /// absorbing it would score wakefulness as sleep — wrong in a new direction and harder to notice than
    /// the truncation being fixed.
    func testAnActiveRunLongerThanTheBoundIsLeftAlone() {
        let tooLong = SleepStager.sparseBridgeActiveMaxMin * 60 + 60
        let out = SleepStager.bridgeSparseSleep(
            [sleep(0, 3000), active(3000, 3000 + tooLong), sleep(3000 + tooLong, 9000)],
            sparse: true, hr: calmHr(0, 9000), baseline: baseline)
        XCTAssertEqual(out.count, 3)
    }

    /// HR is the real gate, not the duration bound. A wearer who is genuinely up keeps HR elevated for
    /// the whole interruption, and that must still block the merge even when it is short.
    func testAShortInterruptionWithElevatedHRIsNotAbsorbed() {
        let hot = calmHr(0, 3000) + calmHr(3001, 3900, bpm: 110) + calmHr(3901, 9000)
        let out = SleepStager.bridgeSparseSleep(
            [sleep(0, 3000), active(3000, 3900), sleep(3900, 9000)],
            sparse: true, hr: hot, baseline: baseline)
        XCTAssertEqual(out.count, 3)
    }

    /// Two consecutive active runs are a night with structure in it, not one interruption.
    func testTwoConsecutiveActiveRunsAreNotAbsorbed() {
        let out = SleepStager.bridgeSparseSleep(
            [sleep(0, 3000), active(3000, 3300), active(3300, 3900), sleep(3900, 9000)],
            sparse: true, hr: calmHr(0, 9000), baseline: baseline)
        XCTAssertEqual(out.count, 4)
    }

    /// A dense 4.0 night must be byte-identical: the bridge is sparse-only and always has been.
    /// `Period` is not Equatable in production, so the fields are compared rather than widening a
    /// production type for a test's convenience.
    func testADenseNightIsUntouched() {
        let periods = [sleep(0, 3000), active(3000, 3900), sleep(3900, 9000)]
        let out = SleepStager.bridgeSparseSleep(periods, sparse: false, hr: calmHr(0, 9000),
                                                baseline: baseline)
        XCTAssertEqual(out.map(\.stage), periods.map(\.stage))
        XCTAssertEqual(out.map(\.start), periods.map(\.start))
        XCTAssertEqual(out.map(\.end), periods.map(\.end))
    }

    /// The pre-existing behaviour — a bare gap between two sleep runs — still merges.
    func testTheOriginalAdjacentPairMergeStillWorks() {
        let out = SleepStager.bridgeSparseSleep(
            [sleep(0, 3000), sleep(3600, 9000)],
            sparse: true, hr: calmHr(0, 9000), baseline: baseline)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.end, 9000)
    }

    /// The trace has to say WHY, and the blocking length is the number a reader needs. The old trace could
    /// only report runsBefore == runsAfter, which says the bridge did nothing and not what stopped it.
    func testABlockedPairReportsTheBoundThatBlockedItWithTheActiveLength() {
        let tooLong = SleepStager.sparseBridgeActiveMaxMin * 60 + 60
        let (_, attempts) = SleepStager.bridgeSparseSleepTraced(
            [sleep(0, 3000), active(3000, 3000 + tooLong), sleep(3000 + tooLong, 9000)],
            sparse: true, hr: calmHr(0, 9000), baseline: baseline)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.reason, "activeTooLong")
        XCTAssertEqual(attempts.first?.bridged, false)
        XCTAssertEqual(attempts.first?.activeMin, SleepStager.sparseBridgeActiveMaxMin + 1)
    }

    /// The tracer and the merge are ONE pass now. This file used to keep a shadow copy of the loop purely
    /// to trace it, which had to be edited in step with the real one — a trace that quietly disagrees
    /// with the behaviour it describes is worse than no trace at all.
    func testTheTracedPassReturnsExactlyWhatThePlainOneDoes() {
        let periods = [sleep(0, 3000), active(3000, 3900), sleep(3900, 9000)]
        let hr = calmHr(0, 9000)
        let plain = SleepStager.bridgeSparseSleep(periods, sparse: true, hr: hr, baseline: baseline)
        let traced = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr,
                                                         baseline: baseline).0
        XCTAssertEqual(plain.map(\.stage), traced.map(\.stage))
        XCTAssertEqual(plain.map(\.start), traced.map(\.start))
        XCTAssertEqual(plain.map(\.end), traced.map(\.end))
    }

    /// #1657, the other half: `hrSleepBandAcross` judged on the MEAN, which a single arousal spike drags
    /// out of band — the exact statistic `confirmSleepWithHR` documents as wrong for this, and uses the
    /// median for instead. A sustained elevation must still be rejected.
    func testABriefSpikeNoLongerPutsTheWholeIntervalOutOfBandButASustainedOneDoes() {
        let spiky = calmHr(0, 3540) + calmHr(3541, 3660, bpm: 190)
        XCTAssertTrue(SleepStager.hrSleepBandAcross(0, 3660, hr: spiky, baseline: baseline))
        XCTAssertFalse(SleepStager.hrSleepBandAcross(0, 3660, hr: calmHr(0, 3660, bpm: 110),
                                                     baseline: baseline))
    }
}
