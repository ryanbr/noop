import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRVAnalyzerTests: XCTestCase {

    func testRMSSDRawHandComputed() {
        // NN = [800, 810, 800, 810] → diffs 10, -10, 10 → sqrt(300/3) = 10.
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(nn)!, 10.0, accuracy: 1e-9)
    }

    func testSDNNRawSampleStdDev() {
        // Sample SD (ddof=1) of [800, 810, 800, 810] = 5.7735026919...
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.sdnnRaw(nn)!, 5.773502691896258, accuracy: 1e-9)
    }

    func testRMSSDRawTooFewReturnsNil() {
        XCTAssertNil(HRVAnalyzer.rmssdRaw([800]))
        XCTAssertNil(HRVAnalyzer.sdnnRaw([]))
    }

    func testRangeFilterDropsOutOfRange() {
        let rr = [250.0, 300, 800, 2000, 2100, 1500]
        // 250 (<300) and 2100 (>2000) dropped; 300 and 2000 kept (inclusive).
        XCTAssertEqual(HRVAnalyzer.rangeFilter(rr), [300, 800, 2000, 1500])
    }

    func testAnalyzeRequiresMinBeats() {
        // 19 clean intervals → below minBeats(20) → empty result.
        let rr = Array(repeating: 800.0, count: 19)
        let result = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertNil(result.rmssd)
        XCTAssertNil(result.sdnn)
        XCTAssertEqual(result.nInput, 19)
        XCTAssertEqual(result.nClean, 0)
    }

    func testAnalyzeGoldenSeries() {
        // 22 intervals oscillating near 800 ms; matches Python golden values.
        let nn: [Double] = [800, 810, 805, 815, 800, 820, 810, 800, 815, 805, 810,
                            800, 820, 815, 805, 810, 800, 815, 810, 805, 800, 820]
        let result = HRVAnalyzer.analyze(rawRR: nn)
        XCTAssertEqual(result.nClean, 22)  // none ectopic (all near local median)
        XCTAssertEqual(result.rmssd!, 11.649647450214351, accuracy: 1e-9)
        XCTAssertEqual(result.sdnn!, 7.101612523427368, accuracy: 1e-9)
        XCTAssertEqual(result.meanNN!, nn.reduce(0,+)/22, accuracy: 1e-9)
    }

    func testEctopicRejectionDropsSpike() {
        // A steady 800 ms series with one impossible 1400 ms beat in the middle.
        // The spike deviates ~75% from local median → rejected. Remaining beats
        // are all 800 → RMSSD 0.
        var nn = Array(repeating: 800.0, count: 30)
        nn[15] = 1400
        let clean = HRVAnalyzer.cleanRR(nn)
        XCTAssertEqual(clean.count, 29)               // exactly one beat dropped
        XCTAssertFalse(clean.contains(1400))
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(clean)!, 0.0, accuracy: 1e-9)
    }

    func testEctopicKeepsModerateVariation() {
        // ±15% variation is within the 20% Malik threshold → all kept.
        let nn = [800.0, 900, 800, 900, 800, 900, 800, 900]  // 900/800 = +12.5%
        let clean = HRVAnalyzer.rejectEctopic(nn)
        XCTAssertEqual(clean.count, nn.count)
    }

    // MARK: - #585 spot honesty gate (maxRejectedFraction)

    func testSpotGateRefusesWhenTooManyBeatsRejected() {
        // 40 input beats: 24 valid 800 ms + 16 out-of-range 100 ms (dropped by the range filter).
        // 24 clean survive (>= minBeats 20), but 16/40 = 0.40 rejected > 0.35 gate → refused (empty).
        var rr = Array(repeating: 800.0, count: 24)
        rr.append(contentsOf: Array(repeating: 100.0, count: 16))   // 100 ms < rrMinMs(300) → range-dropped
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertNil(gated.rmssd, "0.40 rejected > 0.35 gate must refuse the spot reading")
        XCTAssertNil(gated.sdnn)
        XCTAssertEqual(gated.nInput, 40)
        XCTAssertEqual(gated.nClean, 0)   // empty() reports no clean beats on refusal

        // SAME beats with NO gate (nil) still produce a value , 24 clean ≥ minBeats. Proves the gate is
        // the only thing rejecting it, not the beat count.
        let ungated = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertEqual(ungated.nClean, 24)
        XCTAssertEqual(ungated.rmssd!, 0.0, accuracy: 1e-9)   // all-800 survivors → no successive diffs
    }

    func testSpotGateAllowsWhenRejectionUnderCeiling() {
        // 40 input: 30 valid 800 ms + 10 out-of-range → 10/40 = 0.25 rejected < 0.35 gate → allowed.
        var rr = Array(repeating: 800.0, count: 30)
        rr.append(contentsOf: Array(repeating: 100.0, count: 10))
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertEqual(gated.nClean, 30)
        XCTAssertEqual(gated.rmssd!, 0.0, accuracy: 1e-9)
    }

    func testNightlyWindowedRMSSDUnchangedWithDefaultedGate() {
        // The nightly windowed analyze(_:windowStart:windowEnd:) passes NO maxRejectedFraction, so the
        // gate is skipped and the result is byte-identical to analyze(rawRR:) on the same beats , even
        // when the series WOULD trip a spot gate (here 0.40 rejected). Overnight HRV must not move (#585).
        var rr: [RRInterval] = []
        for t in 0..<24 { rr.append(RRInterval(ts: 1000 + t, rrMs: 800)) }   // 24 valid 800 ms
        for t in 0..<16 { rr.append(RRInterval(ts: 1100 + t, rrMs: 100)) }   // 16 range-dropped
        let windowed = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 2000)
        // The spot gate WOULD refuse this (0.40 > 0.35); the nightly path must NOT.
        XCTAssertEqual(windowed.nClean, 24)
        XCTAssertNotNil(windowed.rmssd)
        // Identical to the un-gated raw analysis on the same values.
        let raw = HRVAnalyzer.analyze(rawRR: rr.map { Double($0.rrMs) })
        XCTAssertEqual(windowed.rmssd!, raw.rmssd!, accuracy: 1e-12)
        XCTAssertEqual(windowed.sdnn ?? .nan, raw.sdnn ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(windowed.nClean, raw.nClean)
    }

    // MARK: - #803 rolling / windowed rMSSD timeline

    func testRollingRmssdEmitsWindowedTimelineWithKnownValue() {
        // A clean 1 Hz R-R series oscillating 800/810 ms. Over any trailing window the successive diffs
        // alternate ±10, so rMSSD = sqrt(mean(10^2)) = 10 ms. We build 60 beats (1 s apart) and ask for a
        // 30 s trailing window; every emitted point must read ~10 ms.
        var rr: [RRInterval] = []
        for t in 0..<60 { rr.append(RRInterval(ts: 1000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        let pts = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty, "a dense clean stream must yield a windowed timeline")
        // The first ~7 beats can't fill minBeatsPerWindow(8); once the window holds >= 8 beats every point
        // is the steady ±10 oscillation → 10 ms rMSSD.
        for p in pts { XCTAssertEqual(p.rmssd, 10.0, accuracy: 1e-9) }
        // Right edge of each point is a real interval timestamp inside the series, and points are time-ordered.
        XCTAssertTrue(pts.allSatisfy { $0.ts >= 1000 && $0.ts <= 1059 })
        XCTAssertEqual(pts.map { $0.ts }, pts.map { $0.ts }.sorted())
    }

    func testRollingRmssdStepThinsEmission() {
        // Same 60-beat 1 Hz stream, but a 10 s stride: points must be at least 10 s apart, so far fewer
        // than one-per-beat are emitted while the value stays the steady 10 ms.
        var rr: [RRInterval] = []
        for t in 0..<60 { rr.append(RRInterval(ts: 1000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        let dense = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        let thinned = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 10, minBeatsPerWindow: 8)
        XCTAssertLessThan(thinned.count, dense.count, "a stride must emit fewer points than every-beat")
        // Adjacent emitted points are >= stepSec apart.
        for i in 1..<thinned.count { XCTAssertGreaterThanOrEqual(thinned[i].ts - thinned[i - 1].ts, 10) }
    }

    func testRollingRmssdCleansArtifactWindows() {
        // A steady 800 ms stream with one impossible 1400 ms spike. The Malik ectopic filter drops the
        // spike inside whatever window holds it, so no point spikes , every emitted rMSSD is 0 (all-800
        // survivors have no successive difference).
        var rr: [RRInterval] = []
        for t in 0..<40 { rr.append(RRInterval(ts: 2000 + t, rrMs: 800)) }
        rr[20] = RRInterval(ts: 2020, rrMs: 1400)   // the artifact beat
        let pts = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 20, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty)
        for p in pts { XCTAssertEqual(p.rmssd, 0.0, accuracy: 1e-9, "the 1400 ms artifact must be filtered, never spiking a window") }
    }

    func testRollingRmssdSparseSeriesEmitsNothing() {
        // Fewer beats than minBeatsPerWindow → no point at all (honest absence, no fabricated value).
        let rr = (0..<5).map { RRInterval(ts: 3000 + $0, rrMs: 800) }
        XCTAssertTrue(HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30).isEmpty)
        // Zero / negative window width is rejected.
        XCTAssertTrue(HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 0).isEmpty)
    }

    func testRollingRmssdSortsUnorderedInput() {
        // Input shuffled in time; the function sorts internally so the trailing window is well-defined and
        // the emitted points are time-ordered with the same steady 10 ms value.
        var rr: [RRInterval] = []
        for t in 0..<40 { rr.append(RRInterval(ts: 4000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        rr.shuffle()
        let pts = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertEqual(pts.map { $0.ts }, pts.map { $0.ts }.sorted())
        for p in pts { XCTAssertEqual(p.rmssd, 10.0, accuracy: 1e-9) }
    }

    func testAnalyzeWindowFiltersByTimestamp() {
        // RR rows across two windows; only [1000,1010] should be analyzed.
        var rr: [RRInterval] = []
        for t in 1000...1030 { rr.append(RRInterval(ts: t, rrMs: 800)) }   // 31 in window A
        for t in 5000...5030 { rr.append(RRInterval(ts: t, rrMs: 600)) }   // window B
        let result = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 1030)
        XCTAssertEqual(result.nInput, 31)
        XCTAssertEqual(result.nClean, 31)
        XCTAssertEqual(result.rmssd!, 0.0, accuracy: 1e-9)  // all 800 → no successive diffs
    }

    // MARK: - #257 R-R integrity diagnostics (byte-parity twin of Kotlin HrvRrCoverageTest)

    func testCoverageCleanStreamIsNearOne() {
        // 5 beats of 1000 ms spanning ts 100..104 (4 s wall clock). sum=5000, span=4000 → 1.25.
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: [100, 101, 102, 103, 104],
                                              rrMs: [1000, 1000, 1000, 1000, 1000]), 1.25, accuracy: 1e-9)
    }

    func testCoverageDoubleCountedBeatsExceedsOne() {
        // Each beat stored TWICE at the same second (#257 over-count): sum=6000 over a 2 s span → 3.0.
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: [100, 100, 101, 101, 102, 102],
                                              rrMs: [1000, 1000, 1000, 1000, 1000, 1000]), 3.0, accuracy: 1e-9)
    }

    func testCoverageZeroForTooFewBeatsOrZeroSpan() {
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: [], rrMs: []), 0, accuracy: 1e-9)
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: [100], rrMs: [1000]), 0, accuracy: 1e-9)
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: [100, 100], rrMs: [1000, 1000]), 0, accuracy: 1e-9)
    }

    func testDuplicateBeatsCountsExactRepeats() {
        XCTAssertEqual(HRVAnalyzer.duplicateBeatCount(tsSec: [100, 101, 102], rrMs: [1000, 1010, 1020]), 0)
        XCTAssertEqual(HRVAnalyzer.duplicateBeatCount(tsSec: [100, 100, 101], rrMs: [1000, 1000, 1010]), 1)
        XCTAssertEqual(HRVAnalyzer.duplicateBeatCount(tsSec: [100, 100, 100], rrMs: [1000, 1000, 1000]), 2)
        XCTAssertEqual(HRVAnalyzer.duplicateBeatCount(tsSec: [100, 100], rrMs: [1000, 1010]), 0)  // diff rr = distinct
    }

    // MARK: - SDNN index (5-min segmented SDNN, the Apple-comparable window)

    func testSdnnIndexExcludesInterSegmentDrift() {
        // Three 100 s segments, each internally near-steady (±5 ms) but at very different levels
        // (800 / 900 / 1000 ms). Whole-night SDNN sees the big 800→1000 drift and reads large; the SDNN
        // index averages each segment's OWN (small) SDNN, so it stays small — the exact property that makes
        // it comparable to a watch's short-window reading instead of the drift-inflated whole-night value.
        var rr: [RRInterval] = []
        for t in 0..<50   { rr.append(RRInterval(ts: 0   + t, rrMs: t.isMultiple(of: 2) ? 795 : 805)) }
        for t in 0..<50   { rr.append(RRInterval(ts: 100 + t, rrMs: t.isMultiple(of: 2) ? 895 : 905)) }
        for t in 0..<50   { rr.append(RRInterval(ts: 200 + t, rrMs: t.isMultiple(of: 2) ? 995 : 1005)) }

        let index = HRVAnalyzer.sdnnIndex(rr, segmentSec: 100)
        let wholeNight = HRVAnalyzer.analyze(rawRR: rr.map { Double($0.rrMs) }).sdnn
        let idx = try! XCTUnwrap(index)
        let whole = try! XCTUnwrap(wholeNight)
        XCTAssertEqual(idx, 5.05, accuracy: 1.5, "each segment's own SDNN is ~5 ms")
        XCTAssertGreaterThan(whole, 50, "whole-night SDNN is inflated by the 800→1000 drift")
        XCTAssertLessThan(idx, whole / 5, "the index must strip out the inter-segment drift")
    }

    func testSdnnIndexSteadySeriesIsSmallPositive() {
        // A single steady segment (±5 ms) → a small, sane, non-nil index.
        let rr = (0..<60).map { RRInterval(ts: $0, rrMs: $0.isMultiple(of: 2) ? 795 : 805) }
        let idx = try! XCTUnwrap(HRVAnalyzer.sdnnIndex(rr, segmentSec: 100))
        XCTAssertEqual(idx, 5.05, accuracy: 1.5)
    }

    func testSdnnIndexSingleSegmentEqualsWholeSdnn() {
        // When all beats fall in ONE segment, the index is just that segment's SDNN = the whole SDNN.
        let rr = (0..<60).map { RRInterval(ts: $0, rrMs: [800, 820, 780, 810, 790][$0 % 5]) }
        let index = try! XCTUnwrap(HRVAnalyzer.sdnnIndex(rr, segmentSec: 1000))
        let whole = try! XCTUnwrap(HRVAnalyzer.analyze(rr, windowStart: 0, windowEnd: 999).sdnn)
        XCTAssertEqual(index, whole, accuracy: 1e-9)
    }

    func testSdnnIndexSparseSeriesIsNil() {
        // Fewer than minBeats in the only segment → no qualifying segment → nil (honest absence).
        let rr = (0..<10).map { RRInterval(ts: $0, rrMs: 800) }
        XCTAssertNil(HRVAnalyzer.sdnnIndex(rr, segmentSec: 100))
        XCTAssertNil(HRVAnalyzer.sdnnIndex([], segmentSec: 100))
        XCTAssertNil(HRVAnalyzer.sdnnIndex(rr, segmentSec: 0), "non-positive segment length is rejected")
    }

    // #550 — collapsedCoverage: previews a SAME-SECOND R-R de-dup so the always-on diag reveals whether
    // the #257 over-count is same-second (collapsible) or cross-second (needs an ingest-path fix).

    func testCollapsedCoverageNoOpOnCleanStream() {
        // No same-second collisions → collapse changes nothing → equals rrCoverage.
        let ts = [100, 101, 102, 103, 104], rr: [Double] = [1000, 1000, 1000, 1000, 1000]
        XCTAssertEqual(HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr),
                       HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr), accuracy: 1e-9)
    }

    func testCollapsedCoverageCollapsesSameSecondNearDuplicates() {
        // Each beat double-stamped WITHIN one second, the copies within the 30 ms tol (#257 live+historical).
        let ts = [100, 100, 101, 101, 102, 102]
        let rr: [Double] = [1000, 1010, 1000, 1015, 1000, 1005]
        XCTAssertEqual(HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr), 3.015, accuracy: 1e-9)       // raw over-counts
        XCTAssertEqual(HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr), 1.5, accuracy: 1e-9)  // one per second
    }

    func testCollapsedCoverageKeepsCrossSecondDuplicates() {
        // The SAME beat stamped one second apart (live now-anchored vs historical RTC) — a same-second
        // collapse CANNOT catch it, so collapsedCov stays == raw. This is the discriminating signal.
        let ts = [100, 101, 102, 103], rr: [Double] = [1000, 1000, 1000, 1000]
        XCTAssertEqual(HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr),
                       HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr), accuracy: 1e-9)
    }

    func testCollapsedCoverageRespectsRrToleranceForGenuineTwoBeatsInOneSecond() {
        // Two beats in one second whose rr differ by MORE than the tol are genuine distinct beats, not
        // duplicates — both kept, so collapse is a no-op here too.
        let ts = [100, 100, 101], rr: [Double] = [900, 1200, 1000]  // |1200-900| = 300 ms > 30 ms tol
        XCTAssertEqual(HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr),
                       HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr), accuracy: 1e-9)
    }

    // #1008 — densestSecondWindowSample: the raw-row sample that makes an over-count's MECHANISM readable
    // from the always-on log. Exact-string assertions pin byte-parity with the Kotlin twin.

    /// Near-equal copies clustered in one second (the "same beat stored twice" shape): the sample shows
    /// `[1199,1200,1201]` — values a de-dup would collapse. This is the signature of a duplication bug.
    func testDensestSampleShowsNearEqualCopies() {
        let ts = [100, 100, 100, 101, 102]
        let rr: [Double] = [1200, 1199, 1201, 1200, 1198]
        let src: [Int?] = [nil, nil, nil, nil, nil]
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(tsSec: ts, rrMs: rr, srcCodes: src),
            "beatsPerSec=1.67 maxInSec=3 occSec=3 totBeats=5 src=none | "
                + "t0=100 0s[1199,1200,1201] +1s[1200] +2s[1198]")
    }

    /// Distinct interval trains (a full ~1200 ms beat beside a ~600 ms one, every second): the sample shows
    /// `[600,1200]` — NOT copies of one beat, so a genuine second stream, not a de-dupable duplicate. The
    /// two shapes are what the maintainer needs to tell apart to pick the fix.
    func testDensestSampleShowsDistinctTrains() {
        let ts = [100, 100, 101, 101, 102, 102]
        let rr: [Double] = [1200, 600, 1200, 600, 1200, 600]
        let src: [Int?] = [nil, nil, nil, nil, nil, nil]
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(tsSec: ts, rrMs: rr, srcCodes: src),
            "beatsPerSec=2.00 maxInSec=2 occSec=3 totBeats=6 src=none | "
                + "t0=100 0s[600,1200] +1s[600,1200] +2s[600,1200]")
    }

    /// A non-null srcChannel is surfaced as `@code`, and `src=` lists the distinct codes — so a tagged (Oura
    /// #1071) stream is obvious, and `src=none` on a WHOOP night confirms that machinery does NOT apply.
    func testDensestSampleSurfacesSrcChannelTags() {
        let ts = [100, 100]
        let rr: [Double] = [1000, 1000]
        let src: [Int?] = [1, 2]
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(tsSec: ts, rrMs: rr, srcCodes: src),
            "beatsPerSec=2.00 maxInSec=2 occSec=1 totBeats=2 src=1/2 | t0=100 0s[1000@1,1000@2]")
    }

    /// Nothing to sample (< 2 beats) → empty string, so the engine emits no `hrv rrsample` line.
    func testDensestSampleEmptyForTooFewBeats() {
        XCTAssertEqual(HRVAnalyzer.densestSecondWindowSample(tsSec: [], rrMs: [], srcCodes: []), "")
        XCTAssertEqual(HRVAnalyzer.densestSecondWindowSample(tsSec: [100], rrMs: [1000], srcCodes: [nil]), "")
    }

    // Parity edge cases — the SAME literal strings are asserted in the Kotlin twin, so ties, truncation,
    // short srcCodes, and half-value rounding are pinned byte-for-byte across platforms.

    /// Densest-second TIE (100 & 101 both hold 2) resolves to the EARLIEST ts; equal rrMs order by index.
    func testDensestSampleTieResolvesToEarliestSecond() {
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(
                tsSec: [100, 100, 101, 101, 102], rrMs: [1000, 1000, 1000, 1000, 999],
                srcCodes: [nil, nil, nil, nil, nil]),
            "beatsPerSec=1.67 maxInSec=2 occSec=3 totBeats=5 src=none | t0=100 0s[1000,1000] +1s[1000,1000] +2s[999]")
    }

    /// A runaway second is truncated to maxRowsPerSecond with a `+K` remainder marker.
    func testDensestSampleTruncatesRunawaySecond() {
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(
                tsSec: [50, 50, 50, 50, 50, 51], rrMs: [700, 710, 720, 730, 740, 1000],
                srcCodes: [nil, nil, nil, nil, nil, nil], maxRowsPerSecond: 3),
            "beatsPerSec=3.00 maxInSec=5 occSec=2 totBeats=6 src=none | t0=50 0s[700,710,720,+2] +1s[1000]")
    }

    /// srcCodes SHORTER than the beat list is index-guarded (no crash), and only the tagged beat shows `@`.
    func testDensestSampleShortSrcCodesAreIndexGuarded() {
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(tsSec: [10, 10, 11], rrMs: [1000, 1000, 1000], srcCodes: [3]),
            "beatsPerSec=1.50 maxInSec=2 occSec=2 totBeats=3 src=3 | t0=10 0s[1000@3,1000] +1s[1000]")
    }

    /// beatsPerSec at an exact half (3 beats / 2 seconds = 1.50) folds identically on both platforms.
    func testDensestSampleHalfValueBeatsPerSecRounding() {
        XCTAssertEqual(
            HRVAnalyzer.densestSecondWindowSample(tsSec: [200, 200, 201], rrMs: [900, 900, 900],
                srcCodes: [nil, nil, nil]),
            "beatsPerSec=1.50 maxInSec=2 occSec=2 totBeats=3 src=none | t0=200 0s[900,900] +1s[900]")
    }
}
