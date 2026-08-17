import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// #1391: VO₂max is offered even WITHOUT a waist. `fitnessAgeRows` persists `vo2max_est` = the Nes 2011
/// waist-based estimate when a waist is set, else falls back to the Uth 2004 HR-ratio estimate
/// (15.3·HRmax/RHR, HRmax = Tanaka(age)) — so a user past the age+RHR fitness-age gate gets a VO₂max
/// instead of a blank. Twin of the Android Vo2maxFallbackTest.
///
/// `@MainActor`: `IntelligenceEngine.fitnessAgeRows` is main-actor-isolated, so the whole fixture
/// runs on the main actor to call it from a synchronous test context.
@MainActor
final class Vo2maxFallbackTests: XCTestCase {

    /// ≥ minCoverageDays (4) RHR nights + strain so the fitness-age gate can compute.
    private func gate(_ rhr: Int) -> [DailyMetric] {
        (0..<7).map { i in
            DailyMetric(day: String(format: "2026-08-%02d", 9 + i), totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                        avgHrv: nil, recovery: nil, strain: 50, exerciseCount: nil)
        }
    }

    private func vo2maxEst(waistCm: Double) -> Double? {
        IntelligenceEngine.fitnessAgeRows(
            gateDays: gate(60), age: 40, sex: "male", waistCm: waistCm, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-15"
        ).first { $0.key == "vo2max_est" }?.value
    }

    func testNoWaistFallsBackToUthHrRatioEstimate() {
        let vo2 = vo2maxEst(waistCm: 0)   // no waist → Nes value is nil
        XCTAssertNotNil(vo2, "without a waist, VO₂max must still be offered via the Uth fallback")
        // Uth: 15.3 × Tanaka(40)=180 / RHR 60 = 45.9
        XCTAssertEqual(vo2!, 15.3 * StrainScorer.tanakaHRmax(age: 40) / 60.0, accuracy: 1e-6)
    }

    func testWaistSetUsesTheNesWaistBasedEstimate() {
        let uth = vo2maxEst(waistCm: 0)!
        let nes = vo2maxEst(waistCm: 90)!
        let paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 50)
        // With a waist the persisted value is the Nes waist-based estimate…
        XCTAssertEqual(nes, FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90,
                                                            restingHR: 60, paIndex: paIndex), accuracy: 1e-6)
        // …and it differs from the Uth HR-ratio fallback.
        XCTAssertGreaterThan(abs(nes - uth), 0.01)
    }
}
