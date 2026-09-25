import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// #2460: today's live Effort and the stored day must be scored against the SAME HRmax.
///
/// The Today views do not read the scored day for today, they score it themselves, and both of them
/// passed Tanaka with no reference to the manual HR-max override. The ring then shows
/// `StrainScorer.effectiveEffort(live:stored:)`, which is `max(live, stored)`, so the two numbers never
/// appear side by side and the disagreement was invisible: the user saw one of them and had no way to
/// tell which.
///
/// These tests score one day both ways and compare, which is the only shape that catches it.
///
/// What they do NOT cover: the two view call sites themselves. Both views are SwiftUI bodies whose
/// Effort is computed in a private async method, so the pin here is on `ProfileStore.effortHRmax` and on
/// its agreement with `AnalyticsEngine`. Someone who reintroduced a hand-rolled Tanaka in a view would
/// leave this file green. The resolver existing at all is the guard against that, which is most of why
/// it is a named property rather than a corrected expression in two places.
final class EffortHRmaxOverrideTests: XCTestCase {

    // MARK: the resolver

    /// A manual override wins, and it wins as the exact bpm that was set.
    @MainActor
    func testAnOverrideWins() {
        withProfile(age: 30, hrMaxOverride: 195) { p in
            XCTAssertEqual(p.effortHRmax ?? -1, 195.0, accuracy: 1e-9)
        }
    }

    /// With no override the formula applies, UNROUNDED, and that is also why this is not the existing
    /// `hrMax`. The engine scores against `StrainScorer.tanakaHRmax`, which is not an integer for most
    /// ages; `hrMax` rounds it to an Int, which would put the live value on a slightly different reserve
    /// than the day it belongs to.
    ///
    /// Age 41 is chosen because 208 - 0.7*41 = 179.3, so the rounding actually shows. The expectation is
    /// derived from `p.age` rather than hardcoded, since `age` is computed from the stored birth date.
    @MainActor
    func testNoOverrideIsUnroundedTanakaAndNotTheRoundedHrMax() {
        withProfile(age: 41, hrMaxOverride: 0) { p in
            XCTAssertEqual(p.effortHRmax ?? -1, StrainScorer.tanakaHRmax(age: Double(p.age)), accuracy: 1e-9)
            XCTAssertNotEqual(p.effortHRmax ?? -1, Double(p.hrMax))
        }
    }

    // MARK: the day, scored both ways

    /// The test the bug needed. One day, one profile with an override above the formula, scored by the
    /// live path and by `AnalyticsEngine`, must produce the same number.
    @MainActor
    func testLiveAndStoredAgreeForAnOverriddenProfile() {
        withProfile(age: 30, hrMaxOverride: 195) { p in
            let hr = dayHR()
            let live = StrainScorer.strain(hr, maxHR: p.effortHRmax,
                                           restingHR: StrainScorer.defaultRestingHR,
                                           method: .edwards, sex: p.sex)
            let stored = AnalyticsEngine.analyzeDay(day: Self.day, hr: hr, dayHr: hr,
                                                    profile: engineProfile(p),
                                                    maxHROverride: Double(p.hrMaxOverride),
                                                    effortMethod: .edwards).daily.strain

            XCTAssertNotNil(live, "fixture must score, or this test proves nothing")
            XCTAssertEqual(live ?? -1, stored ?? -2, accuracy: 1e-9)
        }
    }

    /// The same day with no override, which was never broken, so the fix must not have moved it.
    @MainActor
    func testLiveAndStoredAgreeWithNoOverride() {
        withProfile(age: 30, hrMaxOverride: 0) { p in
            let hr = dayHR()
            let live = StrainScorer.strain(hr, maxHR: p.effortHRmax,
                                           restingHR: StrainScorer.defaultRestingHR,
                                           method: .edwards, sex: p.sex)
            let stored = AnalyticsEngine.analyzeDay(day: Self.day, hr: hr, dayHr: hr,
                                                    profile: engineProfile(p),
                                                    maxHROverride: nil,
                                                    effortMethod: .edwards).daily.strain

            XCTAssertNotNil(live)
            XCTAssertEqual(live ?? -1, stored ?? -2, accuracy: 1e-9)
        }
    }

