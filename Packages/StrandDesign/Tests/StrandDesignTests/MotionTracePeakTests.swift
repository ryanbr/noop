import XCTest
import CoreGraphics
@testable import StrandDesign

/// Hoisting `peak` out of the per-epoch loops must not change a single pixel or a single word (#2283).
///
/// `peak` was a computed property that rescanned every epoch, read from inside the `map` in `points` and
/// the `filter` in `accessibilitySummary`. That is a scan per epoch: with 30-second epochs an 8-hour
/// night is ~960 of them, about 1.8 million comparisons every time the strip is laid out, repeated
/// because SwiftUI re-runs `body` on hover, animation and the 1 Hz HR tick.
///
/// These pin the OUTPUT rather than the speed. A performance change that alters what is drawn is not a
/// performance change, it is a regression, and the normalisation, the half-peak threshold and the
/// degenerate cases are exactly where a careless hoist would show it.
final class MotionTracePeakTests: XCTestCase {

    private let size = CGSize(width: 100, height: 40)

    /// The pre-hoist definitions, transcribed, so the new code is compared against the old behaviour
    /// rather than against itself.
    private func referencePoints(_ epochs: [Double]) -> [CGPoint] {
        let peak = max(epochs.max() ?? 0, 0)
        let n = epochs.count
        guard n >= 2, peak > 0 else { return [] }
        let h = size.height
        let usable = h - 2
        return epochs.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let frac = CGFloat(max(0, min(v / peak, 1)))
            return CGPoint(x: x, y: h - frac * usable)
        }
    }

    private func referenceSummary(_ epochs: [Double]) -> String {
        let peak = max(epochs.max() ?? 0, 0)
        guard peak > 0, !epochs.isEmpty else { return "no movement data" }
        let restless = epochs.filter { $0 >= peak * 0.5 }.count
        if restless == 0 { return "calm throughout" }
        let pct = Int((Double(restless) / Double(epochs.count) * 100).rounded())
        return "\(pct)% of the night had elevated movement"
    }

    private func assertMatches(_ epochs: [Double], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let peak = MotionTrace.peak(of: epochs)
        XCTAssertEqual(MotionTrace.points(in: size, epochs: epochs, peak: peak),
                       referencePoints(epochs), label, file: file, line: line)
        XCTAssertEqual(MotionTrace.accessibilitySummary(epochs: epochs, peak: peak),
                       referenceSummary(epochs), label, file: file, line: line)
    }

    func testAnOrdinaryNightIsUnchanged() {
        // 30-second epochs across eight hours, the real shape this draws.
        let epochs = (0..<960).map { i in Double((i * 37) % 100) / 10.0 }
        assertMatches(epochs, "ordinary night")
    }

    func testDegenerateNightsAreUnchanged() {
        // The cases where a careless hoist changes behaviour: dividing by a zero peak, or losing the
        // guard that keeps an empty strip flat rather than crashing.
        assertMatches([], "empty")
        assertMatches([0], "single zero epoch")
        assertMatches([4.2], "single non-zero epoch")
        assertMatches([0, 0, 0, 0], "all zero")
        assertMatches([-1, -2], "negative magnitudes clamp to a flat strip")
    }

    func testHalfPeakThresholdIsUnchanged() {
        // `accessibilitySummary` counts epochs at or above half the peak, so a value exactly on the
        // boundary is the one that would move if the peak were computed differently.
        assertMatches([10, 5, 4.999, 0], "values straddling half peak")
        assertMatches([1, 1, 1], "every epoch at the peak")
    }

    func testTheStripsOwnHelpersAgreeOnTheSamePeak() {
        // The gap these tests cannot close: nothing here checks that `body` passes the peak it computed
        // into both helpers. Pin the next best thing, that the helpers agree when handed the peak the
        // hoisted accessor produces, so a caller threading a DIFFERENT value is the only way to break it.
        let epochs: [Double] = [0, 3, 9, 4.5, 4.4, 0]
        let peak = MotionTrace.peak(of: epochs)
        XCTAssertEqual(peak, 9)
        let pts = MotionTrace.points(in: size, epochs: epochs, peak: peak)
        XCTAssertEqual(pts.count, epochs.count)
        // 9 is the peak, so it must land at the very top of the usable band, and 0 at the baseline.
        XCTAssertEqual(pts[2].y, size.height - (size.height - 2), accuracy: 0.0001)
        XCTAssertEqual(pts[0].y, size.height, accuracy: 0.0001)
        // 4.5 is exactly half the peak and counts as restless; 4.4 does not. Two of six is 33%.
        XCTAssertEqual(MotionTrace.accessibilitySummary(epochs: epochs, peak: peak),
                       "33% of the night had elevated movement")
    }

    func testPeakIgnoresNegativesAndEmpties() {
        XCTAssertEqual(MotionTrace.peak(of: []), 0)
        XCTAssertEqual(MotionTrace.peak(of: [-5, -1]), 0, "a negative peak clamps to zero")
        XCTAssertEqual(MotionTrace.peak(of: [1, 9, 3]), 9)
    }
}
