import XCTest
@testable import Strand

/// The bond-loop pause (#617/#747) must leave a parked connect behind on the drop that trips it (#1539), and
/// its paused-disconnect line must name the cause that was observed.
///
/// Every trip site runs inside `didDisconnectPeripheral` before that handler sets `state.connected = false`.
/// `standingConnectWhilePausedIfDue(justTripped:)` read `state.connected` synchronously there, saw the dying
/// link as up and parked nothing; the floored re-park in the paused branch then refused too, because the
/// trip had just started the 10-minute floor. A pause tripped with the phone in a pocket stayed stranded
/// until the app was next opened, which is the symptom #1539 was meant to fix. Android never had this: its
/// twin posts the check to the handler, so it runs after the teardown.
@MainActor
final class BondLoopPauseParkingTests: XCTestCase {

    private func drainMainQueue() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private func parked(_ state: LiveState) -> Bool {
        state.log.contains { $0.contains("parking a standing connect") }
    }

    func testATripInsideTheDisconnectHandlerParksOnceTheLinkIsDown() async {
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)
        manager.latchBondLoopPauseForTesting(cause: .droppedAfterPairing(cycles: 2))
        state.connected = true                       // the handler has not torn the link down yet
        manager.standingConnectWhilePausedIfDue(justTripped: true)
        state.connected = false                      // ...and now it has
        await drainMainQueue()
        XCTAssertTrue(parked(state), "the trip must leave a parked connect behind")
    }

    func testNoConnectIsParkedWhileTheLinkReallyStaysUp() async {
        let state = LiveState()
        let manager = BLEManager(state: state, collector: nil)
        manager.latchBondLoopPauseForTesting(cause: .refusedBond)
        state.connected = true
        manager.standingConnectWhilePausedIfDue(justTripped: true)
        await drainMainQueue()
        XCTAssertFalse(parked(state), "a live link needs no parked connect")
    }

    // MARK: Paused-disconnect wording

    func testEachPauseCauseNamesWhatWasObserved() {
        XCTAssertEqual(BondLoopPauseCause.refusedBond.pausedReason, "strap keeps refusing to pair")
        XCTAssertEqual(BondLoopPauseCause.pairingNeverFinished.pausedReason, "pairing never finished")
        XCTAssertEqual(BondLoopPauseCause.droppedAfterPairing(cycles: 2).pausedReason,
                       "the link dropped within seconds of pairing 2 times in a row")
    }

    func testTheDropsAfterPairingNeverClaimARefusal() {
        XCTAssertFalse(BondLoopPauseCause.droppedAfterPairing(cycles: 3).pausedReason.contains("refus"))
    }
}
