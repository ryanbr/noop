import XCTest
@testable import StrandAnalytics

/// Behavioral validation of SL1/T1: score the SAME night for different sleeper HISTORIES and show
/// how Rest moves once real regularity + personalized need replace neutral-0.5 / fixed-8h. Prints an
/// old→new table for eyeballing magnitude/direction, and pins the load-bearing directions.
final class RestWiringImpactTests: XCTestCase {
    private typealias Rest = AnalyticsEngine.Rest

    // One fixed scored night so only (need, consistency) vary: 7h TST, 90% eff, 1h deep, 1.5h REM.
    private let tst = 7.0 * 3600, inbed = 7.0 * 3600 / 0.9, eff = 0.90
    private let deep = 1.0 * 3600, rem = 1.5 * 3600

    private func restOld() -> Double {
        Rest.composite(tstSeconds: tst, inBedSeconds: inbed, efficiency: eff,
                       restorativeSeconds: deep + rem, needHours: Rest.defaultNeedHours,
                       consistency: nil, deepSeconds: deep)   // nil → neutral 0.5
    }
    private func restNew(history: [Double], age: Int?) -> (rest: Double, need: Double, cons: Double) {
        let need = Rest.personalizedNeedHours(nightlyHours: history, age: age)
        let cons = VitalityEngine.sleepConsistency(nightlyHours: Array(history.suffix(28)))
        let rest = Rest.composite(tstSeconds: tst, inBedSeconds: inbed, efficiency: eff,
                                  restorativeSeconds: deep + rem, needHours: need,
                                  consistency: cons, deepSeconds: deep)
        return (rest, need, cons ?? -1)
    }

    func testArchetypeImpactTable() {
        let regular = Array(repeating: 8.0, count: 14)
        let irregular = (0..<14).map { $0 % 2 == 0 ? 5.0 : 10.0 }   // mean 7.5, high variance
        let chronicShort = Array(repeating: 5.5, count: 14)
        let longSleeper = Array(repeating: 9.2, count: 14)

        let old = restOld()
        let reg = restNew(history: regular, age: 30)
        let irr = restNew(history: irregular, age: 30)
        let shortS = restNew(history: chronicShort, age: 30)
        let longS = restNew(history: longSleeper, age: 30)

        print(String(format: "OLD (neutral 0.5, need 8h):            Rest %5.1f", old))
        print(String(format: "regular good sleeper:  need %.1f cons %.2f  Rest %5.1f", reg.need, reg.cons, reg.rest))
        print(String(format: "irregular sleeper:     need %.1f cons %.2f  Rest %5.1f", irr.need, irr.cons, irr.rest))
        print(String(format: "chronic short (5.5h):  need %.1f cons %.2f  Rest %5.1f", shortS.need, shortS.cons, shortS.rest))
        print(String(format: "long sleeper (9.2h):   need %.1f cons %.2f  Rest %5.1f", longS.need, longS.cons, longS.rest))

        // Load-bearing directions (SL1): a REGULAR history lifts Rest above an IRREGULAR one for the
        // identical night — regularity now actually matters.
        XCTAssertGreaterThan(reg.rest, irr.rest)
        // T1: chronic-short need is floored (never collapses toward the 5.5h deficit).
        XCTAssertGreaterThanOrEqual(shortS.need, 7.0)
        // T1: a genuine long sleeper's need exceeds the old fixed 8h (more demanding duration term).
        XCTAssertGreaterThan(longS.need, 8.0)
    }
}
