import XCTest
@testable import Strand

final class BLEStartupGateTests: XCTestCase {
    @MainActor
    func testInactiveDeviceSeedPrecedesBothStartupCallbacks() async {
        let gate = BLEStartupGate()
        var releaseStore: CheckedContinuation<Void, Never>?
        var opens = 0
        var allowed = true // The launch default, before the persisted ring selection is read.
        var gateReads = 0
        var actions: [String] = []
        let prepare: @MainActor () async -> Bool = {
            opens += 1
            await withCheckedContinuation { releaseStore = $0 }
            allowed = false
            return true
        }
        let check: @MainActor () -> Bool = { gateReads += 1; return allowed }
        let poweredOn = Task { @MainActor in
            await gate.resume(prepare: prepare, radioIsPoweredOn: { true }, onRefusal: { _ in XCTFail("Unexpected startup refusal") }, isAllowed: check) { actions.append("connect") }
        }
        while releaseStore == nil { await Task.yield() }
        var secondEntered = false
        let restored = Task { @MainActor in
            secondEntered = true
            await gate.resume(prepare: prepare, radioIsPoweredOn: { true }, onRefusal: { _ in XCTFail("Unexpected startup refusal") }, isAllowed: check) { actions.append("discover") }
        }
        // Let the second callback enter the shared preparation while the first is suspended.
        while !secondEntered { await Task.yield() }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(gateReads, 0)
        XCTAssertTrue(actions.isEmpty)
        releaseStore?.resume()
        await poweredOn.value
        await restored.value
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(gateReads, 2)
        XCTAssertTrue(actions.isEmpty, "An inactive WHOOP must neither reconnect nor discover services")
    }

    @MainActor
    func testSelectedWhoopResumesAfterStoreIsReady() async {
        let gate = BLEStartupGate()
        var order: [String] = []
        await gate.resume(prepare: { order.append("store"); return true }, radioIsPoweredOn: { true }, onRefusal: { _ in XCTFail("Unexpected startup refusal") }, isAllowed: {
            order.append("gate")
            return true
        }) { order.append("discover") }
        XCTAssertEqual(order, ["store", "gate", "discover"])
    }

    @MainActor
    func testFailedStoreDoesNotConsultDefaultGateAndCanRetryOnUnlock() async {
        let gate = BLEStartupGate()
        var reads = 0
        var actions = 0
        var refusals: [BLEStartupGate.Refusal] = []
        await gate.resume(prepare: { false }, radioIsPoweredOn: { XCTFail("Radio read before store readiness"); return true }, onRefusal: { refusals.append($0) }, isAllowed: { reads += 1; return true }) { actions += 1 }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(refusals, [.storeNotReady])
        await gate.resume(prepare: { true }, radioIsPoweredOn: { true }, onRefusal: { _ in XCTFail("Unexpected startup refusal") }, isAllowed: { reads += 1; return true }) { actions += 1 }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(actions, 1)
    }

    @MainActor
    func testRadioChangeDuringStoreOpenIsCheckedAfterAwait() async {
        let gate = BLEStartupGate()
        var releaseStore: CheckedContinuation<Void, Never>?
        var radioReady = true
        var refusals: [BLEStartupGate.Refusal] = []
        var actions = 0
        let startup = Task { @MainActor in
            await gate.resume(prepare: {
                await withCheckedContinuation { releaseStore = $0 }
                return true
            }, radioIsPoweredOn: { radioReady }, onRefusal: { refusals.append($0) }, isAllowed: { XCTFail("Policy read after radio changed"); return true }) { actions += 1 }
        }
        while releaseStore == nil { await Task.yield() }
        radioReady = false
        releaseStore?.resume()
        await startup.value
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(refusals, [.radioNotPoweredOn])
    }
    @MainActor
    func testRadioRefusalNamesReasonWithoutReadingDevicePolicy() async {
        let gate = BLEStartupGate()
        var refusals: [BLEStartupGate.Refusal] = []
        await gate.resume(prepare: { true }, radioIsPoweredOn: { false },
                          onRefusal: { refusals.append($0) },
                          isAllowed: { XCTFail("Device policy read with radio unavailable"); return true },
                          action: { XCTFail("Startup ran with radio unavailable") })
        XCTAssertEqual(refusals, [.radioNotPoweredOn])
    }

}
