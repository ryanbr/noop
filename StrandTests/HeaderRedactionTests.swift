import XCTest
@testable import Strand

/// #453: the strap-log HEADER is built from diagnostics lines that never pass through the scrub the log
/// BODY gets as it is appended, so the export sites must redact them themselves.
///
/// Pins the property that matters — a device id embedding a BLE address does not survive into a
/// shareable header — rather than the call sites, which a refactor may legitimately move. It matters now
/// that the header enumerates EVERY paired device: a single-strap install is "my-whoop" and carries no
/// address, but a re-added or second strap is "whoop-<MAC>". Kotlin twin: `HeaderRedactionTest`.
final class HeaderRedactionTests: XCTestCase {

    private let rawMac = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")

    private func containsRawMac(_ s: String) -> Bool {
        rawMac.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func testADeviceIdLineCarryingABLEAddressIsMasked() {
        let line = "  device id=whoop-F1:D4:F7:24:53:DE status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=10m ago"
        let safe = LiveState.redactPii(line)
        XCTAssertFalse(containsRawMac(safe), "raw MAC survived: \(safe)")
    }

    func testTheFunnelsOrphanLineIsMaskedToo() {
        // The line #1620 added prints ids for every id holding samples — the same exposure.
        let line = "(no raw biometric samples under the ACTIVE id 'my-whoop' for this night — they are under "
            + "'whoop-F1:D4:F7:24:53:DE' (4213 rows) instead."
        XCTAssertFalse(containsRawMac(LiveState.redactPii(line)))
    }

    func testAnIdWithNoAddressIsUntouched() {
        let line = "  device id=my-whoop status=ACTIVE brand=WHOOP model=WHOOP 4.0 lastSeen=3h 10m ago"
        XCTAssertEqual(LiveState.redactPii(line), line)
    }
}
