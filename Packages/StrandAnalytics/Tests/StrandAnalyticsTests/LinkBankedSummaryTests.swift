import XCTest
@testable import StrandAnalytics

/// #1635: the per-link banked line, split by PATH. Byte-identical twin of the Kotlin
/// `LinkBankedSummaryTest`, including the exact sentences.
///
/// The split is by path rather than by stream because the realtime decoder yields only
/// hr/rr/events/battery — gravity, respiratory, skin temperature, SpO2 and steps arrive solely through
/// the offload. An earlier live-only version named those five as empty on EVERY link, bonded or not.
final class LinkBankedSummaryTests: XCTestCase {

    private func line(liveHr: Int = 0, liveRr: Int = 0, oHr: Int = 0, oRr: Int = 0, oGrav: Int = 0,
                      oResp: Int = 0, oSkin: Int = 0, oSpo2: Int = 0, oSteps: Int? = 0) -> String {
        ConnectionReadout.linkBankedSummary(
            liveHr: liveHr, liveRr: liveRr, offloadHr: oHr, offloadRr: oRr, offloadGravity: oGrav,
            offloadResp: oResp, offloadSkinTemp: oSkin, offloadSpo2: oSpo2, offloadSteps: oSteps)
    }

    func testAnUnbondedStrapReadsLiveTrafficWithAnOffloadThatNeverRan() {
        XCTAssertEqual(
            line(liveHr: 12, liveRr: 7),
            "banked this link: live hr=12 rr=7 | offload none - the offload banked NOTHING on this link")
    }

    func testAHealthySyncReadsCompletelyDifferently() {
        let healthy = line(liveHr: 3, liveRr: 2, oHr: 1200, oRr: 2400, oGrav: 8000,
                           oResp: 8000, oSkin: 8000, oSpo2: 8000, oSteps: 40)
        XCTAssertEqual(healthy,
            "banked this link: live hr=3 rr=2 | offload hr=1200 rr=2400 gravity=8000 resp=8000"
                + " skinTemp=8000 spo2=8000 steps=40")
        XCTAssertFalse(healthy.contains("nothing banked"))
    }

    func testAPartialOffloadNamesOnlyTheStreamsThatStayedEmpty() {
        let l = line(liveHr: 1, oHr: 500, oRr: 900, oGrav: 0, oResp: 0, oSkin: 700, oSpo2: 700)
        XCTAssertTrue(l.contains("nothing banked from the offload for: gravity, resp, steps"))
    }

    func testAStreamThisPlatformCannotMeasureIsOmittedNotZero() {
        XCTAssertFalse(line(liveHr: 5, oHr: 10, oSteps: nil).contains("steps"))
    }

    func testBatteryNeverAppearsOnEitherPath() {
        XCTAssertFalse(line(liveHr: 9, oHr: 9).contains("battery"))
    }

    func testNegativeCountsCannotLeakIntoADiagnostic() {
        let l = line(liveHr: -5, liveRr: 1, oHr: -3, oGrav: 4)
        XCTAssertTrue(l.contains("live hr=0 rr=1"))
        XCTAssertFalse(l.contains("-3"))
    }
}
