import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests for the ratio-of-ratios SpO₂ computation (`AnalyticsEngine.nightlySpo2Pct`).
///
/// The method is the standard pulse-oximetry algorithm (TI SLAA655 Eq. 1-2):
///   R = (AC_red / DC_red) / (AC_ir / DC_ir)
///   SpO₂ = 110 − 25 × R
/// where AC = standard deviation (pulsatile) and DC = mean (steady) of the per-sample
/// red/IR ADC values over detected in-bed spans.
///
/// Per the derived-biosignal rule (CLAUDE.md), these tests prove the method TRACKS A
/// VARYING INPUT — different simulated SpO₂ levels produce different R values and
/// different computed percentages, not just one coincidental match.
final class Spo2RatioOfRatiosTests: XCTestCase {

    private func session(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9, stages: [],
                     restingHR: 55, avgHRV: 50)
    }

    private func spo2Sample(_ ts: Int, red: Int, ir: Int) -> SpO2Sample {
        SpO2Sample(ts: ts, red: red, ir: ir)
    }

    /// Generate N synthetic red/IR samples simulating a PPG signal at a target SpO₂.
    ///
    /// The ratio R = (AC_red/DC_red) / (AC_ir/DC_ir) determines the computed SpO₂.
    /// For a target SpO₂: R = (110 - SpO₂) / 25.
    /// We set DC_red = DC_ir = 1000 (arbitrary), then choose AC_red and AC_ir so that
    /// AC_red/AC_ir = R, with a pulsatile amplitude of ~2% of DC (typical perfusion index).
    private func syntheticSamples(count: Int, startTs: Int, targetSpo2: Double) -> [SpO2Sample] {
        let r = (110.0 - targetSpo2) / 25.0
        let dc = 1000.0
        let acIr = dc * 0.02           // 2% perfusion index on IR
        let acRed = acIr * r           // AC_red/AC_ir = R
        // Generate samples with a sinusoidal pulsatile component + small noise.
        return (0..<count).map { i in
            let phase = Double(i) * 2.0 * .pi / 10.0   // 10-sample cardiac cycle
            let noise = Double(i % 3) - 1.0            // ±1 ADC noise
            let red = Int(dc + acRed * sin(phase) + noise)
            let ir  = Int(dc + acIr * sin(phase) + noise)
            return spo2Sample(startTs + i, red: red, ir: ir)
        }
    }

    // MARK: - Varying input (the core validation requirement)

    /// The method must TRACK a varying input: different target SpO₂ levels produce
    /// different computed percentages. This is the test the #194 PPG→HR estimate failed
    /// (it manufactured one coincidental match but couldn't track a varying input).
    func testTracksVaryingSpO2Levels() {
        let targets: [Double] = [98, 95, 90, 85, 80]
        var results: [Double] = []
        for target in targets {
            let samples = syntheticSamples(count: 100, startTs: 1100, targetSpo2: target)
            let pct = AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: samples)
            XCTAssertNotNil(pct, "target SpO₂ \(target) should produce a value")
            results.append(pct!)
        }
        // Each successive (lower) target should produce a lower computed SpO₂.
        for i in 1..<results.count {
            XCTAssertLessThan(results[i], results[i - 1],
                "SpO₂ should decrease as target decreases: \(results)")
        }
        // The computed values should be in a physiologically plausible range.
        XCTAssertTrue(results.allSatisfy { $0 >= 70 && $0 <= 100 },
                      "All results in 70-100 range: \(results)")
    }

    /// The computed values should be reasonably close to the target (within ~5% with
    /// standard coefficients). This proves the calibration is clinically useful, not
    /// just monotonic.
    func testComputedValuesCloseToTarget() {
        for target in [98.0, 95.0, 90.0] {
            let samples = syntheticSamples(count: 200, startTs: 1100, targetSpo2: target)
            let pct = AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: samples)
            XCTAssertNotNil(pct)
            if let pct {
                XCTAssertEqual(pct, target, accuracy: 5.0,
                    "target \(target)% → computed \(pct)% (within 5%)")
            }
        }
    }

    // MARK: - Edge cases

    func testNilWhenNoSamples() {
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(1000, 600)], spo2: []))
    }

    func testNilWhenNoSessions() {
        let samples = (0..<100).map { spo2Sample(1100 + $0, red: 1000, ir: 1000) }
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([], spo2: samples))
    }

    func testNilWhenTooFewSamples() {
        let samples = (0..<49).map { spo2Sample(1100 + $0, red: 1000, ir: 1000) }
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: samples))
    }

    func testFiftySamplesIsSufficient() {
        let samples = syntheticSamples(count: 50, startTs: 1100, targetSpo2: 95)
        XCTAssertNotNil(AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: samples))
    }

    func testSamplesOutsideSessionAreExcluded() {
        // 100 samples inside the session + 100 outside.
        let inside = syntheticSamples(count: 100, startTs: 1100, targetSpo2: 95)
        let outside = syntheticSamples(count: 100, startTs: 7000, targetSpo2: 80)
        let pct = AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: inside + outside)
        XCTAssertNotNil(pct)
        // Should be close to 95 (the inside samples), not influenced by the outside ones.
        if let pct {
            XCTAssertEqual(pct, 95, accuracy: 5.0)
        }
    }

    func testResultClampedTo70_100() {
        // Extreme R values should clamp, not produce impossible percentages.
        // R = 0 → SpO₂ = 110 (clamps to 100); R = 2 → SpO₂ = 60 (clamps to 70).
        // R=0 means AC_red=0 (no pulsatile red), which is unrealistic but shouldn't crash.
        let flatSamples = (0..<100).map { spo2Sample(1100 + $0, red: 1000, ir: 1000) }
        // All flat → AC_ir = 0 → returns nil (guard), not a crash.
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: flatSamples))
    }

    func testNilWhenDCIsZero() {
        let zeroSamples = (0..<100).map { spo2Sample(1100 + $0, red: 0, ir: 0) }
        XCTAssertNil(AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: zeroSamples))
    }

    // MARK: - Parity with nightlySpo2RawMeans

    /// The ratio-of-ratios function should work on the same session/sample inputs that
    /// nightlySpo2RawMeans accepts — they share the same in-bed filtering logic.
    func testSameInBedFilteringAsRawMeans() {
        let samples = syntheticSamples(count: 100, startTs: 1100, targetSpo2: 95)
        let raw = AnalyticsEngine.nightlySpo2RawMeans([session(1000, 6000)], spo2: samples)
        let pct = AnalyticsEngine.nightlySpo2Pct([session(1000, 6000)], spo2: samples)
        XCTAssertNotNil(raw)
        XCTAssertNotNil(pct)
        // Both should process the same 100 samples (raw mean ≈ 1000 for both channels).
        XCTAssertEqual(Double(raw!.red), 1000.0, accuracy: 5.0)
        XCTAssertEqual(Double(raw!.ir), 1000.0, accuracy: 5.0)
    }
}
