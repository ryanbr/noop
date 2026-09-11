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

    /// #1303: once a strap ADOPTS its serial the device id IS the serial, and this header enumerates every
    /// paired device. Neither older rule covers that shape — the MAC rule wants MAC form, the serial rule
    /// wants the literal "WHOOP " then a digit — so before this the header leaked it verbatim.
    func testAnAdoptedSerialIdIsMasked() {
        let line = "  device id=whoop-MGB1234567 status=ACTIVE brand=WHOOP model=5.0 MG lastSeen=1h ago"
        let safe = LiveState.redactPii(line)
        XCTAssertFalse(safe.contains("1234567"), "serial survived: \(safe)")
        XCTAssertTrue(safe.contains("whoop-MGB…"), "three-character prefix should remain: \(safe)")
    }

    /// The `-noop` suffix is not identifying and is what separates derived rows from measured ones in the
    /// per-source counts, so it must survive the mask that hides the serial in front of it.
    func testTheComputedSiblingMarkerSurvives() {
        XCTAssertEqual(LiveState.redactPii("Days: whoop-MGB1234567-noop=25"), "Days: whoop-MGB…-noop=25")
    }

    /// Anything too short to be accepted as a serial upstream must not be masked as one here either.
    func testAnIdTooShortToBeASerialIsUntouched() {
        XCTAssertEqual(LiveState.redactPii("id=whoop-ABCDE"), "id=whoop-ABCDE")
    }

    func testAnIdWithNoAddressIsUntouched() {
        let line = "  device id=my-whoop status=ACTIVE brand=WHOOP model=WHOOP 4.0 lastSeen=3h 10m ago"
        XCTAssertEqual(LiveState.redactPii(line), line)
    }

    /// #2092: the same gap as #1303 above, for the OTHER brand. An Oura ring's adopted id is
    /// `oura-<serial>`, and none of the WHOOP-shaped rules match a different literal prefix, so this
    /// header line leaked the ring's serial verbatim until the twin `oura-` rule was added.
    func testAnAdoptedOuraSerialIdIsMasked() {
        let line = "  device id=oura-2H3B2405003655 status=ACTIVE brand=Oura model=Oura Ring 3 lastSeen=1h ago"
        let safe = LiveState.redactPii(line)
        XCTAssertFalse(safe.contains("2405003655"), "serial survived: \(safe)")
        XCTAssertTrue(safe.contains("oura-2H3…"), "three-character prefix should remain: \(safe)")
    }

    /// The `-noop` computed-sibling suffix is brand-agnostic (`DeviceRegistryStore.computedSuffix`), so
    /// it must survive the Oura mask exactly as it does the WHOOP one.
    func testTheComputedSiblingMarkerSurvivesForOuraToo() {
        XCTAssertEqual(LiveState.redactPii("Days: oura-2H3B2405003655-noop=25"), "Days: oura-2H3…-noop=25")
    }

    /// An all-digit serial (this repo's own #2075/#2090 evidence: "2038082631034041") must mask the same
    /// as an alphanumeric one — the rule keys on the "oura-" prefix, not on the serial containing a letter.
    func testAnAllDigitOuraSerialIsMaskedToo() {
        let line = "adopted stable serial id oura-2038082631034041 (was oura-5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148)"
        let safe = LiveState.redactPii(line)
        XCTAssertFalse(safe.contains("2038082631034041"), "serial survived: \(safe)")
        XCTAssertTrue(safe.contains("oura-203…"), "three-character prefix should remain: \(safe)")
        // The PROVISIONAL id in the same line is a CB-UUID, already caught by the earlier UUID rule.
        XCTAssertFalse(safe.contains("5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148"), "provisional UUID survived: \(safe)")
    }

    func testAnIdTooShortToBeAnOuraSerialIsUntouched() {
        XCTAssertEqual(LiveState.redactPii("id=oura-ABCDE"), "id=oura-ABCDE")
    }
}
