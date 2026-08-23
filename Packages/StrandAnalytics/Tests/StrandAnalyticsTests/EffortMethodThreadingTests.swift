import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol
// DailyMetric (read via DayResult.daily below) lives in WhoopStore; AnalyticsEngineTests imports it for
// the same reason. Harmless if the transitive visibility would have sufficed — and this file already
// cost one CI round by assuming a type's module was reachable without saying so.
import WhoopStore

/// #1545: the Effort recipe has to reach the score, and reach the WORKOUTS INSIDE the day by the same
/// route.
///
/// The denominator work landed the arithmetic; this pins the plumbing. Threading a parameter through a
/// dozen call sites is exactly the kind of change that compiles perfectly while quietly dropping the
/// value somewhere in the middle, and the symptom would be invisible — a score that is merely *wrong*,
/// not missing.
///
/// Byte-parity twin of Kotlin `EffortMethodThreadingTest`.
final class EffortMethodThreadingTests: XCTestCase {

    private let day = "2026-08-23"

    /// A flat hour just UNDER Edwards' 50% HRR floor: it earns nothing there, real credit under Banister.
    private func subThresholdHour() -> [HRSample] {
        let bpm = Int((60.0 + (190.0 - 60.0) * 0.45).rounded())
        return (0 ..< 3600).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func profile() -> UserProfile { UserProfile(age: 30, sex: "male") }

    private func score(_ method: StrainScorer.Method) -> Double? {
        AnalyticsEngine.analyzeDay(day: day, hr: subThresholdHour(), dayHr: subThresholdHour(),
                                   profile: profile(), maxHROverride: 190.0,
                                   effortMethod: method).strain
    }

    /// The default must not move. Every caller that says nothing about a method still gets Edwards, and
    /// an hour below the floor still scores nothing — that is what shipped, and this change is supposed
    /// to add a choice, not alter one.
    func testTheDefaultIsStillEdwardsAndStillScoresTheFlooredHourAtZero() {
        let implicit = AnalyticsEngine.analyzeDay(day: day, hr: subThresholdHour(),
                                                  dayHr: subThresholdHour(),
                                                  profile: profile(), maxHROverride: 190.0).strain
        XCTAssertEqual(implicit ?? -2.0, score(.edwards) ?? -1.0, accuracy: 1e-12)
        XCTAssertEqual(implicit ?? -1.0, 0.0, accuracy: 1e-9)
    }

    /// The whole point: asking for Banister actually changes the day's Effort. If the parameter were
    /// dropped anywhere between `analyzeDay` and `StrainScorer`, this is what notices.
    func testBanisterReachesTheDayScore() {
        let banister = score(.banister)
        XCTAssertNotNil(banister)
        XCTAssertGreaterThan(banister!, 40.0, "an hour at 45% HRR should score under Banister")
    }

    /// And it reaches the BOUTS inside the day by the same route. A day scored on Banister whose detected
    /// workouts were still on Edwards would show a session scoring less than the day containing it — a
    /// contradiction a user would notice long before they noticed either number being individually off.
    func testBanisterReachesTheWorkoutsDetectedInsideTheDay() {
        let hr = subThresholdHour()
        let grav = (0 ..< 3600).map { GravitySample(ts: $0, x: 0.9, y: 0.1, z: 0.1) }
        let edwards = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190,
                                             age: 30, profile: profile(), effortMethod: .edwards)
        let banister = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190,
                                              age: 30, profile: profile(), effortMethod: .banister)

        // Whatever the detector finds, it must find the SAME bouts either way — the recipe changes the
        // score, never the segmentation.
        XCTAssertEqual(edwards.count, banister.count, "the method must not change which bouts are detected")
        for (e, b) in zip(edwards, banister) {
            XCTAssertEqual(e.start, b.start)
            if let es = e.strain, let bs = b.strain, es == 0.0 {
                XCTAssertGreaterThan(bs, es, "a floored bout should score under Banister")
            }
        }
    }

    /// A method change must not disturb anything else the day computes.
    func testOnlyEffortMoves() {
        let e = AnalyticsEngine.analyzeDay(day: day, hr: subThresholdHour(), dayHr: subThresholdHour(),
                                           profile: profile(), maxHROverride: 190.0,
                                           effortMethod: .edwards)
        let b = AnalyticsEngine.analyzeDay(day: day, hr: subThresholdHour(), dayHr: subThresholdHour(),
                                           profile: profile(), maxHROverride: 190.0,
                                           effortMethod: .banister)
        XCTAssertEqual(e.daily.restingHr, b.daily.restingHr)
        XCTAssertEqual(e.daily.avgHrv, b.daily.avgHrv)
        XCTAssertEqual(e.sleepSessions.count, b.sleepSessions.count)
        XCTAssertEqual(e.recovery, b.recovery)
    }
}
