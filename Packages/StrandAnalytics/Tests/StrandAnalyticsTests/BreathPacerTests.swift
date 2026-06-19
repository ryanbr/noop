import XCTest
@testable import StrandAnalytics

/// Pins the L1 `BreathPacer` cue list: a fixed `(bpm, inhaleFraction, cycles)` → an exact `[BreathCue]`
/// list (offsets, phase, loops). Pure value logic, so no strap/BLE seam is needed. These are the GOLDEN
/// VECTORS the Kotlin `BreathPacerTest` mirrors byte-for-byte — the cross-platform parity contract.
/// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md.
final class BreathPacerTests: XCTestCase {

    // GOLDEN VECTOR A: 6.0 br/min, 0.4 inhale, 2 cycles.
    // cycleMs = 60000/6 = 10000; inhaleMs = 4000.
    func test_golden_6bpm_2cycles() {
        let cues = BreathPacer.schedule(bpm: 6.0, inhaleFraction: 0.4, cycles: 2)
        XCTAssertEqual(cues, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 4000, phase: .exhale, loops: 2),
            BreathCue(offsetMs: 10000, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 14000, phase: .exhale, loops: 2),
        ])
    }

    // GOLDEN VECTOR B: 5.5 br/min (the coherence / common resonance pace), default inhale, 3 cycles.
    // cycleMs = round(60000/5.5) = round(10909.09) = 10909; inhaleMs = round(10909*0.4) = round(4363.6) = 4364.
    func test_golden_5p5bpm_3cycles_default_fraction() {
        let cues = BreathPacer.schedule(bpm: 5.5, cycles: 3)
        XCTAssertEqual(cues, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 4364, phase: .exhale, loops: 2),
            BreathCue(offsetMs: 10909, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 15273, phase: .exhale, loops: 2),
            BreathCue(offsetMs: 21818, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 26182, phase: .exhale, loops: 2),
        ])
    }

    func test_inhale_lighter_than_exhale_always() {
        for cue in BreathPacer.schedule(bpm: 4.5, cycles: 4) {
            switch cue.phase {
            case .inhale: XCTAssertEqual(cue.loops, 1)
            case .exhale: XCTAssertEqual(cue.loops, 2)
            }
        }
    }

    func test_two_cues_per_cycle_in_time_order() {
        let cues = BreathPacer.schedule(bpm: 7.0, cycles: 5)
        XCTAssertEqual(cues.count, 10)
        for i in 1..<cues.count {
            XCTAssertLessThanOrEqual(cues[i - 1].offsetMs, cues[i].offsetMs)
        }
    }

    func test_zero_or_negative_cycles_is_empty() {
        XCTAssertTrue(BreathPacer.schedule(bpm: 6.0, cycles: 0).isEmpty)
        XCTAssertTrue(BreathPacer.schedule(bpm: 6.0, cycles: -3).isEmpty)
    }

    func test_bpm_and_fraction_clamped_not_trapped() {
        // Absurd bpm clamps to [3,12]; fraction clamps to [0.1,0.9] — still a finite schedule.
        let slow = BreathPacer.schedule(bpm: 0.5, inhaleFraction: -1, cycles: 1)
        XCTAssertFalse(slow.isEmpty)
        // bpm clamps to 3 → cycleMs = 20000; fraction clamps to 0.1 → inhaleMs = 2000.
        XCTAssertEqual(slow, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 2000, phase: .exhale, loops: 2),
        ])
        let fast = BreathPacer.schedule(bpm: 99, inhaleFraction: 5, cycles: 1)
        // bpm clamps to 12 → cycleMs = 5000; fraction clamps to 0.9 → inhaleMs = 4500.
        XCTAssertEqual(fast, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 4500, phase: .exhale, loops: 2),
        ])
    }

    func test_session_duration() {
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 6.0, cycles: 2), 20000)
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 6.0, cycles: 0), 0)
    }
}
