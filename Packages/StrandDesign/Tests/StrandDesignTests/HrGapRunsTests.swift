import XCTest
@testable import StrandDesign

/// #2082: the default Liquid Today sparkline draws its points evenly by index and strokes one continuous
/// path, so hours the strap recorded nothing close up silently and sparse readings look continuous.
///
/// A chart can hand a segment id to the plotting library; a hand-drawn sparkline has to know where to lift
/// the pen. These pin that the runs follow the SAME rule `hrGapSegments` already applies, rather than a
/// second walk that could disagree with it.
final class HrGapRunsTests: XCTestCase {

    func testAContiguousSeriesIsOneRun() {
        let segs = hrGapSegments(bucketTs: [0, 300, 600, 900], bucketSeconds: 300)
        XCTAssertEqual(hrGapRuns(segments: segs), [0...3])
    }

    func testAGapSplitsTheRunWhereTheDataStops() {
        // 0,300 then a three-hour hole, then two more buckets.
        let segs = hrGapSegments(bucketTs: [0, 300, 11_100, 11_400], bucketSeconds: 300)
        XCTAssertEqual(hrGapRuns(segments: segs), [0...1, 2...3])
    }

    func testALoneBucketBetweenTwoGapsIsStillARun() {
        // Dropping it would hide a real reading rather than a gap, which is the opposite of the point.
        let segs = hrGapSegments(bucketTs: [0, 7_200, 14_400], bucketSeconds: 300)
        XCTAssertEqual(hrGapRuns(segments: segs), [0...0, 1...1, 2...2])
    }

    func testEmptyInputYieldsNoRuns() {
        XCTAssertEqual(hrGapRuns(segments: []), [])
    }

    func testASingleBucketIsOneRunOfOne() {
        XCTAssertEqual(hrGapRuns(segments: hrGapSegments(bucketTs: [0], bucketSeconds: 300)), [0...0])
    }

    /// The runs must tile the input exactly: every index in exactly one run, in order. A sparkline that
    /// silently dropped or repeated a bucket would be a worse lie than the one this removes.
    func testTheRunsTileTheSeriesExactly() {
        let segs = hrGapSegments(bucketTs: [0, 300, 5_000, 5_300, 5_600, 90_000], bucketSeconds: 300)
        let runs = hrGapRuns(segments: segs)
        XCTAssertEqual(runs.flatMap { Array($0) }, Array(0..<segs.count))
    }
}
