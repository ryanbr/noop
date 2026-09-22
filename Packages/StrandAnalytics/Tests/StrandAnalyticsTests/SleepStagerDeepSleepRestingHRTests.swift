import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The night's resting HR is the mean HR across its deep-sleep segments, not its single calmest 5-min bin.
final class SleepStagerDeepSleepRestingHRTests: XCTestCase {

    private let start = 1_000_000

    /// 1 Hz samples over [from, to) at `bpm`.
    private func samples(_ from: Int, _ to: Int, bpm: Int) -> [HRSample] {
        (from..<to).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// A 40-min night: 10 min light at 60, 20 min deep at 55, 10 min light holding a 5-min dip at 48.
    private var night: (hr: [HRSample], stages: [StageSegment], end: Int) {
        let hr = samples(start, start + 600, bpm: 60)
            + samples(start + 600, start + 1_800, bpm: 55)
            + samples(start + 1_800, start + 2_100, bpm: 48)
            + samples(start + 2_100, start + 2_400, bpm: 60)
        let stages = [StageSegment(start: start, end: start + 600, stage: "light"),
                      StageSegment(start: start + 600, end: start + 1_800, stage: "deep"),
                      StageSegment(start: start + 1_800, end: start + 2_400, stage: "light")]
        return (hr, stages, start + 2_400)
    }

    func testTheRestingHRIsTheDeepSleepMeanNotTheLowestBin() {
        let n = night
        XCTAssertEqual(SleepStager.sessionDeepSleepRestingHR(start: start, end: n.end, hr: n.hr, stages: n.stages), 55)
        XCTAssertEqual(SleepStager.sessionRestingHR(start: start, end: n.end, hr: n.hr), 48,
                       "the lowest-bin statistic the daytime guard reads is unchanged")
    }

    func testImplausibleSamplesDoNotPullTheDeepSleepMeanDown() {
        let n = night
        let dropouts = samples(start + 600, start + 660, bpm: 0)
        XCTAssertEqual(SleepStager.sessionDeepSleepRestingHR(start: start, end: n.end, hr: dropouts + n.hr,
                                                             stages: n.stages), 55)
    }

    /// Under `rhrMinDeepSleepSamples` of deep sleep the lower quartile of the 5-min bins stands in, which
    /// stays on the resting level rather than dropping to the dip.
    func testTooLittleDeepSleepFallsBackToTheLowerQuartileBin() {
        let n = night
        let briefDeep = [StageSegment(start: start + 600, end: start + 840, stage: "deep")]
        // Bins: 60, 60, 55, 55, 55, 55, 48, 60 → sorted [48, 55, 55, 55, 55, 60, 60, 60], index 8/4 = 2 → 55.
        XCTAssertEqual(SleepStager.sessionDeepSleepRestingHR(start: start, end: n.end, hr: n.hr, stages: briefDeep), 55)
        XCTAssertEqual(SleepStager.sessionDeepSleepRestingHR(start: start, end: n.end, hr: n.hr, stages: []), 55)
    }

    func testASessionWithNoSamplesHasNoRestingHR() {
        XCTAssertNil(SleepStager.sessionDeepSleepRestingHR(start: start, end: start + 600, hr: [], stages: night.stages))
    }
}
