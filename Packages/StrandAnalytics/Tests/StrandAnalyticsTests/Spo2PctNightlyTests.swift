import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// v34 — the nightly SpO2 percentage banked on `DailyMetric.spo2Pct` for a 5/MG night.
///
/// The strap samples SpO2 in RUNS: ~30 one-second samples roughly once per ~1,200 s while asleep. The
/// first samples of each run are the optical front end settling and they read LOW. That makes a naive
/// mean over the night's in-band samples biased downward — and biased *more* on nights made of many short
/// runs, which is the opposite of when you would think to check. These tests pin the two corrections
/// (per-run ramp trim, then median) and, more usefully, pin the size of the bias they remove.
final class Spo2PctNightlyTests: XCTestCase {

    private func session(_ start: Int, _ durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60)
    }

    /// A measurement run: `count` consecutive one-second samples starting at `ts`, the first
    /// `rampCount` of them at the depressed `rampValue`.
    private func run(_ ts: Int, count: Int, settled: Int,
                     rampCount: Int = 0, rampValue: Int = 88) -> [Spo2PctSample] {
        (0..<count).map { Spo2PctSample(ts: ts + $0, pct: $0 < rampCount ? rampValue : settled) }
    }

    // MARK: - The bias this exists to remove

    /// THE MOTIVATING CASE. One 30-sample run whose first 5 are the acquisition ramp at 88 and whose
    /// settled 25 are 97. A naive mean lands at 95.5 — a full 1.5 points below what the strap actually
    /// settled on, entirely from a one-sided artifact. The ramp trim removes exactly those 5 samples and
    /// the median returns the settled value.
    func testTheAcquisitionRampBiasesANaiveMeanAndTheTrimRemovesIt() {
        let samples = run(1_000, count: 30, settled: 97, rampCount: 5)
        let naiveMean = Double(samples.map(\.pct).reduce(0, +)) / Double(samples.count)
        XCTAssertEqual(naiveMean, 95.5, accuracy: 0.001, "the bias is real and this is its size")

        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
        XCTAssertEqual(r?.pct, 97)
        XCTAssertEqual(r?.samples, 25, "the five ramp samples are dropped, the settled 25 are kept")
    }

    // MARK: - Run segmentation

    /// Runs are separated by a gap far larger than the 1 s spacing inside one, so EACH run gets its own
    /// ramp trim. Trimming only the night's first five samples would leave every later run's ramp in.
    func testEachRunIsTrimmedSeparately() {
        let samples = run(1_000, count: 20, settled: 97, rampCount: 5)
            + run(3_000, count: 20, settled: 97, rampCount: 5)
            + run(5_000, count: 20, settled: 97, rampCount: 5)
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 5_000)], samples: samples)
        XCTAssertEqual(r?.samples, 45, "3 runs x (20 - 5) survivors")
        XCTAssertEqual(r?.pct, 97)
    }

    /// A dropped second or two inside a run must NOT split it — the gap threshold sits in the gulf
    /// between 1 s (within a run) and ~1,200 s (between runs), so a small hole is tolerated.
    func testASmallHoleDoesNotSplitARun() {
        // 10 samples, then a 20 s hole, then 10 more: still ONE run, so ONE ramp trim.
        let samples = run(1_000, count: 10, settled: 97, rampCount: 5) + run(1_030, count: 10, settled: 97)
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
        XCTAssertEqual(r?.samples, 15, "one run: 20 samples less one 5-sample ramp")
    }

    func testTheRunGapThresholdIsTheDocumentedOne() {
        XCTAssertEqual(AnalyticsEngine.spo2RunGapSeconds, 60)
        XCTAssertEqual(AnalyticsEngine.spo2RampSamples, 5)
    }

    // MARK: - The half-run cap

    /// The trim never eats more than half a run. A short run must contribute its settled tail rather than
    /// vanishing — otherwise the night would be silently reweighted toward whichever runs happened to be
    /// long, which is a selection effect nobody would see in the output.
    func testAShortRunKeepsItsTailInsteadOfVanishing() {
        // 4 samples: drop min(5, 2) = 2, keep 2.
        let r = AnalyticsEngine.nightlySpo2Pct(
            [session(900, 600)],
            samples: [Spo2PctSample(ts: 1_000, pct: 88), Spo2PctSample(ts: 1_001, pct: 90),
                      Spo2PctSample(ts: 1_002, pct: 96), Spo2PctSample(ts: 1_003, pct: 96)])
        XCTAssertEqual(r?.samples, 2)
        XCTAssertEqual(r?.pct, 96)
    }

    /// A single-sample run keeps its one sample (drop = min(5, 0) = 0) rather than being erased.
    func testASingleSampleRunSurvives() {
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)],
                                               samples: [Spo2PctSample(ts: 1_000, pct: 95)])
        XCTAssertEqual(r?.samples, 1)
        XCTAssertEqual(r?.pct, 95)
    }

    // MARK: - The statistic

    /// The median is the statistic, matching what the cloud reader reports for the same rows — a phone
    /// that disagreed with the server on identical data would poison every future cross-check.
    func testMedianNotMeanOverTheSurvivors() {
        // Survivors after the ramp trim: 90, 97, 97, 97, 97 — median 97, mean 95.6.
        let samples = [90, 90, 90, 90, 90, 90, 97, 97, 97, 97].enumerated()
            .map { Spo2PctSample(ts: 1_000 + $0.offset, pct: $0.element) }
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
        XCTAssertEqual(r?.samples, 5)
        XCTAssertEqual(r?.pct, 97, "a single low survivor must not drag the answer the way a mean would")
    }

    /// An even survivor count averages the two middle values, so the result can land on a half.
    func testEvenSurvivorCountAveragesTheTwoMiddleValues() throws {
        // A 4-sample run: the half-run cap drops 2, leaving survivors 94 and 97 → (94 + 97) / 2 = 95.5.
        let pcts = [88, 88, 94, 97]
        let samples = pcts.enumerated().map { Spo2PctSample(ts: 1_000 + $0.offset, pct: $0.element) }
        let r = try XCTUnwrap(AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples))
        XCTAssertEqual(r.samples, 2)
        XCTAssertEqual(r.pct, 95.5, accuracy: 0.001)
    }

    /// The half-run cap governs whenever a run is shorter than twice the ramp, so the survivor count is
    /// `count - min(5, count/2)` and not simply `count - 5`. Pinned across the crossover at 10.
    func testSurvivorCountFollowsTheCappedTrim() {
        for (count, want) in [(1, 1), (2, 1), (4, 2), (6, 3), (9, 5), (10, 5), (11, 6), (30, 25)] {
            let samples = run(1_000, count: count, settled: 97)
            let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
            XCTAssertEqual(r?.samples, want, "a \(count)-sample run must keep \(want)")
        }
    }

    // MARK: - Session gating and absence

    /// Only in-bed samples count — a daytime reading is not part of the night's saturation.
    func testSamplesOutsideEverySessionAreExcluded() {
        let samples = run(1_000, count: 10, settled: 97) + run(9_000, count: 10, settled: 80)
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
        XCTAssertEqual(r?.samples, 5, "only the in-bed run contributes")
        XCTAssertEqual(r?.pct, 97)
    }

    /// Gap size is the ONLY run signal — a session edge is not a second one. A brief out-of-bed moment
    /// mid-run leaves the run intact and singly-trimmed, because the acquisition ramp is a property of
    /// the SENSOR restarting and the sensor does not restart because the sleep detector drew a line.
    func testABriefSessionEdgeDoesNotSplitARun() {
        let samples = run(1_000, count: 20, settled: 97)
        // Sessions carve out [1000..1004] and [1010..1019] — 15 in-bed samples with only a 6 s hole,
        // which is under the threshold, so this stays ONE run and is trimmed ONCE.
        let r = AnalyticsEngine.nightlySpo2Pct([session(1_000, 4), session(1_010, 9)], samples: samples)
        XCTAssertEqual(r?.samples, 10, "one run of 15, less one 5-sample ramp")
    }

    /// When the excluded stretch IS longer than the gap threshold, the two halves are genuinely separate
    /// runs and each pays its own ramp trim.
    func testAWideSessionGapDoesSplitARun() {
        let samples = run(1_000, count: 10, settled: 97) + run(1_200, count: 10, settled: 97)
        // 200 s apart — comfortably over the 60 s threshold, so two runs: (10-5) + (10-5).
        let r = AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: samples)
        XCTAssertEqual(r?.samples, 10)
    }

    /// Absence stays absence — nothing here may invent a percentage.
    func testNilWhenThereIsNothingToAverage() {
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([], samples: [Spo2PctSample(ts: 1_000, pct: 97)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: []))
        // In-band samples exist, but none of them fall in a session.
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(900, 100)],
                                                    samples: [Spo2PctSample(ts: 9_999, pct: 97)]))
    }

    /// Unsorted input must not change the answer — run boundaries are a property of the timestamps, not
    /// of the order the store happened to hand them over in.
    func testInputOrderDoesNotMatter() {
        let ordered = run(1_000, count: 20, settled: 97, rampCount: 5)
        let shuffled = ordered.reversed().map { $0 }
        XCTAssertEqual(AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: shuffled)?.samples,
                       AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: ordered)?.samples)
        XCTAssertEqual(AnalyticsEngine.nightlySpo2Pct([session(900, 600)], samples: shuffled)?.pct, 97)
    }
}
