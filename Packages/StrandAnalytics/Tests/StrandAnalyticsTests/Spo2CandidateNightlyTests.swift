import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// #112 / #103 — the nightly windowed SpO2 from the 5/MG @82 byte (wearable5.0 FINDINGS §13).
///
/// Byte-parity twin of the Kotlin `Spo2CandidateNightlyTest`: same fixtures, same expected values. The strap
/// measures in 30 s windows; each window with enough in-band seconds yields its median and the night is
/// the mean of those medians. These pin what counts and, more importantly, what does not.
final class Spo2CandidateNightlyTests: XCTestCase {

    private func session(_ start: Int, _ durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60)
    }

    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }

    /// One window of consecutive seconds starting at `start`.
    private func window(_ start: Int, _ values: [Int?]) -> [V18AuxSample] {
        values.enumerated().map { aux(start + $0.offset, $0.element) }
    }

    func testOneWindowYieldsItsMedian() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 3600)], aux: window(1100, [94, 95, 96, 96, 96, 97, 97, 97, 98, 97]))
        XCTAssertEqual(r?.mean, 97)        // median (96 + 97) / 2 = 96.5, rounded half up
        XCTAssertEqual(r?.samples, 10)
    }

    func testNightIsTheMeanOfWindowMedians() {
        let a = window(1100, [96, 96, 96, 96, 96]) + window(2300, [99, 99, 99, 99, 99, 99, 99])
        let r = AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 3600)], aux: a)
        XCTAssertEqual(r?.mean, 98)        // (96 + 99) / 2 = 97.5, not the per-second mean 97.75
        XCTAssertEqual(r?.samples, 12)
    }

    /// Status codes (sub-70 and bit-7 values) stay in the window but never count as readings; a window
    /// with fewer than five in-band seconds is dropped instead of weighing like a full one.
    func testCodesAndThinWindowsDoNotCount() {
        let full = window(1100, [160, 95, 128, 95, 95, 32, 96, 95])
        let thin = window(2300, [78, 160, 128, 16])
        let r = AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 3600)], aux: full + thin)
        XCTAssertEqual(r?.mean, 95)
        XCTAssertEqual(r?.samples, 5)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 3600)], aux: thin))
    }

    /// A gap longer than two seconds ends a window, so two halves of three seconds are two thin windows.
    func testGapSplitsWindows() {
        let a = window(1100, [95, 95, 95]) + window(1106, [95, 95, 95])
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 3600)], aux: a))
    }

    func testOutsideSessionZeroAndMissingAreSkipped() {
        let a = window(500, [99, 99, 99, 99, 99]) + window(1100, [94, nil, 94, 94, 94, 94])
        let r = AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 600)], aux: a)
        XCTAssertEqual(r?.mean, 94)
        XCTAssertEqual(r?.samples, 5)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([], aux: a))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 600)], aux: []))
    }

    /// Boundaries are inclusive, matching the decoder's own 70...100 emit gate exactly.
    func testBandBoundariesMatchTheDecoderGate() {
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: window(1100, [70, 70, 100, 100, 100]))?.samples, 5)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: window(1100, [69, 69, 101, 101, 101])))
    }
}
