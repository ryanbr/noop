import XCTest
@testable import StrandAnalytics

/// Pins the PRE-STORAGE R-R census (#1008/#1118). Its job is to tell an EMISSION defect (the decoder
/// hands over more beat-time than the clock allows) from an INGEST one (the same beats stored twice),
/// so the vectors are the two shapes that distinguish them.
///
/// `ratio` is the only sound discriminator here, and deliberately so: a cross-second repeat counter was
/// written first and deleted, because on a resting heart consecutive intervals are near-identical, so it
/// reported 9 "repeats" out of 10 honest beats. Physics bounds the ratio; resemblance bounds nothing.
final class RrEmissionStatsTests: XCTestCase {

    /// A physiological clean stream: 860 ms intervals laid end to end, so every moment of the span is
    /// covered exactly once and the ratio sits at ~1.0. Note this means ~1.16 beats per second, so some
    /// seconds legitimately carry TWO interval endings — the 2-bucket is normal, not a defect.
    func testCleanEndToEndStreamRatioIsAboutOne() {
        var rr: [(ts: Int, rrMs: Int)] = []
        var tMs = 0
        while tMs < 60_000 {                      // one minute of beats
            tMs += 860
            rr.append((ts: 1_000 + tMs / 1_000, rrMs: 860))
        }
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.intervals, 70)           // ceil(60_000 / 860): the last beat ends just past the minute
        XCTAssertEqual(r.ratio, 1.0, accuracy: 0.05)
        XCTAssertEqual(r.perSecond[2] + r.perSecond[3], 0, "a 60 bpm-ish heart never fills 3+ endings in one second")
    }

    /// The signature this exists to catch: the same beat-time reported twice, so the batch carries ~2x
    /// more beat-time than the clock allows. Physically impossible, and visible BEFORE storage — which is
    /// the whole point, because no ON CONFLICT key can undo an emission defect.
    func testDoubledEmissionShowsAsRatioAboveOne() {
        var rr: [(ts: Int, rrMs: Int)] = []
        var tMs = 0
        while tMs < 60_000 {
            tMs += 860
            let ts = 1_000 + tMs / 1_000
            rr.append((ts: ts, rrMs: 860))
            rr.append((ts: ts, rrMs: 860))        // the same beat again
        }
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.ratio, 2.0, accuracy: 0.1)
        XCTAssertGreaterThan(r.perSecond[1] + r.perSecond[2] + r.perSecond[3], 0)
    }

    /// Two optical channels measuring the SAME beat land in one second ~34 ms apart: the ratio inflates
    /// and the multi-interval buckets fill, which is how the log distinguishes this from a clean stream.
    func testSameSecondChannelTwinsInflateTheRatio() {
        var rr: [(ts: Int, rrMs: Int)] = []
        for i in 0..<30 {
            rr.append((ts: 1_000 + i, rrMs: 860))
            rr.append((ts: 1_000 + i, rrMs: 894))   // same beat, other channel (+34 ms)
        }
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.perSecond, [0, 30, 0, 0])
        XCTAssertGreaterThan(r.ratio, 1.7)
    }

    /// Empty and single-sample batches must not divide by zero; a lone second spans 1 s inclusive.
    func testDegenerateBatches() {
        let empty = RrEmissionStats.compute([])
        XCTAssertEqual(empty.intervals, 0)
        XCTAssertEqual(empty.ratio, 0)
        XCTAssertEqual(empty.perSecond, [0, 0, 0, 0])

        let one = RrEmissionStats.compute([(ts: 5, rrMs: 900)])
        XCTAssertEqual(one.spanSec, 1)
        XCTAssertEqual(one.ratio, 0.9, accuracy: 1e-9)
    }

    /// A 4+ second buckets into the last histogram slot rather than overflowing it.
    func testFourOrMoreBucketsTogether() {
        let rr = (0..<5).map { (ts: 1_000, rrMs: 200 + $0) }
        XCTAssertEqual(RrEmissionStats.compute(rr).perSecond, [0, 0, 0, 1])
    }

    /// The log line is what a strap capture actually carries, so its shape is pinned too.
    func testLogLineShape() {
        let r = RrEmissionStats.compute([(ts: 10, rrMs: 800), (ts: 10, rrMs: 820), (ts: 11, rrMs: 810)])
        let line = RrEmissionStats.logLine(path: "historical", offered: 3, inserted: 2, r)
        XCTAssertTrue(line.hasPrefix("rr emit path=historical offered=3 inserted=2 secs=2 "), line)
        XCTAssertTrue(line.contains("perSec[1/2/3/4+]=1/1/0/0"), line)
    }
}
