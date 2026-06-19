import XCTest
@testable import StrandAnalytics

/// Pins the L1 `ResonanceEngine`: synthetic R-R with a known RSA peak injected at one pace → the engine
/// selects that pace; a too-few-beats pace → unscored; fewer than N scored paces → the honest "no lock"
/// fallback to 5.5. These are the GOLDEN VECTORS the Kotlin `ResonanceEngineTest` mirrors.
/// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L1).
final class ResonanceEngineTests: XCTestCase {

    /// Generate a paced candidate's R-R: a steady baseline R-R with a once-per-breath-cycle sinusoid-like
    /// swing of `swingMs` peak-to-trough, sampled at ~1 beat/sec over `durationSec`. A larger `swingMs`
    /// means a larger RSA amplitude. Beats start at `startTs`; the scorer drops the first 30 s transient.
    /// Deterministic + integer so Swift and Kotlin generate the IDENTICAL series.
    private func pacedBeats(bpm: Double, baselineMs: Int, swingMs: Int,
                            startTs: Int, durationSec: Int) -> [ResonanceEngine.RrBeat] {
        let cycleSec = 60.0 / bpm
        var out: [ResonanceEngine.RrBeat] = []
        var t = startTs
        let end = startTs + durationSec
        while t <= end {
            // Triangle wave over the breath cycle: phase 0→0.5 rises +half, 0.5→1 falls −half.
            let phase = (Double(t - startTs).truncatingRemainder(dividingBy: cycleSec)) / cycleSec
            let tri = phase < 0.5 ? (phase * 2.0) : (2.0 - phase * 2.0)   // 0→1→0
            // Map tri 0..1 onto −half..+half of the swing, integer.
            let delta = Int((tri - 0.5) * Double(swingMs))
            out.append(ResonanceEngine.RrBeat(ts: t, rrMs: baselineMs + delta))
            t += 1
        }
        return out
    }

    // GOLDEN: three paces, the MIDDLE (5.5) carries the biggest swing → it must be locked.
    func test_golden_selects_max_rsa_pace() {
        let samples = [
            ResonanceEngine.PaceSample(bpm: 4.5,
                rr: pacedBeats(bpm: 4.5, baselineMs: 900, swingMs: 40, startTs: 0, durationSec: 150),
                startTs: 0, endTs: 150),
            ResonanceEngine.PaceSample(bpm: 5.5,
                rr: pacedBeats(bpm: 5.5, baselineMs: 900, swingMs: 120, startTs: 1000, durationSec: 150),
                startTs: 1000, endTs: 1150),
            ResonanceEngine.PaceSample(bpm: 6.5,
                rr: pacedBeats(bpm: 6.5, baselineMs: 900, swingMs: 40, startTs: 2000, durationSec: 150),
                startTs: 2000, endTs: 2150),
        ]
        let result = ResonanceEngine.sweep(samples)
        XCTAssertTrue(result.didLock)
        XCTAssertEqual(result.lockedBpm, 5.5)
        // The 5.5 pace has the largest RSA amplitude of the three scored paces.
        let rsa55 = result.scores.first { $0.bpm == 5.5 }?.rsaAmplitude
        let rsa45 = result.scores.first { $0.bpm == 4.5 }?.rsaAmplitude
        XCTAssertNotNil(rsa55)
        XCTAssertNotNil(rsa45)
        XCTAssertGreaterThan(rsa55!, rsa45!)
    }

    // A pace with too few clean beats is UNSCORED (rsaAmplitude nil).
    func test_too_few_beats_pace_is_unscored() {
        // Only ~10 beats total in the window, well under minBeats (20) — even before transient drop.
        let sparse = (0..<10).map { ResonanceEngine.RrBeat(ts: 40 + $0, rrMs: 900) }
        let score = ResonanceEngine.scorePace(
            ResonanceEngine.PaceSample(bpm: 5.5, rr: sparse, startTs: 0, endTs: 200))
        XCTAssertNil(score.rsaAmplitude)
        XCTAssertFalse(score.scored)
    }

    // Fewer than minScoredPaces (3) scored → honest "no lock", fall back to 5.5.
    func test_no_lock_fallback_to_5p5() {
        let good = ResonanceEngine.PaceSample(bpm: 6.0,
            rr: pacedBeats(bpm: 6.0, baselineMs: 900, swingMs: 60, startTs: 0, durationSec: 150),
            startTs: 0, endTs: 150)
        // Two sparse (unscorable) paces.
        let sparseA = ResonanceEngine.PaceSample(bpm: 4.5,
            rr: (0..<5).map { ResonanceEngine.RrBeat(ts: 1040 + $0, rrMs: 900) },
            startTs: 1000, endTs: 1200)
        let sparseB = ResonanceEngine.PaceSample(bpm: 7.0,
            rr: (0..<5).map { ResonanceEngine.RrBeat(ts: 2040 + $0, rrMs: 900) },
            startTs: 2000, endTs: 2200)
        let result = ResonanceEngine.sweep([good, sparseA, sparseB])
        XCTAssertFalse(result.didLock)
        XCTAssertEqual(result.lockedBpm, ResonanceEngine.fallbackBpm)
        XCTAssertEqual(result.lockedBpm, 5.5)
    }

    // The transient drop excludes the first 30 s: beats before startTs+30 don't enter the steady window.
    func test_transient_drop_excludes_early_beats() {
        // A flat (no-swing) pace → RSA ~0 but still scorable if enough beats survive the transient.
        let flat = pacedBeats(bpm: 5.5, baselineMs: 900, swingMs: 0, startTs: 0, durationSec: 150)
        let score = ResonanceEngine.scorePace(
            ResonanceEngine.PaceSample(bpm: 5.5, rr: flat, startTs: 0, endTs: 150))
        // Flat series → zero swing per cycle → RSA amplitude 0 (scored, just no RSA).
        if let rsa = score.rsaAmplitude {
            XCTAssertEqual(rsa, 0, accuracy: 1e-9)
        }
        // Clean-beat count reflects only the post-transient window (≤ 121 beats: ts 30..150).
        XCTAssertLessThanOrEqual(score.cleanBeats, 121)
    }
}
