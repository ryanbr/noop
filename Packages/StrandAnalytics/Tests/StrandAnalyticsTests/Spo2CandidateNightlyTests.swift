import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// #112 / #103 — the nightly gated mean of the 5/MG SpO2 candidate byte.
///
/// This exists to make a volunteer's contribution checkable. The candidate cannot be promoted while two
/// straps disagree about it, and breaking that tie means a third wearer comparing their nightly figure
/// against the one the WHOOP app reports. Reading it off a scrolling chart is not an instrument; one
/// number is. These pin what that number counts and — more importantly — what it refuses to count.
final class Spo2CandidateNightlyTests: XCTestCase {

    private func session(_ start: Int, _ durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60)
    }

    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }

    func testMeanAndSampleCountOverTheSession() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(1100, 94), aux(1200, 96), aux(1300, 95)])
        XCTAssertEqual(r?.mean, 95)
        XCTAssertEqual(r?.samples, 3)
    }

    /// The count is not decoration: a mean over 3 readings and a mean over 3000 are different evidence,
    /// and a volunteer's correlation built on the first would be worthless.
    func testSampleCountTravelsWithTheMean() {
        let many = (0..<50).map { aux(1000 + $0, 93) }
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateMean([session(900, 600)], aux: many)?.samples, 50)
    }

    /// Out-of-band values are DIAGNOSTIC CODES and SATURATION SENTINELS, not low blood oxygen. Averaging
    /// them in would produce a number that is not a percentage of anything — the single most damaging
    /// thing this helper could do, because it would look plausible.
    func testSubSeventyAndSentinelValuesAreExcluded() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)],
            aux: [aux(1100, 94), aux(1150, 3), aux(1200, 0), aux(1250, 0x80), aux(1300, 96)])
        XCTAssertEqual(r?.mean, 95, "only the two in-band readings may count")
        XCTAssertEqual(r?.samples, 2)
    }

    func testDaytimeSamplesOutsideTheSessionAreExcluded() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(500, 99), aux(1100, 94), aux(5000, 88)])
        XCTAssertEqual(r?.samples, 1)
        XCTAssertEqual(r?.mean, 94)
    }

    func testNilWhenNothingInBandFallsInsideASession() {
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 600)], aux: [aux(1100, 5)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 600)], aux: [aux(9999, 95)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([], aux: [aux(1100, 95)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([session(1000, 600)], aux: []))
    }

    /// A record with no @82 at all is not a zero reading.
    func testMissingBytesAreSkippedNotCountedAsZero() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(1100, nil), aux(1200, 96)])
        XCTAssertEqual(r?.mean, 96)
        XCTAssertEqual(r?.samples, 1)
    }

    /// Found 2026-08-24 on the Oura twin (`nightlySpo2CeilingMean`) and fixed here too — same bug, same
    /// helper shape. `sum / kept` on two `Int`s truncates toward zero; three samples averaging
    /// 97.666... must round to 98, not floor to 97.
    func testMeanRoundsRatherThanFloors() {
        let r = AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(1100, 98), aux(1200, 98), aux(1300, 97)])
        XCTAssertEqual(r?.mean, 98, "97.666... must round to 98, not floor to 97")
    }

    /// The boundaries are inclusive, matching the decoder's own `70...100` emit gate exactly.
    func testBandBoundariesMatchTheDecoderGate() {
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(1100, 70), aux(1200, 100)])?.samples, 2)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean(
            [session(1000, 600)], aux: [aux(1100, 69), aux(1200, 101)]))
    }
}
