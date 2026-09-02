import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The HR-only Stage-0 spine (#1801), for a strap that streams heart rate but banks no motion.
///
/// These cases are the ORACLE for the Kotlin twin `SleepStagerHrOnlySpineTest`: the same inputs and the
/// same expected runs are asserted on both sides, so a divergence in the flag rule, the epoch bucketing
/// or the run construction fails on one platform and not the other.
///
/// Baseline 60 throughout, so the sleep band is `60 * hrSleepBandMult` = 63.0 bpm inclusive. Samples are
/// laid down every 10 s, six to a 60 s epoch.
final class SleepStagerHrOnlySpineTests: XCTestCase {

    /// Six samples in each epoch, `bpm` per epoch index.
    private func hr(from epoch: Int, _ bpms: [Int]) -> [HRSample] {
        var out: [HRSample] = []
        for (i, bpm) in bpms.enumerated() {
            let base = (epoch + i) * 60
            for k in 0..<6 { out.append(HRSample(ts: base + k * 10, bpm: bpm)) }
        }
        return out
    }

    private func tuples(_ p: [SleepStager.Period]) -> [String] {
        p.map { "\($0.stage) \($0.start)-\($0.end)" }
    }

    func testNoBaselineOrNoHrYieldsNothing() {
        XCTAssertTrue(SleepStager.hrOnlySleepRuns(hr(from: 1000, [55]), baseline: nil).isEmpty)
        XCTAssertTrue(SleepStager.hrOnlySleepRuns(hr(from: 1000, [55]), baseline: 0).isEmpty)
        XCTAssertTrue(SleepStager.hrOnlySleepRuns([], baseline: 60).isEmpty)
    }

    func testAllInBandIsOneSleepRun() {
        let runs = SleepStager.hrOnlySleepRuns(hr(from: 1000, [55, 55, 55]), baseline: 60)
        XCTAssertEqual(tuples(runs), ["sleep 60000-60170"])
    }

    func testAllOutOfBandIsOneActiveRun() {
        let runs = SleepStager.hrOnlySleepRuns(hr(from: 1000, [90, 90, 90]), baseline: 60)
        XCTAssertEqual(tuples(runs), ["active 60000-60170"])
    }

    func testSleepActiveSleepSegmentsIntoThree() {
        let runs = SleepStager.hrOnlySleepRuns(hr(from: 1000, [55, 55, 90, 55, 55]), baseline: 60)
        XCTAssertEqual(tuples(runs), ["sleep 60000-60110", "active 60120-60170", "sleep 60180-60290"])
    }

    /// A gap wider than `maxGapMin` breaks a run even when the class never changes — the same rule
    /// `buildRuns` applies to a gravity gap.
    func testGapWiderThanMaxGapBreaksASameClassRun() {
        let runs = SleepStager.hrOnlySleepRuns(hr(from: 1000, [55]) + hr(from: 1030, [55]), baseline: 60)
        XCTAssertEqual(tuples(runs), ["sleep 60000-60050", "sleep 61800-61850"])
    }

    /// The band test is a MEDIAN, so one arousal spike inside an epoch cannot flip it to active — the
    /// property `hrSleepBandAcross` documents, asserted here on the epoch reduction.
    func testOneSpikeInAnEpochDoesNotFlipIt() {
        var samples = hr(from: 1000, [55])
        samples[5] = HRSample(ts: samples[5].ts, bpm: 190)
        XCTAssertEqual(tuples(SleepStager.hrOnlySleepRuns(samples, baseline: 60)), ["sleep 60000-60050"])
    }

    /// A run's `end` is the last SAMPLE seen, not the final epoch's start. Pinned because reading the
    /// epoch start reports every run one epoch short of the data it covers — silently, and straight into
    /// the caller's minimum-duration gate. Three 60 s epochs of samples laid every 10 s end at 60170.
    func testRunEndIsTheLastSampleNotTheEpochStart() {
        let runs = SleepStager.hrOnlySleepRuns(hr(from: 1000, [55, 55, 55]), baseline: 60)
        XCTAssertEqual(runs.first?.end, 60170)
        XCTAssertEqual((runs.first!.end - runs.first!.start), 170)
    }

    /// The band is inclusive: 63 is `60 * 1.05` exactly.
    func testBandBoundaryIsInclusive() {
        XCTAssertEqual(tuples(SleepStager.hrOnlySleepRuns(hr(from: 1000, [63]), baseline: 60)),
                       ["sleep 60000-60050"])
        XCTAssertEqual(tuples(SleepStager.hrOnlySleepRuns(hr(from: 1000, [64]), baseline: 60)),
                       ["active 60000-60050"])
    }
}
