import XCTest
@testable import StrandAnalytics
import WhoopProtocol   // RRInterval

/// #977 — the RSA respiratory-rate path must not splice across dropped beats.
///
/// `respRateFromRR` rebuilds beat times by cumulatively summing RR, which cannot represent a stretch
/// where no beats arrived: a 30–45 s dropout is stitched shut and the two sides become adjacent on the
/// beat-time axis, so the tachogram gets a discontinuity the peak-picker reads as a breath. The reporter
/// measured Σ(rrMs) ÷ wall-clock of 0.859 on one WHOOP 5 corpus — one wearer, one strap, so an existence
/// proof that dropouts reach this magnitude, not a population figure.
///
/// The signal is `ts`, and only `ts`: these beats were lost before storage, so they were never in the
/// array to be marked, and `cleanRRGapAware` — which takes `[Double]` and has no clock — cannot see them.
///
/// Every vector here is synthetic and says so. Inventing a "real capture" for a timing bug would be
/// worse than useless: the property under test is the relationship between `ts` and Σ RR, which a
/// fabricated capture would assert by construction.
final class RespRateGapAwareTests: XCTestCase {

    /// ~15 breaths/min of RSA on ~900 ms beats, with `ts` advancing consistently with the intervals.
    /// `gapAfter` inserts a wall-clock jump of `gapS` after that beat index WITHOUT adding beats —
    /// exactly what a dropout looks like in the store.
    private func series(beats: Int, gapAfter: Int? = nil, gapS: Int = 40) -> [RRInterval] {
        var rows: [RRInterval] = []
        var t = 1_000_000
        var carryMs = 0.0
        for i in 0..<beats {
            let rr = 900.0 + 60.0 * sin(2.0 * Double.pi * Double(i) * 0.9 / 4.0)
            carryMs += rr
            if let g = gapAfter, i == g { t += gapS }
            rows.append(RRInterval(ts: t, rrMs: Int(rr.rounded())))
            if carryMs >= 1000 { t += Int(carryMs / 1000); carryMs -= Double(Int(carryMs / 1000)) * 1000 }
        }
        return rows
    }

    /// A contiguous night is untouched. This is the regression guard: the change must alter nothing when
    /// the clock and the beats agree, or it would move every existing user's reported rate.
    func testContiguousNightStillProducesARate() {
        // 330 beats at ~0.9 s is ~297 s, which is ONE ~5-min window (nGrid 1189 < windowSamples 1200).
        // Sized deliberately: with two windows a splice in the first would leave the second to carry the
        // median, and the test would pass whether or not the skip worked.
        let rr = series(beats: 330)
        let rate = SleepStager.respRateFromRR(rr, start: 0, end: 2_000_000)
        XCTAssertFalse(rate.isNaN, "a clean series must still yield a rate")
        XCTAssertTrue((6.0...24.0).contains(rate), "expected a plausible breathing rate, got \(rate)")
    }

    /// The same beat VALUES, with a 40 s wall-clock hole punched in the middle: the only difference is
    /// `ts`. Before this fix the two inputs were indistinguishable, because `ts` was dropped before the
    /// cumulative sum. Now the spliced window is skipped, and with a single window's worth of beats that
    /// leaves nothing to take a median over — NaN, which is the honest answer rather than a fabricated one.
    func testASplicedWindowIsNotMeasured() {
        let clean = series(beats: 330)
        let spliced = series(beats: 330, gapAfter: 165)
        XCTAssertEqual(clean.map(\.rrMs), spliced.map(\.rrMs), "the fixture must differ only in ts")
        XCTAssertTrue(SleepStager.respRateFromRR(spliced, start: 0, end: 2_000_000).isNaN)
    }

    /// A one-second discrepancy is `ts` quantisation, not a dropout: `ts` is whole seconds while beats
    /// are sub-second, so a strict "any disagreement is a gap" rule would reject every ordinary night.
    func testSecondLevelJitterIsNotTreatedAsAGap() {
        let jittered = series(beats: 330, gapAfter: 165, gapS: 1)
        XCTAssertFalse(SleepStager.respRateFromRR(jittered, start: 0, end: 2_000_000).isNaN)
    }

    /// The row filter must keep exactly what `HRVAnalyzer.rangeFilter` keeps — the fix filters rows
    /// rather than values to retain `ts`, and that equivalence is the reason it is safe.
    func testRowFilterMatchesRangeFilter() {
        let raw: [Double] = [250, 300, 900, 1500, 2000, 2001, 45]
        let viaRange = HRVAnalyzer.rangeFilter(raw)
        let viaRows = raw.filter { $0 >= HRVAnalyzer.rrMinMs && $0 <= HRVAnalyzer.rrMaxMs }
        XCTAssertEqual(viaRange, viaRows)
    }
}
