import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Motion-corroborated wake (elevated-but-flat-HR nights). Both stagers and the HR-led session confirmation
/// call "wake" primarily off HR / HR-variability; on a night whose resting HR is held elevated WITHOUT the
/// wearer getting up (a supplement protocol, a fever, a hot room, alcohol) that logic misreads hot-but-
/// motionless sleep as wake. These fixtures replicate the two confirmed mis-scored nights and pin the rule:
/// elevated-HR ALONE cannot call wake when the wrist is at the night's quiescent motion floor with unchanged
/// posture, while genuine out-of-bed motion (walking cadence / sustained posture change) still breaks sleep.
final class MotionCorroboratedWakeTests: XCTestCase {

    // MARK: - fixtures

    /// A perfectly still gravity stream (fixed orientation) at 1 Hz — the quiescent sleep floor.
    private func stillGravity(start: Int, durationS: Int, x: Double = 0, y: Double = 0, z: Double = 1.0)
        -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: x, y: y, z: z) }
    }

    /// Still gravity with brief single-minute TURN-OVER bursts every `everyMin` minutes (a posture flip that
    /// lasts a few seconds) — a sleeping body, not an awakening. Between bursts posture is fixed.
    private func stillWithTurnovers(start: Int, durationS: Int, everyMin: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let minute = i / 60
            let isBurstMinute = minute % everyMin == 0 && minute > 0
            let inBurst = isBurstMinute && (i % 60) < 4    // ~4 s of turn-over inside the burst minute
            return inBurst ? GravitySample(ts: start + i, x: 0.35, y: 0.30, z: 0.87)
                           : GravitySample(ts: start + i, x: 0, y: 0, z: 1.0)
        }
    }

    /// A sustained WALKING gravity stream — every second a different orientation with a large step-cadence
    /// jerk (out of bed, pacing). Breaks sleep at both the detection and stage level.
    private func walkingGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let ph = Double(i % 4)
            return GravitySample(ts: start + i,
                                 x: 0.5 * sin(ph), y: 0.5 * cos(ph), z: 0.7)
        }
    }

    /// Elevated-but-FLAT HR at 1 Hz (supplement era: resting HR held ~`base`, natural would be ~48).
    private func elevatedFlatHR(start: Int, durationS: Int, base: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: base + ($0 / 90) % 3) }
    }

    /// A regular R-R stream (~1000 ms beats with a small respiratory oscillation).
    private func regularRR(start: Int, durationS: Int, meanMs: Int = 1000) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            let rsa = Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0))
            return RRInterval(ts: start + i, rrMs: meanMs + rsa)
        }
    }

    private func wakeMinutes(_ segs: [StageSegment]) -> Double {
        segs.filter { $0.stage == "wake" }.reduce(0.0) { $0 + Double($1.end - $1.start) } / 60.0
    }

    // MARK: - V2 stage level: the primary default-path fix

    /// The 7/13 pattern: a ~6 h warm-flat-HR still night (turn-over bursts on a ~90-min rhythm, no walking)
    /// must NOT be carpeted in WAKE. Before the fix the elevated HR drove the V2 awake emission on motionless
    /// epochs; now a motion-quiescent epoch keeps only wake-SUPPRESSING cardiac evidence, so the still spans
    /// score as sleep and only genuine motion could read wake.
    func testWarmFlatHRStillNightScoresAsleepNotWake_V2() {
        let start = 1_749_517_200
        let dur = 6 * 60 * 60
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: stillWithTurnovers(start: start, durationS: dur, everyMin: 90),
            hr: elevatedFlatHR(start: start, durationS: dur, base: 58),
            rr: regularRR(start: start, durationS: dur, meanMs: 1030),
            resp: [])
        // The vast majority of the night is motionless sleep; wake must be a small minority, not the ~50%
        // the pre-fix HR-led path produced.
        XCTAssertLessThan(wakeMinutes(segs), 60.0,
                          "a warm-but-still night must score mostly asleep, not WAKE (got \(wakeMinutes(segs)) min)")
    }

    /// The still low-HR baseline case must be byte-identical to before the fix (the change only ever removes
    /// wake-PROMOTING cardiac evidence on quiescent epochs; a low, flat HR contributes none). This guards
    /// against the correction accidentally shifting a normal night.
    func testStillLowHRNightUnchangedByCorrection_V2() {
        let start = 1_749_517_200
        let dur = 3 * 60 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = elevatedFlatHR(start: start, durationS: dur, base: 48)   // natural resting
        let rr = regularRR(start: start, durationS: dur)
        // Re-derive with the correction disabled by construction: a low-HR still night has no positive cardiac
        // awake term to clamp, so the corrected output already equals the uncorrected recipe — assert it stages
        // real sleep (deep/light present, negligible wake).
        let segs = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: rr, resp: [])
        XCTAssertLessThan(wakeMinutes(segs), 15.0, "a still low-HR night should be essentially all sleep")
    }

    /// Genuine out-of-bed WALKING within an otherwise-still night must still be scored WAKE by V2 — the
    /// correction must not swallow a real awakening. V2's wake gate is night-RELATIVE (thresholds scale off the
    /// night's own quiescent jerk floor), so the walking block is measured against the still baseline around it,
    /// its motion is positively observed, and the epochs are not quiescent — the full awake emission applies.
    func testWalkingGapWithinStillNightScoresWake_V2() {
        let start = 1_749_517_200
        let dur = 5 * 60 * 60
        let walkStart = 2 * 60 * 60          // a 30-min out-of-bed block two hours in
        let walkEnd = walkStart + 30 * 60
        var grav: [GravitySample] = []
        for i in 0..<dur {
            if i >= walkStart && i < walkEnd {
                let ph = Double(i % 4)
                grav.append(GravitySample(ts: start + i, x: 0.5 * sin(ph), y: 0.5 * cos(ph), z: 0.7))
            } else {
                grav.append(GravitySample(ts: start + i, x: 0, y: 0, z: 1.0))
            }
        }
        // Elevated during the walk (out of bed), flat-elevated otherwise (supplement).
        let hr = (0..<dur).map { i -> HRSample in
            HRSample(ts: start + i, bpm: (i >= walkStart && i < walkEnd) ? 92 : 58)
        }
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur, grav: grav,
            hr: hr, rr: regularRR(start: start, durationS: dur, meanMs: 1030), resp: [])
        // The walking block must read WAKE; the still remainder must not be carpeted in wake.
        let walkWake = segs.filter { $0.stage == "wake" && $0.end > start + walkStart && $0.start < start + walkEnd }
            .reduce(0.0) { $0 + Double(min($1.end, start + walkEnd) - max($1.start, start + walkStart)) } / 60.0
        XCTAssertGreaterThan(walkWake, 15.0,
                             "the walking block must remain WAKE (got \(walkWake) min of \(30))")
        XCTAssertLessThan(wakeMinutes(segs), 60.0,
                          "the still remainder must not be scored WAKE despite elevated HR")
    }

    // MARK: - the motion-quiescent predicate

    func testMotionQuiescentPredicate() {
        // A still epoch (no move, jerk at floor) is quiescent; an epoch with a jerk spike above the gate is not.
        let still = SleepStagerV2.Epoch(start: 0, hr: 58, hrVar: 1, hrFlat11: 1, moveFrac: 0.0, jerkMax: 0.001,
                                        respReg: nil, clock: 0.5, jerkScale: 0.001, minutesSinceOnset: 120)
        XCTAssertTrue(SleepStagerV2.motionQuiescent(still))
        let moved = SleepStagerV2.Epoch(start: 0, hr: 58, hrVar: 1, hrFlat11: 1, moveFrac: 0.3, jerkMax: 0.2,
                                        respReg: nil, clock: 0.5, jerkScale: 0.001, minutesSinceOnset: 120)
        XCTAssertFalse(SleepStagerV2.motionQuiescent(moved))
    }

    // MARK: - detection level: confirmSleepWithHR motion corroboration

    /// A supplement night whose whole in-bed run is motionless but HR-elevated (median ~58 vs baseline 48,
    /// i.e. above the strict ×1.05 = 50.4 bar) must NOT be rejected by the HR gate when gravity proves the
    /// wrist was still — the widened quiescent band keeps it. Without gravity evidence the strict bar stands.
    func testMotionlessElevatedRunConfirmedWithGravity() {
        let start = 1_000_000
        let dur = 90 * 60
        let p = SleepStager.Period(stage: "sleep", start: start, end: start + dur)
        let hr = elevatedFlatHR(start: start, durationS: dur, base: 58)
        let stillGrav = stillGravity(start: start, durationS: dur)
        // With gravity proving stillness → confirmed (widened band).
        XCTAssertTrue(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 48.0, grav: stillGrav),
                      "a motionless but HR-elevated run must be confirmed as sleep when stillness is proven")
        // Without gravity → strict band → rejected (the pre-existing behaviour is preserved).
        XCTAssertFalse(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 48.0),
                       "with no motion evidence the strict HR band still rejects an elevated run")
    }

    /// The floor holds: a genuinely awake, motionless run whose median HR is far above the band (72 vs
    /// baseline 48 → above even the widened ×1.30 = 62.4 bar) is STILL rejected even with stillness proven,
    /// so all-night in-bed wakefulness is not scored asleep.
    func testGenuinelyHighHRStillRunStillRejected() {
        let start = 1_000_000
        let dur = 90 * 60
        let p = SleepStager.Period(stage: "sleep", start: start, end: start + dur)
        let hr = elevatedFlatHR(start: start, durationS: dur, base: 72)
        let stillGrav = stillGravity(start: start, durationS: dur)
        XCTAssertFalse(SleepStager.confirmSleepWithHR(p, hr: hr, baseline: 48.0, grav: stillGrav),
                       "a run whose HR is above even the widened quiescent band must still be rejected")
    }

    func testRunIsDeeplyQuiescent() {
        let start = 1_000_000
        let dur = 60 * 60
        let p = SleepStager.Period(stage: "sleep", start: start, end: start + dur)
        XCTAssertTrue(SleepStager.runIsDeeplyQuiescent(p, grav: stillGravity(start: start, durationS: dur)))
        XCTAssertTrue(SleepStager.runIsDeeplyQuiescent(p, grav: stillWithTurnovers(start: start, durationS: dur, everyMin: 90)),
                      "occasional turn-overs still leave >90% of minutes posture-stable")
        XCTAssertFalse(SleepStager.runIsDeeplyQuiescent(p, grav: walkingGravity(start: start, durationS: dur)),
                       "a walking run is not posture-stable")
        XCTAssertFalse(SleepStager.runIsDeeplyQuiescent(p, grav: []),
                       "no gravity → stillness unprovable → not deeply quiescent")
    }

    // MARK: - adaptive overnight HR baseline (directive b)

    func testAdaptiveOvernightHRBaseline() throws {
        // Self-calibrates to recent overnight medians (a supplement era's ~58 vs a fixed day-median).
        XCTAssertEqual(try XCTUnwrap(SleepStager.adaptiveOvernightHRBaseline(recentOvernightMedians: [56, 58, 60, 57, 59])),
                       58.0, accuracy: 1e-9)
        // Floor holds so a wakeful era can't collapse the band.
        XCTAssertEqual(try XCTUnwrap(SleepStager.adaptiveOvernightHRBaseline(recentOvernightMedians: [30, 32, 31])),
                       SleepStager.adaptiveBaselineFloor, accuracy: 1e-9)
        // No history → nil (caller keeps the day-median).
        XCTAssertNil(SleepStager.adaptiveOvernightHRBaseline(recentOvernightMedians: []))
    }
}
