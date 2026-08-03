import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// #950, second defect — a rescored workout must be scored against the wearer's MEASURED resting HR
/// when one exists, not the hardcoded 60 the day total never uses.
///
/// The day's Effort passes the measured resting into the %HRR denominator; the workout rescore always
/// took the default. For a fit wearer (resting well under 60) that widens the true heart-rate reserve,
/// so every sample sits LOWER in the zone table than it should — the workout under-scores relative to
/// the very day it sits in, which is the incomparability #950 reports.
///
/// Twin of Kotlin `ManualWorkoutRescoreRestingHrTest` — same fixtures, same expectations.
final class ManualWorkoutRescoreRestingHrTests: XCTestCase {

    private let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
    private let hrMax = 190.0

    /// An hour at 148 bpm, 30 s cadence — chosen because the Edwards zone FLIPS with the reserve:
    private func window() -> [HRSample] {
        (0..<120).map { HRSample(ts: $0 * 30, bpm: 148) }
    }

    /// A measured resting of 45 must score the same window strictly higher than the default 60:
    /// 148 bpm is 71.0% of a 45-resting reserve (zone 3) but 67.7% of a 60-resting one (zone 2).
    func testMeasuredRestingScoresHigherThanTheDefaultForAFitWearer() {
        let def = ManualWorkoutRescore.scored(windowSamples: window(), profile: profile, hrMax: hrMax)
        let measured = ManualWorkoutRescore.scored(windowSamples: window(), profile: profile,
                                                   hrMax: hrMax, restingHR: 45)
        XCTAssertNotNil(def?.strain); XCTAssertNotNil(measured?.strain)
        XCTAssertGreaterThan(measured!.strain!, def!.strain!)
    }

    /// nil keeps the old behaviour byte-for-byte — the cold-start path with no measured resting yet.
    func testNilRestingIsByteIdenticalToTheOldCall() {
        let old = ManualWorkoutRescore.scored(windowSamples: window(), profile: profile, hrMax: hrMax)
        let explicit = ManualWorkoutRescore.scored(windowSamples: window(), profile: profile,
                                                   hrMax: hrMax, restingHR: nil)
        XCTAssertEqual(old, explicit)
    }

    /// The resting HR reaches the calories model too — but there it sets the ACTIVE THRESHOLD
    /// (resting + 30% HRR), not the burn rate, so it only moves kcal when samples straddle the two
    /// thresholds. 95 bpm does: active under a 45-resting threshold (88.5) and resting-rate under a
    /// 60-resting one (99). The first version of this test used an all-hard window and failed on both
    /// platforms with IDENTICAL kcal — asserting a mechanism the model doesn't have.
    func testCaloriesSeeTheMeasuredRestingThroughTheActiveThreshold() {
        let warmup = (0..<40).map { HRSample(ts: $0 * 30, bpm: 95) }
        let mixed = warmup + (40..<160).map { HRSample(ts: $0 * 30, bpm: 148) }
        let def = ManualWorkoutRescore.scored(windowSamples: mixed, profile: profile, hrMax: hrMax)!
        let measured = ManualWorkoutRescore.scored(windowSamples: mixed, profile: profile,
                                                   hrMax: hrMax, restingHR: 45)!
        XCTAssertNotEqual(def.kcal, measured.kcal)
    }
}
