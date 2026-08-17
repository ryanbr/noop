import XCTest
@testable import StrandAnalytics

/// #550: the coverage pair encodes WHICH over-count a night has, and until now that reading rule lived
/// only in a comment — so triaging an "HRV reads ~2× high" report required knowing it. These pin the rule.
///
/// The real-capture vectors come from #803 (WHOOP 4.0, two consecutive nights), which is also the first
/// evidence either way on whether the same-second de-dup scoped in #550 would be sufficient. It would not.
final class RrCoverageVerdictTests: XCTestCase {

    /// #803's 2026-07-15, which this file used to call "a night whose beat-time fits the wall clock".
    /// It does not: at 0.89 an eighth of the beat-time is missing. That label was written when the
    /// classifier only looked upward, so `.plausible` was the ONLY verdict this night could receive —
    /// it recorded the absence of an over-count, not the presence of a clean capture. With a floor it
    /// reads as what it is. (#977)
    ///
    /// It lands 0.01 outside the symmetric allowance, so it is also the first case worth re-examining
    /// if real coverage distributions ever say a WHOOP 4.0 night simply runs near 0.89.
    func testNineTenthsOfANightIsNotAFitAnyMore() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.89, collapsed: 0.88), .underCovered)
    }

    /// The reported case (#977): 0.859, measured on one wearer's WHOOP 5 corpus. Previously `.plausible`,
    /// documented as "nothing to explain", for a night missing 14% of its beat-time.
    func testTheReportedUnderCoveredNightIsNamed() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.859, collapsed: 0.85), .underCovered)
    }

    /// The floor mirrors the ceiling exactly: 1.10 above, 0.90 below. Not fitted to any corpus — a
    /// number chosen to sit between 0.859 and 0.89 would be tuned to one capture, which is what the
    /// ceiling's own comment warns against.
    func testFloorMirrorsCeiling() {
        XCTAssertEqual(HRVAnalyzer.coveragePlausibleFloor, 0.90, accuracy: 1e-12)
        XCTAssertEqual(1.0 - HRVAnalyzer.coveragePlausibleFloor,
                       HRVAnalyzer.coveragePlausibleCeiling - 1.0, accuracy: 1e-12)
    }

    /// Symmetric with `testCeilingIsInclusive`: exactly at the floor still reads as fitting, a hair under
    /// does not. Both boundaries are inclusive of the "fits" band.
    func testFloorIsInclusive() {
        let floor = HRVAnalyzer.coveragePlausibleFloor
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: floor, collapsed: floor), .plausible)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: floor - 0.01, collapsed: 0.5), .underCovered)
    }

    /// A night that is almost entirely absent must not read as fitting either — the old classifier
    /// returned `.plausible` for 0.01 as readily as for 1.00.
    func testAnAlmostEmptyNightIsUnderCovered() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.01, collapsed: 0.01), .underCovered)
    }

    /// A genuinely clean night still reads as one — the guard that this did not simply invert the bug.
    func testACleanNightIsStillPlausible() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.99, collapsed: 0.98), .plausible)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 1.00, collapsed: 1.00), .plausible)
    }

    /// The night that prompted the report. #803's 2026-07-16: collapsing same-second duplicates drops it
    /// 2.54 → 1.99, which is still impossible — so the duplicates straddle second boundaries and a
    /// same-second de-dup would NOT fix it. This is the case #550 needs to know about.
    func testRealCrossSecondCaptureIsNotFixableBySameSecondDedup() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 2.54, collapsed: 1.99),
                       .crossSecondOverCount)
    }

    /// Over-covered, but the collapse brings it back in range — the extra beats share a timestamp.
    func testCollapseRecoveringRangeMeansSameSecond() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 1.60, collapsed: 1.02),
                       .sameSecondOverCount)
    }

    /// The ceiling is a rounding allowance, so exactly at it still reads as fitting; a hair over does not.
    func testCeilingIsInclusive() {
        let ceil = HRVAnalyzer.coveragePlausibleCeiling
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: ceil, collapsed: ceil), .plausible)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: ceil + 0.01, collapsed: 0.5),
                       .sameSecondOverCount)
    }

    /// `rrCoverage` returns 0 for a window it cannot measure (< 2 beats / zero span). Absence of evidence
    /// is not a clean night — calling it `plausible` would claim the capture was fine when nothing was
    /// measurable, which is exactly what this verdict exists to avoid.
    func testUnmeasurableWindowIsNotReportedAsClean() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0, collapsed: 0), .unmeasurable)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: -1, collapsed: 0), .unmeasurable)
    }

    /// Parity guard. Every IEEE-754 comparison with NaN is false, so `<=` and `>` are not each other's
    /// inverse there — writing one platform with `<=` and the other with `>` made the twins disagree on a
    /// NaN coverage (Swift said plausible, Kotlin said sameSecondOverCount). Both now negate `>`.
    func testNonFiniteCoverageIsUnmeasurableOnBothPlatforms() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: .nan, collapsed: 0.5), .unmeasurable)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: .nan, collapsed: .nan), .unmeasurable)
    }

    /// The verdict is only ever a function of the pair, never of which is larger — a collapse can never
    /// exceed the raw coverage in practice, but the classifier must not depend on that holding.
    ///
    /// #977: this expected `.plausible` before the floor existed, which was the bug rather than the
    /// intent — half the beat-time is missing at 0.5. The property under test is unchanged and is now
    /// shown more sharply: `collapsed` at 9.9 screams over-count and the verdict still follows
    /// `coverage`.
    func testCollapsedAboveCoverageStillClassifiesOnCoverageFirst() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.5, collapsed: 9.9), .underCovered)
    }

    // MARK: - Acting on the verdict: beat-spread statistics (SDNN)

    /// The whole point of the gate: an over-counted capture inflates SDNN directly, because SDNN is a
    /// spread over EVERY interval and some of those intervals are the same beat twice.
    func testOverCountedWindowsRefuseBeatSpreadStatistics() {
        XCTAssertFalse(HRVAnalyzer.beatSpreadIsTrustworthy(.sameSecondOverCount))
        XCTAssertFalse(HRVAnalyzer.beatSpreadIsTrustworthy(.crossSecondOverCount))
    }

    /// Nothing else gates. `underCovered` is a capture with holes and `unmeasurable` is what a LIVE spot
    /// reading looks like (real-time beats, no timestamps to measure coverage with) — neither duplicates
    /// a beat, and refusing them would suppress honest readings, which is the opposite of the point.
    func testGapsAndUnmeasurableWindowsStayTrusted() {
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.plausible))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.underCovered))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.unmeasurable))
    }

    /// End to end on the shape that motivated this: beats banked in bursts at their record's second
    /// (an Oura night — 6 beats per record, records ~5 s apart) cover more beat-time than wall-clock and
    /// therefore refuse SDNN, while the SAME beats stamped at the times they really occurred stay
    /// trusted. The verdict is measured from the data, never assumed from the device.
    func testBankedBeatsRefuseSpreadWhileTheSameBeatsHonestlySpacedDoNot() {
        let beat = 1000.0                       // 60 bpm
        let rr = [Double](repeating: beat, count: 60)

        // Honest: one beat per second, so beat-time ~= wall-clock (the whole-second stamps cost the
        // final interval, which is what the ceiling's rounding allowance exists for).
        let honestTs = (0..<60).map { $0 }
        let honest = HRVAnalyzer.classifyCoverage(
            coverage: HRVAnalyzer.rrCoverage(tsSec: honestTs, rrMs: rr),
            collapsed: HRVAnalyzer.collapsedCoverage(tsSec: honestTs, rrMs: rr))
        XCTAssertEqual(honest, .plausible)
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(honest))

        // Banked: the same 60 beats delivered as 10 records of 6, each record stamping all six of its
        // beats at its own second, records 5 s apart. 60 s of beat-time inside a 45 s span.
        let bankedTs = (0..<60).map { ($0 / 6) * 5 }
        let banked = HRVAnalyzer.classifyCoverage(
            coverage: HRVAnalyzer.rrCoverage(tsSec: bankedTs, rrMs: rr),
            collapsed: HRVAnalyzer.collapsedCoverage(tsSec: bankedTs, rrMs: rr))
        XCTAssertFalse(HRVAnalyzer.beatSpreadIsTrustworthy(banked), "verdict was \(banked)")
    }

    // MARK: - The second, independent fault: beat-VALUE accuracy (P7')

    /// A beat-accurate stream steps one interval per beat, so each wall-clock gap equals its own R-R
    /// value and the fraction is 1.0. This is what WHOOP R-R and the synthetic fixtures look like.
    func testBeatAccurateStreamMeasuresFully() {
        let rr = [Double](repeating: 1000.0, count: 60)     // 60 bpm, one beat per second
        let ts = (0..<60).map { $0 }
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr), 1.0, accuracy: 1e-9)
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(
            beatAccurateFraction: HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr)))
    }

    /// A BANKED stream stamps a whole record of intervals on one timestamp, so nearly every gap is 0 s
    /// against a ~1 s value. Six beats per record: five of every six gaps are 0, so the fraction lands
    /// far below the boundary — the shape every measured Oura night has (2.6-6.6%).
    func testBankedStreamIsNotBeatAccurateAndRefusesBeatValues() {
        let rr = [Double](repeating: 1000.0, count: 60)
        let ts = (0..<60).map { ($0 / 6) * 7 }              // 10 records of 6, 7 s apart
        let frac = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr)
        XCTAssertLessThan(frac, HRVAnalyzer.beatAccuracyMinFraction)
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: frac))
    }

    /// **The case that motivated P7'.** The two faults are INDEPENDENT: this stream is perfectly
    /// covered — one interval of beat-time per second of wall clock, so `classifyCoverage` says
    /// `plausible` and the over-count gate passes it — yet the beats are banked six to a record, so
    /// their individual values are a decomposition of a record period rather than beat-to-beat
    /// measurements. The 2026-08-06 Oura night is exactly this shape (coverage 1.03, `plausible`,
    /// SDNN 174 ms) and the over-count gate alone let it through.
    func testAPerfectlyCoveredBankedNightStillRefusesBeatValues() {
        // 10 records of 6 beats, records 7 s apart, so the span is 9 * 7 = 63 s. Sixty intervals of
        // 1050 ms are exactly 63 s of beat-time: coverage lands on 1.0 while five of every six gaps
        // are still 0 s. (Coverage is measured across the first-to-last STAMP, so the beat-time has to
        // match that span, not the record count times the record period.)
        let rr = [Double](repeating: 63_000.0 / 60.0, count: 60)
        let ts = (0..<60).map { ($0 / 6) * 7 }
        let verdict = HRVAnalyzer.classifyCoverage(
            coverage: HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr),
            collapsed: HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(verdict),
                      "the over-count gate must PASS this — that is the point (verdict \(verdict))")
        let frac = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr)
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: frac),
                       "the beat-value gate must REFUSE it (fraction \(frac))")
    }

    /// A live spot reading carries no timestamps, so there is nothing to measure and nothing to refuse:
    /// too-short input returns 1.0 and stays trusted. Suppressing honest live readings is the exact
    /// failure this gate must not introduce.
    func testTooShortOrMismatchedInputStaysTrusted() {
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [], rrMs: []), 1.0)
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [5], rrMs: [1000]), 1.0)
        // Mismatched lengths cannot be paired up; refusing on that would be guessing.
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [0, 1, 2], rrMs: [1000]), 1.0)
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: 1.0))
    }

    /// NaN means "not measured", and an unmeasured window must not be silently refused — the same
    /// negated-comparison convention `classifyCoverage` uses so both platforms fold NaN identically.
    func testNaNAccuracyStaysTrusted() {
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: .nan))
    }

    /// The boundary itself: exactly at the minimum is trusted, just below is not.
    func testBoundaryIsInclusive() {
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(
            beatAccurateFraction: HRVAnalyzer.beatAccuracyMinFraction))
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(
            beatAccurateFraction: HRVAnalyzer.beatAccuracyMinFraction - 0.01))
    }

    // MARK: - Spot-capture beat time vs. wall clock

    /// ~700 beats of ~850 ms ≈ 595 s of beat time — impossible in a 60-second window. Twin of
    /// Kotlin `spotCaptureRejectsMoreBeatTimeThanElapsedTime`.
    func testSpotCaptureRejectsMoreBeatTimeThanElapsedTime() {
        let beatTimeMs = (0..<700).reduce(0.0) { sum, i in sum + 830.0 + Double(i % 5) * 10.0 }
        XCTAssertTrue(HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: beatTimeMs, captureMs: 60_000))
    }

    /// ~70 beats of 850 ms ≈ 59.5 s of beat time in 60 s — a normal seated reading stays trusted.
    func testSpotCaptureAcceptsAPlausibleWindow() {
        XCTAssertFalse(HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: 70 * 850.0, captureMs: 60_000))
    }

    /// Exactly at the shared `coveragePlausibleCeiling` stays trusted — the ceiling is a rounding
    /// allowance and the gate uses strict `>` like `classifyCoverage`.
    func testSpotCaptureToleratesTheRoundingAllowance() {
        let atCeiling = 60_000 * HRVAnalyzer.coveragePlausibleCeiling
        XCTAssertFalse(HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: atCeiling, captureMs: 60_000))
        XCTAssertTrue(HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: atCeiling + 1, captureMs: 60_000))
    }

    /// No wall clock to hold the beats against — never reject on a degenerate duration.
    func testSpotCaptureWithZeroElapsedTimeIsNotJudged() {
        XCTAssertFalse(HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: 1_000, captureMs: 0))
    }
}
