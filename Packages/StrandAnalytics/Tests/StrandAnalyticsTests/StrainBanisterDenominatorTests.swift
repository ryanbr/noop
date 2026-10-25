import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// #1545: Banister TRIMP needs its OWN log-map denominator, and the reason is easy to get wrong.
///
/// `strainDenominator` (7201) is derived from *Edwards'* daily ceiling — top zone weight 5 sustained for
/// 24 h = 7200 — so `ln(7201)/ln(7201) = 1` puts a theoretical maximum day at exactly 100. Banister
/// accumulates on a completely different scale, and its ceiling is **sex-dependent** because the exponent
/// differs. Reusing 7201 would quietly score every Banister day against a ceiling it cannot reach.
///
/// These pin the derivation itself. Whether the method is ever *selected* is a separate question; the
/// arithmetic has to be right first, and it is provable without a device.
final class StrainBanisterDenominatorTests: XCTestCase {

    private let d = 1e-9

    // MARK: - The derivation

    /// Ceiling = 24 h × ΔHRR 1.0 × scale × e^b, stated independently of the implementation, with the
    /// PUBLISHED pair per sex: 0.64 and 1.92 for men, 0.86 and 1.67 for women.
    ///
    /// REPINNED (#2835). The women's line used to read `1440.0 * 0.64 * exp(1.67)`, hardcoding the men's
    /// coefficient against the women's exponent, which is what the implementation did. So this test
    /// agreed with the code because both made the same mistake, and its own doc claimed the ceiling was
    /// "stated independently of the implementation" while restating the implementation's error. An
    /// independent statement means the numbers come from the paper, which is now what these two lines
    /// hold.
    func testTheDailyCeilingIsTwentyFourHoursAtFullReserve() {
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sexF: false)),
                       1440.0 * 0.64 * exp(1.92), accuracy: d)
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sexF: true)),
                       1440.0 * 0.86 * exp(1.67), accuracy: d)
    }

    /// The pair cannot be split, which is the repair #2835 actually asked for. Selecting a sex yields
    /// BOTH of that sex's published coefficients, so the earlier failure, women's exponent with men's
    /// multiplier, is no longer expressible.
    func testEachSexGetsBothOfItsPublishedCoefficients() {
        XCTAssertEqual(StrainScorer.banisterCoefficients(sexF: false).scale, 0.64, accuracy: d)
        XCTAssertEqual(StrainScorer.banisterCoefficients(sexF: false).b, 1.92, accuracy: d)
        XCTAssertEqual(StrainScorer.banisterCoefficients(sexF: true).scale, 0.86, accuracy: d)
        XCTAssertEqual(StrainScorer.banisterCoefficients(sexF: true).b, 1.67, accuracy: d)
        XCTAssertNotEqual(StrainScorer.banisterCoefficients(sexF: true).scale, StrainScorer.banisterCoefficients(sexF: false).scale,
                          "a shared multiplier is the defect this pair exists to prevent")
    }

    /// The denominator is (ceiling MINUS a full day of sedentary baseline) + 1.
    ///
    /// #1545 derived it as ceiling + 1, mirroring how `strainDenominator` came from 7200. #1624 subtracts
    /// the same baseline from the denominator that the scorer subtracts from each day, so both ends of the
    /// axis line up with Edwards: no exertion maps to 0 AND a maximum day still maps to 100. Anchoring one
    /// end only would trade one mismatch for the other.
    func testTheDenominatorIsCeilingMinusBaselinePlusOne() {
        XCTAssertEqual(StrainScorer.logMapDenominator(method: .banister, sex: "male"),
                       StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sexF: false)) -
                        StrainScorer.banisterBaseline(minutes: 24.0 * 60.0, StrainScorer.banisterCoefficients(sexF: false)) + 1.0, accuracy: d)
        XCTAssertEqual(StrainScorer.logMapDenominator(method: .banister, sex: "female"),
                       StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sexF: true)) -
                        StrainScorer.banisterBaseline(minutes: 24.0 * 60.0, StrainScorer.banisterCoefficients(sexF: true)) + 1.0, accuracy: d)
    }

    /// The property the whole derivation exists for: a theoretical maximum day maps to exactly 100 under
    /// EITHER method, so the two are on the same axis and a user switching between them is not silently
    /// rescaled.
    func testAMaximumDayIsOneHundredUnderBothMethods() {
        let edwards = StrainScorer.trimpToStrain(7200, denominator: StrainScorer.strainDenominator)
        XCTAssertEqual(edwards, 100.0, accuracy: 1e-6)

        for sex in ["male", "female"] {
            let c = StrainScorer.banisterCoefficients(sexF: sex == "female")
            // #1624: the quantity that maps to the top is a maximum day's EXCESS over the sedentary
            // baseline, not its raw TRIMP — that is what the scorer now feeds the log map. Feeding the raw
            // ceiling overshoots (100.21), which is the arithmetic working, not breaking.
            let ceiling = StrainScorer.banisterDailyCeiling(c) -
                StrainScorer.banisterBaseline(minutes: 24.0 * 60.0, c)
            let mapped = StrainScorer.trimpToStrain(
                ceiling, denominator: StrainScorer.logMapDenominator(method: .banister, sex: sex))
            XCTAssertEqual(mapped, 100.0, accuracy: 1e-6, "\(sex) ceiling should map to the top of the scale")
        }
    }

    /// Sex matters, and the DIRECTION reversed with #2835, which is worth stating rather than quietly
    /// re-sorting. Under the old single 0.64 the women's smaller exponent alone decided it, so the
    /// women's denominator was the smaller. With the published pair the larger multiplier more than
    /// offsets the smaller exponent (0.86·e^1.67 = 4.57 against 0.64·e^1.92 = 4.36), so it is now the
    /// larger. The point of the test is unchanged: the two are not interchangeable.
    func testTheDenominatorsDifferBySexAndFemaleIsNowTheLarger() {
        let male = StrainScorer.logMapDenominator(method: .banister, sex: "male")
        let female = StrainScorer.logMapDenominator(method: .banister, sex: "female")
        XCTAssertGreaterThan(female, male)
        // "f", "F", "Female" all select it — the same prefix rule the scorer itself uses.
        for spelling in ["f", "F", "Female", "female"] {
            XCTAssertEqual(StrainScorer.logMapDenominator(method: .banister, sex: spelling), female, accuracy: d)
        }
    }

    // MARK: - Why reusing Edwards' denominator would be wrong

    /// The bug this guards against. With 7201 a maximum Banister day lands well short of 100 — nobody
    /// would ever see the top of the scale, and the shortfall differs by sex, so the two would not even
    /// be wrong in the same way.
    func testEdwardsDenominatorWouldCapBanisterBelowFull() {
        // REPINNED from a 90-to-99 band to the exact figures (#2835). The band was chosen when a woman's
        // ceiling was 4,896 and scored 95.66 through 7201; with the published 0.86 it is 6,579 and scores
        // 98.98, which still satisfies `< 99.0` by two hundredths. A bound that survives by a sixtieth of a point
        // is not testing anything, and the next coefficient change would have broken it without any
        // statement of what the right answer is. Exact values also make THIS test catch a wrong
        // coefficient: the old pairing scored 95.66 here, three points away. Pinned exactly rather
        // than with a tolerance because `trimpToStrain` rounds to two decimals, so these ARE the outputs.
        let expected = ["male": 98.47, "female": 98.98]
        for (sex, want) in expected {
            let c = StrainScorer.banisterCoefficients(sexF: sex == "female")
            let wrong = StrainScorer.trimpToStrain(StrainScorer.banisterDailyCeiling(c),
                                                   denominator: StrainScorer.strainDenominator)
            XCTAssertEqual(wrong, want, accuracy: 1e-9,
                           "\(sex): reusing 7201 caps a maximum Banister day here")
            XCTAssertLessThan(wrong, 100.0, "\(sex): nobody would ever see the top of the scale")
        }
    }

    // MARK: - Edwards is untouched

    /// The default is still Edwards and still resolves to 7201, so nothing about existing scores moves.
    func testEdwardsIsUnchangedAndStillTheDefault() {
        XCTAssertEqual(StrainScorer.logMapDenominator(method: .edwards, sex: "male"),
                       StrainScorer.strainDenominator, accuracy: d)
        XCTAssertEqual(StrainScorer.logMapDenominator(method: .edwards, sex: "female"),
                       StrainScorer.strainDenominator, accuracy: d)

        // A real scoring call with no method argument must land on Edwards, byte-for-byte.
        let samples = (0 ..< 900).map { HRSample(ts: $0, bpm: 150) }
        let implicitDefault = StrainScorer.strain(samples, maxHR: 190, restingHR: 60)
        let explicitEdwards = StrainScorer.strain(samples, maxHR: 190, restingHR: 60, method: .edwards)
        XCTAssertNotNil(implicitDefault)
        XCTAssertEqual(implicitDefault!, explicitEdwards!, accuracy: 1e-12)
    }

    // MARK: - The behaviour #1545 asked about

    /// The claim under the request: an intermittent session — hard sets with recovery between — is
    /// scored relatively higher by Banister than by Edwards, because Edwards pays **nothing** below 50%
    /// HRR while Banister's exponential still credits it and weights the peaks far more heavily.
    ///
    /// Compared as a RATIO against a steady moderate session of the same length, because the two methods
    /// have different natural magnitudes and comparing raw scores across them would prove nothing.
    func testIntermittentWorkFaresBetterUnderBanister() {
        // 60 min. Lifting: 30 s at 85% HRR, then 150 s at 40% — repeated. Walking: a flat 58%.
        let rest = 60.0, max = 190.0, reserve = max - rest
        func bpm(_ pctHRR: Double) -> Int { Int((rest + reserve * pctHRR / 100.0).rounded()) }
        var lifting: [HRSample] = [], walking: [HRSample] = []
        for t in 0 ..< 3600 {
            lifting.append(HRSample(ts: t, bpm: (t % 180) < 30 ? bpm(85) : bpm(40)))
            walking.append(HRSample(ts: t, bpm: bpm(58)))
        }

        let liftEd = StrainScorer.strain(lifting, maxHR: max, restingHR: rest, method: .edwards)!
        let walkEd = StrainScorer.strain(walking, maxHR: max, restingHR: rest, method: .edwards)!
        let liftBa = StrainScorer.strain(lifting, maxHR: max, restingHR: rest, method: .banister)!
        let walkBa = StrainScorer.strain(walking, maxHR: max, restingHR: rest, method: .banister)!

        // Edwards: the walk out-scores the lifting outright — exactly the report in #1545.
        XCTAssertGreaterThan(walkEd, liftEd, "Edwards should favour the steady session; that is the complaint")
        // Banister: the lifting session closes the gap substantially.
        XCTAssertGreaterThan(liftBa / walkBa, liftEd / walkEd,
                             "Banister should rate the intermittent session relatively higher")
    }

    /// The mechanism that actually explains #1545, and it is NOT the exponential weighting of peaks.
    ///
    /// Edwards pays **zero** below 50% HRR. A session that sits just under that floor — which is what an
    /// hour of lifting looks like for plenty of people once the sets are averaged against the rests —
    /// scores literally nothing, no matter how long it lasts. Banister has no floor, so the same hour
    /// scores in the same range as a moderate walk.
    ///
    /// This is the difference between "the metric under-rates lifting" and "the metric cannot see it at
    /// all", and it is the one worth showing.
    func testASessionBelowTheFiftyPercentFloorScoresNothingUnderEdwards() {
        let rest = 60.0, max = 190.0
        let bpm = Int((rest + (max - rest) * 0.45).rounded())   // a flat 45% HRR — just under the floor
        let hour = (0 ..< 3600).map { HRSample(ts: $0, bpm: bpm) }

        let edwards = StrainScorer.strain(hour, maxHR: max, restingHR: rest, method: .edwards)
        let banister = StrainScorer.strain(hour, maxHR: max, restingHR: rest, method: .banister)

        XCTAssertEqual(edwards, 0.0, "an hour below the floor earns nothing under Edwards, by design")
        XCTAssertNotNil(banister)
        XCTAssertGreaterThan(banister!, 40.0, "Banister credits the same hour on the 0–100 axis")
    }
}
