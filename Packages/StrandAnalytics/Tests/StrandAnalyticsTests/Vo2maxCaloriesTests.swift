import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Keytel 2005 FITNESS-ADJUSTED calorie path: when a resting HR is known, a Uth VO2max
/// (15.3·HRmax/HRrest) is threaded into the more accurate Keytel equation that reads fitness; with
/// no resting HR the estimator falls back to the base (fitness-blind) model, byte-identical to
/// before. Expected values hand-computed from the published coefficients — the Kotlin twin
/// `Vo2maxCaloriesTest` asserts the SAME literals, which is the cross-platform parity contract.
final class Vo2maxCaloriesTests: XCTestCase {

    func testVo2maxForIsUthAndNilWithoutRestingHR() {
        XCTAssertEqual(Calories.vo2maxFor(hrmax: 190.0, restingHR: 50.0)!, 58.14, accuracy: 1e-9)
        XCTAssertNil(Calories.vo2maxFor(hrmax: 190.0, restingHR: nil))
        XCTAssertNil(Calories.vo2maxFor(hrmax: 190.0, restingHR: 0.0))
        XCTAssertNil(Calories.vo2maxFor(hrmax: 0.0, restingHR: 50.0))
    }

    func testActiveRateUsesFitnessModelWhenVo2maxKnown() {
        let r = Calories.activeKcalPerS(Calories.male, hr: 150.0, hrmax: 190.0, weightKg: 80.0, age: 30.0, vo2max: 58.14)
        XCTAssertEqual(r, 0.248825127469726, accuracy: 1e-12)
    }

    func testActiveRateFallsBackToBaseWhenNoVo2max() {
        let base = Calories.activeKcalPerS(Calories.male, hr: 150.0, hrmax: 190.0, weightKg: 80.0, age: 30.0, vo2max: nil)
        XCTAssertEqual(base, 0.24495339388145318, accuracy: 1e-12)
        // The whole point: the fitness anchor MOVES the number (here it is higher).
        let fit = Calories.activeKcalPerS(Calories.male, hr: 150.0, hrmax: 190.0, weightKg: 80.0, age: 30.0, vo2max: 58.14)
        XCTAssertNotEqual(fit, base)
    }

    func testFemaleAndNonbinaryFitnessCoeffs() {
        XCTAssertEqual(
            Calories.activeKcalPerS(Calories.female, hr: 150.0, hrmax: 190.0, weightKg: 80.0, age: 30.0, vo2max: 58.14),
            0.18585803059273417, accuracy: 1e-12)
        XCTAssertEqual(
            Calories.activeKcalPerS(Calories.nonbinary, hr: 150.0, hrmax: 190.0, weightKg: 80.0, age: 30.0, vo2max: 58.14),
            0.2173415790312301, accuracy: 1e-12)
    }

    func testBoutThreadsVo2maxWhenRestingHRKnown() {
        // Dense 1 Hz bout, 60 s all at HR 150 (well above the 92 bpm active gate for RHR 50 / HRmax 190),
        // male 80 kg / age 30. Every second is billed the fitness active rate → total = 60 × that rate.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 150) }
        let kcal = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 190.0, restingHR: 50.0).0
        XCTAssertEqual(kcal, 0.248825127469726 * 60, accuracy: 1e-9)
    }
}
