import XCTest
@testable import Strand

/// The per-device key behind the ECG "may be running" latch.
///
/// The latch is persisted because the strap's state is: a capture keeps generating across an app kill,
/// and iOS kills this app in the background routinely. What these pin is the part that is pure and
/// therefore testable without a CoreBluetooth seam. The latch's own read and write are exercised only
/// by a real session.
final class EcgRunningLatchKeyTests: XCTestCase {

    /// Two straps must not share a latch. A per-install key would claim the SECOND strap may be
    /// generating after a capture that only ever ran on the first, which is the whole reason the device
    /// id is in the key at all.
    func testTwoDevicesGetDifferentKeys() {
        let a = BLEManager.ecgRunningKey("whoop-AAAA")
        let b = BLEManager.ecgRunningKey("whoop-BBBB")
        XCTAssertNotEqual(a, b)
    }

    /// Same device, same key, every time: the latch has to be findable on the NEXT launch, which is the
    /// launch that matters.
    func testTheKeyIsStableForOneDevice() {
        XCTAssertEqual(BLEManager.ecgRunningKey("my-whoop"), BLEManager.ecgRunningKey("my-whoop"))
    }

    /// Namespaced, and carrying the id. A bare id would collide with any other per-device default this
    /// app stores under the same name.
    func testTheKeyIsNamespacedAndCarriesTheDeviceId() {
        let key = BLEManager.ecgRunningKey("my-whoop")
        XCTAssertTrue(key.hasPrefix("noopEcgMayBeRunning."), key)
        XCTAssertTrue(key.hasSuffix("my-whoop"), key)
        XCTAssertNotEqual(key, "my-whoop")
    }

    /// The legacy single-strap id is not special-cased. It was worth pinning: "my-whoop" is the seeded
    /// id on every single-WHOOP install, so if any shortcut ever treated it as the shared/global case
    /// the two-strap bug would come straight back for the majority of installs.
    func testTheSeededSingleStrapIdIsKeyedLikeAnyOther() {
        XCTAssertEqual(BLEManager.ecgRunningKey("my-whoop"), "noopEcgMayBeRunning.my-whoop")
        XCTAssertNotEqual(BLEManager.ecgRunningKey("my-whoop"), BLEManager.ecgRunningKey("whoop-1234"))
    }
}
