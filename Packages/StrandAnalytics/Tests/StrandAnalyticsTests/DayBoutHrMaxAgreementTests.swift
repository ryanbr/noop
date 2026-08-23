import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// #1545: a workout and the day containing it must be scored against the SAME HRmax.
///
/// `analyzeDay` computes `effMaxHR = maxHROverride ?? tanakaHRmax(age)` for the day's Effort, but used to
/// hand `WorkoutDetector.detect` only `maxHROverride`. With no override — the default — the detector fell
/// back to `StrainScorer.estimateHRmax`, which returns `max(observed p99.5, Tanaka)`. So every bout was
/// measured against a HRmax at least as high as its own day's, and usually higher.
///
/// A higher HRmax is a bigger reserve and therefore a SMALLER %HRR, so bouts were held to a STRICTER
/// standard than the day they sit inside. At age 30 / RHR 60 with an observed 195 bpm, a 125 bpm minute is
/// zone 1 for the day and zone 0 for the bout — it counts toward the day total and scores nothing in the
/// workout. That lands hardest at the 50% floor, which is the whole subject of #1545.
///
/// Byte-parity twin of Kotlin `DayBoutHrMaxAgreementTest`.
final class DayBoutHrMaxAgreementTests: XCTestCase {

    private let age = 30.0
    private let rhr = 60.0
    private var tanaka: Double { StrainScorer.tanakaHRmax(age: age) }   // 187 for age 30

    /// The arithmetic the fix is about, stated independently of the engine.
    private func zoneWeight(_ bpm: Double, _ hrmax: Double) -> Int {
        let pct = (bpm - rhr) / (hrmax - rhr) * 100.0
        if pct >= 90 { return 5 }; if pct >= 80 { return 4 }; if pct >= 70 { return 3 }
        if pct >= 60 { return 2 }; if pct >= 50 { return 1 }
        return 0
    }

    /// The divergence, in the estimator itself: `estimateHRmax` never returns BELOW Tanaka, so the bout's
    /// fallback HRmax is always ≥ the day's. That is why the bug is one-directional — bouts could only
    /// ever be under-scored relative to their day, never over-scored.
    func testTheBoutFallbackIsNeverBelowTheDaysTanaka() {
        for observed in [150.0, 185.0, 195.0, 210.0] {
            let est = StrainScorer.estimateHRmax(Array(repeating: observed, count: 700), age: age).0
            XCTAssertGreaterThanOrEqual(est, tanaka - 1e-9, "observed \(observed) gave \(est)")
        }
    }

    /// The concrete split: the same heart rate is worth a zone to the day and nothing to the bout, purely
    /// because the two used different HRmax values.
    func testTheSameMinuteSplitsAcrossTheZoneFloor() {
        let boutMax = StrainScorer.estimateHRmax(Array(repeating: 195.0, count: 700), age: age).0
        XCTAssertEqual(boutMax, 195.0, accuracy: 1e-9, "fixture assumes the observed value wins")
        XCTAssertEqual(zoneWeight(125, tanaka), 1, "day scores it zone 1")
        XCTAssertEqual(zoneWeight(125, boutMax), 0, "bout scored it zone 0 — the bug")
    }

    /// The fix, end to end — and it is a DETECTION change, not only a scoring one.
    ///
    /// A 138 bpm bout is 61.4% HRR against the day's Tanaka 187 (zone 2) but 57.8% against an observed
    /// 195 (zone 1). The detector's z2+ qualification gate needs half the bout in zone 2 or above, so
    /// before the fix this workout was DROPPED — by a standard its own day never applied.
    func testTheDaysHrMaxReachesDetectionAndScoring() {
        let res = AnalyticsEngine.analyzeDay(
            day: "2026-08-23", hr: dayWithAHardPeakAndABoundaryBout(),
            gravity: movingAllDay(), dayHr: dayWithAHardPeakAndABoundaryBout(),
            dayGravity: movingAllDay(), profile: UserProfile(age: age, sex: "male"))

        XCTAssertFalse(res.workouts.isEmpty, "the boundary bout should now be detected")
        for w in res.workouts {
            XCTAssertEqual(w.hrmax ?? -1, tanaka, accuracy: 1e-9,
                           "every bout must carry the day's HRmax, not the observed estimate")
        }
    }

    /// An explicit override still wins — the fix must never override the user's own number.
    func testAnExplicitOverrideStillWins() {
        let res = AnalyticsEngine.analyzeDay(
            day: "2026-08-23", hr: dayWithAHardPeakAndABoundaryBout(),
            gravity: movingAllDay(), dayHr: dayWithAHardPeakAndABoundaryBout(),
            dayGravity: movingAllDay(), profile: UserProfile(age: age, sex: "male"),
            maxHROverride: 175.0)

        XCTAssertFalse(res.workouts.isEmpty)
        for w in res.workouts { XCTAssertEqual(w.hrmax ?? -1, 175.0, accuracy: 1e-9) }
    }

    // A day with: a brief hard effort (lifts the observed p99.5 above Tanaka), a long rest that sets a low
    // resting baseline, and a sustained bout sitting exactly between the two HRmax interpretations.
    private func dayWithAHardPeakAndABoundaryBout() -> [HRSample] {
        var out: [HRSample] = []
        out.reserveCapacity(7200)
        func run(_ from: Int, _ until: Int, _ bpm: Int) {
            for t in from ..< until { out.append(HRSample(ts: t, bpm: bpm)) }
        }
        run(0, 600, 195)        // hard peak → observed p99.5 = 195
        run(600, 2400, 60)      // rest → 10th-percentile resting baseline stays 60
        run(2400, 6000, 138)    // the boundary bout: zone 2 on Tanaka, zone 1 on observed
        run(6000, 7200, 60)
        return out
    }

    // Motion must actually vary: intensity is the euclidean step between consecutive gravity samples and
    // has to clear `motionThreshold` (0.20) after smoothing, so a constant vector detects nothing.
    private func movingAllDay() -> [GravitySample] {
        (0 ..< 7200).map { GravitySample(ts: $0, x: $0 % 2 == 0 ? 0.9 : 0.5, y: 0.1, z: 0.1) }
    }
}
