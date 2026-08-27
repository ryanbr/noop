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

    /// #1451: a strap banking one record every 5 s is HEALTHY, but its reporting-second ratio reads ~5.
    /// `modalGap` states the cadence so that ratio is read against the right baseline instead of against
    /// 1.0, and `fill` shows each record's beat-time fits the slot it covers. Kotlin twin:
    /// `modalGapReportsRecordCadenceAndFillFitsOnAHealthyMultiSecondStrap`.
    func testModalGapReportsRecordCadenceAndFillFitsOnAHealthyMultiSecondStrap() {
        // Six records, 5 s apart, each carrying 5 s of beat-time in 6 intervals (~833 ms each).
        var rr: [(ts: Int, rrMs: Int)] = []
        for rec in 0..<6 { for _ in 0..<6 { rr.append((ts: rec * 5, rrMs: 833)) } }
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.modalGapSec, 5)               // cadence discovered, not assumed
        XCTAssertEqual(r.fill, [5, 0, 0, 0])           // every bounded record fits its own slot
        let line = RrEmissionStats.logLine(path: "historical", offered: rr.count, inserted: rr.count, r)
        XCTAssertTrue(line.contains("modalGap=5s"), line)
        XCTAssertTrue(line.contains("fill[<=1/<=1.5/<=2/>2]=5/0/0/0"), line)
    }

    /// #1451: the measurement a timeline fix needs. Records 1 s apart each carrying ~1.7 s of beat-time
    /// overflow the interval they cover, so no scheme that places beats inside a record's own slot can be
    /// correct. Kotlin twin: `fillCatchesRecordsCarryingMoreBeatTimeThanTheirSlot`.
    func testFillCatchesRecordsCarryingMoreBeatTimeThanTheirSlot() {
        var rr: [(ts: Int, rrMs: Int)] = []
        for t in 0..<5 { rr.append((ts: t, rrMs: 850)); rr.append((ts: t, rrMs: 850)) }
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.modalGapSec, 1)
        XCTAssertEqual(r.fill, [0, 0, 4, 0])           // 1.7 lands in the <=2.0 bucket, four bounded records
        // The two measures are coupled, and that is the point: if every record fitted its slot the totals
        // could not exceed the span either. `ratio` says the session over-counts; `fill` says WHICH records.
        XCTAssertGreaterThan(r.ratio, 1.0)
        let line = RrEmissionStats.logLine(path: "historical", offered: 10, inserted: 10, r)
        XCTAssertTrue(line.contains("fill[<=1/<=1.5/<=2/>2]=0/0/4/0"), line)
    }

    /// The log line is what a strap capture actually carries, so its shape is pinned too.
    func testLogLineShape() {
        let r = RrEmissionStats.compute([(ts: 10, rrMs: 800), (ts: 10, rrMs: 820), (ts: 11, rrMs: 810)])
        let line = RrEmissionStats.logLine(path: "historical", offered: 3, inserted: 2, r)
        XCTAssertTrue(line.hasPrefix("rr emit path=historical offered=3 inserted=2 secs=2 "), line)
        XCTAssertTrue(line.contains("perSec[1/2/3/4+]=1/1/0/0"), line)

        // A LIVE path censuses before the insert and cannot know what the conflict key kept, so it
        // passes nil and the line must say "n/a". Echoing `offered` there would read as "the primary
        // key absorbed nothing" — a claim neither live path is in a position to make.
        let live = RrEmissionStats.logLine(path: "live-standard", offered: 3, inserted: nil, r)
        XCTAssertTrue(live.contains("offered=3 inserted=n/a "), live)
    }

    /// A GAP must not read as healthy emission. Two doubled seconds an hour apart carry a 2.0 emission
    /// defect, but the wall span between them dilutes `ratio` to almost nothing — so `ratio` alone would
    /// report the *opposite* of the truth on exactly the session this instrumentation is meant to judge.
    /// `ratioRep` divides by the seconds that reported and holds at ~1.6, which is the readable signal.
    func testGapDilutesSpanRatioButNotReportingRatio() {
        let rr = [(ts: 0, rrMs: 800), (ts: 0, rrMs: 800), (ts: 3_600, rrMs: 800), (ts: 3_600, rrMs: 800)]
        let r = RrEmissionStats.compute(rr)
        XCTAssertEqual(r.secondsWithRr, 2)
        XCTAssertEqual(r.spanSec, 3_601)
        XCTAssertLessThan(r.ratio, 0.01, "span ratio is diluted by the gap, as documented")
        let line = RrEmissionStats.logLine(path: "historical", offered: 4, inserted: 4, r)
        XCTAssertTrue(line.contains("ratio=0.00 ratioRep=1.60"), line)
    }

    /// The LIVE census rate-limit. Twin of Kotlin `shouldEmitLiveCensusRateLimits` — same table, same
    /// answers, oracle-checked against a standalone Swift build of the helper.
    ///
    /// The `lastEmit=0` rows are the ones that matter. The sentinel is checked explicitly, not left to
    /// the gap arithmetic: with a real unix `nowSec` (~1.8e9) the subtraction clears any gap by accident
    /// of magnitude, so the "first flush always reports" contract held in production while being false
    /// for small timestamps — which is exactly what a unit test uses.
    func testShouldEmitLiveCensus() {
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 0, nowSec: 0))
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 0, nowSec: 1))
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 0, nowSec: 1_700_000_000))
        XCTAssertFalse(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 1_700_000_000, nowSec: 1_700_000_000))
        XCTAssertFalse(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 1_700_000_000, nowSec: 1_700_000_899))
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 1_700_000_000, nowSec: 1_700_000_900))
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 1_700_000_000, nowSec: 1_700_000_901))
        XCTAssertTrue(RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: 1_700_000_900, nowSec: 1_700_000_000))
    }
}
