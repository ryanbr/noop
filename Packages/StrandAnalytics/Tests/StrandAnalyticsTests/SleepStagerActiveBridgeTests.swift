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

    // MARK: - End to end, through detectSleep
    //
    // The unit cases above pin the bridge. These pin the thing the reporter actually saw: a night with
    // one interruption arriving as ONE session instead of a truncated fragment.
    //
    // This twin is not optional. The Kotlin version of exactly this test is what found the bound wrong —
    // every unit case passed at 20 while the real pipeline still returned two sessions, because
    // classifyStill smears the still/moving boundary and buildRuns closes at sample edges, so a 15-minute
    // interruption becomes a 21-minute run. That smear is a property of THIS implementation, so without
    // the twin a divergence in Swift's windowing would leave the bound silently wrong on Apple only.

    /// 2025-06-10 00:00:00 UTC.
    private var refMidnight: Int { 1_749_513_600 }
    private func at(_ hour: Int, _ minute: Int = 0) -> Int { refMidnight + hour * 3_600 + minute * 60 }

    /// Still gravity at 1/min — constant orientation, so every delta is 0.
    private func stillG(_ from: Int, _ toExclusive: Int) -> [GravitySample] {
        stride(from: from, to: toExclusive, by: 60).map { GravitySample(ts: $0, x: 0, y: 0, z: 1.0) }
    }

    /// Moving gravity at 1/min — orientation swings every sample, so deltas are large.
    private func movingG(_ from: Int, _ toExclusive: Int) -> [GravitySample] {
        stride(from: from, to: toExclusive, by: 60).enumerated().map { i, t in
            i % 2 == 0 ? GravitySample(ts: t, x: 1.0, y: 0, z: 0)
                       : GravitySample(ts: t, x: 0, y: 1.0, z: 0)
        }
    }

    private func hr1Hz(_ from: Int, _ toExclusive: Int, _ bpm: Int) -> [HRSample] {
        (from ..< toExclusive).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// A night with a 30-minute gravity dropout early (so it reads sparse, as a 5/MG's does) and a
    /// 15-minute up-and-about in the middle.
    private func interruptedNight(tripBpm: Int) -> ([HRSample], [GravitySample]) {
        let grav = stillG(at(0), at(0, 30))
            + stillG(at(1), at(2))
            + movingG(at(2), at(2, 15))
            + stillG(at(2, 15), at(6))
        let hr = hr1Hz(at(0), at(2), 50)
            + hr1Hz(at(2), at(2, 15), tripBpm)
            + hr1Hz(at(2, 15), at(6), 50)
        return (hr, grav)
    }

    func testANightWithOneShortInterruptionIsDetectedAsASingleSession() {
        let (hr, grav) = interruptedNight(tripBpm: 52)
        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hr), "the fixture must read as sparse")
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1, "the interruption must not end the night")
        let spanMin = Double((sessions[0].end - sessions[0].start)) / 60.0
        XCTAssertGreaterThan(spanMin, 5 * 60, "the whole night should survive, got \(spanMin) min")
    }

    /// The same night with the wearer genuinely up — HR elevated for the whole quarter hour. Absorbing
    /// that would score wakefulness as sleep: wrong in a new direction and harder to notice than the
    /// truncation being fixed.
    func testTheSameNightWithAGenuinelyAwakeInterruptionIsNotBridgedIntoOne() {
        let (hr, grav) = interruptedNight(tripBpm: 110)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        let spanMin = sessions.reduce(0.0) { $0 + Double($1.end - $1.start) / 60.0 }
        XCTAssertTrue(sessions.count != 1 || spanMin < 5 * 60,
                      "an awake interruption must not be absorbed (\(sessions.count) sessions, \(spanMin) min)")
    }

    /// The RENDERED line, not just the fields — and deliberately the whole string, byte for byte.
    ///
    /// The Kotlin twin asserts this identical literal. Nothing in the tree compares the two languages'
    /// trace output automatically, so a format change on one side would otherwise diverge in silence and
    /// only surface when someone tried to read a capture from the other platform.
    func testThePairLineRendersExactlyAsItsKotlinTwinDoes() {
        let line = SleepStager.GateTrace.runLine(
            index: -1, startTs: 0, endTs: 0, verdict: SleepStager.GateVerdict.dropped, gate: "sparseBridgePair",
            detail: "pair=0 gapMin=23 activeMin=21 hrInSleepBand=true reason=activeTooLong")
        XCTAssertEqual(
            line,
            "gate run=-1 spanS=0 DROPPED gate=sparseBridgePair "
                + "pair=0 gapMin=23 activeMin=21 hrInSleepBand=true reason=activeTooLong")
    }
}
