import XCTest
@testable import WhoopStore

final class WhoopLiveCapabilitiesTests: XCTestCase {

    func testBaseExcludesCalibratedSpo2() {
        XCTAssertFalse(WhoopLiveCapabilities.base.contains(.spo2))
        XCTAssertEqual(
            WhoopLiveCapabilities.base,
            [.hr, .hrv, .skinTemp, .sleep, .strainLoad]
        )
    }

    func testFourPointOhHasNoSteps() {
        let caps = WhoopLiveCapabilities.metrics(forModel: "4.0")
        XCTAssertFalse(caps.contains(.steps))
        XCTAssertFalse(caps.contains(.spo2))
        XCTAssertTrue(caps.contains(.hr))
    }

    func testFiveAndMGIncludeSteps() {
        for model in ["5.0 MG", "WHOOP 5.0", "MG", "whoop5"] {
            let caps = WhoopLiveCapabilities.metrics(forModel: model)
            XCTAssertTrue(caps.contains(.steps), model)
            XCTAssertFalse(caps.contains(.spo2), model)
        }
    }

    func testEncodedIsSortedAndStable() {
        XCTAssertEqual(
            WhoopLiveCapabilities.encoded(forModel: "4.0"),
            "hr,hrv,skinTemp,sleep,strainLoad"
        )
        XCTAssertEqual(
            WhoopLiveCapabilities.encoded(forModel: "5.0 MG"),
            "hr,hrv,skinTemp,sleep,steps,strainLoad"
        )
    }

    func testStripSpo2TokenHandlesPositions() {
        XCTAssertEqual(
            WhoopLiveCapabilities.stripSpo2Token(fromEncoded: "hr,hrv,spo2,skinTemp,sleep,strainLoad"),
            "hr,hrv,skinTemp,sleep,strainLoad"
        )
        XCTAssertEqual(
            WhoopLiveCapabilities.stripSpo2Token(fromEncoded: "spo2,hr"),
            "hr"
        )
        XCTAssertEqual(
            WhoopLiveCapabilities.stripSpo2Token(fromEncoded: "hr,spo2"),
            "hr"
        )
        XCTAssertEqual(
            WhoopLiveCapabilities.stripSpo2Token(fromEncoded: "hr,hrv,skinTemp"),
            "hr,hrv,skinTemp"
        )
    }

    func testWithoutCalibratedSpo2() {
        let raw: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp]
        XCTAssertEqual(
            WhoopLiveCapabilities.withoutCalibratedSpo2(raw),
            [.hr, .hrv, .skinTemp]
        )
    }
}
