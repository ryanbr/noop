import XCTest
@testable import Strand

/// The fourth appearance of one defect, after `FirmwareAttribution`, `LastSyncAttribution.resolve` and
/// `writeHealthPrefKey`. What makes this one worse is that the global reading feeds a VERDICT: the alarm
/// section does not merely print a timestamp, it concludes "alarm unreliable" from it.
///
/// The field capture said "Strap clock: 20d behind wall (reset/stale — alarm unreliable)" for an active
/// 5/MG whose own header two lines up said "Last sync: never (this strap)" and "no history rows ever
/// persisted". A strap that has banked nothing cannot be 20 days stale; the 20 days belonged to the paired
/// 4.0, last seen exactly 20 days earlier. The same strap's own alarm readback said 2045, ahead of the wall
/// clock rather than behind it, so the two lines disagreed in direction as well as value.
///
/// Twin of Kotlin `StrapClockAttributionTest`.
final class StrapClockAttributionTests: XCTestCase {

    func testAStrapsOwnRangeReplyAlwaysWins() {
        XCTAssertEqual(LastSyncAttribution.resolveStrapClockTs(perDevice: 500, legacyGlobal: 900, pairedCount: 1), 500)
        XCTAssertEqual(LastSyncAttribution.resolveStrapClockTs(perDevice: 500, legacyGlobal: 900, pairedCount: 3), 500)
    }

    /// The single-strap upgrade path: unattributed, but only one strap can have written it.
    func testTheLegacyGlobalIsTrustworthyOnlyWithOneStrapPaired() {
        XCTAssertEqual(LastSyncAttribution.resolveStrapClockTs(perDevice: nil, legacyGlobal: 900, pairedCount: 1), 900)
        XCTAssertNil(LastSyncAttribution.resolveStrapClockTs(perDevice: nil, legacyGlobal: 900, pairedCount: 2))
    }

    /// THE case from the capture. The verdict is withheld rather than borrowed: for a strap that has never
    /// answered a range reply, "not known" is correct and "20d stale, alarm unreliable" is an accusation
    /// sourced from another strap.
    func testAnActiveStrapWithNoRangeReplyOfItsOwnBorrowsNoVerdict() {
        XCTAssertNil(LastSyncAttribution.resolveStrapClockTs(perDevice: nil, legacyGlobal: 1_787_000_000, pairedCount: 2))
    }

    func testANonPositiveStampIsNoStamp() {
        XCTAssertNil(LastSyncAttribution.resolveStrapClockTs(perDevice: 0, legacyGlobal: 0, pairedCount: 1))
        XCTAssertNil(LastSyncAttribution.resolveStrapClockTs(perDevice: -1, legacyGlobal: -1, pairedCount: 1))
        XCTAssertEqual(LastSyncAttribution.resolveStrapClockTs(perDevice: -1, legacyGlobal: 900, pairedCount: 1), 900)
    }

    /// Keyed on the peripheral identifier, lowercased, blank-rejecting, exactly as `prefKey` is.
    func testTheKeyIsPerPeripheralLowercasedAndRefusesABlank() {
        XCTAssertEqual(LastSyncAttribution.strapClockPrefKey(peripheralId: "AA-BB-CC"), "strap.newestRecordTs.aa-bb-cc")
        XCTAssertEqual(LastSyncAttribution.strapClockPrefKey(peripheralId: "  aa-bb-cc  "), "strap.newestRecordTs.aa-bb-cc")
        XCTAssertNil(LastSyncAttribution.strapClockPrefKey(peripheralId: nil))
        XCTAssertNil(LastSyncAttribution.strapClockPrefKey(peripheralId: "   "))
    }

    /// It must not collide with the legacy global key, or the fix would overwrite what it falls back to.
    func testThePerDeviceKeyIsDistinctFromTheLegacyGlobal() {
        XCTAssertNotEqual(LastSyncAttribution.strapClockPrefKey(peripheralId: "aa-bb-cc"), "strap.newestRecordTs")
    }
}
