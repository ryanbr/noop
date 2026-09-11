import XCTest
import WhoopStore
@testable import Strand

/// #2075: the Live Console must read out the ACTIVE device, not whichever field happens to be populated.
///
/// `LiveState` is one object every live source writes into, so a bonded WHOOP sitting beside a streaming
/// Oura ring leaves every WHOOP-only field truthful-looking while the console is naming the ring. The
/// report was a ring on 93% displaying the strap's 72% under "Oura Ring 5", with a WHOOP pairing pill.
///
/// Mirrors Android `LiveConsoleReadoutTest` case-for-case.
final class LiveConsoleReadoutTests: XCTestCase {

    private func device(_ id: String, _ brand: String) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: "m", nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: [.hr],
                     status: .active, addedAt: 1000, lastSeenAt: 1000)
    }

    // MARK: - activeIsWhoop

    func testAnOuraActiveDeviceIsNotAWhoop() {
        let rows = [device("my-whoop", "WHOOP"), device("oura-123", "Oura")]
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: rows, activeId: "oura-123"))
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: rows, activeId: "my-whoop"))
    }

    func testTheLegacySeededRowIsAWhoopWhateverItsBrandSays() {
        // SourceIdentity's rule: the seeded id counts even if the brand column is blank.
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [device("my-whoop", "")], activeId: "my-whoop"))
    }

    func testAnUnresolvableActiveDeviceStaysWhoopFirst() {
        // Before the registry opens, the console already names "WHOOP"; the gate must agree rather than
        // blanking a working strap's readouts on a cold start.
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [], activeId: nil))
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [], activeId: "oura-123"))
    }

    func testBrandMatchingIsCaseInsensitive() {
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [device("w1", "whoop")], activeId: "w1"))
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: [device("o1", "OURA")], activeId: "o1"))
    }

    // MARK: - batteryPercent

    func testAWhoopActiveDeviceShowsTheStrapCharge() {
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.4, ringPct: 93), 72)
    }

    /// ROUNDS, it does not truncate. The surfaces this seam replaced disagreed: Devices and the widget
    /// rounded, the Live Console truncated. Folding them onto a truncating seam would have quietly moved
    /// five readouts down by a point, which is the kind of change nobody reports and everyone notices.
    func testTheChargeIsRoundedNotTruncated() {
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.6, ringPct: nil), 73)
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.4, ringPct: nil), 72)
        // The exact half goes up, matching Kotlin's Math.round over a positive percentage.
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 72.5, ringPct: nil), 73)
        XCTAssertEqual(LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: 99.7, ringPct: nil), 100)
    }

    func testARingActiveDeviceShowsTheRingCharge() {
        // The reported numbers exactly: ring 93, strap 72.40, console showed 72.
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: false, whoopPct: 72.4, ringPct: 93), 93)
    }

    func testARingActiveDeviceNeverFallsBackToTheStrapCharge() {
        // The heart of it. Nothing is the honest answer; the strap's number under the ring's name is a
        // confident lie, and is the bug.
        XCTAssertNil(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: false, whoopPct: 72.4, ringPct: nil))
    }

    /// The Devices list asks this PER ROW rather than of the active
    /// device, which is the stronger question there because the row itself is in hand. Composed here so
    /// the two halves are pinned together the way the screen actually uses them.
    /// Calls `SourceIdentity.isWhoop` directly, where the screens call `SourceCoordinator.isWhoop`.
    /// That wrapper is main-actor isolated, so a synchronous test cannot reach it, and it delegates to
    /// this verbatim with no logic of its own — so the behaviour under test is the same one.
    func testARingRowShowsTheRingChargeEvenWhenTheStrapReportedOne() {
        let ring = device("oura-123", "Oura")
        let strap = device("my-whoop", "WHOOP")
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: SourceIdentity.isWhoop(ring),
                                              whoopPct: 72.4, ringPct: 93), 93)
        XCTAssertEqual(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: SourceIdentity.isWhoop(strap),
                                              whoopPct: 72.4, ringPct: 93), 72)
    }

    func testAWhoopActiveDeviceIgnoresAnyRingCharge() {
        // Symmetry: a ring that reported earlier must not leak into a strap's readout either.
        XCTAssertNil(
            LiveConsoleReadout.batteryPercent(activeIsWhoop: true, whoopPct: nil, ringPct: 93))
    }
}
