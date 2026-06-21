import XCTest
@testable import WhoopProtocol

/// PpgBeats — beat detection → R-R from the WHOOP 5.0 v26 PPG buffer, and the FEASIBILITY harness for
/// "can 24 Hz support RMSSD?" (the open question; `PpgHr`'s header records the contributor's "no RMSSD").
///
/// These are SYNTHETIC + deterministic: a known R-R series is rendered into a 24 Hz pulse waveform, then
/// recovered, so the recovered-vs-injected error IS the measurement. No capture fixtures, no hardware.
/// The real-world arbiter (v26 vs the strap's own v18 R-R) is a separate, fixture-driven test.
///
/// NOTE: numeric tolerances below are PROVISIONAL — set by reasoning about the 24 Hz grid + parabolic
/// refinement, not yet confirmed against a `swift test` run in this environment. Treat a failure as
/// "tighten/loosen the tolerance or the detector," not necessarily "the idea is wrong."
final class PpgBeatsTests: XCTestCase {
    private let fs = PpgBeats.sampleRateHz   // 24

    // MARK: - Synthetic signal helpers

    /// Render beat times (seconds) into an fs-Hz pulse waveform over [0, durationSec): each beat is a
    /// narrow systolic bump (Gaussian, ~0.12 s). Returns integer ADC-like counts.
    private func synthPPG(beatTimesSec: [Double], durationSec: Double, amp: Double = 1000) -> [Int] {
        let n = Int((durationSec * Double(fs)).rounded())
        let width = 0.12
        var out = [Int]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / Double(fs)
            var v = 0.0
            for bt in beatTimesSec {
                let dt = t - bt
                if abs(dt) < 0.6 { v += exp(-(dt * dt) / (2 * width * width)) }
            }
            out.append(Int((v * amp).rounded()))
        }
        return out
    }

    /// Beat times (s) from an R-R series (ms), starting at `startSec`.
    private func beatTimes(rrMs: [Double], startSec: Double = 0.5) -> [Double] {
        var t = startSec
        var out = [t]
        for rr in rrMs { t += rr / 1000.0; out.append(t) }
        return out
    }

    /// Split a flat sample stream into per-second v26 records (fs samples each).
    private func records(_ samples: [Int], baseTs: Int = 1_000_000) -> [(ts: Int, samples: [Int])] {
        var out = [(ts: Int, samples: [Int])]()
        var idx = 0, sec = 0
        while idx + fs <= samples.count {
            out.append((ts: baseTs + sec, samples: Array(samples[idx..<idx + fs])))
            idx += fs; sec += 1
        }
        return out
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// RMSSD (ms) of an R-R series — inlined so the test needs no StrandAnalytics dependency.
    private func rmssd(_ rr: [Double]) -> Double {
        guard rr.count >= 2 else { return 0 }
        var sumSq = 0.0
        for k in 1..<rr.count { let d = rr[k] - rr[k - 1]; sumSq += d * d }
        return (sumSq / Double(rr.count - 1)).squareRoot()
    }

    // MARK: - 1. Sub-sample refinement recovers a known parabola vertex

    func testRefinePeakRecoversFractionalVertex() {
        // Downward parabola peaking at index 5.3; the integer max is at i = 5.
        let vertex = 5.3
        let x = (0..<11).map { -pow(Double($0) - vertex, 2) }
        XCTAssertEqual(PpgBeats.refinePeakIndex(x, 5), vertex, accuracy: 0.02,
                       "parabolic interpolation must recover sub-sample peak position")
    }

    // MARK: - 2. Constant R-R recovered near truth

    func testConstantRRRecovered() {
        let rrTrue = 800.0                                   // 75 bpm
        let bts = beatTimes(rrMs: Array(repeating: rrTrue, count: 60))   // ~48 s
        let rr = PpgBeats.deriveRR(records: records(synthPPG(beatTimesSec: bts, durationSec: 49)))
        XCTAssertGreaterThan(rr.count, 40, "should recover most beats over ~48 s")
        XCTAssertEqual(median(rr), rrTrue, accuracy: 20.0, "median recovered R-R within ~half a 24 Hz sample")
    }

    // MARK: - 3. THE feasibility measurement — known RMSSD in, RMSSD out at 24 Hz

    func testRecoversInjectedRMSSD() {
        // A deterministic, physiologically-plausible R-R series with real beat-to-beat variability.
        let rrTrue: [Double] = [780, 825, 795, 815, 770, 830, 800, 810, 785, 820,
                                790, 835, 775, 805, 815, 780, 825, 795, 810, 790,
                                830, 785, 815, 800, 820, 775, 810, 795, 825, 790,
                                805, 835, 780, 815, 800, 820, 785, 810, 795, 830]
        let injected = rmssd(rrTrue)                          // ~30 ms class
        let bts = beatTimes(rrMs: rrTrue)
        let dur = (bts.last ?? 1) + 0.6
        let rr = PpgBeats.deriveRR(records: records(synthPPG(beatTimesSec: bts, durationSec: dur)))
        XCTAssertGreaterThanOrEqual(rr.count, 30, "need enough beats to estimate RMSSD")
        let recovered = rmssd(rr)
        // The measurement: how close can 24 Hz + parabolic refinement get to a ~30 ms RMSSD? If this gap
        // is large even on CLEAN synthetic data, that quantifies the contributor's "no RMSSD" claim.
        XCTAssertEqual(recovered, injected, accuracy: 15.0,
                       "recovered RMSSD \(recovered) vs injected \(injected) — the 24 Hz feasibility figure")
    }

    // MARK: - 4. #194 guards — not pinned to the record rate

    func testDifferentHeartRatesSeparate() {
        let slow = PpgBeats.deriveRR(records: records(
            synthPPG(beatTimesSec: beatTimes(rrMs: Array(repeating: 1200, count: 40)), durationSec: 50)))  // 50 bpm
        let fast = PpgBeats.deriveRR(records: records(
            synthPPG(beatTimesSec: beatTimes(rrMs: Array(repeating: 600, count: 90)), durationSec: 56)))   // 100 bpm
        let mSlow = median(slow), mFast = median(fast)
        // A lag-24 (=1000 ms) artifact would pin BOTH near 1000; real detection must separate them.
        XCTAssertGreaterThan(mSlow, 1050, "50 bpm must recover ~1200 ms, not collapse toward 1000")
        XCTAssertLessThan(mFast, 750, "100 bpm must recover ~600 ms, not collapse toward 1000")
    }

    func testSixtyBpmNotSnapped() {
        // 60 bpm: period = 24 samples = the record rate — the exact #194 danger zone. A SMOOTH pulse here
        // must survive (removeRecordRateComponent only de-combs a DISCONTINUOUS boundary artifact).
        let rr = PpgBeats.deriveRR(records: records(
            synthPPG(beatTimesSec: beatTimes(rrMs: Array(repeating: 1000, count: 45)), durationSec: 47)))
        XCTAssertEqual(median(rr), 1000.0, accuracy: 25.0, "a true 60 bpm must not be erased or snapped")
    }
}
