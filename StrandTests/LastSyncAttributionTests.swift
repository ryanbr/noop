import XCTest
@testable import Strand

/// Pins last-sync attribution. Kotlin twin: `LastSyncAttributionTest`.
///
/// Reported three times before it was believed, which is the part worth keeping: the number was
/// plausible, so the reading was treated as mistaken rather than the label. The capture had
/// "Last sync: 4d ago" beside zero banked rows for the active 5/MG, and a 4.0 last seen three days
/// earlier — the timestamp on the 5/MG's screen belonged to the other strap.
final class LastSyncAttributionTests: XCTestCase {

    func testThisStrapsOwnStampAlwaysWins() {
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 500, legacyGlobal: 900, pairedCount: 1), 500)
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 500, legacyGlobal: 900, pairedCount: 3), 500)
    }

    /// The single-strap upgrade path. The global key is unattributed, but with one strap paired there is
    /// only one strap it can have come from — so it reads correctly across the upgrade instead of
    /// resetting to "never" for everyone.
    func testTheLegacyGlobalIsHonouredOnlyWhenOneStrapCouldHaveWrittenIt() {
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 1), 900)
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 2))
    }

    /// THE case from the capture. Two straps, and the active one has never synced: the honest answer is
    /// "never", not the other strap's timestamp. Not a degraded answer — the correct one.
    func testAStrapThatHasNeverSyncedSaysSoEvenWhenAnotherHas() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 1_787_000_000, pairedCount: 2))
    }

    /// Zero is "never recorded", not a timestamp — the defaults API returns 0.0 for a missing Double, so
    /// treating it as a value would date every strap to 1970.
    func testZeroAndNilAreBothAbsent() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: 0, legacyGlobal: 0, pairedCount: 1))
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: nil, pairedCount: 1))
        XCTAssertEqual(LastSyncAttribution.resolve(perDevice: 0, legacyGlobal: 900, pairedCount: 1), 900)
    }

    /// A zero-paired registry must not license the global. The count is the evidence that exactly one
    /// strap could have written it; "no straps" is not that evidence, and treating it as such would let a
    /// failed registry read resurrect the bug.
    func testAnEmptyRegistryDoesNotLicenseTheGlobal() {
        XCTAssertNil(LastSyncAttribution.resolve(perDevice: nil, legacyGlobal: 900, pairedCount: 0))
    }

    func testThePrefKeyIsPerDeviceAndCaseInsensitive() {
        XCTAssertEqual(LastSyncAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"),
                       "noop.lastSyncAt.f1:d4:f7:24:53:de")
        XCTAssertEqual(LastSyncAttribution.prefKey(peripheralId: "f1:d4:f7:24:53:de"),
                       LastSyncAttribution.prefKey(peripheralId: "F1:D4:F7:24:53:DE"))
        XCTAssertNil(LastSyncAttribution.prefKey(peripheralId: nil))
        XCTAssertNil(LastSyncAttribution.prefKey(peripheralId: "   "))
    }

    /// It must not collide with the firmware key, which is built the same way from the same identifier.
    func testItDoesNotCollideWithTheFirmwareKeyForTheSameStrap() {
        let id = "f1:d4:f7:24:53:de"
        XCTAssertNotEqual(LastSyncAttribution.prefKey(peripheralId: id),
                          FirmwareAttribution.prefKey(peripheralId: id))
    }

    /// The #57 write-health pair had the identical defect one line below in the same capture: "rows last
    /// landed 4d ago" against a strap whose own row count was zero. Both halves are scoped, because they
    /// are read as a pair — "stalled more recently than ok" is the alarm — and scoping only one would
    /// compare this strap's stall against another strap's success.
    func testTheWriteHealthPairIsScopedAndItsHalvesStayDistinct() {
        let id = "f1:d4:f7:24:53:de"
        XCTAssertEqual(LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteOkAt"),
                       "sync.lastWriteOkAt.f1:d4:f7:24:53:de")
        XCTAssertNotEqual(LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteOkAt"),
                          LastSyncAttribution.writeHealthPrefKey(peripheralId: id, kind: "lastWriteStalledAt"))
        XCTAssertNil(LastSyncAttribution.writeHealthPrefKey(peripheralId: nil, kind: "lastWriteOkAt"))
        XCTAssertNil(LastSyncAttribution.writeHealthPrefKey(peripheralId: "  ", kind: "lastWriteOkAt"))
    }

    /// Two straps must never share a write-health key, or one strap's successful offload would clear the
    /// alarm raised by another strap's stall.
    func testTwoStrapsGetDifferentWriteHealthKeys() {
        XCTAssertNotEqual(
            LastSyncAttribution.writeHealthPrefKey(peripheralId: "aa:bb:cc:dd:ee:ff", kind: "lastWriteOkAt"),
            LastSyncAttribution.writeHealthPrefKey(peripheralId: "ff:ee:dd:cc:bb:aa", kind: "lastWriteOkAt"))
    }
}
