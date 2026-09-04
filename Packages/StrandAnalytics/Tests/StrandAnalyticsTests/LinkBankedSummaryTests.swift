import XCTest
@testable import StrandAnalytics

/// #1635: the per-link banked-rows line, the database-side companion to `linkEpitaph`.
///
/// Byte-identical twin of the Kotlin `LinkBankedSummaryTest`. The case it exists for: an unbonded 5/MG
/// streams heart rate and R-R over the standard profile while every bond-gated stream banks nothing, and
/// the epitaph reports that link as hundreds of healthy inbound frames.
final class LinkBankedSummaryTests: XCTestCase {

    func testNamesTheStreamsThatBankedNothingWhenOthersDid() {
        let line = ConnectionReadout.linkBankedSummary(
            hr: 456, rr: 187, gravity: 0, resp: 0, skinTemp: 0, spo2: 0, steps: 0, battery: 2)
        XCTAssertTrue(line.contains("hr=456"))
        XCTAssertTrue(line.contains("gravity=0"))
        XCTAssertTrue(line.contains("nothing banked live for: gravity, resp, skinTemp, spo2, steps"))
    }

    func testAFullyHealthyLinkGetsNoCallOut() {
        let line = ConnectionReadout.linkBankedSummary(
            hr: 400, rr: 380, gravity: 900, resp: 900, skinTemp: 900, spo2: 900, steps: 12, battery: 3)
        XCTAssertTrue(line.hasPrefix("banked live this link:"))
        XCTAssertFalse(line.contains("nothing banked live for"))
    }

    func testALinkThatStoredNothingSaysSoOnce() {
        let line = ConnectionReadout.linkBankedSummary(
            hr: 0, rr: 0, gravity: 0, resp: 0, skinTemp: 0, spo2: 0, steps: 0, battery: 0)
        XCTAssertTrue(line.contains("NOTHING was stored from the live streams"))
        XCTAssertFalse(line.contains("nothing banked live for"))
    }

    func testNegativeCountsCannotLeakIntoADiagnostic() {
        let line = ConnectionReadout.linkBankedSummary(
            hr: -5, rr: 1, gravity: 0, resp: 0, skinTemp: 0, spo2: 0, steps: 0, battery: 0)
        XCTAssertTrue(line.contains("hr=0"))
        XCTAssertFalse(line.contains("-5"))
    }

    /// The two platforms must produce the SAME sentence, since a report may come from either.
    func testTheExactSentenceForTheFieldCase() {
        XCTAssertEqual(
            ConnectionReadout.linkBankedSummary(
                hr: 456, rr: 187, gravity: 0, resp: 0, skinTemp: 0, spo2: 0, steps: 0, battery: 2),
            "banked live this link: hr=456 rr=187 gravity=0 resp=0 skinTemp=0 spo2=0 steps=0 battery=2"
                + " - nothing banked live for: gravity, resp, skinTemp, spo2, steps")
    }


    /// Apple's store does not return a step count, so the line must omit steps rather than print zero.
    func testAStreamThisPlatformCannotMeasureIsOmittedNotZero() {
        let line = ConnectionReadout.linkBankedSummary(
            hr: 456, rr: 187, gravity: 0, resp: 0, skinTemp: 0, spo2: 0, steps: nil, battery: 2)
        XCTAssertFalse(line.contains("steps"), "an unmeasured stream must not appear at all")
        XCTAssertTrue(line.contains("nothing banked live for: gravity, resp, skinTemp, spo2"))
    }
}
