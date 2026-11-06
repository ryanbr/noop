import XCTest
import StrandAnalytics
@testable import Strand

/// The Charge breakdown must report a night's skin temperature once. The scorer's driver list already
/// carries a skin-temperature row whenever the night has a deviation, so the separate relative row is drawn
/// only when that driver is absent. These run the real `RecoveryScorer.chargeDrivers`, so a renamed driver
/// label fails here instead of silently bringing the second row back.
final class ChargeBreakdownSkinTempOnceTests: XCTestCase {

    private var trustedHrvFixture: BaselineState {
        BaselineState(baseline: 55, spread: 12 / 1.253, nValid: 20, nightsSinceUpdate: 0, status: .trusted)
    }

    private func driverRows(skinTempDev: Double?) -> [ChargeDriver] {
        RecoveryScorer.chargeDrivers(hrv: 58, rhr: 54, resp: nil,
                                     hrvBaseline: trustedHrvFixture, rhrBaseline: nil,
                                     respBaseline: nil, sleepPerf: 0.85, skinTempDev: skinTempDev)
    }

    func testANightWithADeviationReportsSkinTemperatureOnlyAsADriverRow() {
        for deviation in [0.4, -0.6, 0.0] {
            let drivers = driverRows(skinTempDev: deviation)
            XCTAssertTrue(drivers.contains { $0.label == ChargeBreakdownSection.skinTempDriverLabel },
                          "The scorer must list skin temperature for a deviation of \(deviation).")
            XCTAssertFalse(ChargeBreakdownSection.showsSeparateSkinTempRow(drivers: drivers),
                           "A deviation of \(deviation) would be printed twice.")
        }
    }

    func testANightWithoutADeviationHasNoSkinTemperatureDriver() {
        let drivers = driverRows(skinTempDev: nil)
        XCTAssertFalse(drivers.contains { $0.label == ChargeBreakdownSection.skinTempDriverLabel })
        XCTAssertTrue(ChargeBreakdownSection.showsSeparateSkinTempRow(drivers: drivers))
    }
}
