import CoreBluetooth
import XCTest
@testable import Strand

/// Pins the ADVERTISEMENT/GATT split: a 16-bit member UUID may appear in an advertisement, but only the
/// 128-bit vendor service exists in GATT, so widening the scan must not widen service discovery.
/// Kotlin twin: `WhoopModelScanUuidTest`.
final class WhoopModelScanServiceTests: XCTestCase {

    private let vendor5 = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    private let sig16 = CBUUID(string: "FD4B")

    func testWhoop4AdvertisementSetIsUnchanged() {
        // The 4.0 gains nothing: its service is not a 16-bit member UUID, and a wider filter would only
        // cost radio time on the overwhelmingly common path.
        XCTAssertEqual(WhoopModel.whoop4.advertisedScanServices, [WhoopModel.whoop4.scanService])
    }

    func testWhoop5AdvertisementSetAddsTheSixteenBitForm() {
        let uuids = WhoopModel.whoop5mg.advertisedScanServices
        XCTAssertEqual(uuids.first, vendor5)   // vendor UUID still first: today's behaviour is a subset
        XCTAssertTrue(uuids.contains(sig16))
        XCTAssertEqual(uuids.count, 2)
    }

    func testTheSixteenBitEntryIsNotTheVendorUuid() {
        // The distinction IS the bug: a band advertising 0xFD4B surfaces as the Bluetooth-base expansion,
        // which does not equal the vendor UUID, so a filter carrying only the vendor UUID never matches it.
        XCTAssertNotEqual(sig16, vendor5)
    }

    func testGattServiceStaysTheVendorUuidAlone() {
        // After connecting, the strap exposes the real 128-bit service. Widening GATT discovery with an
        // advertisement-only UUID would be wrong, not merely redundant.
        XCTAssertEqual(WhoopModel.whoop5mg.scanService, vendor5)
    }
}
