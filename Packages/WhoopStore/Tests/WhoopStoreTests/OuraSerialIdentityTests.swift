import XCTest
@testable import WhoopStore

final class OuraSerialIdentityTests: XCTestCase {
    func testLogSafeNeverLeaksTheFullSerial() {
        XCTAssertEqual(OuraSerialIdentity.logSafe(serial: "2H3B2405003655"), "2H3…")
        XCTAssertEqual(OuraSerialIdentity.logSafe(serial: "2038082631034041"), "203…")
        XCTAssertEqual(OuraSerialIdentity.logSafe(serial: nil), "?")
        XCTAssertEqual(OuraSerialIdentity.logSafe(serial: "  "), "?")
        XCTAssertFalse(OuraSerialIdentity.logSafe(serial: "2H3B2405003655").contains("2405003655"))
    }

    func testLogSafeUppercasesAndTrims() {
        XCTAssertEqual(OuraSerialIdentity.logSafe(serial: "  2h3b2405003655  "), "2H3…")
    }

    func testIdPrefixMatchesTheBrandCatalog() {
        XCTAssertEqual(OuraSerialIdentity.idPrefix, "oura")
    }
}
