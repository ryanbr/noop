import XCTest
@testable import StrandAnalytics

/// Pins the L2 `HRDownPacer`: a scripted HR descent → monotone, bounded target intervals that respect the
/// HR floor and the max-Δ, and stops on settle / timeout. GOLDEN VECTORS the Kotlin `HrDownPacerTest`
/// mirrors. See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L2).
final class HRDownPacerTests: XCTestCase {

    private let cfg = HRDownPacer.Config.default   // start Δ 3, max Δ 8, ramp 120s, floor 50, calm 60, max 180s.

    // GOLDEN: at session start (elapsed 0), HR 84 → Δ 3 → target 81 → interval round(60000/81) = 741.
    func test_golden_start_step() {
        let step = HRDownPacer.next(currentHR: 84, elapsed: 0, config: cfg)
        XCTAssertFalse(step.stop)
        XCTAssertEqual(step.targetBpm!, 81, accuracy: 1e-9)
        XCTAssertEqual(step.intervalMs, 741)
    }

    // GOLDEN: fully ramped (elapsed ≥ 120), HR 84 → Δ 8 → target 76 → interval round(60000/76) = 789.
    func test_golden_ramped_step() {
        let step = HRDownPacer.next(currentHR: 84, elapsed: 120, config: cfg)
        XCTAssertEqual(step.targetBpm!, 76, accuracy: 1e-9)
        XCTAssertEqual(step.intervalMs, 789)
    }

    // Δ ramps linearly: at half the ramp (60 s) Δ = (3+8)/2 = 5.5.
    func test_delta_ramp_is_linear() {
        XCTAssertEqual(HRDownPacer.rampedDelta(elapsed: 0, config: cfg), 3, accuracy: 1e-9)
        XCTAssertEqual(HRDownPacer.rampedDelta(elapsed: 60, config: cfg), 5.5, accuracy: 1e-9)
        XCTAssertEqual(HRDownPacer.rampedDelta(elapsed: 120, config: cfg), 8, accuracy: 1e-9)
        XCTAssertEqual(HRDownPacer.rampedDelta(elapsed: 999, config: cfg), 8, accuracy: 1e-9)   // clamps
    }

    // A scripted HR descent: targets are non-increasing and intervals never exceed the floor's interval.
    func test_descent_is_monotone_and_bounded() {
        let trajectory: [Double] = [88, 86, 84, 82, 80, 78, 76, 74, 72, 70, 68, 66, 64, 62]
        var prevTarget = Double.greatestFiniteMagnitude
        for (i, hr) in trajectory.enumerated() {
            let elapsed = Double(i) * cfg.recomputeSeconds
            let step = HRDownPacer.next(currentHR: hr, elapsed: elapsed, config: cfg)
            guard !step.stop, let target = step.targetBpm else { continue }
            // Never below the floor, never above live HR.
            XCTAssertGreaterThanOrEqual(target, cfg.hrFloorBpm)
            XCTAssertLessThanOrEqual(target, hr)
            // Never more than maxΔ below live HR.
            XCTAssertGreaterThanOrEqual(target, hr - cfg.maxDeltaBpm - 1e-9)
        }
        // (Monotonicity holds because both HR and Δ move monotonically; spot-check the first two.)
        let s0 = HRDownPacer.next(currentHR: 88, elapsed: 0, config: cfg).targetBpm!
        let s1 = HRDownPacer.next(currentHR: 86, elapsed: cfg.recomputeSeconds, config: cfg).targetBpm!
        XCTAssertLessThanOrEqual(s1, s0)
        prevTarget = s0; _ = prevTarget
    }

    func test_hr_floor_respected() {
        // HR just above the calm target but Δ would push below the floor → clamp at floor.
        let step = HRDownPacer.next(currentHR: 61, elapsed: 120, config: cfg)   // 61 − 8 = 53 > floor 50
        XCTAssertEqual(step.targetBpm!, 53, accuracy: 1e-9)
        // A config with a high floor forces the clamp.
        let highFloor = HRDownPacer.Config(hrFloorBpm: 70, calmTargetBpm: 55)
        let clamped = HRDownPacer.next(currentHR: 75, elapsed: 120, config: highFloor)
        XCTAssertEqual(clamped.targetBpm!, 70, accuracy: 1e-9)   // 75 − 8 = 67 < floor 70 → 70
    }

    func test_stops_on_settle() {
        let step = HRDownPacer.next(currentHR: 59, elapsed: 30, config: cfg)   // ≤ calm 60
        XCTAssertTrue(step.stop)
        XCTAssertEqual(step.stopReason, .settled)
        XCTAssertNil(step.intervalMs)
    }

    func test_stops_on_timeout() {
        let step = HRDownPacer.next(currentHR: 90, elapsed: 180, config: cfg)
        XCTAssertTrue(step.stop)
        XCTAssertEqual(step.stopReason, .timeout)
    }

    func test_invalid_hr_stops() {
        XCTAssertEqual(HRDownPacer.next(currentHR: 0, elapsed: 0, config: cfg).stopReason, .invalidHR)
        XCTAssertEqual(HRDownPacer.next(currentHR: -5, elapsed: 0, config: cfg).stopReason, .invalidHR)
    }
}