    /// Why the old behaviour was not a harmless difference but a wrong number on the ring.
    ///
    /// An override is set because the real maximum is ABOVE the formula, so Tanaka gives the smaller
    /// reserve, the larger %HRR and the larger Effort. `effectiveEffort` takes the max, so the formula's
    /// value did not merely differ from the day's, it displaced it. This pins the direction, so a future
    /// change that reintroduces a second yardstick cannot be argued to be cosmetic.
    @MainActor
    func testTheOldTanakaOnlyValueWouldHaveOutvotedTheStoredDay() {
        withProfile(age: 30, hrMaxOverride: 195) { p in
            let hr = dayHR()
            // Exactly what both views used to compute.
            let oldLive = StrainScorer.strain(hr, maxHR: StrainScorer.tanakaHRmax(age: Double(p.age)),
                                              restingHR: StrainScorer.defaultRestingHR,
                                              method: .edwards, sex: p.sex)
            let stored = AnalyticsEngine.analyzeDay(day: Self.day, hr: hr, dayHr: hr,
                                                    profile: engineProfile(p),
                                                    maxHROverride: Double(p.hrMaxOverride),
                                                    effortMethod: .edwards).daily.strain

            XCTAssertGreaterThan(oldLive ?? -1, stored ?? -1, "the fixture must exercise the divergence")
            XCTAssertEqual(StrainScorer.effectiveEffort(live: oldLive, stored: stored) ?? -1,
                           oldLive ?? -2, accuracy: 1e-9, "the wrong value is the one that was displayed")

            // With the fix the same call is a no-op: both sides are the day's own number.
            let newLive = StrainScorer.strain(hr, maxHR: p.effortHRmax,
                                              restingHR: StrainScorer.defaultRestingHR,
                                              method: .edwards, sex: p.sex)
            XCTAssertEqual(StrainScorer.effectiveEffort(live: newLive, stored: stored) ?? -1,
                           stored ?? -2, accuracy: 1e-9)
        }
    }

    // MARK: fixture

    /// A profile with the given age and override, with the stored defaults restored afterwards.
    ///
    /// `ProfileStore` writes straight to `UserDefaults.standard` and has no injectable suite, so a test
    /// that sets a birth date or an override leaves it there for whatever runs next. That is not
    /// hypothetical for this key in particular: `IntelligenceEngine` reads `hrMaxOverride` to choose the
    /// HRmax it scores with, so a stray 195 left behind here would quietly rescore another suite's
    /// fixtures, and the failure would look like anything except this file. Same save-and-restore shape
    /// as `DetectedWorkoutReconciliationTests.withPreferences`, narrowed to the keys touched here.
    @MainActor
    private func withProfile(age: Int, hrMaxOverride: Int, sex: String = "male",
                             _ body: (ProfileStore) -> Void) {
        let defaults = UserDefaults.standard
        let keys = ["profile.dateOfBirth", "profile.age", "profile.sex", "profile.hrMaxOverride"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let p = ProfileStore()
        p.dateOfBirth = ProfileStore.dateOfBirth(forAge: age)
        p.sex = sex
        p.hrMaxOverride = hrMaxOverride
        body(p)
    }

    /// The day key the fixture's timestamps fall in, under the tests' UTC offset.
    private static let day = "2026-09-26"

    /// A calendar day at 60 bpm with a 40-minute block at 140, which is zone 2 under Tanaka and zone 1
    /// under a 195 override. The two yardsticks have to actually disagree or the comparison is vacuous.
    private func dayHR() -> [HRSample] {
        let base = 1_790_380_800   // 2026-09-26T00:00:00Z
        return (0 ..< 7200).map { i in
            HRSample(ts: base + i, bpm: (i >= 1800 && i < 4200) ? 140 : 60)
        }
    }

    /// The same profile in the engine's shape, so the only difference between the two paths under test
    /// is the HRmax resolution itself.
    @MainActor
    private func engineProfile(_ p: ProfileStore) -> UserProfile {
        UserProfile(weightKg: p.weightKg, heightCm: p.heightCm,
                    age: Double(p.age), sex: p.sex)
    }
}
