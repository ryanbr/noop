import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// #950 — TRIMP must weight each HR reading by its OWN gap, not by one factor guessed from the window's
/// first two timestamps.
///
/// The report: a hard ride showed Effort 6.9 while the day around it showed 14, computed from the same
/// samples. The old code inferred ONE per-sample duration from `hr[1].ts - hr[0].ts` and multiplied the
/// whole zone-weight sum by it. NOOP's stream is not uniformly spaced — live Bluetooth ~1 s, banked 5/MG
/// history ~30 s, dropouts larger — so whichever gap came first set the scale for the entire window, and
/// the workout window and the day window (different first samples) got different scales.
///
/// Twin of Kotlin `StrainSampleDurationTest` — same fixtures, same expected values.
final class StrainSampleDurationTests: XCTestCase {

    private let rest = 60.0
    private let maxHR = 190.0
    private var reserve: Double { maxHR - rest }

    /// A bpm solidly in Edwards zone 4 (85% HRR).
    private var hard: Int { Int(rest + 0.85 * reserve) }

    private func series(_ ts: Int...) -> [HRSample] { ts.map { HRSample(ts: $0, bpm: hard) } }

    private func uniform(_ n: Int, stepS: Int) -> [HRSample] {
        (0..<n).map { HRSample(ts: $0 * stepS, bpm: hard) }
    }

    // MARK: - the invariant that keeps every pre-existing strain test green

    /// Uniform spacing: per-sample gaps all equal the first gap, so TRIMP is byte-identical to the old
    /// single-factor code. This is why the fix moves no existing assertion.
    func testUniformSeriesIsByteIdenticalToTheOldComputation() {
        let hr = uniform(120, stepS: 30)
        var w = 0
        for s in hr { w += StrainScorer.zoneWeight(Double(s.bpm), restingHR: rest, hrReserve: reserve) }
        let oldTrimp = Double(w) * StrainScorer.sampleDurationMinutes(hr)
        let newTrimp = StrainScorer.edwardsTRIMP(hr, restingHR: rest, hrReserve: reserve,
                                                 durations: StrainScorer.sampleDurationsMinutes(hr))
        XCTAssertEqual(oldTrimp, newTrimp, accuracy: 1e-9)
        XCTAssertEqual(newTrimp, 240.0, accuracy: 1e-9)   // 120 samples x zone-4 weight x 0.5 min
    }

    // MARK: - the reported defect

    /// The #950 shape: a few 1 s live samples, then 30 s banked history. The old code scaled the whole
    /// hour by the 1 s first gap and lost ~96% of the effort; per-sample gaps recover it.
    func testMixedCadenceNoLongerCollapsesTheWindow() {
        let live = (0..<10).map { HRSample(ts: $0, bpm: hard) }
        let banked = (0..<120).map { HRSample(ts: 60 + $0 * 30, bpm: hard) }
        let hr = live + banked
        let trimp = StrainScorer.edwardsTRIMP(hr, restingHR: rest, hrReserve: reserve,
                                              durations: StrainScorer.sampleDurationsMinutes(hr))
        // Old: (10+120) x 4 x (1/60) = 8.67. New: the banked hour carries its real half-minute weights.
        XCTAssertGreaterThan(trimp, 230.0)
    }

    /// The workout window and the day containing it must agree: appending low-HR context around a hard
    /// window may only ADD effort, never shrink what the window alone scores. Under the old code the day
    /// could score a fraction of its own workout purely from a different first gap.
    func testAddingContextAroundAWindowNeverShrinksItsTrimp() {
        let workout = (0..<120).map { HRSample(ts: 1000 + $0 * 30, bpm: hard) }
        let idleBefore = (0..<60).map { HRSample(ts: $0, bpm: 55) }
        let day = idleBefore + workout
        let w = StrainScorer.edwardsTRIMP(workout, restingHR: rest, hrReserve: reserve,
                                          durations: StrainScorer.sampleDurationsMinutes(workout))
        let d = StrainScorer.edwardsTRIMP(day, restingHR: rest, hrReserve: reserve,
                                          durations: StrainScorer.sampleDurationsMinutes(day))
        XCTAssertGreaterThanOrEqual(d, w - 1e-9)
    }

    // MARK: - the clamp

    /// A dropout gap is capped: one reading before a 3 h hole may carry at most `maxSampleGapMin`, not
    /// the whole hole — otherwise a single zone-5 sample invents hours of effort.
    func testDropoutGapIsClampedNotCredited() {
        let durations = StrainScorer.sampleDurationsMinutes(series(0, 3 * 3600))
        XCTAssertEqual(durations, [StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin])
    }

    /// No genuine cadence is truncated: the clamp sits at 4x the sparsest real cadence (~30 s).
    func testThirtySecondCadenceIsNotClamped() {
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes(uniform(3, stepS: 30)), [0.5, 0.5, 0.5])
    }

    // MARK: - edges

    func testEdgesMatchTheOldFallbacks() {
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes([]), [])
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes(series(5)), [StrainScorer.fallbackSampleMin])
        // Coincident timestamps keep the 1 s fallback rather than a zero-duration sample.
        for d in StrainScorer.sampleDurationsMinutes(series(7, 7)) {
            XCTAssertEqual(d, StrainScorer.fallbackSampleMin, accuracy: 1e-9)
        }
    }
}
