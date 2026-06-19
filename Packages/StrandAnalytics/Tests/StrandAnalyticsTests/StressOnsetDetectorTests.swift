import XCTest
@testable import StrandAnalytics

/// Pins the L3 `StressOnsetDetector` — the highest-value test, guarding the credibility line: it fires
/// ONCE on a fresh non-metabolic HRV dip, is suppressed by the exercise gate (HR-out-of-band and/or
/// motion), honours the rate limit + quiet hours, and replays safely (a re-fed window can't re-fire).
/// GOLDEN/behaviour vectors the Kotlin `StressOnsetDetectorTest` mirrors.
/// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
final class StressOnsetDetectorTests: XCTestCase {

    private let on = StressOnsetDetector.Config(enabled: true, autoNudge: true)

    /// A clean R-R buffer of `n` beats all equal to `rrMs` (RMSSD 0 if constant) — for the seed step.
    private func flat(_ rrMs: Int, _ n: Int) -> [Int] { Array(repeating: rrMs, count: n) }

    /// A clean R-R buffer of `n` beats alternating ±`jitterMs` around `rrMs`, giving a controllable RMSSD
    /// (≈ 2*jitter). Larger jitter → higher RMSSD → higher HRV.
    private func jittered(_ rrMs: Int, jitter: Int, _ n: Int) -> [Int] {
        (0..<n).map { rrMs + ($0 % 2 == 0 ? jitter : -jitter) }
    }

    // Establish a HEALTHY baseline, then a deep dip → fires exactly once (the edge), with resting HR + still.
    func test_fires_once_on_fresh_dip_then_not_again() {
        // 1) Seed a high-HRV baseline (jitter 60 → RMSSD ~120).
        let highHRV = jittered(900, jitter: 60, 60)
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 10_000, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)   // seeding tick: fast == baseline, no dip
        XCTAssertNotNil(d.baselineRMSSD)

        // 2) A deep HRV dip (jitter 5 → RMSSD ~10, well under baseline*0.6) while resting + still → FIRE.
        let lowHRV = jittered(900, jitter: 5, 60)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 10_060, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        XCTAssertEqual(d.reason, .onset)

        // 3) Still dipped on the next tick (not a fresh edge) → no re-fire.
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 10_120, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .notAnEdge)
    }

    // The EXERCISE GATE: the SAME deep dip must NOT fire when HR is out of the resting band (a workout).
    func test_exercise_gate_suppresses_when_hr_out_of_band() {
        let highHRV = jittered(900, jitter: 60, 60)
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        let lowHRV = jittered(900, jitter: 5, 60)
        // HR 140 (brisk exercise) → out of [55,100] → gated, never a "you're stressed" cue.
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 140, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .exerciseGated)
    }

    // The EXERCISE GATE: motion (recent gravity above the move threshold) also suppresses, even in-band HR.
    func test_exercise_gate_suppresses_when_moving() {
        let highHRV = jittered(900, jitter: 60, 60)
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        let lowHRV = jittered(900, jitter: 5, 60)
        // Resting HR but the wrist is moving (0.5 g » 0.15 gate) → metabolic dip → gated.
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.5,
            sessionActive: false, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .exerciseGated)
    }

    // Replay-safety: re-feeding the SAME firing window with the post-fire state can't re-fire.
    func test_replay_safe_cannot_refire() {
        let highHRV = jittered(900, jitter: 60, 60)
        let lowHRV = jittered(900, jitter: 5, 60)
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        let firedState = d.nextState
        // Replay the exact same low window + state → wasBelow is true, so no fresh edge → no fire.
        let replay = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: firedState, config: on, nowSec: 61, tzOffsetSec: 0)
        XCTAssertFalse(replay.shouldNudge)
    }

    // Rate limit: even a fresh edge within 15 min of the last fire is suppressed.
    func test_rate_limit_blocks_second_fire_within_window() {
        let highHRV = jittered(900, jitter: 60, 60)
        let lowHRV = jittered(900, jitter: 5, 60)
        // Fire once.
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldNudge)
        // Recover above (fresh edge reset), then dip AGAIN only 5 min after the fire → rate-limited.
        d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 120, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: d.nextState, config: on, nowSec: 360, tzOffsetSec: 0)   // +5 min
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .suppressed)
    }

    // Master toggle off → never fires, state untouched.
    func test_disabled_never_fires() {
        let off = StressOnsetDetector.Config(enabled: false, autoNudge: true)
        let d = StressOnsetDetector.evaluate(rrBuffer: jittered(900, jitter: 5, 60), currentHR: 70,
            recentMotionG: 0.0, sessionActive: false, state: .initial, config: off,
            nowSec: 0, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .disabled)
        XCTAssertEqual(d.nextState, StressOnsetDetector.State.initial)
    }

    // A running manual session suppresses the auto-nudge.
    func test_active_session_suppresses() {
        let highHRV = jittered(900, jitter: 60, 60)
        let lowHRV = jittered(900, jitter: 5, 60)
        var d = StressOnsetDetector.evaluate(rrBuffer: highHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        d = StressOnsetDetector.evaluate(rrBuffer: lowHRV, currentHR: 70, recentMotionG: 0.0,
            sessionActive: true, state: d.nextState, config: on, nowSec: 60, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .suppressed)
    }

    // Too few clean beats → insufficientData, never invented.
    func test_insufficient_data() {
        let d = StressOnsetDetector.evaluate(rrBuffer: flat(900, 5), currentHR: 70, recentMotionG: 0.0,
            sessionActive: false, state: .initial, config: on, nowSec: 0, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldNudge)
        XCTAssertEqual(d.reason, .insufficientData)
    }
}
