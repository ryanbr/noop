import XCTest
@testable import Strand

/// Pins the banked-sleep heal's device SCOPE (#1248). The `#899` overlap heal used to read/dedupe/delete
/// only under `computedId`, so a live source that banks its OWN hypnogram under its OWN device id (an Oura
/// ring) was never healed — and those un-collapsed rows were re-read as `providedSleep` and re-detected
/// every pass, ballooning one night to 14 stored rows / 9 phantom "naps". `healDeviceIds` is the pure set
/// of ids the heal now sweeps; tested directly. Mirrors the Android `healDeviceIds` so the two platforms
/// heal the same device ids.
@MainActor
final class IntelligenceHealDeviceScopeTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testRingIdIsInScope_theBug() {
        // The exact #1248 shape: a WHOOP is primary (computed under "my-whoop-noop") and an Oura ring
        // banks its own hypnogram under "oura-2H3B". The ring id MUST be swept, or its drift-duped
        // hypnograms survive forever.
        let ids = IE.healDeviceIds(computedId: "my-whoop-noop", registeredIds: ["my-whoop", "oura-2H3B"])
        XCTAssertEqual(ids, ["my-whoop", "my-whoop-noop", "oura-2H3B"])
        XCTAssertTrue(ids.contains("oura-2H3B"), "the ring id the computedId-only heal missed")
    }

    func testComputedIdAlwaysPresent_evenWithNoRegisteredDevices() {
        // A BLE-only install with an empty registry still heals its computed rows (the prior behaviour).
        XCTAssertEqual(IE.healDeviceIds(computedId: "my-whoop-noop", registeredIds: []), ["my-whoop-noop"])
    }

    func testDeDuplicatesAndSortsDeterministically() {
        // computedId can also appear in the registry list; the union de-dups and sorts so the sweep order
        // is stable across runs and matches Kotlin's toSortedSet().
        let ids = IE.healDeviceIds(computedId: "b-noop", registeredIds: ["oura-1", "b-noop", "a-whoop"])
        XCTAssertEqual(ids, ["a-whoop", "b-noop", "oura-1"])
    }
}
